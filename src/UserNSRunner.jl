const rootfs_url_root = "https://julialangmirror.s3.amazonaws.com"
const rootfs_url = "$rootfs_url_root/binarybuilder-rootfs-2017-11-01.tar.gz"
const rootfs_sha256 = "43d75724f0f5c5680a5fe60cc49ae6a72a8514355162c647834b563e374be7e2"
const rootfs_tar = joinpath(dirname(@__FILE__), "..", "deps", "rootfs.tar.gz")
const rootfs = joinpath(dirname(@__FILE__), "..", "deps", "root")
const sandbox_path = joinpath(dirname(@__FILE__), "..", "deps", "sandbox")

"""
    UserNSRunner

A `UserNSRunner` represents an "execution context", an object that bundles all
necessary information to run commands within the container that contains
our crossbuild environment.  Use `run()` to actually run commands within the
`DockerRunner`, and `runshell()` as a quick way to get an interactive shell
within the crossbuild environment.
"""
type UserNSRunner
    sandbox_cmd::Cmd
    platform::Platform
end

function update_rootfs(;verbose::Bool = false)
    # Check to make sure we have the latest version downloaded properly
    try
        if verbose
            info("Verifying rootfs download...")
        end
        download_verify(rootfs_url, rootfs_sha256, rootfs_tar; verbose=verbose)
    catch
        if verbose
            info("rootfs image verification failed, downloading new rootfs...")
        end

        # If download_verify failed, we need to clear out the old rootfs and
        # download the new rootfs image.  Start by removing the old rootfs: 
        rm(rootfs; force=true, recursive=true)
        rm(rootfs_tar; force=true)

        # Then download and unpack again
        download_verify(rootfs_url, rootfs_sha256, rootfs_tar; verbose=verbose)
    end

    # Next, if the rootfs does not already exist, unpack it
    if !isdir(rootfs)
        if verbose
            info("Unpacking rootfs...")
        end
        unpack(rootfs_tar, rootfs; verbose=verbose)
    end
end

function UserNSRunner(sandbox::String; cwd = nothing, platform::Platform = platform_key(), extra_env=Dict{String, String}())
    sandbox_cmd = `$sandbox_path --rootfs $rootfs --overlay $sandbox/overlay_root --overlay_workdir $sandbox/overlay_workdir --workspace $sandbox/workspace`
    if cwd != nothing
        sandbox_cmd = `$sandbox_cmd --cd $cwd`
    end
    sandbox_cmd = setenv(sandbox_cmd, merge(target_envs(triplet(platform)), extra_env))
    UserNSRunner(sandbox_cmd, platform)
end

function show(io::IO, x::UserNSRunner)
    p = x.platform
    # Displays as, e.g., Linux x86_64 (glibc) DockerRunner
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
            # Write out the logfile, regardless of whether it was successful or not
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
