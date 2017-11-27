const rootfs_url_root = "https://julialangmirror.s3.amazonaws.com"
const rootfs_url = "$rootfs_url_root/binarybuilder-rootfs-2017-11-20.tar.gz"
const rootfs_sha256 = "0ea0925c022e8dc6834906ac6edecd668d66e9cecb9667c39cce7d278467c6f2"
const sandbox_path = joinpath(dirname(@__FILE__), "..", "deps", "sandbox")

# Note that rootfs_tar and rootfs can be overridden by the environment variables shown in __init__()
rootfs_base = joinpath(dirname(@__FILE__), "..", "deps", "downloads", "rootfs")
rootfs = joinpath(dirname(@__FILE__), "..", "deps", "root")

"""
    UserNSRunner

A `UserNSRunner` represents an "execution context", an object that bundles all
necessary information to run commands within the container that contains
our crossbuild environment.  Use `run()` to actually run commands within the
`UserNSRunner`, and `runshell()` as a quick way to get an interactive shell
within the crossbuild environment.
"""
type UserNSRunner
    sandbox_cmd::Cmd
    platform::Platform
end

add_ext(base, squashfs) = string(base, squashfs ? ".squash" : ".tar.gz")

"""
    update_rootfs(;verbose::Bool = true)

Updates the stored rootfs containing all cross-compilers and other compilation
machinery for the builder.
"""
function update_rootfs(;verbose::Bool = true, squashfs::Bool = false)
    # Check to make sure we have the latest version downloaded properly
    rootfs_sha256 = squashfs ? rootfs_squash_sha256 : rootfs_targz_sha256
    rootfs_url = add_ext(rootfs_base_url, squashfs)
    rootfs_path = add_ext(rootfs_base, squashfs)
    try
        if verbose
            info("Verifying rootfs download...")
        end
        mkpath(dirname(rootfs_base))
        download_verify(rootfs_url, rootfs_sha256, rootfs_path; verbose=verbose)
    catch
        if verbose
            info("rootfs image verification failed, downloading new rootfs...")
        end

        # If download_verify failed, we need to clear out the old rootfs and
        # download the new rootfs image.  Start by removing the old rootfs: 
        rm(rootfs; force=true, recursive=true)
        rm(rootfs_path; force=true, recursive=true)
        mkpath(dirname(rootfs_base))

        # Then download and unpack again
        download_verify(rootfs_url, rootfs_sha256, rootfs_path; verbose=verbose)
    end

    # Next, if the rootfs does not already exist, unpack it
    if !isdir(rootfs) && !squashfs
        if verbose
            info("Unpacking rootfs...")
        end
        unpack(rootfs_tar, rootfs; verbose=verbose)
    end
end

"""
    update_sandbox_binary(;verbose::Bool = true)

Builds/updates the `sandbox` binary that launches all commands within the rootfs
"""
function update_sandbox_binary(;verbose::Bool = true)
    cd(joinpath(dirname(@__FILE__), "..", "deps")) do
        if !isfile("sandbox") || stat("sandbox").mtime < stat("sandbox.c").mtime
            if verbose
                info("Rebuilding sandbox binary...")
            end
            oc = OutputCollector(`gcc -o sandbox sandbox.c`; verbose=verbose)
            wait(oc)
        end
    end
end

function UserNSRunner(sandbox::String; overlay = true, cwd = nothing, platform::Platform = platform_key(), extra_env=Dict{String, String}())
    if overlay
        sandbox_cmd = `$sandbox_path --rootfs $rootfs --overlay $sandbox/overlay_root --overlay_workdir $sandbox/overlay_workdir --workspace $sandbox/workspace`
    else
        sandbox_cmd = `$sandbox_path --rootfs $rootfs --workspace $sandbox`
    end

    if cwd != nothing
        sandbox_cmd = `$sandbox_cmd --cd $cwd`
    end
    sandbox_cmd = setenv(sandbox_cmd, merge(target_envs(triplet(platform)), extra_env))
    UserNSRunner(sandbox_cmd, platform)
end

function show(io::IO, x::UserNSRunner)
    p = x.platform
    # Displays as, e.g., Linux x86_64 (glibc) UserNSRunner
    write(io, typeof(p), " ", arch(p), " ",
          Compat.Sys.islinux(p) ? "($(p.libc)) " : "",
          "UserNSRunner")
end

function Base.run(ur::UserNSRunner, cmd, logpath::AbstractString; verbose::Bool = false, tee_stream=STDOUT)
    did_succeed = true
    cd(dirname(sandbox_path)) do
        oc = OutputCollector(setenv(`$(ur.sandbox_cmd) $cmd`, ur.sandbox_cmd.env); verbose=verbose, tee_stream=tee_stream)

        did_succeed = wait(oc)

        if !isempty(logpath)
            # Write out the logfile, regardless of whether it was successful
            mkpath(dirname(logpath))
            open(logpath, "w") do f
                # First write out the actual command, then the command output
                println(f, cmd)
                print(f, merge(oc))
            end
        end
    end

    # Return whether we succeeded or not
    return did_succeed
end

function run_interactive(ur::UserNSRunner, cmd::Cmd, stdin = nothing, stdout = nothing, stderr = nothing)
    cd(dirname(sandbox_path)) do
        cmd = setenv(`$(ur.sandbox_cmd) $(cmd)`, ur.sandbox_cmd.env)
        if stdin != nothing
            cmd = pipeline(cmd, stdin=stdin)
        end
        if stdout != nothing
            cmd = pipeline(cmd, stdout=stdout)
        end
        if stderr != nothing
            cmd = pipeline(cmd, stderr=stderr)
        end
        run(cmd)
    end
end

function runshell(ur::UserNSRunner, args...)
    run_interactive(ur, `/bin/bash`, args...)
end

function runshell()
    return runshell(UserNSRunner(pwd(); cwd="/workspace/", overlay=false))
end
