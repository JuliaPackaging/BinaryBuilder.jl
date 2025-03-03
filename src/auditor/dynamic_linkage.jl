using ObjectFile.ELF
using Patchelf_jll: patchelf

function os_from_elf_note(oh::ELFHandle)
    for section in Sections(oh)
        section_type(section) == ELF.SHT_NOTE || continue
        seek(oh, section_offset(section))
        name_length = read(oh, UInt32)
        iszero(name_length) && continue
        descriptor_length = read(oh, UInt32)
        note_type = read(oh, UInt32)
        name = String(read(oh, name_length - 1))  # skip trailing NUL
        if note_type == 1
            # Technically it's part of the Linux specification that any executable should
            # have an ELF note with type 1, name GNU, and descriptor length ≥4, but in
            # practice I haven't observed that consistently, especially on musl. So for
            # now, only bother checking FreeBSD, which uses an ELF note rather than OS/ABI
            # to identify itself on AArch64 and RISC-V.
            if name == "FreeBSD" && descriptor_length == 4
                return name
            end
        end
    end
    return nothing
end

os_from_elf_note(::ObjectHandle) = nothing

"""
    platform_for_object(oh::ObjectHandle)

Returns the platform the given `ObjectHandle` should run on.  E.g.
if the given `ObjectHandle` is an `x86_64` Linux ELF object, this function
will return `Platform("x86_64", "linux")`.  This function does not yet distinguish
between different libc's such as `:glibc` and `:musl`.
"""
function platform_for_object(oh::ObjectHandle)
    if oh isa ELFHandle
        mach_to_arch = Dict(
            ELF.EM_386 => "i686",
            ELF.EM_X86_64 => "x86_64",
            ELF.EM_AARCH64 => "aarch64",
            ELF.EM_PPC64 => "powerpc64le",
            ELF.EM_RISCV => "riscv64", # Could also be riscv32; should check ELF_CLASS
            ELF.EM_ARM => "arm",
        )
        mach = oh.header.e_machine
        if !haskey(mach_to_arch, mach)
            error("Unknown ELF architecture $(mach)")
        end

        arch = mach_to_arch[mach]

        if arch == "arm"
            # See if we can find an `.ARM.attributes` section
            attr = try
                findfirst(Sections(oh), ".ARM.attributes")
            catch
                nothing
            end

            if attr !== nothing
                attr_data = read(attr)
                error("Elliot, you need to parse out the ARM version here!")
                # Parse out the .ARM.attributes section to find ARM version
            end
        end

        if oh.ei.osabi == ELF.ELFOSABI_NONE
            return Platform(arch, os_from_elf_note(oh) == "FreeBSD" ? "freebsd" : "linux")
        elseif oh.ei.osabi == ELF.ELFOSABI_LINUX
            return Platform(arch, "linux")
        elseif oh.ei.osabi == ELF.ELFOSABI_FREEBSD
            return Platform(arch, "freebsd")
        else
            error("Unknown ELF OSABI $(oh.ei.osabi)")
        end
    elseif oh isa MachOHandle
        mach_to_arch = Dict(
            MachO.CPU_TYPE_X86_64 => "x86_64",
            MachO.CPU_TYPE_ARM64 => "aarch64",
        )
        mach = oh.header.cputype
        if !haskey(mach_to_arch, mach)
            error("Unknown MachO architecture $(mach)")
        end
        return Platform(mach_to_arch[mach], "macos")
    elseif oh isa COFFHandle
        if is64bit(oh)
            return Platform("x86_64", "windows")
        else
            return Platform("i686", "windows")
        end
    else
        error("Unknown ObjectHandle type $(typeof(oh))")
    end
end

function _rpaths(file::AbstractString)
    readmeta(file) do ohs
        vcat(rpaths.(RPath.(ohs))...)
    end
end

function _canonical_rpaths(file::AbstractString)
    readmeta(file) do ohs
        vcat(canonical_rpaths.(RPath.(ohs))...)
    end
end

