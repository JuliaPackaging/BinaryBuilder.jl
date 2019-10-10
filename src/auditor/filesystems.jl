function check_case_sensitivity(prefix::Prefix, all_files::Vector; io::IO = stdout)
    lower_files = Set()
    all_ok = true
    for f in all_files
        lf = lowercase(f)
        if lf in lower_files
            warn(io, "$(relpath(f, prefix.path)) causes a case-sensitivity ambiguity!")
            all_ok = false
        end
    end
    return all_ok
end


function check_absolute_paths(prefix::Prefix, all_files::Vector; io::IO = stdout)
    # Finally, check for absolute paths in any files.  This is not a "fatal"
    # offense, as many files have absolute paths.  We want to know about it
    # though, so we'll still warn the user.
    for f in all_files
        try
            file_contents = String(read(f))
            if occursin(prefix.path, file_contents)
                if !silent
                    warn(io, "$(relpath(f, prefix.path)) contains an absolute path")
                end
            end
        catch
            if !silent
                warn(io, "Skipping abspath scanning of $(f), as we can't open it")
            end
        end
    end

    return true
end
