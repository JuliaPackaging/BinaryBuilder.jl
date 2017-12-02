export audit, collect_files, collapse_symlinks

using ObjectFile
using ObjectFile.ELF

"""
    is_for_platform(h::ObjectHandle, platform::Platform)

Returns `true` if the given `ObjectHandle` refers to an object of the given
`platform`; E.g. if the given `platform` is for AArch64 Linux, then `h` must
be an `ELFHandle` with `h.header.e_machine` set to `ELF.EM_AARCH64`.
"""
function is_for_platform(h::ObjectHandle, platform::Platform)
    if platform isa Linux
        h isa ELFHandle || return false
        (h.ei.osabi == ELF.ELFOSABI_LINUX ||
         h.ei.osabi == ELF.ELFOSABI_NONE) || return false
        mach = h.header.e_machine
        if platform.arch == :i686
            return mach == ELF.EM_386
        elseif platform.arch == :x86_64
            # Allow i686 as well, because that's technically ok
            return (
                mach == ELF.EM_386 ||
                mach == ELF.EM_X86_64)
        elseif platform.arch == :aarch64
            return mach == ELF.EM_AARCH64
        elseif platform.arch == :powerpc64le || platform.arch == :ppc64le
            return mach == ELF.EM_PPC64
        elseif platform.arch == :armv7l
            return mach == ELF.EM_ARM
        else
            error("Unknown architecture")
        end
    elseif platform isa Windows
        h isa COFFHandle || return false
        return true
    elseif platform isa MacOS
        h isa MachOHandle || return false
        return true
    else
        error("Unkown platform")
    end
end

# AUDITOR TODO LIST:
#
# * Auto-determine minimum glibc version (to sate our own curiosity)
# * Detect instruction sets that are non-portable

"""
    audit(prefix::Prefix; platform::Platform = platform_key();
                          verbose::Bool = false,
                          silent::Bool = false,
                          autofix::Bool = false)

Audits a prefix to attempt to find deployability issues with the binary objects
that have been installed within.  This auditing will check for relocatability
issues such as dependencies on libraries outside of the current `prefix`,
usage of advanced instruction sets such as AVX2 that may not be usable on many
platforms, linkage against newer glibc symbols, etc...

This method is still a work in progress, only some of the above list is
actually implemented, be sure to actually inspect `Auditor.jl` to see what is
and is not currently in the realm of fantasy.
"""
function audit(prefix::Prefix; io=STDERR,
                               platform::Platform = platform_key(),
                               verbose::Bool = false,
                               silent::Bool = false,
                               autofix::Bool = false)
    if verbose
        info(io, "Beginning audit of $(prefix.path)")
    end

    # If this is false then it's bedtime for bonzo boy
    all_ok = true

    # Inspect binary files, looking for improper linkage
    predicate = f -> (filemode(f) & 0o111) != 0 || valid_dl_path(f, platform)
    bin_files = collect_files(prefix, predicate)
    for f in collapse_symlinks(bin_files)
        # Peel this binary file open like a delicious tangerine
        oh = try
            h = readmeta(f)
            if !is_for_platform(h, platform)
                if verbose
                    warn(io, "Skipping binary analysis of $(relpath(f, prefix.path)) (incorrect platform)")
                end
                continue
            end
            h
        catch
            # If this isn't an actual binary file, skip it
            if verbose
                info(io, "Skipping binary analysis of $(relpath(f, prefix.path))")
            end
            continue
        end
        rp = RPath(oh)

        if verbose
            msg = strip("""
            Checking $(relpath(f, prefix.path)) with RPath list $(rpaths(rp))
            """)
            info(io, msg)
        end

        # Look at every non-default dynamic link
        libs = filter_default_linkages(find_libraries(oh), oh)
        for libname in keys(libs)
            if !isfile(libs[libname])
                # If we couldn't resolve this library, let's try autofixing,
                # if we're allowed to by the user
                if autofix
                    # First, is this a library that we already know about?
                    known_bins = lowercase.(basename.(bin_files))
                    kidx = findfirst(known_bins .== lowercase(basename(libname)))
                    if kidx > 0
                        # If it is, point to that file instead!
                        new_link = update_linkage(prefix, platform, path(oh), libs[libname], bin_files[kidx]; verbose=verbose)

                        if verbose
                            msg = replace("""
                            Linked library $(libname) has been auto-mapped to
                            $(new_link)
                            """, '\n', ' ')
                            info(io, strip(msg))
                        end
                    else
                        msg = replace("""
                        Linked library $(libname) could not be resolved and
                        could not be auto-mapped
                        """, '\n', ' ')
                        if !silent
                            warn(io, strip(msg))
                        end
                        all_ok = false
                    end
                else
                    msg = replace("""
                    Linked library $(libname) could not be resolved within
                    the given prefix
                    """, '\n', ' ')
                    if !silent
                        warn(io, strip(msg))
                    end
                    all_ok = false
                end
            elseif !startswith(libs[libname], prefix.path)
                msg = replace("""
                Linked library $(libname) (resolved path $(libs[libname]))
                is not within the given prefix
                """, '\n', ' ')
                if !silent
                    warn(io, strip(msg))
                end
                all_ok = false
            end
        end
    end

    # Inspect all shared library files for our platform (but only if we're
    # running native, don't try to load library files from other platforms)
    if platform == platform_key()
        # Find all dynamic libraries
        predicate = f -> valid_dl_path(f, platform)
        shlib_files = collect_files(prefix, predicate)

        for f in shlib_files
            if verbose
                info(io, "Checking shared library $(relpath(f, prefix.path))")
            end
            hdl = Libdl.dlopen_e(f)
            if hdl == C_NULL
                # TODO: Use the relevant ObjFileBase packages to inspect why this
                # file is being nasty to us.

                if !silent
                    warn(io, "$(relpath(f, prefix.path)) cannot be dlopen()'ed")
                end
                all_ok = false
            else
                Libdl.dlclose(hdl)
            end
        end
    end

    # Search _every_ file in the prefix path to find hardcoded paths
    predicate = f -> !startswith(f, joinpath(prefix, "logs")) &&
                     !startswith(f, joinpath(prefix, "manifests"))
    all_files = collect_files(prefix, predicate)

    # Finally, check for absolute paths in any files.  This is not a "fatal"
    # offense, as many files have absolute paths.  We want to know about it
    # though, so we'll still warn the user.
    for f in all_files
        file_contents = readstring(f)
        if contains(file_contents, prefix.path)
            if !silent
                warn(io, "$(relpath(f, prefix.path)) contains an absolute path")
            end
        end
    end

    return all_ok
