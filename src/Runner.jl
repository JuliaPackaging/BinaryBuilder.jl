abstract type Runner; end

function target_nbits(target::AbstractString)
    if startswith(target, "i686-") || startswith(target, "arm-")
        return "32"
    else
        return "64"
    end
end

function target_proc_family(target::AbstractString)
    if startswith(target, "arm") || startswith(target, "aarch")
        return "arm"
    elseif startswith(target, "power")
        return "power"
    else
        return "intel"
    end
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

    # Start with the default musl ld path:
    lib_path = "/usr/local/lib64:/usr/local/lib:/lib:/usr/local/lib:/usr/lib"

    # Then add on our target-specific locations
    lib_path *= ":/opt/$(target)/lib64:/opt/$(target)/lib"
    lib_path *= ":/opt/$(target)/$(target)/lib64:/opt/$(target)/$(target)/lib"

    # Finally add on our destination location
    lib_path *= ":/workspace/destdir/lib64:/workspace/destdir/lib"

    # Start with the standard PATH:
    path = "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

    # Slip our tools into the front
    path = "/opt/super_binutils/bin:/opt/$(target)/bin:" * path

    mapping = Dict(
        # Activate the given target via `PATH` and `LD_LIBRARY_PATH`
        "PATH" => path,
        "LD_LIBRARY_PATH" => lib_path,

        # Define toolchain envvars
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

        # Useful tools
        "target" => target,
        "nproc" => "$(Sys.CPU_CORES)",
        "nbits" => target_nbits(target),
        "proc_family" => target_proc_family(target),
        "TERM" => "screen",

        # We should always be looking for packages already in the prefix
        "PKG_CONFIG_PATH" => "/workspace/destdir/lib/pkgconfig",
        "PKG_CONFIG_SYSROOT_DIR" => "/workspace/destdir",

        # Autotools really appreciates being able to build stuff for the
        # host system, so we set this to ease its woes
        "CC_FOR_BUILD" => "/opt/x86_64-linux-gnu/bin/gcc",
    )

    # If we're on OSX, default to clang instead of gcc for CC and CXX
    # Also default to asking for a minimum of OSX 10.8 for C++ ABI
    if contains(target, "-apple-")
        mapping["CC"] = "/opt/$(target)/bin/clang"
        mapping["CXX"] = "/opt/$(target)/bin/clang++"
        mapping["LDFLAGS"] = "-mmacosx-version-min=10.8"
    end

    return mapping
end

function destdir_envs(destdir::String)
    Dict(
        "prefix" => destdir,
    )
end

runner_override = ""
function preferred_runner()
    global runner_override
    if runner_override != ""
        if runner_override in ["userns", "privileged"]
            return UserNSRunner
        elseif runner_override in ["qemu"]
            return QemuRunner
        end
    end

    @static if Compat.Sys.islinux()
        # If runner_override is not yet set, let's probe to see if we can use
        # unprivileged containers, and if we can't, switch over to privileged.
        if !probe_unprivileged_containers()
            msg = strip("""
            Unable to run unprivileged containers on this system!
            This may be because your kernel does not support mounting overlay
            filesystems within user namespaces. To work around this, we will
            switch to using privileged containers. This requires the use of
            sudo. To choose this automatically, set the BINARYBUILDER_RUNNER
            environment variable to "privileged" before starting Julia.
            """)
            Compat.@warn(replace(msg, "\n" => " "))
            runner_override = "privileged"
        end

        return UserNSRunner
    else
        return QemuRunner
    end
end

"""
    runshell(platform::Platform = platform_key())

Launch an interactive shell session within the user namespace, with environment
setup to target the given `platform`.
"""
function runshell(platform::Platform = platform_key(); verbose::Bool = false)
    runshell(preferred_runner(), platform; verbose=verbose)
end
