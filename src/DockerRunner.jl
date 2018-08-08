"""
    DockerRunner

A `DockerRunner` represents Elliot's bowing of his head to the inevitability
that the QemuRunner just isn't ready for primetime yet, and he needs something
to use while he's on the plane to JuliaCon to whip up said JuliaCon presentation.
"""
mutable struct DockerRunner <: Runner
    docker_cmd::Cmd
    platform::Platform
end


function DockerRunner(workspace_root::String; cwd = nothing,
                      platform::Platform = platform_key(),
                      extra_env=Dict{String, String}(),
                      verbose::Bool = false,
                      mappings::Vector = platform_def_mappings(platform),
                      workspaces::Vector = [])
    global use_ccache

    # Ensure the rootfs for this platform is downloaded and up to date.
    # Also, since we require the Linux(:x86_64) shard for HOST_CC....
    update_rootfs(triplet.([platform, Linux(:x86_64)]);
                  verbose=verbose, squashfs=false, mount=true)

    # Check to make sure we're not going to try and bindmount within an
    # encrypted directory, as that triggers kernel bugs
    check_encryption(workspace_root; verbose=verbose)

    # Construct environment variables we'll use from here on out
    envs = merge(target_envs(triplet(platform)), extra_env)

    # the workspace_root is always a workspace, and we always mount it first
    insert!(workspaces, 1, workspace_root => "/workspace")

    # If we're enabling ccache, then map in a docker volume for it
    if use_ccache
        push!(workspaces, "binarybuilder_ccache" => "/root/.ccache")
    end

    # Construct docker command
    docker_cmd = `docker run`

    if cwd != nothing
        docker_cmd = `$docker_cmd -w $(abspath(cwd))`
    end

    # Add in read-only mappings and read-write workspaces
    for (outside, inside) in reverse!(mappings)
        # Docker needs these things canonicalized, otherwise its mappings can get denied
        if isdir(outside) || isfile(outside)
            outside = realpath(outside)
        end

        if occursin("x86_64-apple-darwin", outside)
            docker_cmd = `$docker_cmd -v $(outside):$inside`
        else
            docker_cmd = `$docker_cmd -v $(outside):$inside:ro`
        end
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
    return DockerRunner(docker_cmd, platform)
end


function Base.run(dr::DockerRunner, cmd, logpath::AbstractString; verbose::Bool = false, tee_stream=stdout)
    did_succeed = true
    oc = OutputCollector(`$(dr.docker_cmd) staticfloat/julia_crossbase:x64 $(cmd)`; verbose=verbose, tee_stream=tee_stream)
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

    # Return whether we succeeded or not
    return did_succeed
end

function run_interactive(dr::DockerRunner, cmd::Cmd; stdin = nothing, stdout = nothing, stderr = nothing)
    cmd = `$(dr.docker_cmd) -ti staticfloat/julia_crossbase:x64 $(cmd)`
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