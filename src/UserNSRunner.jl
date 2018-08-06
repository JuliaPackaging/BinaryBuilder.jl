import Base: show

"""
    UserNSRunner

A `UserNSRunner` represents an "execution context", an object that bundles all
necessary information to run commands within the container that contains
our crossbuild environment.  Use `run()` to actually run commands within the
`UserNSRunner`, and `runshell()` as a quick way to get an interactive shell
within the crossbuild environment.
"""
mutable struct UserNSRunner <: Runner
    sandbox_cmd::Cmd
    env::Dict{String, String}
    platform::Platform
end

function platform_def_mapping(platform)
    tp = triplet(platform)
    mapping = Pair{String,String}[
        shards_dir(tp) => joinpath("/opt", tp)
    ]

    # We might also need the x86_64-linux-gnu platform for bootstrapping,
    # so make sure that's always included
    if platform != Linux(:x86_64)
        ltp = triplet(Linux(:x86_64))
        push!(mapping, shards_dir(ltp) => joinpath("/opt", ltp))
    end

    # If we're trying to run macOS and we have an SDK directory, mount that!
    if platform == MacOS()
        sdk_version = "MacOSX10.10.sdk"
        sdk_shard_path = shards_dir(sdk_version)
        push!(mapping, sdk_shard_path => joinpath("/opt", tp, sdk_version))
    end

    # Reverse mapping order, because `sandbox` reads them backwards
    reverse!(mapping)
    return mapping
end

function UserNSRunner(workspace_root::String; cwd = nothing,
                      platform::Platform = platform_key(),
                      extra_env=Dict{String, String}(),
                      verbose::Bool = false,
                      mappings::Vector = platform_def_mapping(platform),
                      workspaces::Vector = Pair[])
    global use_ccache

    # Ensure the rootfs for this platform is downloaded and up to date.
    # Also, since we require the Linux(:x86_64) shard for HOST_CC....
    update_rootfs(triplet.([platform, Linux(:x86_64)]); verbose=verbose)

    # Check to make sure we're not going to try and bindmount within an
    # encrypted directory, as that triggers kernel bugs
    check_encryption(workspace_root; verbose=verbose)

    # Construct environment variables we'll use from here on out
    envs = merge(target_envs(triplet(platform)), extra_env)

    # the workspace_root is always a workspace, and we always mount it first
    insert!(workspaces, 1, workspace_root => "/workspace")

    # If we're enabling ccache, then mount in a read-writeable volume at /root/.ccache
    if use_ccache
        if !isdir(ccache_dir())
            mkpath(ccache_dir())
        end
        push!(workspaces, ccache_dir() => "/root/.ccache")
    end


    # Construct sandbox command
    sandbox_cmd = `$(sandbox_path())`
    if verbose
        sandbox_cmd = `$sandbox_cmd --verbose`
    end
    sandbox_cmd = `$sandbox_cmd --rootfs $(rootfs_dir())`
    if cwd != nothing
        sandbox_cmd = `$sandbox_cmd --cd $cwd`
    end

    # Add in read-only mappings and read-write workspaces
    for (outside, inside) in mappings
        sandbox_cmd = `$sandbox_cmd --map $outside:$inside`
    end
    for (outside, inside) in workspaces
        sandbox_cmd = `$sandbox_cmd --workspace $outside:$inside`
    end

    # Check to see if we need to run privileged containers.
    if runner_override == "privileged"
        # Next, prefer `sudo`, but allow fallback to `su`. Also, force-set
        # $LD_LIBRARY_PATH with these commands, because it is typically
        # lost and forgotten.  :(
        if sudo_cmd() == `sudo`
            sandbox_cmd = `$(sudo_cmd()) -E LD_LIBRARY_PATH=$(envs["LD_LIBRARY_PATH"]) $sandbox_cmd`
        else
            sandbox_cmd = `$(sudo_cmd()) "$sandbox_cmd"`
        end
    end

    # Finally, return the UserNSRunner in all its glory
    return UserNSRunner(sandbox_cmd, envs, platform)
end

function show(io::IO, x::UserNSRunner)
    p = x.platform
    # Displays as, e.g., Linux x86_64 (glibc) UserNSRunner
    write(io, "$(typeof(p).name.name)", " ", arch(p), " ",
          Compat.Sys.islinux(p) ? "($(p.libc)) " : "",
          "UserNSRunner")
end

function Base.run(ur::UserNSRunner, cmd, logpath::AbstractString; verbose::Bool = false, tee_stream=stdout)
    if runner_override == "privileged"
        msg = "Running privileged container via `sudo`, may ask for your password:"
        BinaryProvider.info_onchange(msg, "privileged", "userns_run_privileged")
    end

    did_succeed = true
    cd(rootfs_dir()) do
        oc = OutputCollector(setenv(`$(ur.sandbox_cmd) -- $(cmd)`, ur.env); verbose=verbose, tee_stream=tee_stream)

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