"""
    is_for_platform(h::ObjectHandle, platform::AbstractPlatform)

Returns `true` if the given `ObjectHandle` refers to an object of the given
`platform`; E.g. if the given `platform` is for AArch64 Linux, then `h` must
be an `ELFHandle` with `h.header.e_machine` set to `ELF.EM_AARCH64`.

In particular, this method and [`platform_for_object()`](@ref) both exist
because the latter is not smart enough to deal with `:glibc` and `:musl` yet.
"""
function is_for_platform(h::ObjectHandle, platform::AbstractPlatform)
    if Sys.islinux(platform) || Sys.isfreebsd(platform)
        # First off, if h isn't an ELF object, quit out
        if !(h isa ELFHandle)
            return false
        end
        # If the ELF object has an OSABI, check it matches platform
        if h.ei.osabi != ELF.ELF.ELFOSABI_NONE
            if Sys.islinux(platform)
                if h.ei.osabi != ELF.ELFOSABI_LINUX
                    return false
                end
            elseif Sys.isfreebsd(platform)
                if h.ei.osabi != ELF.ELFOSABI_FREEBSD
                    return false
                end
            else
                error("Unknown OS ABI type $(typeof(platform))")
            end
        else
            # If no OSABI, check whether it has a matching ELF note
            if Sys.isfreebsd(platform)
                if os_from_elf_note(h) != "FreeBSD"
                    return false
                end
            end
        end
        # Check that the ELF arch matches our own
        m = h.header.e_machine
        if arch(platform) == "i686"
            return m == ELF.EM_386
        elseif arch(platform) == "x86_64"
            # Allow i686 on x86_64, because that's technically ok
            return m == ELF.EM_386 || m == ELF.EM_X86_64
        elseif arch(platform) == "aarch64"
            return m == ELF.EM_AARCH64
        elseif arch(platform) == "powerpc64le"
            return m == ELF.EM_PPC64
        elseif arch(platform) == "riscv64"
            # Could also be riscv32; should check ELF_CLASS
            return m == ELF.EM_RISCV
        elseif arch(platform) ∈ ("armv7l", "armv6l")
            return m == ELF.EM_ARM
        else
            error("Unknown $(os(platform)) architecture $(arch(platform))")
        end
    elseif Sys.iswindows(platform)
        if !(h isa COFFHandle)
            return false
        end

        if arch(platform) == "x86_64"
            return true
        elseif arch(platform) == "i686"
            return !is64bit(h)
        else
            error("Unknown $(os(platform)) architecture $(arch(platform))")
        end
    elseif Sys.isapple(platform)
        # We'll take any old Mach-O handle
        if !(h isa MachOHandle)
            return false
        end
        return true
    else
        error("Unkown platform $(os(platform))")
    end
end

# These are libraries we should straight-up ignore, like libsystem on OSX
function should_ignore_lib(lib, ::ELFHandle, platform::AbstractPlatform)
    ignore_libs = [
        # dynamic loaders
        "ld-linux-x86-64.so.2",
        "ld-linux.so.2",
        "ld-linux-armhf.so.3",
        "ld-linux-aarch64.so.1",
        "ld-linux-riscv64-lp64d.so.1",
        "ld-musl-x86_64.so.1",
        "ld-musl-i386.so.1",
        "ld-musl-aarch64.so.1",
        "ld-musl-armhf.so.1",
        "ld64.so.2",
        # C runtime
        "libc.so",
        "libc.so.6",
        "libc.so.7",
        "libc.musl-x86_64.so.1",
        "libc.musl-i386.so.1",
        "libc.musl-aarch64.so.1",
        "libc.musl-armhf.so.1",
        # C++ runtime
        "libstdc++.so.6",
        "libc++.so.1",
        "libcxxrt.so.1",
        # libc libraries
        "libdl.so.2",
        "librt.so.1",
        "libm.so.5",
        "libm.so.6",
        "libthr.so.3",
        "libpthread.so.0",
    ]
    if Sys.isfreebsd(platform)
        push!(ignore_libs,
              # From FreeBSD SDK
              "libdevstat.sos.7",
              "libdl.so.1",
              "libexecinfo.so.1",
              "libkvm.so.7",
              "libutil.so.9",
              )
    elseif libc(platform) == "glibc"
        push!(ignore_libs,
              # Part of Glibc
              "libresolv.so.2",
              "libutil.so.1",
              )
    end
    return lowercase(basename(lib)) in ignore_libs
