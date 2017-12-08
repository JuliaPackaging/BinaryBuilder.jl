if Sys.is_linux()

using VT100
using BinaryBuilder
    
pty = VT100.create_pty(false)
function BinaryBuilder.WizardState(ins::Base.TTY, outs::Base.TTY)
    state = BinaryBuilder.WizardState()
    state.ins = ins
    state.outs = outs
    state.platforms = supported_platforms()
    state
end

# Test the download stage
## Tarballs
using HTTP

r = HTTP.Router()
#tar_libfoo() = read(`tar czf - -C $(dirname(@__FILE__))/build_tests libfoo`)
tar_libfoo() = read(`tar czf - -C $(Pkg.dir("BinaryBuilder","test"))/build_tests libfoo`)
function serve_tgz(req, resp)
    HTTP.Response(200, tar_libfoo())
end
HTTP.register!(r, "/*/source.tar.gz", HTTP.HandlerFunction(serve_tgz))
server = HTTP.Server(r)
@async HTTP.serve(server, ip"127.0.0.1", 14444; verbose=false)

do_try(f) = try
    f()
catch e
    bt = catch_backtrace()
    Base.display_error(STDERR, e, bt)
end

ins, outs = Base.TTY(pty.slave; readable=true), Base.TTY(pty.slave; readable=false);

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

# We're done with the server
put!(server.in, HTTP.Nitrogen.KILL)

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
    wait(t)
end

readavailable(pty.master)

# Technically until the terminal has been put into raw mode
# We could probably detect that, but good enough for now.
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
    write(pty.master, "rm -rf \$DESTDIR/*\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    wait_for_menu(pty)
    write(pty.master, "\r")
    wait_for_non_menu(pty)
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "mkdir -p \$DESTDIR/{lib,bin}\n")
    write(pty.master, "cp fooifier \$DESTDIR/bin\n")
    write(pty.master, "cp libfoo.so \$DESTDIR/lib\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    # Step 4
    write(pty.master, "ad")
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
    write(pty.master, "rm -rf \$DESTDIR/*\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    # How would you like to proceed
    wait_for_menu(pty)
    write(pty.master, "\e[B")
    sleep(1)
    write(pty.master, "\r") # Why is this needed?
    wait_for_non_menu(pty)
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "if [ -f fooifier ]; then\nexit\nfi\n")
    write(pty.master, "make install\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    # Step 4
    write(pty.master, "ad")
end

rm(tempspace; force=true, recursive=true)

end
