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
    # Helper function to generate paths such as /opt/x86_64-apple-darwin14/bin/llvm-ar
    tool = x -> "/opt/$(target)/bin/$(x)"
    # Helper function to generate paths such as /opt/x86_64-linux-gnu/bin/x86_64-linux-gnu-gcc
    target_tool = x -> tool("$(target)-$(x)")

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

        # binutils/toolchain envvars
        "RANLIB" => target_tool("ranlib"),
        "STRIP" => target_tool("strip"),
        "LIBTOOL" => target_tool("libtool"),
        "LIPO" => target_tool("lipo"),

        # Useful tools for our buildscripts
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

    # If we're on MacOS or FreeBSD, we default to LLVM tools instead of GCC.
    # On all of our clangy platforms we actually have GCC tools available as well,
    # they're just not used by default.  Override these environment variables in
    # your scripts if you want to use them.
    if contains(target, "-apple-") || contains(target, "-freebsd")
        mapping["AR"] = tool("llvm-ar")
        mapping["AS"] = tool("llvm-as")
        mapping["CC"] = tool("clang")
        mapping["CXX"] = tool("clang++")
        # flang isn't a realistic option yet, so we still use gfortran here
        mapping["FC"] = target_tool("gfortran")
        mapping["LD"] = tool("llvm-ld")
        mapping["NM"] = tool("llvm-nm")
        mapping["OTOOL"] = target_tool("otool")
        mapping["INSTALL_NAME_TOOL"] = target_tool("install_name_tool")
    else
        mapping["AR"] = target_tool("ar")
        mapping["AS"] = target_tool("as")
        mapping["CC"] = target_tool("gcc")
        mapping["CXX"] = target_tool("g++")
        mapping["FC"] = target_tool("gfortran")
        mapping["LD"] = target_tool("ld")
        mapping["NM"] = target_tool("nm")
    end

    # On OSX, we need to do a little more work.
    if contains(target, "-apple-")
        # First, tell CMake what our deployment target is, so that it tries to
        # set -mmacosx-version-min and such appropriately
        mapping["MACOSX_DEPLOYMENT_TARGET"] = "10.8"

        # Also put this into LDFLAGS because some packages are hard of hearing
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
