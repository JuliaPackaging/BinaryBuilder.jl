using VT100
using BinaryBuilder
using GitHub
using Compat
using Compat.Test

if Compat.Sys.islinux()

# Create fake terminal to communicate with BinaryBuilder over
pty = VT100.create_pty(false)
ins, outs = Base.TTY(pty.slave; readable=true), Base.TTY(pty.slave; readable=false)

# Helper function to create a state, assign input/output streams, assign platforms, etc...
function BinaryBuilder.WizardState(ins::Base.TTY, outs::Base.TTY)
    state = BinaryBuilder.WizardState()
    state.ins = ins
    state.outs = outs
    state.platforms = supported_platforms()
    return state
end

# Helper function to try something and panic if it doesn't work
do_try(f) = try
    f()
catch e
    bt = catch_backtrace()
    Base.display_error(stderr, e, bt)

    # If a do_try fails, panic
    Base.Test.@test false
end


# Test the download stage
## Tarballs
using HTTP

r = HTTP.Router()
tar_libfoo() = read(`tar czf - -C $(Pkg.dir("BinaryBuilder","test"))/build_tests libfoo`)
function serve_tgz(req)
    HTTP.Response(200, tar_libfoo())
end
HTTP.register!(r, "/*/source.tar.gz", HTTP.HandlerFunction(serve_tgz))
server = HTTP.Server(r)
@async HTTP.serve(server, ip"127.0.0.1", 14444; verbose=false)

# Test one tar.gz download
let state = BinaryBuilder.WizardState(ins, outs)
    state.step = :step2
    t = @async do_try(()->BinaryBuilder.step2(state))
    # URL
    write(pty.master, "http://127.0.0.1:14444/a/source.tar.gz\n")
    # Would you like to download additional sources?
    write(pty.master, "N\n")
    # Do you require any (binary) dependencies ? 
    write(pty.master, "N\n")
    # Wait for that step to complete
    wait(t)
end

# Test two tar.gz download
let state = BinaryBuilder.WizardState(ins, outs)
    state.step = :step2
    t = @async do_try(()->BinaryBuilder.step2(state))
    # URL
    write(pty.master, "http://127.0.0.1:14444/a/source.tar.gz\n")
    # Would you like to download additional sources?
    write(pty.master, "y\n")
    write(pty.master, "http://127.0.0.1:14444/b/source.tar.gz\n")
    # Would you like to download additional sources?
    write(pty.master, "N\n")
    # Do you require any (binary) dependencies ? 
    write(pty.master, "N\n")
    # Wait for that step to complete
    wait(t)
end

# Package up libfoo and dump a tarball in /tmp
tempspace = tempname()
mkdir(tempspace)
local tar_hash
open(joinpath(tempspace, "source.tar.gz"), "w") do f
    data = tar_libfoo()
    tar_hash = BinaryProvider.sha256(data)
    write(f, data)
end

# Test step3 success path
let state = BinaryBuilder.WizardState(ins, outs)
    state.step = :step3
    state.source_urls = ["http://127.0.0.1:14444/a/source.tar.gz\n"]
    state.source_files = [joinpath(tempspace, "source.tar.gz")]
    state.source_hashes = [bytes2hex(tar_hash)]
    t = @async do_try(()->BinaryBuilder.step34(state))
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "make install\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    # Step 4
    write(pty.master, "ad")
    write(pty.master, "libfoo\nfooifier\n")
    wait(t)
end

# Test download with a broken symlink that used to kill the wizard
# https://github.com/JuliaPackaging/BinaryBuilder.jl/issues/183
let state = BinaryBuilder.WizardState(ins, outs)
    # download tarball with known broken symlink
    bsym_url = "https://github.com/staticfloat/small_bin/raw/d846f4a966883e7cc032a84acf4fa36695d05482/broken_symlink/broken_symlink.tar.gz"
    bsym_hash = "470d47f1e6719df286dade223605e0c7e78e2740e9f0ecbfa608997d52a00445"
    bsym_path = joinpath(tempspace, "broken_symlink.tar.gz")
    download_verify(bsym_url, bsym_hash, bsym_path)
    
    state.step = :step3
    state.source_urls = [bsym_url]
    state.source_files = [bsym_path]
    state.source_hashes = [bsym_hash]
    t = @async do_try(()->BinaryBuilder.step34(state))

    # If we get this far we've already won, follow through for good measure
    write(pty.master, "mkdir -p \$WORKSPACE/destdir/bin\n")
    write(pty.master, "cp /bin/bash \$WORKSPACE/destdir/bin/\n")
    write(pty.master, "exit\n")
    # We do not want to edit the script now
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    readuntil(pty.master, "unique variable name for each build artifact:")
    # Name the 'binary artifact' `bash`:
    write(pty.master, "bash\n")

    # Wait for the step to complete
    wait(t)
