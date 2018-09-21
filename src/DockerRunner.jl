"""
    DockerRunner

A `DockerRunner` represents Elliot's bowing of his head to the inevitability
that the QemuRunner just isn't ready for primetime yet, and he needs something
to use while he's on the plane to JuliaCon to whip up said JuliaCon presentation.
"""
mutable struct DockerRunner <: Runner
    docker_cmd::Cmd
    prefix::AbstractString
    rootfs_version::VersionNumber
    platform::Platform
end

docker_image(version::VersionNumber) = "julia_binarybuilder_rootfs:v$(version)"
docker_image(rootfs::CompilerShard) = docker_image(rootfs.version)

"""
    import_docker_image(rootfs::CompilerShard; verbose::Bool = false)

Checks to see if the given rootfs has been imported into docker yet; if it
hasn't, then do so so that we can run things like:

    docker run -ti binarybuilder_rootfs:v2018.08.27 /bin/bash

Which, after all, is the foundation upon which this whole doodad is built.
"""
function import_docker_image(rootfs::CompilerShard; verbose::Bool = false)
    if rootfs.archive_type != :targz
        throw(ArgumentError("Unable to import squashfs into docker!  Use .tar.gz shards!"))
    end

    # Does this image already exist?  If so, we're done!
    if success(`docker inspect --type=image $(docker_image(rootfs))`)
        if verbose
            @info("Docker base image already exists, skipping import...")
        end
        return
    end

    # Otherwise, import it!
    dockerfile_cmds = "ENTRYPOINT [\"/docker_entrypoint.sh\"]"
    run(`docker import $(download_path(rootfs)) -c $(dockerfile_cmds) $(docker_image(rootfs))`)
    return
end

function DockerRunner(workspace_root::String;
                      cwd = nothing,
                      platform::Platform = platform_key_abi(),
                      workspaces::Vector = [],
                      extra_env=Dict{String, String}(),
                      verbose::Bool = false)
    global use_ccache

    # Check to make sure we're not going to try and bindmount within an
    # encrypted directory, as that can trigger kernel bugs
    check_encryption(workspace_root; verbose=verbose)

    # Choose and prepare our shards
    shards = choose_shards(platform)
    prepare_shard.(shards; mount_squashfs = false, verbose=verbose)

    # Import docker image
    import_docker_image(shards[1]; verbose=verbose)
    
    # Construct environment variables we'll use from here on out
    envs = merge(platform_envs(platform), extra_env)

    # the workspace_root is always a workspace, and we always mount it first
    insert!(workspaces, 1, workspace_root => "/workspace")

    # If we're enabling ccache, then map in a named docker volume for it
    if use_ccache
        push!(workspaces, "binarybuilder_ccache" => "/root/.ccache")
    end

    # Construct docker command
    docker_cmd = `docker run --privileged `#--cap-add SYS_ADMIN`

    if cwd != nothing
        docker_cmd = `$docker_cmd -w $(abspath(cwd))`
    end

    # Add in read-only mappings and read-write workspaces
    for shard in shards[2:end]
        outside = realpath(mount_path(shard))
        inside = map_target(shard)
        docker_cmd = `$docker_cmd -v $(outside):$(inside):ro`
    end
    for (outside, inside) in workspaces
        if isdir(outside) || isfile(outside)
            outside = realpath(outside)
        end
        docker_cmd = `$docker_cmd -v $(outside):$inside`
    end

    # Build up environment mappings
    for (k, v) in envs
        docker_cmd = `$docker_cmd -e $k=$v`
    end

    # Finally, return the DockerRunner in all its glory
    return DockerRunner(docker_cmd, workspace_root, shards[1].version, platform)
end

"""
    chown_cleanup(dr::DockerRunner)

On Linux, the user id inside of the docker container doesn't correspond to ours
on the outside, so permissions get all kinds of screwed up.  To fix this, we
have to `chown -R \$(id -u):\$(id -g) \$prefix`, which really sucks, but is
still better than nothing.  This is why we prefer the UserNSRunner on Linux.
"""
function chown_cleanup(dr::DockerRunner; verbose::Bool = false)
    if !Sys.islinux()
        return
    end

    if verbose
        @info("chown'ing prefix back to us...")
    end
    run(`$(sudo_cmd()) chown $(getuid()):$(getgid()) -R $(dr.prefix)`)
end

function Base.run(dr::DockerRunner, cmd, logpath::AbstractString; verbose::Bool = false, tee_stream=stdout)
    did_succeed = true
    oc = OutputCollector(`$(dr.docker_cmd) $(docker_image(dr.rootfs_version)) $(cmd)`; verbose=verbose, tee_stream=tee_stream)
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

    # Cleanup permissions, if we need to.
    chown_cleanup(dr; verbose=verbose)

    # Return whether we succeeded or not
    return did_succeed
end

function run_interactive(dr::DockerRunner, cmd::Cmd; stdin = nothing, stdout = nothing, stderr = nothing)
    run_flags = (stdin === nothing && stdout === nothing && stderr === nothing) ? "-ti" : "-i"
    cmd = `$(dr.docker_cmd) $(run_flags) -i $(docker_image(dr.rootfs_version)) $(cmd)`
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
    
    # Cleanup permissions, if we need to.
    chown_cleanup(dr)
end
