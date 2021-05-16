function check_codesigned(path::AbstractString, platform::AbstractPlatform)
    # We only perform ad-hoc codesigning on Apple platforms
    if !Sys.isapple(platform)
        return true
    end

    ur = preferred_runner()(dirname(path); cwd="/workspace/", platform=platform)
    return run(ur, `/usr/local/bin/ldid -d $(basename(path))`)
end

function ensure_codesigned(path::AbstractString, prefix::Prefix, platform::AbstractPlatform;
                           verbose::Bool = false, subdir::AbstractString="")
    # We only perform ad-hoc codesigning on Apple platforms
    if !Sys.isapple(platform)
        return true
    end

    rel_path = relpath(path, prefix.path)
    ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
    with_logfile(prefix, "ldid_$(basename(rel_path)).log"; subdir) do io
        run(ur, `/usr/local/bin/ldid -S -d $(rel_path)`, io; verbose=verbose)
    end
end
