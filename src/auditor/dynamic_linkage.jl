using ObjectFile.ELF
import ObjectFile: rpaths, canonical_rpaths

"""
    platform_for_object(oh::ObjectHandle)

Returns the platform the given `ObjectHandle` should run on.  E.g.
if the given `ObjectHandle` is an x86_64 Linux ELF object, this function
will return `Linux(:x86_64)`.  This function does not yet distinguish
between different libc's such as `:glibc` and `:musl`.
"""
function platform_for_object(oh::ObjectHandle)
    if oh isa ELFHandle
        mach_to_arch = Dict(
            ELF.EM_386 => :i686,
            ELF.EM_X86_64 => :x86_64,
            ELF.EM_AARCH64 => :aarch64,
            ELF.EM_PPC64 => :powerpc64le,
            ELF.EM_ARM => :armv7l,
        )
        mach = oh.header.e_machine
        if !haskey(mach_to_arch, mach)
            error("Unknown ELF architecture $(mach)")
        end

        arch = mach_to_arch[mach]

        if oh.ei.osabi == ELF.ELFOSABI_LINUX || oh.ei.osabi == ELF.ELFOSABI_NONE
            return Linux(arch)
        elseif oh.ei.osabi == ELF.ELFOSABI_FREEBSD
            return FreeBSD(arch)
        else
            error("Unknown ELF OSABI $(oh.ei.osabi)")
        end
    elseif oh isa MachOHandle
        return MacOS()
    elseif oh isa COFFHandle
        if is64bit(oh)
            return Windows(:x86_64)
        else
            return Windows(:i686)
        end
    else
        error("Unknown ObjectHandle type $(typeof(oh))")
    end
end

function rpaths(file::AbstractString)
    readmeta(file) do oh
        rpaths(RPath(oh))
    end
end

function canonical_rpaths(file::AbstractString)
    readmeta(file) do oh
        canonical_rpaths(RPath(oh))
    end
end

"""
    is_for_platform(h::ObjectHandle, platform::Platform)

Returns `true` if the given `ObjectHandle` refers to an object of the given
`platform`; E.g. if the given `platform` is for AArch64 Linux, then `h` must
be an `ELFHandle` with `h.header.e_machine` set to `ELF.EM_AARCH64`.

In particular, this method and `platform_for_object()` both exist because
the latter is not smart enough to deal with `:glibc` and `:musl` yet.
"""
function is_for_platform(h::ObjectHandle, platform::Platform)
    if platform isa Linux || platform isa FreeBSD
        # First off, if h isn't an ELF object, quit out
        if !(h isa ELFHandle)
            return false
        end
        # If the ELF object has an OSABI, check it matches platform
        if h.ei.osabi != ELF.ELF.ELFOSABI_NONE
            if platform isa Linux
                if h.ei.osabi != ELF.ELFOSABI_LINUX
                    return false
                end
            elseif platform isa FreeBSD
                if h.ei.osabi != ELF.ELFOSABI_FREEBSD
                    return false
                end
            else
                error("Unknown OS ABI type $(typeof(platform))")
            end
        end
        # Check that the ELF arch matches our own
        m = h.header.e_machine
        if platform.arch == :i686
            return m == ELF.EM_386
        elseif platform.arch == :x86_64
            # Allow i686 on x86_64, because that's technically ok
            return m == ELF.EM_386 || m == ELF.EM_X86_64
        elseif platform.arch == :aarch64
            return m == ELF.EM_AARCH64
        elseif platform.arch == :powerpc64le
            return m == ELF.EM_PPC64
        elseif platform.arch == :armv7l
            return m == ELF.EM_ARM
        else
            error("Unknown $(typeof(platform)) architecture $(platform.arch)")
        end
    elseif platform isa Windows
        if !(h isa COFFHandle)
            return false
        end

        if platform.arch == :x86_64
            return true
        elseif platform.arch == :i686
            return !is64bit(h)
        else
            error("Unknown $(typeof(platform)) architecture $(platform.arch)")
        end
    elseif platform isa MacOS
        # We'll take any old Mach-O handle
        if !(h isa MachOHandle)
            return false
        end
        return true
    else
        error("Unkown platform $(typeof(platform))")
    end
end

# These are libraries we should straight-up ignore, like libsystem on OSX
function should_ignore_lib(lib, ::ELFHandle)
    ignore_libs = [
        # Basic runtimes
        "libc.so",
        "libc.so.6",
        "libstdc++.so.6",
        # POSIX libraries
        "libdl.so.2",
        "librt.so.1",
        # libgcc Linux and FreeBSD style
        "libgcc_s.1.so",
        "libgcc_s.so.1",
        "libm.so.6",
        "libgfortran.so.3",
        "libgfortran.so.4",
        # libpthread and libgomp are pretty safe bets
        "libpthread.so.0",
        "libgomp.so.1",
        # dynamic loaders from our alpine environment
        "ld-linux-x86-64.so.2",
    ]
    return lowercase(basename(lib)) in ignore_libs
end
function should_ignore_lib(lib, ::MachOHandle)
    ignore_libs = [
        "libsystem.b.dylib",
        "libstdc++.6.dylib",
        "libc++.1.dylib",
    ]
    return lowercase(basename(lib)) in ignore_libs
