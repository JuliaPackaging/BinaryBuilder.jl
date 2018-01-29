function print_build_tarballs(io::IO, state::WizardState;
        with_travis_tags=false)
    platforms_string = string("[\n    ",join(state.platforms,",\n  "),"\n]\n")
    urlhashes = zip(state.source_urls, state.source_hashes)
    sources_string = string("[\n",join(map(urlhashes) do x
        (src, hash) = x
        string("    ", repr(src)," =>\n    ", repr(hash), ",\n")
    end,"\n"),"]")

    stuff = collect(zip(state.files, state.file_kinds))
    products_string = join(map(stuff) do x
        file, kind = x
        file = normalize_name(file)
        kind == :executable ? "    ExecutableProduct(prefix,$(repr(file)))" :
        kind == :library ? "    LibraryProduct(prefix,$(repr(file)))" :
        "    FileProduct(prefix,$(repr(file)))"
    end,",\n")

    dependencies_string = ""
    if !isempty(state.dependencies)
        dependencies_string = """
        dependencies = [
        """
        dependencies_string *= join(map(state.dependencies) do dep
            if isa(dep, InlineBuildDependency)
                """
                BinaryBuilder.InlineBuildDependency(raw\"\"\"
                $(dep.script)
                \"\"\")
                """
            elseif isa(dep, RemoteBuildDependency)
                "\"$(dep.url)\""
            end
        end, ",\n")
        dependencies_string *= "]\n"
    end

    println(io, """
    using BinaryBuilder

    # These are the platforms built inside the wizard
    platforms = $(platforms_string)

    # If the user passed in a platform (or a few, comma-separated) on the
    # command-line, use that instead of our default platforms
    if length(ARGS) > 0
        platforms = platform_key.(split(ARGS[1], ","))
    end
    info("Building for \$(join(triplet.(platforms), ", "))")

    # Collection of sources required to build $(state.name)
    sources = $(sources_string)

    script = raw\"\"\"
    $(state.history)
    \"\"\"

    products = prefix -> [
    $products_string
    ]

    $dependencies_string
    # Build the given platforms using the given sources
    hashes = autobuild(pwd(), "$(state.name)", platforms, sources, script, products$(
        isempty(dependencies_string) ? "" : ", dependencies=dependencies"))
    """)
end

function print_travis_buildjl(io::IO, repo)
    println(io, """
    if !isempty(get(ENV,"TRAVIS_TAG",""))
        print_buildjl(pwd(), products, hashes,
            "https://github.com/$(GitHub.name(repo))/releases/download/\$(ENV["TRAVIS_TAG"])")
    end
    """)
end

function print_travis_file(io::IO, state::WizardState)
    println(io, """
    language: julia
    os:
      - linux
    julia:
      - 0.6
    notifications:
      email: false
    git:
      depth: 99999999
    cache:
      timeout: 1000
      directories:
        - downloads
    env:
      global:
        - BINARYBUILDER_DOWNLOADS_CACHE=downloads
        - BINARYBUILDER_AUTOMATIC_APPLE=false
    sudo: required

    # Before anything else, get the latest versions of things
    before_script:
      - julia -e 'Pkg.clone("https://github.com/JuliaPackaging/BinaryProvider.jl")'
      - julia -e 'Pkg.clone("https://github.com/JuliaPackaging/BinaryBuilder.jl"); Pkg.build()'

    script:
      - julia build_tarballs.jl
    """)
end

function print_travis_deploy(io, repo, secure_key)
    print(io,
    """
    deploy:
        provider: releases
        api_key:
            # Note; this api_key is only valid for $(GitHub.name(repo)); you need
            # to make your own: https://docs.travis-ci.com/user/deployment/releases/
            secure: $secure_key
        file_glob: true
        file: products/*
        skip_cleanup: true
        on:
            repo: $(GitHub.name(repo))
            tags: true
    """)
end

mutable struct termios
    c_iflag::Cint
    c_oflag::Cint
    c_cflag::Cint
    c_lflag::Cint
    c_line::UInt8
    c_cc::NTuple{19, UInt8}
    termios() = new()
end

const TCGETS = 0x5401
const TCSETS = 0x5402
const ECHO = 0o10

