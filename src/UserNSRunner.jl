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

    shards::Vector{CompilerShard}
    workspace_root::String
end

function UserNSRunner(workspace_root::String;
                      cwd = nothing,
                      workspaces::Vector = Pair[],
                      platform::Platform = platform_key_abi(),
                      extra_env=Dict{String, String}(),
                      verbose::Bool = false,
                      compiler_wrapper_path::String = mktempdir(),
                      kwargs...)
    global use_ccache, use_squashfs, runner_override

	# Check that our kernel is new enough to use this runner
	kernel_version_check()

    # Check to make sure we're not going to try and bindmount within an
    # encrypted directory, as that triggers kernel bugs
    check_encryption(workspace_root; verbose=verbose)

    # Construct environment variables we'll use from here on out
    envs = merge(platform_envs(platform; verbose=verbose), extra_env)

    # JIT out some compiler wrappers, add it to our mounts
    generate_compiler_wrappers!(platform; bin_path=compiler_wrapper_path)
    push!(workspaces, compiler_wrapper_path => "/opt/bin")

    # the workspace_root is always a workspace, and we always mount it first
    insert!(workspaces, 1, workspace_root => "/workspace")

    # If we're enabling ccache, then mount in a read-writeable volume at /root/.ccache
    if use_ccache
        if !isdir(ccache_dir())
            mkpath(ccache_dir())
        end
        push!(workspaces, ccache_dir() => "/root/.ccache")
    end

    # Choose the shards we're going to mount
    shards = choose_shards(platform; extract_kwargs(kwargs, (:preferred_gcc_version,:bootstrap_list))...)
	
    # Construct sandbox command to look at the location it'll be mounted under
    mpath = mount_path(shards[1], workspace_root)
    sandbox_cmd = `$(mpath)/sandbox`
    if verbose
        sandbox_cmd = `$sandbox_cmd --verbose`
    end
    sandbox_cmd = `$sandbox_cmd --rootfs $(mpath)`
    if cwd != nothing
        sandbox_cmd = `$sandbox_cmd --cd $cwd`
    end

    # Add in read-only mappings and read-write workspaces
    for (outside, inside) in workspaces
        sandbox_cmd = `$sandbox_cmd --workspace $outside:$inside`
    end

    # Mount in compiler shards (excluding the rootfs shard)
    for shard in shards[2:end]
        mpath = mount_path(shard, workspace_root)
        sandbox_cmd = `$sandbox_cmd --map $(mpath):$(map_target(shard))`
    end

	# If runner_override is not yet set, let's probe to see if we can use
	# unprivileged containers, and if we can't, switch over to privileged.
	if runner_override == ""
		if !probe_unprivileged_containers()
			msg = strip("""
			Unable to run unprivileged containers on this system!
			This may be because your kernel does not support mounting overlay
			filesystems within user namespaces. To work around this, we will
			switch to using privileged containers. This requires the use of
			sudo. To choose this automatically, set the BINARYBUILDER_RUNNER
			environment variable to "privileged" before starting Julia.
			""")
			@warn(replace(msg, "\n" => " "))
			runner_override = "privileged"
		else
			runner_override = "userns"
		end
	end

    # Check to see if we need to run privileged containers.
    if runner_override == "privileged"
        # Next, prefer `sudo`, but allow fallback to `su`. Also, force-set
        # our environmental mappings with sudo, because it is typically
        # lost and forgotten.  :(
        if sudo_cmd() == `sudo`
            sudo_envs = vcat([["-E", "$k=$(envs[k])"] for k in keys(envs)]...)
            sandbox_cmd = `$(sudo_cmd()) $(Cmd(sudo_envs)) $(sandbox_cmd)`
        else
            sandbox_cmd = `$(sudo_cmd()) "$sandbox_cmd"`
        end
    end

    # Finally, return the UserNSRunner in all its glory
    return UserNSRunner(sandbox_cmd, envs, platform, shards, workspace_root)
end

function show(io::IO, x::UserNSRunner)
    p = x.platform
    # Displays as, e.g., Linux x86_64 (glibc) UserNSRunner
    write(io, "$(typeof(p).name.name)", " ", arch(p), " ",
          Sys.islinux(p) ? "($(p.libc)) " : "",
          "UserNSRunner")
end

mount_shards(ur::UserNSRunner; verbose::Bool = false) = mount.(ur.shards, ur.workspace_root; verbose=verbose)
unmount_shards(ur::UserNSRunner; verbose::Bool = false) = unmount.(ur.shards, ur.workspace_root; verbose=verbose)

prompted_userns_run_privileged = false
function Base.run(ur::UserNSRunner, cmd, logpath::AbstractString; verbose::Bool = false, tee_stream=stdout)
    global prompted_userns_run_privileged
    if runner_override == "privileged" && !prompted_userns_run_privileged
        @info("Running privileged container via `sudo`, may ask for your password:")
        prompted_userns_run_privileged = true
    end

    did_succeed = false
    try
        mount_shards(ur; verbose=verbose)
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
    finally
        unmount_shards(ur; verbose=verbose)
    end


    # Return whether we succeeded or not
    return did_succeed
