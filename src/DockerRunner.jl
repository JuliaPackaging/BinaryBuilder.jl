"""
    DockerRunner

Use `docker` as an execution engine; a reasonable backup for platforms that do
not have user namespaces (e.g. MacOS, Windows).
"""
mutable struct DockerRunner <: Runner
    docker_cmd::Cmd
    env::Dict{String, String}
    platform::Platform

    shards::Vector{CompilerShard}
    workspace_root::String
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
function import_docker_image(rootfs::CompilerShard, workspace_root::String; verbose::Bool = false)
    # Does this image already exist?  If so, we're done!
    if success(`docker inspect --type=image $(docker_image(rootfs))`)
        if verbose
            @info("Docker base image already exists, skipping import...")
        end
        return
    end

    # Otherwise, import it!
    dockerfile_cmds = "ENTRYPOINT [\"/docker_entrypoint.sh\"]"
    rootfs_path = mount(rootfs, workspace_root; verbose=verbose)
    if verbose
        @info("Importing docker base image from $(rootfs_path) to $(docker_image(rootfs))")
    end
    run(pipeline(pipeline(
        `tar -c -C $(rootfs_path) .`,
        `docker import - -c $(dockerfile_cmds) $(docker_image(rootfs))`;
    ); stdout=devnull))
    return
end

# Helper function to delete a previously-imported docker image
delete_docker_image() = delete_docker_image(first(choose_shards(platform_key_abi())))
delete_docker_image(rootfs::CompilerShard) = success(`docker rmi $(docker_image(rootfs))`)

function DockerRunner(workspace_root::String;
                      cwd = nothing,
                      platform::Platform = platform_key_abi(),
                      workspaces::Vector = [],
                      extra_env=Dict{String, String}(),
                      verbose::Bool = false,
                      compiler_wrapper_path::String = mktempdir(),
                      src_name::AbstractString = "",
                      kwargs...)
    global use_ccache

    # Check to make sure we're not going to try and bindmount within an
    # encrypted directory, as that can trigger kernel bugs
    check_encryption(workspace_root; verbose=verbose)

    # Construct environment variables we'll use from here on out
    envs = merge(platform_envs(platform, src_name; verbose=verbose), extra_env)

    # JIT out some compiler wrappers, add it to our mounts
    generate_compiler_wrappers!(platform; bin_path=compiler_wrapper_path, extract_kwargs(kwargs, (:compilers,))...)
    push!(workspaces, compiler_wrapper_path => "/opt/bin")

    # the workspace_root is always a workspace, and we always mount it first
    insert!(workspaces, 1, workspace_root => "/workspace")

    # If we're enabling ccache, then map in a named docker volume for it
    if use_ccache
        if !isdir(ccache_dir())
            mkpath(ccache_dir())
        end
        push!(workspaces, "binarybuilder_ccache" => "/root/.ccache")
    end

    # Choose the shards we're going to mount
    shards = choose_shards(platform; extract_kwargs(kwargs, (:preferred_gcc_version,:bootstrap_list,:compilers))...)

    # Import docker image
    import_docker_image(shards[1], workspace_root; verbose=verbose)

    # Construct docker command
    docker_cmd = `docker run --rm --privileged `#--cap-add SYS_ADMIN`

    if cwd != nothing
        docker_cmd = `$docker_cmd -w /$(abspath(cwd))`
    end

    # Add in read-only mappings and read-write workspaces
    for shard in shards[2:end]
        outside = realpath(mount(shard, workspace_root; verbose=verbose))
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
    return DockerRunner(docker_cmd, envs, platform, shards, workspace_root)
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
    run(`$(sudo_cmd()) chown $(getuid()):$(getgid()) -R $(dr.workspace_root)`)
end

function Base.run(dr::DockerRunner, cmd, logger::IO=stdout; verbose::Bool=false, tee_stream=stdout)
    did_succeed = true
    docker_cmd = `$(dr.docker_cmd) $(docker_image(dr.shards[1])) $(cmd)`
    @debug("About to run: $(docker_cmd)")

    oc = OutputCollector(docker_cmd; verbose=verbose, tee_stream=tee_stream)
    did_succeed = wait(oc)

    # First write out the actual command, then the command output
    println(logger, cmd)
    print(logger, merge(oc))

    # Cleanup permissions, if we need to.
    chown_cleanup(dr; verbose=verbose)

    # Return whether we succeeded or not
    return did_succeed
end

function run_interactive(dr::DockerRunner, cmd::Cmd; stdin = nothing, stdout = nothing, stderr = nothing, verbose::Bool = false)
    tty_or_nothing(s) = s === nothing || typeof(s) <: Base.TTY
    run_flags = all(tty_or_nothing.((stdin, stdout, stderr))) ? "-ti" : "-i"
    docker_cmd = `$(dr.docker_cmd) $(run_flags) -i $(docker_image(dr.shards[1])) $(cmd)`
    if verbose
        @debug("About to run: $(docker_cmd)")
    end

    if stdin isa AnyRedirectable
        docker_cmd = pipeline(docker_cmd, stdin=stdin)
    end
    if stdout isa AnyRedirectable
        docker_cmd = pipeline(docker_cmd, stdout=stdout)
    end
    if stderr isa AnyRedirectable
        docker_cmd = pipeline(docker_cmd, stderr=stderr)
    end

    if stdout isa IOBuffer
        if !(stdin isa IOBuffer)
            stdin = devnull
        end
        process = open(docker_cmd, "r", stdin)
        @async begin
            while !eof(process)
                write(stdout, read(process))
            end
        end
        wait(process)
    else
        run(docker_cmd)
    end
    
    # Cleanup permissions, if we need to.
    chown_cleanup(dr; verbose=verbose)
end
