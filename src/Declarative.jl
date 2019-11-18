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
    # Turn `source` values back into pairs, instead of dicts
    for idx in 1:length(meta["sources"])
        if isa(meta["sources"][idx], Dict) && length(meta["sources"][idx]) == 1
            meta["sources"][idx] = first(meta["sources"][idx])
        end
    end

    # Turn `version` back into a VersionNumber (not a string)
    meta["version"] = VersionNumber(meta["version"])

    # Reconstruct our `Product`s
    function reconstruct_product(p::Dict)
        if p["type"] == "exe"
            return ExecutableProduct(p)
        elseif p["type"] == "lib"
            return LibraryProduct(p)
        elseif p["type"] == "file"
            return FileProduct(p)
        else
            error("Unknown product type $(p["type"])")
        end
    end
    meta["products"] = Product[reconstruct_product(p) for p in meta["products"]]

    # Convert platforms back to acutal Platform objects
    meta["platforms"] = [platform_key_abi(p) for p in meta["platforms"]]

    # Return the cleaned-up meta for fun
    return meta
end
