# merge multiple JSON objects garnered via `--meta-json`
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
    # Turn `source` values back into AbstractSource's
    meta["sources"] = sourcify.(meta["sources"])

    # Turn `dependencies` back into AbstractDependency's
    meta["dependencies"] = dependencify.(meta["dependencies"])

    # Turn `version` back into a VersionNumber (not a string)
    meta["version"] = VersionNumber(meta["version"])

    # Reconstruct our `Product`s
    function reconstruct_product(p::Dict)
        if p["type"] == "exe"
            return ExecutableProduct(p)
        elseif p["type"] == "lib"
            return LibraryProduct(p)
        elseif p["type"] == "framework"
            return FrameworkProduct(p)
        elseif p["type"] == "file"
            return FileProduct(p)
        else
            error("Unknown product type $(p["type"])")
        end
    end
    meta["products"] = Product[reconstruct_product(p) for p in meta["products"]]

    if haskey(meta, "platform")
        # Convert platforms back to actual Platform objects
        meta["platforms"] = [platform_key_abi(p) for p in meta["platforms"]]
    else
        # If the key isn't there it's because this is a platform-independent
        # build, so use `AnyPlatform()`.
        meta["platforms"] = [AnyPlatform()]
    end

    # Return the cleaned-up meta for fun
    return meta
end
