# Use these libraries to verify dynamic library dependency chains eventually
#using MachO
#using COFF
#using ELF
#using ObjFileBase
export audit, collect_files

function audit(prefix::Prefix)
    # Search _every_ file in the prefix path to find hardcoded paths
    predicate = f -> !startswith(f, joinpath(prefix, "logs")) &&
                     !startswith(f, joinpath(prefix, "manifests"))
    all_files = collect_files(prefix, predicate)

    # If this is false then it's bedtime for bonzo boy
    all_ok = true

    # First, check for absolute paths in files
    for f in all_files
        file_contents = readstring(f)
        if contains(file_contents, prefix.path)
            warn("$(relpath(f,prefix.path)) contains hints of an absolute path")
            all_ok = false
        end
    end

    # Inspect all relevant shared library files
    shlib_regex = Regex(".*\\.$(Libdl.dlext)[\\.0-9]*\$")
    shlib_files = filter(f -> ismatch(shlib_regex, f), all_files)
    for f in shlib_files
        if Libdl.dlopen_e(f) == C_NULL
            # TODO: Use the relevant ObjFileBase packages to inspect why this
            # file is being nasty to us.

            # TODO: Commenting this out for now since we have cross-compilation working
            # and that obviously doesn't play well with this test.
            #warn("$(relpath(f, prefix.path)) cannot be dlopen()'ed")
            #all_ok = false
        end
    end

    # Eventually, we'll want to filter out MachO binaries, ELF binaries, etc...
    # and inspect those more thoroughly in order to provide more interesting
    # feedback.
    #binaries = filter(f -> filemode(f) & 0o100, all_files)
    
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