end
function should_ignore_lib(lib, ::MachOHandle, platform::AbstractPlatform)
    ignore_libs = [
        "libbsm.0.dylib",
        "libcups.2.dylib",
        "libobjc.a.dylib",
        "libpmenergy.dylib",
        "libpmsample.dylib",
        "libsandbox.1.dylib",
        "libsystem.b.dylib",
        # This is not built by clang or GCC, so we leave it as a system library
        "libc++.1.dylib",
        "libresolv.9.dylib",
        # Frameworks in the SDK
        "accelerate",
        "appkit",
        "applicationservices",
        "audiotoolbox",
        "audiounit",
        "avfoundation",
        "carbon",
        "cfnetwork",
        "cocoa",
        "coreaudio",
        "corebluetooth",
        "corefoundation",
        "coregraphics",
        "corelocation",
        "coremedia",
        "coremidi",
        "coreservices",
        "coretext",
        "corevideo",
        "corewlan",
        "diskarbitration",
        "forcefeedback",
        "foundation",
        "gamecontroller",
        "imageio",
        "iobluetooth",
        "iokit",
        "iosurface",
        "localauthentication",
        "mediaaccessibility",
        "metal",
        "metalkit",
        "opencl",
        "opengl",
        "opendirectory",
        "quartz",
        "quartzcore",
        "security",
        "securityinterface",
        "systemconfiguration",
        "videotoolbox",
    ]
    return lowercase(basename(lib)) in ignore_libs
end
function should_ignore_lib(lib, ::COFFHandle, platform::AbstractPlatform)
    ignore_libs = [
        # Core runtime libs
        "ntdll.dll",
        "msvcrt.dll",
        "kernel32.dll",
        "user32.dll",
        "shell32.dll",
        "shlwapi.dll",
        "advapi32.dll",
        "crypt32.dll",
        "ws2_32.dll",
        "rpcrt4.dll",
        "usp10.dll",
        "dwrite.dll",
        "gdi32.dll",
        "gdiplus.dll",
        "comdlg32.dll",
        "secur32.dll",
        "ole32.dll",
        "dbeng.dll",
        "wldap32.dll",
        "opengl32.dll",
        "winmm.dll",
        "iphlpapi.dll",
        "imm32.dll",
        "comctl32.dll",
        "oleaut32.dll",
        "userenv.dll",
        "netapi32.dll",
        "winhttp.dll",
        "msimg32.dll",
        "dnsapi.dll",
        "wsock32.dll",
        "psapi.dll",
        "bcrypt.dll",

        # Compiler support libraries
        "libgcc_s_seh-1.dll",
        "libgcc_s_sjlj-1.dll",
        "libgfortran-3.dll",
        "libgfortran-4.dll",
        "libgfortran-5.dll",
        "libstdc++-6.dll",
        "libwinpthread-1.dll",

        # This one needs some special attention, eventually
        "libgomp-1.dll",
    ]
    return lowercase(basename(lib)) in ignore_libs
end

# Determine whether a library is a "default" library or not, if it is we need
# to map it to `@rpath/$libname` on OSX or `\$ORIGIN/$libname` on Linux/FreeBSD
is_default_lib(lib, oh) = false

function valid_library_path(f::AbstractString, p::AbstractPlatform)
    if Sys.iswindows(p)
        return endswith(f, ".dll")
    elseif Sys.isapple(p)
        return endswith(f, ".dylib")
    else
        return occursin(r".+\.so(\.[\d]+)*$", f)
    end
end

function patchelf_flags(p::AbstractPlatform)
    flags = []

    # ppc64le and aarch64 have 64KB page sizes, don't muck up the ELF section load alignment
    # TODO: What is the riscv64 page size?
    if arch(p) in ("powerpc64le", "aarch64")
        append!(flags, ["--page-size", "65536"])
    end

    # We return arrays so that things interpolate properly
    return flags
