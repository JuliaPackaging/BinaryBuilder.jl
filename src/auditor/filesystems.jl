function check_case_sensitivity(prefix::Prefix)
    all_ok = true

    function check_set(root, list)
        lowered = Set()
        for f in list
            lf = lowercase(f)
            if lf in lowered
                audit_warn("$(relpath(joinpath(root, f), prefix.path)) causes a case-sensitivity ambiguity!",
                           @__FILE__, @__LINE__)
                all_ok = false
            end
            push!(lowered, lf)
        end
    end

    for (root, dirs, files) in walkdir(prefix.path)
        check_set(root, dirs)
        check_set(root, files)
    end

    return all_ok
end


function check_absolute_paths(prefix::Prefix, all_files::Vector; silent::Bool = false)
    # Finally, check for absolute paths in any files.  This is not a "fatal"
    # offense, as many files have absolute paths.  We want to know about it
    # though, so we'll still warn the user.
    for f in all_files
        try
            file_contents = String(read(f))
            if occursin(prefix.path, file_contents)
                if !silent
                    audit_warn("$(relpath(f, prefix.path)) contains an absolute path", @__FILE__, @__LINE__)
                end
            end
        catch
            if !silent
                audit_warn("Skipping abspath scanning of $(f), as we can't open it", @__FILE__, @__LINE__)
            end
        end
    end

    return true
end
