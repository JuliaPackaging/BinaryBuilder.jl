function check_case_sensitivity(prefix::Prefix)
    all_ok = true

    function check_set(root, list)
        lowered = Set()
        for f in list
            lf = lowercase(f)
            if lf in lowered
                @lock AUDITOR_LOGGING_LOCK @warn("$(relpath(joinpath(root, f), prefix.path)) causes a case-sensitivity ambiguity!")
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
                    @lock AUDITOR_LOGGING_LOCK @warn("$(relpath(f, prefix.path)) contains an absolute path")
                end
            end
        catch
            if !silent
                @lock AUDITOR_LOGGING_LOCK @warn("Skipping abspath scanning of $(f), as we can't open it")
            end
        end
    end

    return true
end

function ensure_executability(oh::ObjectHandle; verbose::Bool=false, silent::Bool=false)
    old_mode = filemode(path(oh))
    # Execution permissions only for users who can read the file
    read_mask = (old_mode & 0o444) >> 2
    # Check whether the file has executable permission for all
    if old_mode & read_mask != read_mask
        if verbose
            @lock AUDITOR_LOGGING_LOCK @info "Making $(path(oh)) executable"
        end
        try
            # Add executable permission for all users that can read the file
            chmod(path(oh), old_mode | read_mask)
        catch e
            if isa(e, InterruptException)
                rethrow(e)
            end
            if !silent
                @lock AUDITOR_LOGGING_LOCK @warn "$(path(oh)) could not be made executable!" exception=(e, catch_backtrace())
            end
        end
    end
    return true
end