end

function relink_to_rpath(prefix::Prefix, platform::AbstractPlatform, path::AbstractString,
                         old_libpath::AbstractString; verbose::Bool=false, subdir::AbstractString="")
    ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
    rel_path = relpath(path, prefix.path)
    libname = basename(old_libpath)
    relink_cmd = ``

    # Create a new linkage that looks like @rpath/$lib on OSX
    with_logfile(prefix, "relink_to_rpath_$(basename(rel_path)).log"; subdir) do io
        if Sys.isapple(platform)
            ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
            install_name_tool = "/opt/bin/$(triplet(ur.platform))/install_name_tool"
            relink_cmd = `$install_name_tool -change $(old_libpath) @rpath/$(libname) $(rel_path)`
            @lock AUDITOR_SANDBOX_LOCK run(ur, relink_cmd, io; verbose=verbose)
        elseif Sys.islinux(platform) || Sys.isbsd(platform)
            run_with_io(io, `$(patchelf()) $(patchelf_flags(platform)) --replace-needed $(old_libpath) $(libname) $(path)`)
        end
    end
end

function fix_identity_mismatch(prefix::Prefix, platform::AbstractPlatform, path::AbstractString,
                               oh::ObjectHandle; verbose::Bool=false, subdir::AbstractString="")
    # Only macOS needs to fix identity mismatches
    if !Sys.isapple(platform)
        return nothing
    end
    id_lc = [lc for lc in MachOLoadCmds(oh) if typeof(lc) <: MachOIdDylibCmd]
    if isempty(id_lc)
        return nothing
    end
    id_lc = first(id_lc)

    rel_path = relpath(path, prefix.path)
    old_id = dylib_name(id_lc)
    new_id = "@rpath/$(basename(old_id))"
    if old_id == new_id
        return nothing
    end

    if verbose
        @lock AUDITOR_LOGGING_LOCK @info("Modifying dylib id from \"$(old_id)\" to \"$(new_id)\"")
    end

    ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
    install_name_tool = "/opt/bin/$(triplet(ur.platform))/install_name_tool"
    id_cmd = `$install_name_tool -id $(new_id) $(rel_path)`

    # Create a new linkage that looks like @rpath/$lib on OSX,
    with_logfile(prefix, "fix_identity_mismatch_$(basename(rel_path)).log"; subdir) do io
        @lock AUDITOR_SANDBOX_LOCK run(ur, id_cmd, io; verbose=verbose)
    end
end