function set_terminal_echo(fd, enable::Bool)
    # Linux only
    t = termios()
    ccall(:ioctl, Cint, (Cint, Cint, Ref{termios}), fd, TCGETS, t)
    old = (t.c_lflag & ECHO) != 0
    if enable
        t.c_lflag |= ECHO
    else
        t.c_lflag &= ~ECHO
    end
    ccall(:ioctl, Cint, (Cint, Cint, Ref{termios}), fd, TCSETS, t)
    old
end

const travis_headers = Dict(
    "Accept" => "application/vnd.travis-ci.2+json",
    "Content-Type" => "application/json",
    "User-Agent" => "Travis-WHY-YOU-HAVE-BAD-DOCS (https://github.com/travis-ci/travis-ci/issues/5649)"
)

function authenticate_travis(github_token)
    resp = HTTP.post("https://api.travis-ci.org/auth/github",
        body=JSON.json(Dict(
            "github_token" => github_token
        )), headers = travis_headers, statusraise = false)
    JSON.parse(resp.body)["access_token"]
end

function sync_and_wait_travis(outs, repo_name, travis_token)
    println(outs, "Asking travis to sync github and waiting until it knows about our new repo.")
    println(outs, "This may take a few seconds (or minutes, depending on Travis' mood)")
    headers = merge!(Dict("Authorization"=>"token $travis_token"),travis_headers)
    resp = HTTP.post("https://api.travis-ci.org/users/sync"; headers=headers, statusraise=false)
    if resp.status != 200 && resp.status != 409
        error("Failed to sync travis (got status $(resp.status))")
    end
    while true
        resp = HTTP.get("https://api.travis-ci.org/repos/$(repo_name)"; headers=headers, statusraise=false)
        if resp.status == 200
            println("Done waiting")
            # Let's sleep another 5 seconds - Sometimes there's still a race here
            sleep(5.0)
            return JSON.parse(resp.body)["repo"]["id"]
        end
        println("Still Waiting..."); sleep(5.0)
    end
end

function activate_travis_repo(repo_id, travis_token)
    headers = merge!(Dict("Authorization"=>"token $travis_token",
                          "Travis-API-Version"=>3))
    HTTP.post("https://api.travis-ci.org/repo/$(repo_id)/activate"; headers=headers)
end

function obtain_token(outs, ins, repo_name, user)
    println(outs)
    print_with_color(:bold, "Creating a github access token.\n")
    println(outs, """
    We will use this token to create to repository, and then pass it to travis
    for future uploads of binary artifacts.
    You will be prompted for your GitHub credentials.
    """)
    params = Dict(
        "scopes" => ["public_repo",
        # These are required to authenticate against travis
        "read:org", "user:email", "repo_deployment",
        "repo:status","public_repo", "write:repo_hook"
        ],
        "note" => "GitHub releases deployment for $(user)/$(repo_name) - Generated by BinaryBuilder.jl",
        "note_url" => "https://github.com/JuliaPackaging/BinaryBuilder.jl",
        "fingerpint" => randstring(40)
    )
    while true
        print(outs, "Please enter the github.com password for $(user): ")
        terminal = Base.Terminals.TTYTerminal("xterm", ins, outs, outs)
        old = set_terminal_echo(Base._fd(ins), false)
        pass = try
            readline(ins)
        finally
            set_terminal_echo(Base._fd(ins), old)
        end
        println(outs)
        resp = HTTP.post("https://$user:$pass@api.github.com/authorizations"; body=JSON.json(params), statusraise=false)
        if resp.status == 401 && startswith(strip(get(resp.headers, "X-Github-Otp", "")), "required")
            println(outs, "Two factor authentication in use.  Enter auth code.")
            print(outs, "> ")
            otp_code = readline(ins)
            resp = HTTP.post("https://$user:$pass@api.github.com/authorizations"; body=JSON.json(params), headers=Dict("X-GitHub-OTP"=>otp_code),
                statusraise=false)
        end
        if resp.status == 401
            print_with_color(:red, outs, "Invalid credentials!\n")
            continue
        end
        if resp.status != 200
            GitHub.handle_response_error(resp)
        end
        return JSON.parse(resp.body)["token"]
    end