end


# Clear anything waiting to be read on `pty.master`
readavailable(pty.master)

# These technically should wait until the terminal has been put into/come out
# of raw mode.  We could probably detect that, but good enough for now.
wait_for_menu(pty) = sleep(1)
wait_for_non_menu(pty) = sleep(1)

# Step 3 failure path (no binary in destdir -> return to build)
let state = BinaryBuilder.WizardState(ins, outs)
    state.step = :step3
    state.source_urls = ["http://127.0.0.1:14444/a/source.tar.gz\n"]
    state.source_files = [joinpath(tempspace, "source.tar.gz")]
    state.source_hashes = [bytes2hex(tar_hash)]
    t = @async do_try(()->BinaryBuilder.step34(state))
    sleep(1)
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "make install\n")
    write(pty.master, "rm -rf \$prefix/*\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    wait_for_menu(pty)
    write(pty.master, "\r")
    wait_for_non_menu(pty)
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "mkdir -p \$prefix/{lib,bin}\n")
    write(pty.master, "cp fooifier \$prefix/bin\n")
    write(pty.master, "cp libfoo.so \$prefix/lib\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    # Step 4
    write(pty.master, "ad")
    write(pty.master, "libfoo\nfooifier\n")
    wait(t)
end

# Step 3 failure path (no binary in destdir -> start over)
let state = BinaryBuilder.WizardState(ins, outs)
    state.step = :step3
    state.source_urls = ["http://127.0.0.1:14444/a/source.tar.gz\n"]
    state.source_files = [joinpath(tempspace, "source.tar.gz")]
    state.source_hashes = [bytes2hex(tar_hash)]
    t = @async do_try(()->while state.step == :step3
        BinaryBuilder.step34(state)
    end)
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "make install\n")
    write(pty.master, "rm -rf \$prefix/*\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    # How would you like to proceed
    wait_for_menu(pty)
    write(pty.master, "\e[B")
    sleep(1)
    write(pty.master, "\r")
    wait_for_non_menu(pty)
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "make install\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    # Step 4
    write(pty.master, "ad")
    write(pty.master, "libfoo\nfooifier\n")
    wait(t)
end

struct GitHubSimulator <: GitHub.GitHubAPI
end

function GitHub.gh_post(g::GitHubSimulator, endpoint; auth = nothing, headers = Dict(), kwargs...)
    if endpoint == "/authorizations"
        @test isa(auth, GitHub.UsernamePassAuth)
        @test auth.username == "TestUser"
        @test auth.password == "test"
        # Simulate 2FA enabled
        if !haskey(headers, "X-GitHub-OTP")
            return HTTP.Response(401, Dict("X-GitHub-OTP"=>"required"))
        else
            return HTTP.Response(200; body=Vector{UInt8}("""
            {
              "id": 1,
              "url": "https://api.github.com/authorizations/1",
              "scopes": [
                "public_repo"
              ],
              "token": "abcdefgh12345678",
              "token_last_eight": "12345678",
              "hashed_token": "25f94a2a5c7fbaf499c665bc73d67c1c87e496da8985131633ee0a95819db2e8",
              "app": {
                "url": "http://my-github-app.com",
                "name": "my github app",
                "client_id": "abcde12345fghij67890"
              },
              "note": "optional note",
              "note_url": "http://optional/note/url",
              "updated_at": "2011-09-06T20:39:23Z",
              "created_at": "2011-09-06T17:26:27Z",
              "fingerprint": ""
            }
            """))
        end
    else
        error()
    end
end

push_counter = 0
create_repo_counter = 0
function BinaryBuilder.push_repo(g::GitHubSimulator, args...)
    global push_counter += 1
end
function GitHub.create_repo(api::GitHubSimulator, owner, name::String, params=Dict{String,Any}(); kwargs...)
    global create_repo_counter += 1
    GitHub.Repo("TestUser/TestRepo")
end

function emulate_travis(req)
    if req.target == "/travis/auth/github"
        HTTP.Response(200; body=Vector{UInt8}("""
        {"access_token":"some_token"}
        """))
    elseif req.target == "/travis/users/sync"
        HTTP.Response(200)
    elseif req.target == "/travis/repos/TestUser/TestRepo"
        HTTP.Response(200; body=Vector{UInt8}("""
        {
          "repo": {
            "id": 1,
            "slug": "TestUser/TestRepo",
            "description": "Whatever",
            "last_build_id": 23436881,
            "last_build_number": "792",
            "last_build_state": "passed",
            "last_build_duration": 2542,
            "last_build_started_at": "2014-04-21T15:27:14Z",
            "last_build_finished_at": "2014-04-21T15:40:04Z",
            "active": "true"
          }
        }
        """))
    elseif req.target == "/travis/repo/1/activate"
        HTTP.Response(200)
    elseif req.target == "/travis/repos/TestUser/TestRepo/key"
        HTTP.Response(200; body=Vector{UInt8}("""
        {"key":"-----BEGIN PUBLIC KEY-----\\n"""*
        "MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA88f8L8L5XhApAf0WC3VQ\\n"*
        "AdA2x6ZBB6flQ7/xbhFOIHgK2zX+GT1kvr5BrrKjscD1/pNm13LMXeBD/R+PlcTo\\n"*
        "hAJYAxbeniTD//Zkx6mocCmqkNjpp7N6i1HOmls/vWvs3c4ZrZpy9hWk70MOH1j3\\n"*
        "VXxDuugfWkTiq6GExLrTRaVLe0qagL0goIHSTdpJbyWxOct3+W8bv8v/scwqmnQf\\n"*
        "ecjGYRjEqAXWYQLTJ+VY2zRGcksESztykfgA9Hj/CH0Jh5wE43hUXa61CEdseQ7P\\n"*
        "QtMX8OPzcu2QWOoSHHnv6Q0Tte7xc+TKG3h3KC2DW/x2qog5RsXMh2UJXsLG+iDv\\n"*
        "tYidlyekxcmldbpNm7169CnjRa3Kq55vIwtRiMPTcLbrMwzi1aJWOBVPthfDTu//\\n"*
        "6HM3ajzZIo6xmg5lddBB09jsY5uoqdu5ddKAo9Wkeqn/gYzQrHyc7jvLMDo7RPFp\\n"*
        "ZnY8u2tWFYK/O1LonqJY3Oyf4ZS2aKDTciVoNSBIqJzAgC2LF1E8WEBMcmFy4xeB\\n"*
        "4Ke2j6bF+szTnKbcRTHhu9AvSkDdWxN3JFolGNHYnIHD0jNlc3rlTSkQfzCFgP3U\\n"*
        "9RQRgz6ix3lP608gL0j64GuSFuIqulmn9UiKgf8J8eV9FLybbZ1WayBe8Bbfbh3c\\n"*
        "y7a79CxhXJ0WJxO5pQijKXkCAwEAAQ==\\n"*
        """-----END PUBLIC KEY-----\\n",
        "fingerprint":"e3:5c:d0:0d:d8:00:bb:6d:fb:c2:e7:9b:59:9f:91:50"}
        """))
    else
        error()
    end
end
HTTP.register!(r, "/travis/*", HTTP.HandlerFunction(emulate_travis))

# Test GitHub Deploy
let state = BinaryBuilder.WizardState(ins, outs)
    state.step = :step7
    state.source_urls = ["http://127.0.0.1:14444/a/source.tar.gz\n"]
    state.source_files = [joinpath(tempspace, "source.tar.gz")]
    state.source_hashes = [bytes2hex(tar_hash)]
    state.global_git_cfg = LibGit2.GitConfig(joinpath(tempspace, ".gitconfig"))
    state.github_api = GitHubSimulator()
    state.files = String[]
    state.file_kinds = Symbol[]
    state.file_varnames = Symbol[]
    state.travis_endpoint = "http://127.0.0.1:14444/travis/"
    LibGit2.set!(state.global_git_cfg, "github.user", "TestUser")
    t = @async BinaryBuilder.github_deploy(state)
    readuntil(pty.master, "Enter the desired name for the new repository: ")
    write(pty.master, "TestRepo\n")
    readuntil(pty.master, "Please enter the github.com password for TestUser:")
    write(pty.master, "test\n")
    readuntil(pty.master, "Two factor authentication in use.  Enter auth code.")
    write(pty.master, "12345\n")
    readuntil(pty.master, "Enter your desired license [MIT]: ")
    write(pty.master, "\n")
    readuntil(pty.master, "Enter your name:")
    write(pty.master, "Test User\ntest@user.email\n")
    readuntil(pty.master, "Deployment Complete")
end


# We're done with the server
put!(server.in, HTTP.Servers.KILL)

end #if

rm(tempspace; force=true, recursive=true)

# Make sure canonicalization does what we expect
zmq_url = "https://github.com/zeromq/zeromq3-x/releases/download/v3.2.5/zeromq-3.2.5.tar.gz"
@test BinaryBuilder.canonicalize_source_url(zmq_url) == zmq_url
