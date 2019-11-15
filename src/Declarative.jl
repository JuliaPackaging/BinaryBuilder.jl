# merge mutiple JSON objects garnered via `--meta-json`
function merge_json_objects(objs::Vector)
    merged = Dict()
    for obj in objs
        for k in keys(obj)
            if !haskey(merged, k)
                merged[k] = obj[k]
            else
                if merged[k] != obj[k]
                    if !isa(merged[k], Array)
                        merged[k] = [merged[k]]
                    end

                    if isa(obj[k], Array)
                        append!(merged[k], obj[k])
                    else
                        push!(merged[k], obj[k])
                    end
                    merged[k] = unique(merged[k])
                end
            end
        end
    end
    return merged
end

# Fix various things that go wrong with the JSON translation
function cleanup_merged_object!(meta::Dict)
    for idx in 1:length(meta["sources"])
        if isa(meta["sources"][idx], Dict) && length(meta["sources"][idx]) == 1
            meta["sources"][idx] = first(meta["sources"][idx])
        end
    end
    meta["version"] = VersionNumber(meta["version"])
    return meta
end
