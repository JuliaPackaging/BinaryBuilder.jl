function print_build_tarballs(io::IO, state::WizardState;
        with_travis_tags=false)
    urlhashes = zip(state.source_urls, state.source_hashes)
    sources_string = join(map(urlhashes) do x
        string(repr(x[1])," =>\n    ", repr(x[2]), ",\n")
    end,"\n    ")
    platforms_string = join(state.platforms,",\n    ")

    stuff = collect(zip(state.files, state.file_kinds, state.file_varnames))
    products_string = join(map(stuff) do x
        file, kind, varname = x
        # Normalize the filename, e.g. `"foo/libfoo.tar.gz"` would get mapped to `"libfoo"`
        file = normalize_name(file)
        if kind == :executable
            return "ExecutableProduct(prefix, $(repr(file)), $(repr(varname)))"
        elseif kind == :library
            return "LibraryProduct(prefix, $(repr(file)), $(repr(varname)))"
        else
            return "FileProduct(prefix, $(repr(file)), $(repr(varname)))"
        end
    end,",\n    ")

    dependencies_string = ""
    if !isempty(state.dependencies)
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
        end, ",\n    ")
    end

    println(io, """
    # Note that this script can accept some limited command-line arguments, run
    # `julia build_tarballs.jl --help` to see a usage message.
    using BinaryBuilder

    name = $(repr(state.name))
    version = $(repr(state.version))

    # Collection of sources required to build $(state.name)
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
    products(prefix) = [
        $products_string
    ]

    # Dependencies that must be installed before this package can be built
    dependencies = [
        $dependencies_string
    ]

    # Build the tarballs, and possibly a `build.jl` as well.
    build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies)
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

function authenticate_travis(github_token; travis_endpoint=DEFAULT_TRAVIS_ENDPOINT)
    resp = HTTP.post("$(travis_endpoint)auth/github",
        body=JSON.json(Dict(
            "github_token" => github_token
        )), headers = travis_headers)
    JSON.parse(HTTP.payload(resp, String))["access_token"]
end

function sync_and_wait_travis(outs, repo_name, travis_token; travis_endpoint=DEFAULT_TRAVIS_ENDPOINT)
    println(outs, "Asking travis to sync github and waiting until it knows about our new repo.")
    println(outs, "This may take a few seconds (or minutes, depending on Travis' mood)")
    headers = merge!(Dict("Authorization"=>"token $travis_token"),travis_headers)
    resp = HTTP.post("$(travis_endpoint)users/sync"; headers=headers, status_exception=false)
    if resp.status != 200 && resp.status != 409
        error("Failed to sync travis (got status $(resp.status))")
    end
    while true
        resp = HTTP.get("$(travis_endpoint)repos/$(repo_name)"; headers=headers, status_exception=false)
        if resp.status == 200
            println(outs, "Done waiting")
            # Let's sleep another 5 seconds - Sometimes there's still a race here
            sleep(5.0)
            return JSON.parse(HTTP.payload(resp, String))["repo"]["id"]
        end
        println(outs, "Still Waiting..."); sleep(5.0)
    end
end

function activate_travis_repo(repo_id, travis_token; travis_endpoint=DEFAULT_TRAVIS_ENDPOINT)
    headers = merge!(Dict("Authorization"=>"token $travis_token",
                          "Travis-API-Version"=>3))
    HTTP.post("$(travis_endpoint)repo/$(repo_id)/activate"; headers=headers)
end

function obtain_token(outs, ins, repo_name, user; github_api=Github.DEFAULT_API)
    println(outs)
    printstyled("Creating a github access token.\n", bold=true)
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
        headers = Dict{String, String}("User-Agent"=>"BinaryBuilder-jl")
        auth = GitHub.UsernamePassAuth(user, pass)
        resp = GitHub.gh_post(github_api, "/authorizations",
            headers=headers, params=params, handle_error=false,
            auth = auth)
        if resp.status == 401 && startswith(strip(HTTP.getkv(resp.headers, "X-GitHub-OTP", "")), "required")
            println(outs, "Two factor authentication in use.  Enter auth code.")
            print(outs, "> ")
            otp_code = readline(ins)
            resp = GitHub.gh_post(github_api, "/authorizations",
                headers=merge(headers, Dict("X-GitHub-OTP"=>otp_code)),
                params=params, handle_error=false,
                auth = auth)
        end
        if resp.status == 401
            printstyled(outs, "Invalid credentials!\n", color=:red)
            continue
        end
        if resp.status != 200
            GitHub.handle_response_error(resp)
        end
        return JSON.parse(HTTP.payload(resp, String))["token"]
    end
end

"""
    set_global_git_config(username, email)

Sets up a `~/.gitconfig` with the given `username` and `email`.
"""
function set_global_git_config(username, email)
    LibGit2.with(LibGit2.GitConfig(LibGit2.Consts.CONFIG_LEVEL_GLOBAL)) do cfg
        LibGit2.set!(cfg, "user.name", username)
        LibGit2.set!(cfg, "user.email", email)
    end
    return nothing
end

"""
    init_git_config(repo, state)

Ask the user for their username and password for a repository-local
`.git/config` file.  This is used during an interactive wizard session.
"""
function init_git_config(repo, state)
    msg = """
    Global `~/.gitconfig` information not found.
    In order to create a git repository, we need a
    "name" and "email address" to identify the git
    commits we are about to create.  To avoid this
    prompt in the future and to set your name and
    email address globally, run

        BinaryBuilder.set_global_git_config(username, email)

    """
    println(state.outs, msg)
    print(state.outs, "Enter your name: ")
    username = readline(state.ins)
    print(state.outs, "Enter your email address: ")
    email = readline(state.ins)

    LibGit2.with(LibGit2.GitConfig(repo)) do cfg
        LibGit2.set!(cfg, "user.name", username)
        LibGit2.set!(cfg, "user.email", email)
    end
end

function common_git_repo_setup(repo_dir, repo, state)
    local license_text
    while true
        print(state.outs, "Enter your desired license [MIT]: ")
        lic = readline(state.ins)
        isempty(lic) && (lic = "MIT")
        license_text = try
            PkgLicenses.readlicense(lic)
        catch
            printstyled("License $lic is not available.", color=:red)
            println("Available licenses are:")
            foreach(PkgLicenses.LICENSES) do lic
                println("- $(lic[1])")
            end
            continue
        end
        break
    end

    # check to see if the user has already setup git config settings
    if (LibGit2.get(state.global_git_cfg, "user.name", nothing) == nothing ||
        LibGit2.get(state.global_git_cfg, "user.email", nothing) == nothing) &&
        (LibGit2.getconfig(repo, "user.name", nothing) == nothing) ||
        (LibGit2.getconfig(repo, "user.email", nothing) == nothing)
        # If they haven't, prompt them to make a global one, and then actually
        # make a repository-local config right now.
        init_git_config(repo, state)
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
        LibGit2.add!(repo, "build_tarballs.jl", "LICENSE.md", "README.md",
                           ".travis.yml", ".gitignore")
        LibGit2.commit(repo, "Add autogenerated files to build $(state.name)")
    end

    println("Your repository is all set up in $(repo_dir)")
end

function obtain_secure_key(outs, token, gr; travis_endpoint=DEFAULT_TRAVIS_ENDPOINT)
    travis_token = authenticate_travis(token; travis_endpoint=travis_endpoint)
    repo_id = sync_and_wait_travis(outs, GitHub.name(gr), travis_token; travis_endpoint=travis_endpoint)
    activate_travis_repo(repo_id, travis_token; travis_endpoint=travis_endpoint)
    # Obtain the appropriate encryption key from travis
    key = JSON.parse(HTTP.payload(HTTP.get("$(travis_endpoint)repos/$(GitHub.name(gr))/key"), String))["key"]
    pk_ctx = MbedTLS.PKContext()
    # Some older repositories have keys starting with "BEGIN RSA PUBLIC KEY"
    # which would indicate that they are in PKCS#1 format. However, they are
    # instead in PKCS#8 format with incorrect header guards, so fix that up
    # and never think about it again.
    key = replace(key, "RSA PUBLIC KEY" => "PUBLIC KEY")
    MbedTLS.parse_public_key!(pk_ctx, key)
    # Encrypted the token
    entropy = MbedTLS.Entropy()
    rng = MbedTLS.CtrDrbg()
    MbedTLS.seed!(rng, entropy)
    outbuf = fill(UInt8(0), 4096)
    len = MbedTLS.encrypt!(pk_ctx, token, outbuf, rng)
    secure_key = base64encode(outbuf[1:len])
end

function get_github_user(outs, ins, cfg=LibGit2.GitConfig())
    # Get user name
    user = LibGit2.get(cfg, "github.user", "")
    if isempty(user)
        println(state.outs, """
        GitHub username not globally configured. You will have to enter your
        GitHub username below. To avoid this prompt in the future, set your
        GitHub username using `git config --global github.user <username>`.
        """)
        print(outs, "GitHub user name: ")
        user = readline(ins)
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

function push_repo(api::GitHub.GitHubWebAPI, lrepo, rrepo, user, token, refspecs)
    # Push the empty commit
    LibGit2.push(lrepo, remoteurl="https://github.com/$(GitHub.name(rrepo)).git",
        payload=Nullable(LibGit2.UserPasswordCredentials(deepcopy(user),deepcopy(token))),
        refspecs=refspecs)
end

function github_deploy(state::WizardState)
    println(state.outs, """
    Let's deploy a builder repository to GitHub. This repository will be set up
    to use Travis CI to build binaries and then upload them to GitHub releases.
    """)

    # Prompt for the GitHub repository name
    print(state.outs, "Enter the desired name for the new repository: ")
    github_name = readline(state.ins)

    user = get_github_user(state.outs, state.ins, state.global_git_cfg)

    # Could re-use the package manager's token here, but we need to create a
    # new token for deployment purposes anyway
    token = obtain_token(state.outs, state.ins, github_name, user; github_api=state.github_api)

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
        gr = GitHub.create_repo(state.github_api, GitHub.Owner(user),
                github_name; auth=auth)
        # Set up travis
        push_repo(state.github_api, repo, gr, user, token, ["+HEAD:refs/heads/master"])
        try
            secure_key = obtain_secure_key(state.outs, token, gr; travis_endpoint=state.travis_endpoint)
            open(joinpath(repo_dir, ".travis.yml"), "w") do f
                # Create the first part of the .travis.yml file
                print_travis_file(f, state)
                println(f)
                # Create the deployment portion
                print_travis_deploy(f, gr, secure_key)
            end
        catch e
            Base.display_error(stderr, e, catch_backtrace())
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
        LibGit2.add!(repo, "build_tarballs.jl", "LICENSE.md", "README.md",
                           ".travis.yml", ".gitignore")
        LibGit2.commit(repo, "Add autogenerated files to build $(state.name)")
        push_repo(state.github_api, repo, gr, user, token, ["+HEAD:refs/heads/master"])
        println(state.outs, "Deployment Complete")
    end
    rm(repo_dir; recursive=true)
end


function step7(state::WizardState)
    printstyled(state.outs, "\t\t\tDone!\n\n", bold=true)

    print(state.outs, "Your build script was:\n\n\t")
    print(state.outs, replace(state.history, "\n" => "\n\t"))

    printstyled(state.outs, "\t\t\t# Step 7: Deployment\n\n", bold=true)

    function nonempty_line_prompt(name, msg)
        val = ""
        while true
            print(state.outs, msg, "\n> ")
            val = readline(state.ins)
            println(state.outs)
            if !isempty(val)
                break
            end
            printstyled(state.outs, "$(name) may not be empty!\n", color=:red)
        end
        return val
    end

    msg = strip("""
    Enter a name for this project.  This will be used for filenames:
    """)
    state.name = nonempty_line_prompt("Name", msg)
    msg = strip("""
    Enter a version number for this project.  This will be used for filenames:
    """)
    state.version = VersionNumber(nonempty_line_prompt("Version", msg))
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
