import Base: run, show
export update_build_image, DockerRunner, run, runshell

# The docker image we use
const BUILD_IMAGE = "staticfloat/julia_crossbuild:x64"
BUILD_IMAGE_UPDATED = false

"""
    should_update_build_image(force::Bool)

Helper function to determine whether we shuold or should not attempt to update
the build image containing all cross-compiler toolchains. To override automatic
updating, set the environment variable `BINBUILD_IMAGE_AUTOUPDATE` to `"true"`
or `"false"`.  To force updating always, set `force` to `true`.
"""
function should_update_build_image(force::Bool)
    global BUILD_IMAGE_UPDATED

    # If we're forcing the issue, then return true
    if force
        return true
    end

    # If we've already updated, then don't bother to
    if BUILD_IMAGE_UPDATED
        return false
    end

    # If the user has explicitly preferred us not to, then don't
    const no_synonyms = ["n", "no", "false"]
    if lowercase(get(ENV, "BINBUILD_IMAGE_AUTOUPDATE", "y")) in no_synonyms
        return false
    end

    # Otherwise, DEWIT!
    return true
end

"""
    update_build_image(; verbose::Bool = false, force::Bool = false)

Updates the build image containing all cross-compiler toolchains.  Checks for
updates upon first attempt to run a build by default.  Set `force` to `true`
to force an update, and to disable automatic updates (for instance if you are
sitting in a coffee shop desperately trying to test your build scripts and you
don't particularly feel like waiting for download the new 4GB+ image that
`@staticfloat` just pushed up) set the environment variable
`BINBUILD_IMAGE_AUTOUPDATE` to `"false"` before importing `BinaryBuilder`.
"""
function update_build_image(; verbose::Bool = false, force::Bool = false)
    global BUILD_IMAGE_UPDATED
    if should_update_build_image(force)    
        msg = """
        Updating build image $BUILD_IMAGE, this may take a few minutes. To
        disable automatic image updating, set the `BINBUILD_IMAGE_AUTOUPDATE`
        environment variable to `"false"` in your shell environment or in your
        `~/.juliarc.jl` file.
        """
        info(replace(strip(msg), "\n", " "))

        oc = OutputCollector(`docker pull $BUILD_IMAGE`; verbose=verbose)
        did_succeed = wait(oc)
        if !did_succeed
            error("Could not update build image $BUILD_IMAGE")
        end

        BUILD_IMAGE_UPDATED = true
    end
end


"""
    DockerRunner

A `DockerRunner` represents an "execution context", an object that bundles all
necessary information to run commands within the docker container that contains
our crossbuild environment.  Use `run()` to actually run commands within the
`DockerRunner`, and `runshell()` as a quick way to get an interactive shell
within the crossbuild environment.
"""
type DockerRunner
    cmd_prefix::Cmd
    platform::Platform
end

function show(io::IO, x::DockerRunner)
    p = x.platform
    # Displays as, e.g., Linux x86_64 (glibc) DockerRunner
    write(io, typeof(p), " ", arch(p), " ",
          Compat.Sys.islinux(p) ? "($(p.libc)) " : "",
          "DockerRunner")
end

"""
    getuid()

Wrapper function around libc's `getuid()` function
"""
function getuid()
    return ccall((:getuid, :libc), UInt32, ())
end

"""
    getgid()

Wrapper function around libc's `getgid()` function
"""
function getgid()
    return ccall((:getgid, :libc), UInt32, ())
end

"""
    target_envs(target::String)

Given a `target` (this term is used interchangeably with `triplet`), generate a
`Dict` mapping representing all the environment variables to be set within the
build environment to force compiles toward the defined target architecture.

Examples of things set are `PATH`, `CC`, `RANLIB`, as well as nonstandard
things like `target`.
"""
function target_envs(target::AbstractString)
    target_tool = tool -> "/opt/$(target)/bin/$(target)-$(tool)"
    mapping = Dict(
        "PATH" => "/opt/$(target)/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
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

        # Autotools really appreciates being able to build stuff for the
        # host system, so we set this to ease its woes
        "CC_FOR_BUILD" => "/opt/x86_64-linux-gnu/bin/gcc",
    )

    return mapping
end

"""
    DockerRunner(; prefix::Prefix = global_prefix,
                   platform::Platform = platform_key(),
                   volume_mapping::Vector = [])

Creates a `DockerRunner` object to run commands within the environment defined
by the given `prefix`, `platform` and `volume_mapping`s.  The `prefix` given
will be mounted into the Docker image at the same path as it exists within the
host file system, and any extra volumes that should be mapped in can be done
so with `volume_mapping`, which expects tuples of paths in a similar spirit to
`docker`'s `-v` option.
"""
function DockerRunner(;prefix::Prefix = BinaryProvider.global_prefix,
                       platform::Platform = platform_key(),
                       volume_mapping::Vector = [],
                       extra_env::Dict{String, String} = Dict{String, String}())
    # We are using `docker run` to provide isolation
    cmd_prefix = `docker run --rm -i`

    # The volumes we'll always map into the docker container
    push!(volume_mapping, (prefix.path, prefix.path))
    for v in volume_mapping
        cmd_prefix = `$cmd_prefix -v $(v[1]):$(v[2])`
    end

    # The environment variables we'll set
    env_mapping = target_envs(triplet(platform))
    for v in env_mapping
        cmd_prefix = `$cmd_prefix -e $(v[1])=$(v[2])`
    end
    for v in extra_env
        cmd_prefix = `$cmd_prefix -e $(v[1])=$(v[2])`
    end

    # Set our user id and group id to match the outside world
    cmd_prefix = `$cmd_prefix --user=$(getuid()):$(getgid())`

    # Don't run with a confined seccomp profile
    cmd_prefix = `$cmd_prefix --security-opt seccomp=unconfined`

    # Manually set DESTDIR environment variable
    cmd_prefix = `$cmd_prefix -e DESTDIR=$(prefix.path)`

    # Actually update the build image, if we need to
    update_build_image()

    return DockerRunner(cmd_prefix, platform)
end

"""
    run(dr::DockerRunner, cmd::Cmd, logpath::String; verbose::Bool = false)

Given a `DockerRunner`, runs `cmd` within the docker environment, storing any
output logs into `logpath` and returning `false` if the command did not
complete successfully.  This command will also mount in the current directory
into the docker environment.
"""
function run(dr::DockerRunner, cmd::Cmd, logpath::AbstractString; verbose::Bool = false)
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

    # Return whether we succeeded or not
    return did_succeed
end

"""
    runshell(dr::DockerRunner)

Open an interactive session inside a Docker environment defined by a
`DockerRunner` object with the current directory mapped in as well.
"""
function runshell(dr::DockerRunner)
    d = pwd()
    user_cmd = `$(dr.cmd_prefix) -w $(d) -v $(d):$(d) -t $BUILD_IMAGE bash`
    run(user_cmd)
end

"""
    runshell(platform::Platform)

Open an interactive session inside a Docker environment created for a
particular target `platform`.
"""
function runshell(platform::Platform)
    runshell(DockerRunner(platform=platform))
end