end
function should_ignore_lib(lib, ::COFFHandle)
    ignore_libs = [
        "msvcrt.dll",
        "kernel32.dll",
        "user32.dll",
        "libgcc_s_seh-1.dll",
        "libgcc_s_sjlj-1.dll",
        "libgfortran-3.dll",
        "libgfortran-4.dll",
        "libstdc++-6.dll",
    ]
    return lowercase(basename(lib)) in ignore_libs
end

# Determine whether a library is a "default" library or not, if it is we need
# to map it to `@rpath/$libname` on OSX.
is_default_lib(lib, oh) = false
function is_default_lib(lib, ::MachOHandle)
    default_libs = [
        "libgcc_s.1.dylib",
        "libgfortran.3.dylib",
        "libgfortran.4.dylib",
        "libquadmath.0.dylib",
    ]
    return lowercase(basename(lib)) in default_libs
end

function relink_to_rpath(prefix::Prefix, platform::Platform, path::AbstractString,
                         old_libpath::AbstractString; verbose::Bool = false)
    ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
    rel_path = relpath(path, prefix.path)
    libname = basename(old_libpath)
    relink_cmd = ``

    if Compat.Sys.isapple(platform)
        install_name_tool = "/opt/x86_64-apple-darwin14/bin/install_name_tool"
        relink_cmd = `$install_name_tool -change $(old_libpath) @rpath/$(libname) $(rel_path)`
    elseif Compat.Sys.islinux(platform)
        patchelf = "/usr/local/bin/patchelf"
        relink_cmd = `$patchelf --replace-needed $(old_libpath) \$ORIGIN/$(libname) $(rel_path)`
    end

    # Create a new linkage that looks like $ORIGIN/../lib, or similar
    logpath = joinpath(logdir(prefix), "relink_to_rpath_$(basename(rel_path))_$(libname).log")
    run(ur, relink_cmd, logpath; verbose=verbose)
end

"""
    update_linkage(prefix::Prefix, platform::Platform, path::AbstractString,
                   old_libpath, new_libpath; verbose::Bool = false)

Given a binary object located at `path` within `prefix`, update its dynamic
linkage to point to `new_libpath` instead of `old_libpath`.  This is done using
a tool within the cross-compilation environment such as `install_name_tool` on
MacOS or `patchelf` on Linux.  Windows platforms are completely skipped, as
they do not encode paths or RPaths within their executables.
"""
function update_linkage(prefix::Prefix, platform::Platform, path::AbstractString,
                        old_libpath, new_libpath; verbose::Bool = false)
    # Windows doesn't do updating of linkage
    if Compat.Sys.iswindows(platform)
        return
    end

    ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
    rel_path = relpath(path, prefix.path)

    add_rpath = x -> ``
    relink = (x, y) -> ``
    origin = ""
    patchelf = "/usr/local/bin/patchelf"
    install_name_tool = "/opt/x86_64-apple-darwin14/bin/install_name_tool"
    if Compat.Sys.isapple(platform)
        origin = "@loader_path"
        add_rpath = rp -> `$install_name_tool -add_rpath $(joinpath(origin,rp)) $(rel_path)`
        relink = (op, np) -> `$install_name_tool -change $(op) $(np) $(rel_path)`
    elseif Compat.Sys.islinux(platform)
        origin = "\$ORIGIN"
        current_rpaths = [r for r in rpaths(path) if !isempty(r)]
        add_rpath = rp -> begin
            # Join together RPaths to set new one
            rpaths = unique(vcat(current_rpaths, joinpath(origin,rp)))
            
            # I don't like strings ending in '/.', like '$ORIGIN/.'.  I don't think
            # it semantically makes a difference, but why not be correct AND beautiful?
            chomp_dot = path -> begin
                if path[end-1:end] == "/."
                    return path[1:end-2]
                end
                return path
            end

            rpath_str = join(chomp_dot.(rpaths), ':')
            return `$patchelf --set-rpath $(rpath_str) $(rel_path)`
        end
        relink = (op, np) -> `$patchelf --replace-needed $(op) $(np) $(rel_path)`
    end

    # If the relative directory doesn't already exist within the RPATH of this
    # binary, then add it in.
    new_libdir = abspath(dirname(new_libpath) * "/")
    if !(new_libdir in canonical_rpaths(path))
        libname = basename(old_libpath)
        logpath = joinpath(logdir(prefix), "update_rpath_$(libname).log")
        cmd = add_rpath(relpath(new_libdir, dirname(path)))
        run(ur, cmd, logpath; verbose=verbose)
    end

    # Create a new linkage that depends on $ORIGIN or @rpath to find things.
    # This allows us to split things up into multiple packages, and as long as the
    # libraries that this guy is interested in have been `dlopen()`'ed previously,
    # (and have the appropriate SONAME) things should "just work".
    logpath = joinpath(logdir(prefix), "update_linkage_$(basename(path))_$(basename(old_libpath)).log")
    new_libpath = relpath(new_libpath, dirname(path))
    if Compat.Sys.isapple(platform)
        # On MacOS, we need to explicitly add `@rpath/` before our library linkage path.
        new_libpath = joinpath("@rpath", new_libpath)
    end
    cmd = relink(old_libpath, new_libpath)
    run(ur, cmd, logpath; verbose=verbose)

    return new_libpath
end
