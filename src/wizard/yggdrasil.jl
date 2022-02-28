# Only update yggdrasil once
const yggdrasil_updated = Ref(false)
function get_yggdrasil()
    # TODO: Eventually, we want to use a Pkg cache to store Yggdrasil,
    # but since that doens't exist yet, we'll stick it into `deps`:
    yggdrasil_dir = BinaryBuilderBase.cached_git_clone("https://github.com/JuliaPackaging/Yggdrasil.git"; verbose=true)

    if !yggdrasil_updated[]
        @info("Updating bare Yggdrasil clone in deps/Yggdrasil...")
        repo = LibGit2.GitRepo(yggdrasil_dir)
        LibGit2.fetch(repo)
        origin_master_oid = LibGit2.GitHash(LibGit2.lookup_branch(repo, "origin/master", true))
        LibGit2.reset!(repo, origin_master_oid, LibGit2.Consts.RESET_SOFT)
    end
    yggdrasil_updated[] = true
    return yggdrasil_dir
end

"""
    yggdrasil_build_tarballs_path(name::String)

Return the relative path within an Yggdrasil clone where this project (given
its name) would be stored.  This is useful for things like generating the
`build_tarballs.jl` file and checking to see if it already exists, etc...

Note that we do not allow case-ambiguities within Yggdrasil, we check for this
using the utility function `case_insensitive_file_exists(path)`.
"""
function yggdrasil_build_tarballs_path(name)
    dir = uppercase(name[1])
    return "$(dir)/$(name)/build_tarballs.jl"
end

using LibGit2: GitRepo, GitCommit, GitTree, GitObject
function case_insensitive_repo_file_exists(repo::GitRepo, path)
    # Walk from top-to-bottom, checking all branches for the eventual leaf node
    tree = LibGit2.peel(GitTree, GitCommit(repo, "origin/master"))
    spath = splitpath(path)

    frontier = GitTree[tree]

    for (idx,node) in enumerate(spath)
        lnode = lowercase(node)
        new_frontier = GitTree[]
        for tree in frontier
            LibGit2.treewalk(tree) do root, entry
                if lowercase(LibGit2.filename(entry)) == lnode &&
                     (idx == lastindex(spath) || LibGit2.entrytype(entry) == GitTree)
                    push!(new_frontier, GitTree(entry))
                end
                return 1
            end
        end
        frontier = new_frontier
        isempty(frontier) && return false
    end
    return !isempty(frontier)
end

function with_yggdrasil_pr(f::Function, pr_number::Integer)
    # Get Yggdrasil, then force it to fetch our pull request refspec
    yggy = LibGit2.GitRepo(get_yggdrasil())

    # First, delete any local branch that might exist with our "pr-$(pr_number)" name:
    branch_name = "pr-$(pr_number)"
    branch = LibGit2.lookup_branch(yggy, branch_name)
    if branch !== nothing
        LibGit2.delete_branch(branch)
    end

    mktempdir() do tmpdir
        # Fetch the PR contents down into a local branch
        @info("Fetching Yggdrasil PR #$(pr_number) and checking out to $(tmpdir)")
        LibGit2.fetch(yggy; refspecs=["pull/$(pr_number)/head:refs/heads/$(branch_name)"])
        LibGit2.clone(LibGit2.path(yggy), tmpdir; branch=branch_name)

        cd(tmpdir) do
            f()
        end
    end
end

function test_yggdrasil_pr(pr_number::Integer)
    # Get list of files changed in this PR
    with_yggdrasil_pr(pr_number) do
        # Analyze the current repository, figure out what files have been changed
        @info("Inspecting changed files in PR #$(pr_number)")
        r = GitHub.Repo("JuliaPackaging/Yggdrasil")
        changed_files = [f.filename for f in GitHub.pull_request_files(r, pr_number)]

        # Discard anything that doens't end with `build_tarballs.jl`
        filter!(f -> endswith(f, "build_tarballs.jl"), changed_files)

        # Discard anything starting with 0_RootFS
        filter!(f -> !startswith(f, "0_RootFS"), changed_files)

        # If there's nothing left, fail out
        if length(changed_files) == 0
            error("Unable to find any valid changes!")
        end

        # Use TerminalMenus to narrow down which to build
        terminal = TTYTerminal("xterm", stdin, stdout, stderr)
        if length(changed_files) > 1
            builder_idx = request(terminal,
                "Multiple recipes modified, which to build?",
                RadioMenu(basename.(dirname.(changed_files)); charset=:ascii)
            )
            println()

            build_tarballs_path = joinpath(pwd(), changed_files[builder_idx])
        else
            build_tarballs_path = joinpath(pwd(), first(changed_files))
        end

        # Next, run that `build_tarballs.jl`
        successful = false

        while true
            try
                cd(dirname(build_tarballs_path)) do
                    run(`$(Base.julia_cmd()) --color=yes build_tarballs.jl --verbose --debug`)
                    @info("Build successful! Recipe temporarily available at $(joinpath(pwd(), "build_tarballs.jl"))")
                end

                # Exit the `while` loop
                @info("Build successful!")
                break
            catch
            end

            what_do = request(terminal,
                "Build unsuccessful:",
                RadioMenu([
                    # The definition of insanity
                    "Try again immediately",
                    "Edit build_tarball.jl file, then try again",
                    "Bail out",
                ]; charset=:ascii)
            )
            println()

            if what_do == 2
                edit_script(build_tarballs_path, stdin, stdout, stderr)
                @info("Building with new recipe...")
                continue
            elseif what_do == 3
                break
            end
        end

        # If we make it this far, we are in a good state; check to see if we've modified stuff;
        # if we have, offer to push it up to a new branch.
        if LibGit2.isdirty(LibGit2.GitRepo(pwd()))
            what_do = request(terminal,
               "Changes to $(build_tarballs_path) detected:",
                RadioMenu([
                    "Open a PR to the Yggdrasil PR",
                    "Display diff and quit",
                    "Discard",
                ]; charset=:ascii)
            )
            println()

            if what_do == 1
                dummy_name = basename(dirname(build_tarballs_path))
                dummy_version = v"1.33.7"
                yggdrasil_deploy(dummy_name, dummy_version, [], read(build_tarballs_path))
            elseif what_do == 2
                cd(dirname(build_tarballs_path))
                run(`git diff`)
            end
        end
    end
end