end

const AnyRedirectable = Union{Base.AbstractCmd, Base.TTY, IOStream}
function run_interactive(ur::UserNSRunner, cmd::Cmd; stdin = nothing, stdout = nothing, stderr = nothing)
    global prompted_userns_run_privileged
    if runner_override == "privileged" && !prompted_userns_run_privileged
        @info("Running privileged container via `sudo`, may ask for your password:")
        prompted_userns_run_privileged = true
    end

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

    try
        mount_shards(ur)
        if stdout isa IOBuffer
            if !(stdin isa IOBuffer)
                stdin = devnull
            end
            process = open(cmd, "r", stdin)
            @async begin
                while !eof(process)
                    write(stdout, read(process))
                end
            end
            wait(process)
        else
            run(cmd)
        end
    finally
        unmount_shards(ur)
    end
end

"""
    uname()

On Linux systems, return the strings returned by the `uname()` function in libc
"""
function uname()
    # Get libc and handle to uname
    libcs = filter(x -> occursin("libc.so", x), dllist())
    if isempty(libcs)
        error("Could not find libc, unable to call uname()")
    end
    libc = dlopen(first(libcs))
    uname_hdl = dlsym(libc, :uname)

    # The uname struct can have wildly differing layouts; we take advantage
    # of the fact that it is just a bunch of NULL-terminated strings laid out
    # one after the other, and that it is (as best as I can tell) at maximum
    # around 1.5KB long.  We bump up to 2KB to be safe.
    uname_struct = zeros(UInt8, 2048)
    ccall(uname_hdl, Cint, (Ptr{UInt8},), uname_struct)

    # Parse out all the strings embedded within this struct
    strings = String[]
    idx = 1
    while idx < length(uname_struct)
        # Extract string
        new_string = unsafe_string(pointer(uname_struct, idx))
        push!(strings, new_string)
        idx += length(new_string) + 1

        # Skip trailing zeros
        while uname_struct[idx] == 0 && idx < length(uname_struct)
            idx += 1
        end
    end

    return strings
end

function kernel_version_check(;verbose::Bool = false)
    # If we're not on Linux, just say everything is okay.
    if !Sys.islinux()
        return
    end

    uname_strings = try
        uname()
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end

        @warn("Unable to run `uname()` to check version number; assuming kernel version >= 3.18")
        return
    end

    # Otherwise, get the strings, convert to VersionNumber
    kernel_version = nothing

    # Some distributions tack extra stuff onto the version number.  We walk backwards
    # from the end, searching for the longest string that we can extract a VersionNumber
    # out of.  We choose a minimum length of 5, as all kernel version numbers will be at
    # least `X.Y.Z`.
    for end_idx in length(uname_strings[3]):-1:5
        try
            kernel_version = VersionNumber(uname_strings[3][1:end_idx])
            break
        catch e
            if isa(e, InterruptException)
                rethrow(e)
            end
        end
    end

    # If we were unable to parse any part of the version number, then warn and exit.
    if kernel_version === nothing
        @warn("Unable to check version number; assuming kernel version >= 3.18")
        return
    end

    # Otherwise, we have a kernel version and if it's too old, we should freak out.
    if kernel_version < v"3.18"
        error("Kernel version too old: detected $(kernel_version), need at least 3.18!")
    end

    if verbose
        @info("Parsed kernel version \"$(kernel_version)\"")
    end
end

function probe_unprivileged_containers(;verbose::Bool=false)
    # Choose and prepare our shards
    root_shard = choose_shards(Linux(:x86_64))[1]

    # Ensure we're not about to make fools of ourselves by trying to mount an
    # encrypted directory, which triggers kernel bugs.  :(
    check_encryption(tempdir())

    return mktempdir() do tmpdir
        try
            # Construct an extremely simple sandbox command
            mpath = mount(root_shard, tmpdir)
            sandbox_cmd = `$(mpath)/sandbox --rootfs $(mpath)`
            cmd = `$(sandbox_cmd) -- /bin/sh -c "echo hello julia"`

            if verbose
                @info("Probing for unprivileged container capability...")
            end
            oc = OutputCollector(cmd; verbose=verbose, tail_error=false)
            return wait(oc) && merge(oc) == "hello julia\n"
        finally
            unmount(root_shard, tmpdir)
        end
    end
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
        @info("Checking to see if $path is encrypted...")
    end

    # Get a listing of the current mounts.  If we can't do this, just give up
    if !isfile("/proc/mounts")
        if verbose
            @info("Couldn't open /proc/mounts, returning...")
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
        parent_mounts[argmax(map(m->length(m[1]), parent_mounts))]
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

    is_encrypted, mountpoint = is_ecryptfs(storage_dir(); verbose=verbose)
    if is_encrypted
        push!(msg, replace(strip("""
        Cannot mount rootfs at $(storage_dir()), it has been encrypted!  Change
        your rootfs cache directory to one outside of $(mountpoint) by setting
        the BINARYBUILDER_ROOTFS_DIR environment variable and try again.
        """), "\n" => " "))
    end

    if !isempty(msg)
        error(join(msg, "\n"))
    end
end