end

"""
    collect_files(prefix::Prefix, predicate::Function = f -> true)

Find all files that satisfy `predicate()` when the full path to that file is
passed in, returning the list of file paths.
"""
function collect_files(prefix::Prefix, predicate::Function = f -> true)
    collected = String[]
    for (root, dirs, files) in walkdir(prefix.path)
        for f in files
            f_path = joinpath(root, f)

            # Only add this file into our list if it is not already contained.
            # This removes duplicate symlinks
            if predicate(f_path)
                push!(collected, f_path)
            end
        end
    end
    return collected
end


"""
    collapse_symlinks(files::Vector{String})

Given a list of files, prune those that are symlinks pointing to other files
within the list.
"""
function collapse_symlinks(files::Vector{String})
    abs_files = abspath.(files)
    predicate = f -> begin
        try
            return !(islink(f) && realpath(f) in abs_files)
        catch
            return false
        end
    end
    return filter(predicate, files)
end

"""
    filter_default_linkages(libs::Dict, oh::ObjectHandle)

Given libraries obtained through `ObjectFile.find_libraries()`, filter out
libraries that are "default" libraries and should be available on any system.
"""
function filter_default_linkages(libs::Dict, oh::ObjectHandle)
    return Dict(k => libs[k] for k in keys(libs) if !should_ignore_lib(k, oh))
end

function should_ignore_lib(lib, ::ELFHandle)
    default_libs = [
        "libc.so.6",
        # libgcc Linux and FreeBSD style
        "libgcc_s.1.so",
        "libgcc_s.so.1",
        "libm.so.6",
        "libgfortran.so.3",
        "libgfortran.so.4",
    ]
    return lowercase(basename(lib)) in default_libs
end

function should_ignore_lib(lib, ::MachOHandle)
    default_libs = [
        "libsystem.b.dylib",
        "libgcc_s.1.dylib",
        "libgfortran.3.dylib",
        "libgfortran.4.dylib",
        "libquadmath.0.dylib",
    ]
    return lowercase(basename(lib)) in default_libs
end

function should_ignore_lib(lib, ::COFFHandle)
    default_libs = [
        "msvcrt.dll",
        "kernel32.dll",
        "user32.dll",
        "libgcc_s_sjlj-1.dll",
        "libgfortran-3.dll",
        "libgfortran-4.dll",
    ]
    return lowercase(basename(lib)) in default_libs
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

    ur = UserNSRunner(prefix.path; cwd="/workspace/", platform=platform, verbose=true)
    rel_path = relpath(path, prefix.path)

    add_rpath = x -> ``
    relink = (x, y) -> ``
    origin = ""
    patchelf = "/usr/local/bin/patchelf"
    install_name_tool = "/opt/x86_64-apple-darwin14/bin/install_name_tool"
    if Compat.Sys.isapple(platform)
        origin = "@loader_path"
        add_rpath = rp -> `$install_name_tool -add_rpath $(rp) $(rel_path)`
        relink = (op, np) -> `$install_name_tool -change $(op) $(np) $(rel_path)`
    elseif Compat.Sys.islinux(platform)
        origin = "\$ORIGIN"
        full_rpath = join(':', rpaths(RPath(readmeta(path))))
        add_rpath = rp -> `$patchelf --set-rpath $(full_rpath):$(rp) $(rel_path)`
        relink = (op, np) -> `$patchelf --replace-needed $(op) $(np) $(rel_path)`
    end

    if !(dirname(new_libpath) in canonical_rpaths(RPath(readmeta(path))))
        libname = basename(old_libpath)
        logpath = joinpath(logdir(prefix), "update_rpath_$(libname).log")
        cmd = add_rpath(relpath(dirname(new_libpath), dirname(path)))
        run(ur, cmd, logpath; verbose=verbose)
    end

    # Create a new linkage that looks like $ORIGIN/../lib, or similar
    libname = basename(old_libpath)
    logpath = joinpath(logdir(prefix), "update_linkage_$(libname).log")
    origin_relpath = joinpath(origin, relpath(new_libpath, dirname(path)))
    cmd = relink(old_libpath, origin_relpath)
    run(ur, cmd, logpath; verbose=verbose)

    return origin_relpath
end
