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
    platform_envs(platform::Platform)

Given a `platform`, generate a `Dict` mapping representing all the environment
variables to be set within the build environment to force compiles toward the
defined target architecture.  Examples of things set are `PATH`, `CC`,
`RANLIB`, as well as nonstandard things like `target`.
"""
function platform_envs(platform::Platform, host_target="x86_64-linux-gnu")
    global use_ccache

    # Convert platform to a triplet, but strip out the ABI parts
    target = triplet(abi_agnostic(platform))

    # Helper function to generate paths such as /opt/x86_64-apple-darwin14/bin/llvm-ar
    tool_path = (n, t = target) -> "/opt/$(t)/bin/$(n)"
    # Helper functions to generate paths such as /opt/x86_64-linux-gnu/bin/x86_64-linux-gnu-gcc
    target_tool_path = (n, t = target) -> tool_path("$(t)-$(n)", t)
    host_tool_path = (n, t = host_target) -> tool_path("$(t)-$(n)", t)
    llvm_tool_path = (n) -> "/opt/$(host_target)/tools/$(n)"
    
    # Start with the default musl ld path
    lib_path = "/usr/local/lib64:/usr/local/lib:/lib:/usr/local/lib:/usr/lib"

    # Add our glibc directory (this coupled with our Glibc patches to reject musl
    # binaries gives us a dual-libc environment)
    lib_path *= ":/lib64"

    # Then add on our target-specific locations
    lib_path *= ":/opt/$(target)/lib64:/opt/$(target)/lib"
    #lib_path *= ":/opt/$(target)/$(target)/lib64:/opt/$(target)/$(target)/lib"

    # Add on our host-target location:
    lib_path *= ":/opt/$(host_target)/lib64:/opt/$(host_target)/lib"

    # Finally add on our destination location
    lib_path *= ":/workspace/destdir/lib64:/workspace/destdir/lib"

    # Start with the standard PATH:
    path = "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

    # Slip our tools into the front, followed by host tools
    path = "/opt/$(target)/bin:/opt/$(host_target)/bin:/opt/$(host_target)/tools:" * path

    # Then slip $prefix/bin onto the end, so that dependencies naturally show up
    path = path * ":/workspace/destdir/bin"

    mapping = Dict(
        # Activate the given target via `PATH` and `LD_LIBRARY_PATH`
        "PATH" => path,
        "LD_LIBRARY_PATH" => lib_path,

        # We conditionally add on some compiler flags; we'll cull empty ones at the end
        "CFLAGS" => "",
        "CPPFLAGS" => "",
        "LDFLAGS" => "",

        # binutils/toolchain envvars
        "DSYMUTIL" => llvm_tool_path("llvm-dsymutil"),
        "LIBTOOL" => target_tool_path("libtool"),
        "LIPO" => target_tool_path("lipo"),
        "OTOOL" => target_tool_path("otool"),
        "INSTALL_NAME_TOOL" => target_tool_path("install_name_tool"),
        "OBJCOPY" => target_tool_path("objcopy"),
        "READELF" => target_tool_path("readelf"),
        "RANLIB" => target_tool_path("ranlib"),
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
        mapping["AR"] = llvm_tool_path("llvm-ar")
        mapping["AS"] = llvm_tool_path("llvm-as")
        # Because there's only a single `clang` binary, we store it in `x86_64-linux-gnu`,
        # but LLVMBuilder puts the `clang` binary into `tools`, not `bin`.
        mapping["CC"] = llvm_tool_path("clang -target $(target) --sysroot /opt/$(target)/$(target)/sys-root")
        mapping["CXX"] = llvm_tool_path("clang++ -target $(target) --sysroot /opt/$(target)/$(target)/sys-root")
        # flang isn't a realistic option yet, so we still use gfortran here
        mapping["FC"] = target_tool_path("gfortran")
        mapping["LD"] = llvm_tool_path("llvm-ld")
        mapping["NM"] = llvm_tool_path("llvm-nm")
        mapping["OBJDUMP"] = llvm_tool_path("llvm-objdump")
    else
        mapping["AR"] = target_tool_path("ar")
        mapping["AS"] = target_tool_path("as")
        mapping["CC"] = target_tool_path("gcc")
        mapping["CXX"] = target_tool_path("g++")
        mapping["FC"] = target_tool_path("gfortran")
        mapping["LD"] = target_tool_path("ld")
        mapping["NM"] = target_tool_path("nm")
        mapping["OBJDUMP"] = target_tool_path("objdump")
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
    # so we set all the environment variables that we've seen them called
    # and hope for the best.
    for host_map in (tool -> "HOST$(tool)", tool -> "$(tool)_FOR_BUILD", tool -> "BUILD_$(tool)")
        mapping[host_map("AR")] = host_tool_path("ar")
        mapping[host_map("AS")] = host_tool_path("as")
        mapping[host_map("CC")] = host_tool_path("gcc")
        mapping[host_map("CXX")] = host_tool_path("g++")
        mapping[host_map("DSYMUTIL")] = llvm_tool_path("llvm-dsymutil")
        mapping[host_map("FC")] = host_tool_path("gfortran")
        mapping[host_map("LIPO")] = host_tool_path("lipo")
        mapping[host_map("LD")] = host_tool_path("ld")
        mapping[host_map("NM")] = host_tool_path("nm")
        mapping[host_map("RANLIB")] = host_tool_path("ranlib")
        mapping[host_map("READELF")] = host_tool_path("readelf")
        mapping[host_map("OBJCOPY")] = host_tool_path("objcopy")
        mapping[host_map("OBJDUMP")] = host_tool_path("objdump")
        mapping[host_map("STRIP")] = host_tool_path("strip")
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