const AnyRedirectable = Union{Base.AbstractCmd, Base.TTY, IOStream}
function run_interactive(ur::UserNSRunner, cmd::Cmd; stdin = nothing, stdout = nothing, stderr = nothing)
    if runner_override == "privileged"
        msg = "Running privileged container via `sudo`, may ask for your password:"
        BinaryProvider.info_onchange(msg, "privileged", "userns_run_privileged")
    end

    cd(rootfs_dir()) do
        cmd = setenv(`$(ur.sandbox_cmd) -- $(cmd)`, ur.env)
        if stdin isa AnyRedirectable
            cmd = pipeline(cmd, stdin=stdin)
        end
        if stdout isa AnyRedirectable
            cmd = pipeline(cmd, stdout=stdout)
        end
        if stderr isa AnyRedirectable
            cmd = pipeline(cmd, stderr=stderr)
        end

        if stdout isa IOBuffer
            if !(stdin isa IOBuffer)
                stdin = devnull
            end
            out, process = open(cmd, "r", stdin)
            @async begin
                while !eof(out)
                    write(stdout, read(out))
                end
            end
            wait(process)
        else
            run(cmd)
        end
    end
end

function runshell(ur::UserNSRunner, args...; kwargs...)
    run_interactive(ur, `/bin/bash`, args...; kwargs...)
end

function runshell(::Type{UserNSRunner}, platform::Platform = platform_key(); verbose::Bool = false)
    ur = UserNSRunner(
        pwd();
        cwd="/workspace/",
        platform=platform,
        verbose=verbose
    )
    return runshell(ur)
end

function probe_unprivileged_containers(;verbose::Bool=false)
    # Ensure the base rootfs is available
    update_rootfs(String[]; verbose=false)

    # Ensure we're not about to make fools of ourselves by trying to mount an
    # encrypted directory, which triggers kernel bugs.  :(
    check_encryption(pwd())

    # Construct an extremely simple sandbox command
    sandbox_cmd = `$(sandbox_path()) --rootfs $(rootfs_dir())`
    cmd = `$(sandbox_cmd) -- /bin/bash -c "echo hello julia"`

    if verbose
        Compat.@info("Probing for unprivileged container capability...")
    end
    oc = OutputCollector(cmd; verbose=verbose, tail_error=false)
    return wait(oc) && merge(oc) == "hello julia\n"
end

"""
    is_ecryptfs(path::AbstractString; verbose::Bool=false)

Checks to see if the given `path` (or any parent directory) is placed upon an
`ecryptfs` mount.  This is known not to work on current kernels, see this bug
for more details: https://bugzilla.kernel.org/show_bug.cgi?id=197603

This method returns whether it is encrypted or not, and what mountpoint it used
to make that decision.
"""
function is_ecryptfs(path::AbstractString; verbose::Bool=false)
    # Canonicalize `path` immediately, and if it's a directory, add a "/" so
    # as to be consistent with the rest of this function
    path = abspath(path)
    if isdir(path)
        path = abspath(path * "/")
    end

    if verbose
        Compat.@info("Checking to see if $path is encrypted...")
    end

    # Get a listing of the current mounts.  If we can't do this, just give up
    if !isfile("/proc/mounts")
        if verbose
            Compat.@info("Couldn't open /proc/mounts, returning...")
        end
        return false, path
    end
    mounts = String(read("/proc/mounts"))

    # Grab the fstype and the mountpoints
    mounts = [split(m)[2:3] for m in split(mounts, "\n") if !isempty(m)]

    # Canonicalize mountpoints now so as to dodge symlink difficulties
    mounts = [(abspath(m[1]*"/"), m[2]) for m in mounts]

    # Fast-path asking for a mountpoint directly (e.g. not a subdirectory)
    direct_path = [m[1] == path for m in mounts]
    parent = if any(direct_path)
        mounts[findfirst(direct_path)]
    else
        # Find the longest prefix mount:
        parent_mounts = [m for m in mounts if startswith(path, m[1])]
        parent_mounts[indmax(map(m->length(m[1]), parent_mounts))]
    end

    # Return true if this mountpoint is an ecryptfs mount
    return parent[2] == "ecryptfs", parent[1]
end

function check_encryption(workspace_root::AbstractString;
                          verbose::Bool = false)
    # If we've explicitly allowed ecryptfs, just quit out immediately
    global allow_ecryptfs
    if allow_ecryptfs
        return
    end
    msg = []
    
    is_encrypted, mountpoint = is_ecryptfs(workspace_root; verbose=verbose)
    if is_encrypted
        push!(msg, replace(strip("""
        Will not launch a user namespace runner within $(workspace_root), it
        has been encrypted!  Change your working directory to one outside of
        $(mountpoint) and try again.
        """), "\n" => " "))
    end

    is_encrypted, mountpoint = is_ecryptfs(rootfs_dir(); verbose=verbose)
    if is_encrypted
        push!(msg, replace(strip("""
        Cannot mount rootfs at $(rootfs_dir()), it has been encrypted!  Change
        your rootfs cache directory to one outside of $(mountpoint) by setting
        the BINARYBUILDER_ROOTFS_DIR environment variable and try again.
        """), "\n" => " "))
    end

    is_encrypted, mountpoint = is_ecryptfs(shards_dir(); verbose=verbose)
    if is_encrypted
        push!(msg, replace(strip("""
        Cannot mount rootfs shards within $(shards_dir()), it has been
        encrypted!  Change your shard cache directory to one outside of
        $(mountpoint) by setting the BINARYBUILDER_SHARDS_DIR environment
        variable and try again.
        """), "\n" => " "))
    end

    if !isempty(msg)
        error(join(msg, "\n"))
    end
end
