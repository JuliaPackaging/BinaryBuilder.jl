import Base: run, show

type DockerRunner
    cmd_prefix::Cmd
    platform::Symbol
end

function show(io::IO, x::DockerRunner)
    write(io, "$(x.platform) DockerRunner")
end

function getuid()
    return ccall((:getuid, :libc), UInt32, ())
end

function getgid()
    return ccall((:getgid, :libc), UInt32, ())
end

function target_envs(target::String)
    target_tool = tool -> "/opt/$(target)/bin/$(target)-$(tool)"
    mapping = Dict(
        "PATH" => "/opt/$(target)/bin:/usr/local/bin:/usr/bin:/bin",
        "AR" => target_tool("ar"),
        "CC" => target_tool("gcc"),
        "CXX" => target_tool("g++"),
        "FC" => target_tool("gfortran"),
        "LD" => target_tool("ld"),
        "NM" => target_tool("nm"),
        "AS" => target_tool("as"),
        "RANLIB" => target_tool("ranlib"),
        "STRIP" => target_tool("strip"),
        "INSTALL_NAME_TOOL" => target_tool("install_name_tool"),
        "LIBTOOL" => target_tool("libtool"),
        "LIPO" => target_tool("lipo"),
        "OTOOL" => target_tool("otool"),
        "target" => target,
    )

    return mapping
end

function platform_map(platform::Symbol)
    const mapping = Dict(
        :linux64 => "x86_64-linux-gnu",
        :linuxaarch64 => "aarch64-linux-gnu",
        :linuxarmv7l => "arm-linux-gnueabihf",
        :linuxppc64le => "powerpc64le-linux-gnu",
        :mac64 => "x86_64-apple-darwin14",
        #:win64 => "x86_64-mingw-something-something",
    )
    return mapping[platform]
end

function current_platform()
    @static if is_linux()
        @static if Sys.ARCH == :x86_64
            return :linux64
        end
        @static if Sys.ARCH == :aarch64
            return :linuxaarch64
        end
        @static if Sys.ARCH == :armv7l
            return :linuxarmv7l
        end
        @static if Sys.ARCH == :ppc64le
            return :linuxppc64le
        end
    end
    @static if is_apple()
        return :mac64
    end
    #@static if is_windows()
    #    return :win64
    #end
end

function DockerRunner(prefix::Prefix = global_prefix, volume_mapping::Vector = [], platform::Symbol = current_platform())
    # We are using `docker run` to provide isolation
    cmd_prefix = `docker run --rm -i`

    # The volumes we'll always map into the docker container
    push!(volume_mapping, (prefix.path, prefix.path))
    for v in volume_mapping
        cmd_prefix = `$cmd_prefix -v $(v[1]):$(v[2])`
    end

    # The environment variables we'll set
    env_mapping = target_envs(platform_map(platform))
    for v in env_mapping
        cmd_prefix = `$cmd_prefix -e $(v[1])=$(v[2])`
    end

    # Set our user id and group id to match the outside world
    cmd_prefix = `$cmd_prefix --user=$(getuid()):$(getgid())`

    # Manually set DESTDIR environment variable
    cmd_prefix = `$cmd_prefix -e DESTDIR=$(prefix.path)`

    return DockerRunner(cmd_prefix, platform)
end

function run(dr::DockerRunner, cmd::Cmd, logpath::AbstractString; verbose::Bool = false)
    const BUILD_IMAGE = "staticfloat/julia_workerbase:crossbuild-x64"

    # Create the directory where we'll store logs, if we need to
    mkpath(dirname(logpath))

    # Run the command
    d = pwd()
    user_cmd = `$(dr.cmd_prefix) -w $(d) -v $(d):$(d) $BUILD_IMAGE $cmd`
    oc = OutputCollector(user_cmd; verbose=verbose)
    did_succeed = wait(oc)

    # Write out the logfile, regardless of whether it was successful or not 
    mkpath(dirname(logpath))
    open(logpath, "w") do f
        # First write out the actual command, then the command output
        println(f, cmd)
        print(f, merge(oc))
    end

    # If we were not successful, fess up
    if !did_succeed
        msg = "Build step $(step.name) did not complete successfully\n"
        error(msg)
    end

    return true
end