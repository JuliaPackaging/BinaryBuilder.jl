export audit, collect_files

using ObjectFile

# AUDITOR TODO LIST:
#
# * Auto-determine minimum glibc version (to sate our own curiosity)
# * Detect instruction sets that are non-portable

"""
    audit(prefix::Prefix; platform::Platform = platform_key();
                          verbose::Bool = false,
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
function audit(prefix::Prefix; platform::Platform = platform_key(),
                               verbose::Bool = false,
                               autofix::Bool = false)
    if verbose
        info("Beginning audit of $(prefix.path)")
    end

    # If this is false then it's bedtime for bonzo boy
    all_ok = true

    # Inspect binary files, looking for improper linkage
    predicate = f -> (filemode(f) & 0o111) != 0 || valid_dl_path(f, platform)
    bin_files = collect_files(prefix, predicate)
    for f in bin_files
        # Peel this binary file open like a delicious tangerine
        oh = try
            readmeta(f)
        catch
            # If this isn't an actual binary file, skip it
            if verbose
                info("Skipping binary analysis of $(relpath(f, prefix.path))")
            end
            continue
        end
        rp = RPath(oh)

        if verbose
            msg = strip("""
            Checking $(relpath(f, prefix.path)) with RPath list $(rpaths(rp))
            """)
            info(msg)
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
                            info(strip(msg))
                        end
                    else
                        msg = replace("""
                        Linked library $(libname) could not be resolved and
                        could not be auto-mapped
                        """, '\n', ' ')
                        warn(strip(msg))
                        all_ok = false
                    end
                else
                    msg = replace("""
                    Linked library $(libname) could not be resolved within
                    the given prefix
                    """, '\n', ' ')
                    warn(strip(msg))
                    all_ok = false
                end
            elseif !startswith(libs[libname], prefix.path)
                msg = replace("""
                Linked library $(libname) (resolved path $(libs[libname]))
                is not within the given prefix
                """, '\n', ' ')
                warn(strip(msg))
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
                info("Checking shared library $(relpath(f, prefix.path))")
            end
            hdl = Libdl.dlopen_e(f)
            if hdl == C_NULL
                # TODO: Use the relevant ObjFileBase packages to inspect why this
                # file is being nasty to us.

                warn("$(relpath(f, prefix.path)) cannot be dlopen()'ed")
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
            warn("$(relpath(f, prefix.path)) contains an absolute path")
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
    real_paths = String[]
    for (root, dirs, files) in walkdir(prefix.path)
        for f in files
            f_path = joinpath(root, f)

            # Calculate the realpath, but keep the nicely formatted path too
            f_real_path = realpath(f_path)

            # Only add this file into our list if it is not already contained.
            # This removes duplicate symlinks
            if !(f_real_path in real_paths) && predicate(f_path)
                push!(collected, f_path)
                push!(real_paths, realpath(f_path))
            end
        end
    end
    return collected
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
        "libgcc_s.1.so",
    ]
    return lowercase(basename(lib)) in default_libs
end

function should_ignore_lib(lib, ::MachOHandle)
    default_libs = [
        "libsystem.b.dylib",
        "libgcc_s.1.dylib",
    ]
    return lowercase(basename(lib)) in default_libs
end

function should_ignore_lib(lib, ::COFFHandle)
    default_libs = [
        "msvcrt.dll",
        "kernel32.dll",
        "user32.dll",
        "libgcc_s_sjlj-1.dll",
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
    if is_windows(platform)
        return
    end

    dr = DockerRunner(;prefix=prefix, platform=platform)

    add_rpath = x -> ``
    relink = (x, y) -> ``
    origin = ""
    if is_apple(platform)
        origin = "@loader_path"
        add_rpath = rp -> `install_name_tool -add_rpath $(rp) $(path)`
        relink = (op, np) -> `install_name_tool -change $(op) $(np) $(path)`
    elseif is_linux(platform)
        origin = "\$ORIGIN"
        full_rpath = join(':', rpaths(RPath(readmeta(path))))
        add_rpath = rp -> `patchelf --set-rpath $(full_rpath):$(rp) $(path)`
        relink = (op, np) -> `patchelf --replace-needed $(op) $(np) $(path)`
    end

    if !(dirname(new_libpath) in canonical_rpaths(RPath(readmeta(path))))
        libname = basename(old_libpath)
        logpath = joinpath(logdir(prefix), "update_rpath_$(libname).log")
        cmd = add_rpath(relpath(dirname(new_libpath), dirname(path)))
        run(dr, cmd, logpath; verbose=verbose)
    end

    # Create a new linkage that looks like $ORIGIN/../lib, or similar
    libname = basename(old_libpath)
    logpath = joinpath(logdir(prefix), "update_linkage_$(libname).log")
    origin_relpath = joinpath(origin, relpath(new_libpath, dirname(path)))
    cmd = relink(old_libpath, origin_relpath)
    run(dr, cmd, logpath; verbose=verbose)

    return origin_relpath
end

