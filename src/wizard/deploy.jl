function print_build_tarballs(io::IO, state::WizardState)
    urlhashes = zip(state.source_urls, state.source_hashes)
    sources_string = join(map(urlhashes) do x
        string(repr(x[1])," =>\n    ", repr(x[2]), ",\n")
    end,"\n    ")
    platforms_string = join(state.platforms,",\n    ")

    stuff = collect(zip(state.files, state.file_kinds, state.file_varnames))
    products_string = join(map(stuff) do x
        file, kind, varname = x
        
        if kind == :executable
            # It's very common that executable products are in `bin`,
            # so we special-case these to just print the basename:
            dir_path = dirname(file)
            if isempty(dir_path) || dirname(file) == "bin"
                return "ExecutableProduct($(repr(basename(file))), $(repr(varname)))"
            else
                return "ExecutableProduct($(repr(basename(file))), $(repr(varname)); dir_path=$(repr(dir_path)))"
            end
        elseif kind == :library
            # Normalize library names, since they are almost always in `lib`/`bin`
            return "LibraryProduct($(repr(normalize_name(file))), $(repr(varname)))"
        else
            return "FileProduct($(repr(file)), $(repr(varname)))"
        end
    end,",\n    ")

    deps = something(state.dependencies, String[])
    dependencies_string = join(string.("\"", deps, "\",\n"), "\n    ")

    println(io, """
    # Note that this script can accept some limited command-line arguments, run
    # `julia build_tarballs.jl --help` to see a usage message.
    using BinaryBuilder

    name = $(repr(state.name))
    version = $(repr(state.version))

    # Collection of sources required to complete build
    sources = [
        $(sources_string)
    ]

    # Bash recipe for building across all platforms
    script = raw\"\"\"
    $(state.history)
    \"\"\"

    # These are the platforms we will build for by default, unless further
    # platforms are passed in on the command line
    platforms = [
        $(platforms_string)
    ]

    # The products that we will ensure are always built
    products = [
        $(products_string)
    ]

    # Dependencies that must be installed before this package can be built
    dependencies = [
        $(dependencies_string)
    ]

    # Build the tarballs, and possibly a `build.jl` as well.
    build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies)
    """)
end

"""
    yggdrasil_deploy(state::WizardState)

Write out a WizardState to a `build_tarballs.jl` in an `Yggdrasil` clone, then
open a pull request against `Yggdrasil`.
"""
function yggdrasil_deploy(state::WizardState)
    btb = IOBuffer()
    print_build_tarballs(btb, state)
    seek(btb, 0)
    build_tarballs_content = String(read(btb))

    return yggdrasil_deploy(
        name,
        version,
        branch_name,
        build_tarballs_content,
    )
end

function yggdrasil_deploy(name, version, build_tarballs_content; branch_name=nothing)
    # First, fork Yggdrasil (this just does nothing if it already exists)
    gh_auth = github_auth(;allow_anonymous=false)
    fork = GitHub.create_fork("JuliaPackaging/Yggdrasil"; auth=gh_auth)

    mktempdir() do tmp
        # Clone our bare Yggdrasil out to a temporary directory
        repo = LibGit2.clone(get_yggdrasil(), tmp)

        # Check out a unique branch name
        @info("Checking temporary Yggdrasil out to $(tmp)")
        if branch_name === nothing
            recipe_hash = bytes2hex(sha256(build_tarballs_content)[end-3:end])
            branch_name = "wizard/$(name)-v$(version)_$(recipe_hash)"
        end
        LibGit2.branch!(repo, branch_name)
        
        # Spit out the buildscript to the appropriate file:
        rel_bt_path = yggdrasil_build_tarballs_path(name)
        @info("Generating $(rel_bt_path)")
        output_path = joinpath(tmp, rel_bt_path)
        mkpath(dirname(output_path))
        open(output_path, "w") do io
            write(io, build_tarballs_content)
        end

        # Commit it and push it up to our fork
        @info("Committing and pushing to $(fork.full_name)#$(branch_name)...")
        LibGit2.add!(repo, rel_bt_path)
        LibGit2.commit(repo, "New Recipe: $(name) v$(version)")
        creds = LibGit2.UserPasswordCredential(
            dirname(fork.full_name),
            deepcopy(gh_auth.token)
        )
        try
            LibGit2.push(
                repo,
                refspecs=["+HEAD:refs/heads/$(branch_name)"],
                remoteurl="https://github.com/$(fork.full_name).git",
                credentials=creds,
                # This doesn't work :rage: instead we use `+HEAD:` at the beginning of our
                # refspec: https://github.com/JuliaLang/julia/issues/23057
                #force=true,
            )
        finally
            Base.shred!(creds)
        end
        
        # Open a pull request against Yggdrasil
        @info("Opening a pull request against JuliaPackaging/Yggdrasil...")
        params = Dict(
            "base" => "master",
            "head" => "$(dirname(fork.full_name)):$(branch_name)",
            "maintainer_can_modify" => true,
            "title" => "Wizard recipe: $(name)-v$(version)",
            "body" => """
            This pull request contains a new build recipe I built using the BinaryBuilder.jl wizard:

            * Package name: $(name)
            * Version: v$(version)

            @staticfloat please review and merge.
            """
        )
        pr = create_or_update_pull_request("JuliaPackaging/Yggdrasil", params, auth=gh_auth)
        @info("Pull request created: $(pr.html_url)")
    end
end

function step7(state::WizardState)
    print(state.outs, "Your build script was:\n\n\t")
    println(state.outs, replace(state.history, "\n" => "\n\t"))

    printstyled(state.outs, "\t\t\t# Step 7: Deployment\n\n", bold=true)

    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
    deploy_select = request(terminal,
        "How should we deploy this build recipe?",
        RadioMenu([
            "Open a pull request against the community buildtree, Yggdrasil",
            "Write to a local file",
            "Print to stdout",
        ])
    )
    println(state.outs)

    if deploy_select == 1
        yggdrasil_deploy(state)
    elseif deploy_select == 2
        filename = nonempty_line_prompt(
            "filename",
            "Enter path to build_tarballs.jl to write to:";
            ins=state.ins,
            outs=state.outs,
        )
        mkpath(dirname(abspath(filename)))
        open(filename, "w") do io
            print_build_tarballs(io, state)
        end
    else
        println(state.outs, "Your generated build_tarballs.jl:")
        println(state.outs, "\n```")
        print_build_tarballs(state.outs, state)
        println(state.outs, "```")
    end
end
