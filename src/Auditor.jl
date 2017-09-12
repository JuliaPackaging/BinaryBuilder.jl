# Use these libraries to verify dynamic library dependency chains eventually
#using MachO
#using COFF
#using ELF
#using ObjFileBase
export audit, collect_files

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

    # Inspect all shared library files for our platform
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

        # TODO: Check linking against global libraries
    end

    # Eventually, we'll want to filter out MachO binaries, ELF binaries, etc...
    # and inspect those more thoroughly in order to provide more interesting
    # feedback.
    bin_files = collect_files(prefix, f -> (filemode(f) & 0o111) != 0)
    bin_files = filter(f -> !(f in shlib_files), bin_files)
    for f in bin_files
        if verbose
            info("Checking binary $(relpath(f, prefix.path))")
        end

        # TODO: Check linking against global libraries
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
`collect_files(prefix::Prefix, predicate::Function = f -> true)`

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
