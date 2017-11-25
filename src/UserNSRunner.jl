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

function UserNSRunner(workspace_root::String; overlay = true, cwd = nothing,
                      platform::Platform = platform_key(),
                      extra_env=Dict{String, String}(),
                      verbose::Bool = true)
    global sandbox_path

    # Ensure the rootfs for this platform is downloaded and up to date
    update_rootfs(triplet(platform); verbose=verbose)

    # Construct sandbox command
    sandbox_cmd = `$sandbox_path --rootfs $(rootfs_dir())`

    # If `overlay` is `true`, we are using overlayfs to create a temporary
    # layer on top of an underyling read-only filesystem image.  Otherwise,
    # we can actually edit the `$workspace_root` folder.  The only case where
    # we set `overlay` to `false` right now is when launching the `vim` editor
    # inside of the userns to edit a script outside of the userns.
    if overlay
        sandbox_cmd = `$sandbox_cmd --overlay $workspace_root/overlay_root`
        sandbox_cmd = `$sandbox_cmd --overlay_workdir $workspace_root/overlay_workdir`
        sandbox_cmd = `$sandbox_cmd --workspace $workspace_root/workspace`
    else
        sandbox_cmd = `$sandbox_cmd --workspace $workspace_root`
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
