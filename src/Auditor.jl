# Use these libraries to verify dynamic library dependency chains eventually
#using MachO
#using COFF
#using ELF
#using ObjFileBase

function audit(prefix::Prefix)
    # Search _every_ file for the prefix path to find hardcoded paths
    all_files = collect_files(prefix, f -> !startswith(f, joinpath(prefix, "logs")))

    # Eventually, we'll want to filter out MachO binaries, ELF binaries, etc...
    # and inspect those more thoroughly in order to provide more interesting
    # feedback.   
    #binaries = filter(f -> filemode(f) & 0o100, all_files)

    all_ok = true

    for f in all_files
        file_contents = readstring(f)
        if contains(file_contents, prefix.path)
            warn("$(relpath(f,prefix.path)) contains hints of an absolute path")
            all_ok = false
        end
    end

    return all_ok
end

function collect_files(prefix::Prefix, predicate::Function)
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
