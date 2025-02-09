using ldid_jll: ldid

function check_codesigned(path::AbstractString, platform::AbstractPlatform)
    # We only perform ad-hoc codesigning on Apple platforms
    if !Sys.isapple(platform)
        return true
    end

    return run(`$(ldid()) -d $(basename(path))`)
end

function ensure_codesigned(path::AbstractString, prefix::Prefix, platform::AbstractPlatform;
                           verbose::Bool = false, subdir::AbstractString="")
    # We only perform ad-hoc codesigning on Apple platforms
    if !Sys.isapple(platform)
        return true
    end

    with_logfile(prefix, "ldid_$(basename(path)).log"; subdir) do io
        run(pipeline(`$(ldid()) -S -d $(path)`; stdout=io, stderr=io))
    end
end
