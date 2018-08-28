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

function target_dlext(target::AbstractString)
    if endswith(target, "-mingw32")
        return "dll"
    elseif occursin("-apple-", target)
        return "dylib"
    else
        return "so"
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
function target_envs(target::AbstractString, host_target="x86_64-linux-gnu")
    global use_ccache

    # Helper function to generate paths such as /opt/x86_64-apple-darwin14/bin/llvm-ar
    tool_path = (n, t = target) -> "/opt/$(t)/bin/$(n)"
    # Helper function to generate paths such as /opt/x86_64-linux-gnu/bin/x86_64-linux-gnu-gcc
    target_tool_path = (n, t = target) -> tool_path("$(t)-$(n)", t)
    
    # Start with the default musl ld path:
    lib_path = "/usr/local/lib64:/usr/local/lib:/lib:/usr/local/lib:/usr/lib"

    # Add on our glibc-compatibility layer
    lib_path *= ":/usr/glibc-compat/lib"

    # Then add on our target-specific locations
    lib_path *= ":/opt/$(target)/lib64:/opt/$(target)/lib"
    lib_path *= ":/opt/$(target)/$(target)/lib64:/opt/$(target)/$(target)/lib"

    # Finally add on our destination location
    lib_path *= ":/workspace/destdir/lib64:/workspace/destdir/lib"

    # Start with the standard PATH:
    path = "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

    # Slip our tools into the front
    path = "/opt/$(target)/bin:" * path

    mapping = Dict(
        # Activate the given target via `PATH` and `LD_LIBRARY_PATH`
        "PATH" => path,
        "LD_LIBRARY_PATH" => lib_path,

        # binutils/toolchain envvars
        "LIBTOOL" => target_tool_path("libtool"),
        "LIPO" => target_tool_path("lipo"),
        "OTOOL" => target_tool_path("otool"),
        "INSTALL_NAME_TOOL" => target_tool_path("install_name_tool"),
        "OBJCOPY" => target_tool_path("objcopy"),
        "OBJDUMP" => target_tool_path("objdump"),
        "READELF" => target_tool_path("readelf"),
        "STRIP" => target_tool_path("strip"),
        "WINDRES" => target_tool_path("windres"),
        "WINMC" => target_tool_path("winmc"),
        "LLVM_TARGET" => target,
        "LLVM_HOST_TARGET" => host_target,

        # Useful tools for our buildscripts
        "target" => target,
        "nproc" => "$(Sys.CPU_THREADS)",
        "nbits" => target_nbits(target),
        "proc_family" => target_proc_family(target),
        "dlext" => target_dlext(target),
        "TERM" => "screen",

        # We should always be looking for packages already in the prefix
        "PKG_CONFIG_PATH" => "/workspace/destdir/lib/pkgconfig",
        "PKG_CONFIG_SYSROOT_DIR" => "/workspace/destdir",

        # We like to be able to get at our .bash_history afterwards. :)
        "HISTFILE"=>"/meta/.bash_history",
    )

    # If we're on MacOS or FreeBSD, we default to LLVM tools instead of GCC.
    # On all of our clangy platforms we actually have GCC tools available as well,
    # they're just not used by default.  Override these environment variables in
    # your scripts if you want to use them.
    if occursin("-apple-", target) || occursin("-freebsd", target)
        mapping["AR"] = tool_path("llvm-ar")
        mapping["AS"] = tool_path("llvm-as")
        mapping["CC"] = tool_path("clang")
        mapping["CXX"] = tool_path("clang++")
        # flang isn't a realistic option yet, so we still use gfortran here
        mapping["FC"] = target_tool_path("gfortran")
        mapping["LD"] = tool_path("llvm-ld")
        mapping["NM"] = tool_path("llvm-nm")
        mapping["RANLIB"] = tool_path("llvm-ranlib")
    else
        mapping["AR"] = target_tool_path("ar")
        mapping["AS"] = target_tool_path("as")
        mapping["CC"] = target_tool_path("gcc")
        mapping["CXX"] = target_tool_path("g++")
        mapping["FC"] = target_tool_path("gfortran")
        mapping["LD"] = target_tool_path("ld")
        mapping["NM"] = target_tool_path("nm")
        mapping["RANLIB"] = target_tool_path("ranlib")
    end

    # On OSX, we need to do a little more work.
    if occursin("-apple-", target)
        # First, tell CMake what our deployment target is, so that it tries to
        # set -mmacosx-version-min and such appropriately
        mapping["MACOSX_DEPLOYMENT_TARGET"] = "10.8"

        # Also put this into LDFLAGS because some packages are hard of hearing
        mapping["LDFLAGS"] = "-mmacosx-version-min=10.8"
    end

    # There is no broad agreement on what host compilers should be called,
    # so we set all the environment variabels that we've seen it called as,
    # and hope for the best.
    for host_map in (tool -> "HOST$(tool)", tool -> "$(tool)_FOR_BUILD", tool -> "BUILD_$(tool)")
        mapping[host_map("AR")] = target_tool_path("ar", "x86_64-linux-gnu")
        mapping[host_map("AS")] = target_tool_path("as", "x86_64-linux-gnu")
        mapping[host_map("CC")] = target_tool_path("gcc", "x86_64-linux-gnu")
        mapping[host_map("CXX")] = target_tool_path("g++", "x86_64-linux-gnu")
        mapping[host_map("FC")] = target_tool_path("gfortran", "x86_64-linux-gnu")
        mapping[host_map("LIPO")] = target_tool_path("lipo", "x86_64-linux-gnu")
        mapping[host_map("LD")] = target_tool_path("ld", "x86_64-linux-gnu")
        mapping[host_map("NM")] = target_tool_path("nm", "x86_64-linux-gnu")
        mapping[host_map("RANLIB")] = target_tool_path("ranlib", "x86_64-linux-gnu")
        mapping[host_map("READELF")] = target_tool_path("readelf", "x86_64-linux-gnu")
        mapping[host_map("OBJCOPY")] = target_tool_path("objcopy", "x86_64-linux-gnu")
        mapping[host_map("OBJDUMP")] = target_tool_path("objdump", "x86_64-linux-gnu")
        mapping[host_map("STRIP")] = target_tool_path("strip", "x86_64-linux-gnu")
    end
    
    # If we're using `ccache`, prepend it to `CC`, `CXX`, `FC`, `HOSTCC`, etc....
    if use_ccache
        for tool in ("CC", "CXX", "FC")
            for m in (tool, "BUILD_$(tool)", "HOST$(tool)", "$(tool)_FOR_BUILD")
                mapping[m] = string("ccache ", mapping[m])
            end
        end
    end

    return mapping
end

runner_override = ""
function preferred_runner()
    global runner_override
    if runner_override != ""
        if runner_override in ["userns", "privileged"]
            return UserNSRunner
        elseif runner_override in ["qemu"]
            return QemuRunner
        elseif runner_override in ["docker"]
            return DockerRunner
        end
    end

    @static if Sys.islinux()
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

function runshell(r::Runner, args...; kwargs...)
    run_interactive(r, `/bin/bash`, args...; kwargs...)
end

function runshell(::Type{R}, platform::Platform = platform_key(); verbose::Bool = false) where {R <: Runner}
    return runshell(R(pwd(); cwd="/workspace/", platform=platform, verbose=verbose))
end