"""
    update_linkage(prefix::Prefix, platform::AbstractPlatform, path::AbstractString,
                   old_libpath, new_libpath; verbose::Bool = false)

Given a binary object located at `path` within `prefix`, update its dynamic
linkage to point to `new_libpath` instead of `old_libpath`.  This is done using
a tool within the cross-compilation environment such as `install_name_tool` on
MacOS or `patchelf` on Linux.  Windows platforms are completely skipped, as
they do not encode paths or RPaths within their executables.
"""
function update_linkage(prefix::Prefix, platform::AbstractPlatform, path::AbstractString,
                        old_libpath, new_libpath; verbose::Bool=false, subdir::AbstractString="")
    # Windows doesn't do updating of linkage
    if Sys.iswindows(platform)
        return
    end

    ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
    rel_path = relpath(path, prefix.path)

    normalize_rpath = rp -> rp
    add_rpath = x -> ``
    relink = (x, y) -> ``
    install_name_tool = "/opt/bin/$(triplet(ur.platform))/install_name_tool"
    if Sys.isapple(platform)
        normalize_rpath = rp -> begin
            if !startswith(rp, "@loader_path")
                return "@loader_path/$(rp)"
            end
            return rp
        end
        add_rpath = rp -> `$install_name_tool -add_rpath $(rp) $(rel_path)`
        relink = (op, np) -> `$install_name_tool -change $(op) $(np) $(rel_path)`
    elseif Sys.islinux(platform) || Sys.isbsd(platform)
        normalize_rpath = rp -> begin
            if rp == "."
                return "\$ORIGIN"
            end
            if startswith(rp, ".") || !startswith(rp, "/")
                # Relative paths starting with `.`, or anything which isn't an absolute
                # path.  It may also be a relative path without the leading `./`
                return "\$ORIGIN/$(rp)"
            end
            return rp
        end
        current_rpaths = [r for r in _rpaths(path) if !isempty(r)]
        add_rpath = rp -> begin
            # Join together RPaths to set new one
            rpaths = unique(vcat(current_rpaths, rp))

            # I don't like strings ending in '/.', like '$ORIGIN/.'.  I don't think
            # it semantically makes a difference, but why not be correct AND beautiful?
            chomp_slashdot = path -> begin
                if length(path) > 2 && path[end-1:end] == "/."
                    return path[1:end-2]
                end
                return path
            end
            rpaths = chomp_slashdot.(rpaths)
            # Remove paths starting with `/workspace`: they will not work outisde of the
            # build environment and only create noise when debugging.
            filter!(rp -> !startswith(rp, "/workspace"), rpaths)

            rpath_str = join(rpaths, ':')
            return `$(patchelf()) $(patchelf_flags(platform)) --set-rpath $(rpath_str) $(path)`
        end
        relink = (op, np) -> `$(patchelf()) $(patchelf_flags(platform)) --replace-needed $(op) $(np) $(path)`
    end

    # If the relative directory doesn't already exist within the RPATH of this
    # binary, then add it in.
    new_libdir = abspath(dirname(new_libpath) * "/")
    if !(new_libdir in _canonical_rpaths(path))
        libname = basename(old_libpath)
        cmd = add_rpath(normalize_rpath(relpath(new_libdir, dirname(path))))
        with_logfile(prefix, "update_rpath_$(basename(path))_$(libname).log"; subdir) do io
            if Sys.isapple(platform)
                @lock AUDITOR_SANDBOX_LOCK run(ur, cmd, io; verbose=verbose)
            elseif Sys.islinux(platform) || Sys.isbsd(platform)
                run_with_io(io, cmd)
            end
        end
    end

    # Create a new linkage that uses the RPATH and/or environment variables to find things.
    # This allows us to split things up into multiple packages, and as long as the
    # libraries that this guy is interested in have been `dlopen()`'ed previously,
    # (and have the appropriate SONAME) things should "just work".
    if Sys.isapple(platform)
        # On MacOS, we need to explicitly add `@rpath/` before our library linkage path.
        # Note that this is still overridable through DYLD_FALLBACK_LIBRARY_PATH
        new_libpath = joinpath("@rpath", basename(new_libpath))
    else
        # We just use the basename on all other systems (e.g. Linux).  Note that using
        # $ORIGIN, while cute, doesn't allow for overrides via LD_LIBRARY_PATH.  :[
        new_libpath = basename(new_libpath)
    end
    cmd = relink(old_libpath, new_libpath)
    with_logfile(prefix, "update_linkage_$(basename(path))_$(basename(old_libpath)).log"; subdir) do io
        if Sys.isapple(platform)
            @lock AUDITOR_SANDBOX_LOCK run(ur, cmd, io; verbose=verbose)
        elseif Sys.islinux(platform) || Sys.isbsd(platform)
            run_with_io(io, cmd)
        end
    end

    return new_libpath
end


"""
    is_troublesome_library_link(libname::AbstractString, platform::AbstractPlatform)

Return `true` if depending on `libname` is known to cause problems at runtime, `false` otherwise.
"""
function is_troublesome_library_link(libname::AbstractString, platform::AbstractPlatform)
    if Sys.isapple(platform)
        # In https://github.com/JuliaGtk/GtkSourceWidget.jl/pull/9 we found that
        # depending on these libraries is an indication that system copies of libxml and
        # libiconv has been picked up during compilation.  At runtime, the system copies
        # will be loaded, which are very likely to be incompatible with those provided
        # by JLL packages.  The solution is to make sure that JLL copies of these
        # libraries are used.
        if libname in ("/usr/lib/libxml2.2.dylib", "/usr/lib/libiconv.2.dylib")
            return true
        end
    end
    return false
end
