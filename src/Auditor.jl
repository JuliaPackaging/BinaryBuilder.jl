export audit, collect_files

using ObjectFile

# AUDITOR TODO LIST:
#
# * Find external library dependencies (e.g. libgfortran)
# * Auto-copy in external libraries?  Or provide an easy way for the user to
# * Auto re-write libraries to use RPATH, etc...
# * Auto-determine minimum glibc version (to sate our own curiosity)
# * Detect instruction sets that are non-portable

"""
    audit(prefix::Prefix; platform::Symbol = platform_key();
                          verbose::Bool = false)

Audits a prefix to attempt to find deployability issues with the binary objects
that have been installed within.  This auditing will check for relocatability
issues such as dependencies on libraries outside of the current `prefix`,
usage of advanced instruction sets such as AVX2 that may not be usable on many
platforms, linkage against newer glibc symbols, etc...

This method is still a work in progress, only some of the above list is
actually implemented, be sure to actually inspect `Auditor.jl` to see what is
and is not currently in the realm of fantasy.
"""
function audit(prefix::Prefix; platform::Symbol = platform_key(),
                               verbose::Bool = false)
    if verbose
        info("Beginning audit of $(prefix.path)")
    end

    # If this is false then it's bedtime for bonzo boy
    all_ok = true

    # Find all dynamic libraries
    predicate = f -> valid_dl_path(f, platform)
    shlib_files = collect_files(prefix, predicate)

    # Inspect binary files, looking for improper linkage
    bin_files = collect_files(prefix, f -> (filemode(f) & 0o111) != 0)
    bin_files = filter(f -> !(f in shlib_files), bin_files)
    for f in bin_files
        if verbose
            info("Checking binary $(relpath(f, prefix.path))")
        end

        # Peel this binary file open like a delicious tangerine
        oh = readmeta(f)
        libs = filter_default_linkages(find_libraries(oh), oh)

        # Look at every non-default link
        for libname in keys(libs)
            if !startswith(libs[libname], prefix.path)
                msg = replace("""
                Linked library $(libname) (resolved path $(libs[libname]))
                is not within the given prefix
                """, '\n', ' ')
                warn(msg)
            end
        end
    end

    # Inspect all shared library files for our platform (but only if we're
    # running native, don't try to load library files from other platforms)
    if platform == platform_key()
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
            warn("$(relpath(f,prefix.path)) contains hints of an absolute path")
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
            if predicate(f_path)
                push!(collected, f_path)
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
    return basename(lib) in default_libs
end

function should_ignore_lib(lib, ::MachOHandle)
    default_libs = [
        "libSystem.B.dylib",
        "libgcc_s.1.dylib",
    ]
    return basename(lib) in default_libs
end

function should_ignore_lib(lib, ::COFFHandle)
    default_libs = [
        "msvcrt.dll",
        "KERNEL32.dll",
    ]
    return basename(lib) in default_libs
end