end

function common_git_repo_setup(repo_dir, repo, state)
    local license_text
    while true
        print(state.outs, "Enter your desired license [MIT]: ")
        lic = readline(state.ins)
        isempty(lic) && (lic = "MIT")
        license_text = try
            PkgDev.readlicense(lic)
        catch
            print_with_color(:red, "License $lic is not available.")
            println("Available licenses are:")
            foreach(PkgDev.LICENSES) do lic
                println("- $(lic[1])")
            end
            continue
        end
        break
    end

    LibGit2.commit(repo, "Initial empty commit")
    # Now create the build_tarballs file
    open(joinpath(repo_dir, "build_tarballs.jl"), "w") do f
        print_build_tarballs(f, state)
    end
    # Create the license file
    open(joinpath(repo_dir, "LICENSE.md"), "w") do f
        print(f, license_text)
    end
    # Create the gitignore file
    open(joinpath(repo_dir, ".gitignore"), "w") do f
        print(f, """
        products/
        downloads/
        build/
        """)
    end
end

function local_deploy(state::WizardState)
    repo_dir = tempname()
    LibGit2.with(LibGit2.init(repo_dir)) do repo
        common_git_repo_setup(repo_dir, repo, state)
        open(joinpath(repo_dir, ".travis.yml"), "w") do f
            # Create the first part of the .travis.yml file
            print_travis_file(f, state)
        end
        # Create README file
        open(joinpath(repo_dir, "README.md"), "w") do f
            print(f, """
            # $(state.name) builder

            This repository builds binary artifacts for the $(state.name) project.
            This repository has a default .travis.yml file that can be used to build
            binary artifacts on Travis CI. You will however need to setup the release
            upload manually. See https://docs.travis-ci.com/user/deployment/releases/.

            If you don't wish to use travis, you can use the build_tarballs.jl
            file manually and upload the resulting artifacts to a hosting provider
            of your choice.
            """)
        end
        LibGit2.add!(repo, "build_tarballs.jl", "LICENSE.md", "README.md", ".travis.yml")
        LibGit2.commit(repo, "Add autogenerated files to build $(state.name)")
    end

    println("Your repository is all set up in $(repo_dir)")
end

function obtain_secure_key(outs, token, gr)
    travis_token = authenticate_travis(token)
    repo_id = sync_and_wait_travis(outs, GitHub.name(gr), travis_token)
    activate_travis_repo(repo_id, travis_token)
    # Obtain the appropriate encryption key from travis
    key = JSON.parse(HTTP.get("https://api.travis-ci.org/repos/$(GitHub.name(gr))/key").body)["key"]
    pk_ctx = MbedTLS.PKContext()
    MbedTLS.parse_public_key!(pk_ctx, key)
    # Encrypted the token
    entropy = MbedTLS.Entropy()
    rng = MbedTLS.CtrDrbg()
    MbedTLS.seed!(rng, entropy)
    outbuf = fill(UInt8(0), 4096)
    len = MbedTLS.encrypt!(pk_ctx, token, outbuf, rng)
    secure_key = base64encode(outbuf[1:len])
end

function get_github_user(outs, ins)
    # Get user name
    user = try
        PkgDev.GitHub.user()
    catch
        print(outs, "GitHub user name: ")
        readline(ins)
    end
    user
end

"""
Sets up travis for an existing repository
"""
function setup_travis(repo)
    # Get user name
    user = get_github_user(STDOUT, STDIN)
    gr = GitHub.Repo(repo)
    token = obtain_token(STDOUT, STDIN, GitHub.name(gr), user)
    secure_key = obtain_secure_key(STDOUT, token, gr)
    print_travis_deploy(STDOUT, gr, secure_key)
end

function github_deploy(state::WizardState)
    println(state.outs, """
    Let's deploy a builder repository to GitHub. This repository will be set up
    to use Travis CI to build binaries and then upload them to GitHub releases.
    """)

    # Prompt for the GitHub repository name
    print(state.outs, "Enter the desired name for the new repository: ")
    github_name = readline(state.ins)

    user = get_github_user(state.outs, state.ins)

    # Could re-use the package manager's token here, but we need to create a
    # new token for deployment purposes anyway
    token = obtain_token(state.outs, state.ins, github_name, user)

    # Create a local repository
    repo_dir = tempname()
    auth = GitHub.OAuth2(token)
    LibGit2.with(LibGit2.init(repo_dir)) do repo
        common_git_repo_setup(repo_dir, repo, state)
        # Create the README file
        open(joinpath(repo_dir, "README.md"), "w") do f
            print(f, """
            # $github_name

            [![Build Status](https://travis-ci.org/$(user)/$(github_name).svg?branch=master)](https://travis-ci.org/$(user)/$(github_name))

            This repository builds binary artifacts for the $(state.name) project. Binary artifacts are automatically uploaded to
            [this repository's GitHub releases page](https://github.com/$(user)/$(github_name)/releases) whenever a tag is created
            on this repository.

            This repository was created using [BinaryBuilder.jl](https://github.com/JuliaPackaging/BinaryBuilder.jl)
            """)
        end
        # Create the GitHub repository
        gr = GitHub.create_repo(GitHub.Owner(PkgDev.GitHub.user()),
                github_name; auth=auth)
        # Append the build.jl generation on travis
        open(joinpath(repo_dir, "build_tarballs.jl"), "a") do f
            print_travis_buildjl(f, gr)
        end
        # Push the empty commit
        LibGit2.push(repo, remoteurl="https://github.com/$(user)/$(github_name).git",
            payload=Nullable(LibGit2.UserPasswordCredentials(deepcopy(user),deepcopy(token))),
            refspecs=["+HEAD:refs/heads/master"])
        # Set up travis
        try
            secure_key = obtain_secure_key(state.outs, token, gr)
            open(joinpath(repo_dir, ".travis.yml"), "w") do f
                # Create the first part of the .travis.yml file
                print_travis_file(f, state)
                println(f)
                # Create the deployment portion
                print_travis_deploy(f, gr, secure_key)
            end
        catch e
            Base.display_error(STDERR, e, catch_backtrace())
            println(:red, """
                Something went wrong generating the deployment steps.
                We will finish pushing to GitHub, but you may have to setup
                deployment manually.
            """)
            open(joinpath(repo_dir, ".travis.yml"), "w") do f
                # Create the first part of the .travis.yml file
                print_travis_file(f, state)
            end
        end
        LibGit2.add!(repo, "build_tarballs.jl", "LICENSE.md", "README.md", ".travis.yml")
        LibGit2.commit(repo, "Add autogenerated files to build $(state.name)")
        LibGit2.push(repo, remoteurl="https://github.com/$(user)/$(github_name).git",
            payload=Nullable(LibGit2.UserPasswordCredentials(deepcopy(user),token)),
            refspecs=["+HEAD:refs/heads/master"])
    end
    rm(repo_dir; recursive=true)
end


function step7(state::WizardState)
    print_with_color(:bold, state.outs, "\t\t\tDone!\n\n")

    print(state.outs, "Your build script was:\n\n\t")
    print(state.outs, replace(state.history, "\n", "\n\t"))

    print_with_color(:bold, state.outs, "\t\t\t# Step 7: Deployment\n\n")

    while true
        msg = strip("""
        Pick a name for this project.  This will be used for filenames:
        """)
        print(state.outs, msg, "\n> ")
        state.name = readline(state.ins)
        println(state.outs)
        if isempty(state.name)
            print_with_color(:red, state.outs, "Name may not be empty!\n")
            continue
        end
        break
    end
    println(state.outs, "Use this as your build_tarballs.jl:")
    println(state.outs, "\n```")
    print_build_tarballs(state.outs, state)
    println(state.outs, "```")

    println(state.outs, "Use this as your .travis.yml")
    println(state.outs, "\n```")
    print_travis_file(state.outs, state)
    println(state.outs, "```")

    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
    deploy_select = request(terminal,
        "May I help you with the deployment of these scripts?",
        RadioMenu([
            "Let's create a GitHub repository",
            "Just get me a local git repository",
            "No, thanks"
        ])
    )
    println(state.outs)

    if deploy_select == 1
        github_deploy(state)
    elseif deploy_select == 2
        local_deploy(state)
    else
        return
    end
end
