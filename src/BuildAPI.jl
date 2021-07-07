export build!, package!

function build!(meta::BuildMeta,
                src_name::String,
                src_version::VersionNumber,
                sources::Vector{<:AbstractSource},
                script::String,
                platform::AbstractPlatform,
                dependencies::Vector{<:Dependency};
                compilers::Vector{Symbol} = [:c])
    # First, construct a `BuildConfig` representing this build
    config = BuildConfig(
        src_name,
        src_version,
        sources,
        dependencies,
        compilers,
        script,
        platform,
    )
    push!(meta.builds, config)

    # If json output is requested, we skip all our builds
    if meta.json_output !== nothing
        return
    end

    build_results = 
    return build_results
end

function package!(meta::BuildMeta,
                  builds::Vector{BuildResult},
                  jll_name::String,
                  script::String,
                  products::Vector{<:Product})
    return package_results
end

function build_tarballs(ARGS, src_name, src_version, sources, script,
                        platforms, products, dependencies;
                        julia_compat::String = DEFAULT_JULIA_VERSION_SPEC,
                        compilers::Vector{Symbol} = [:c],
                        kwargs...)
    meta = BuildMeta(ARGS)
    build_results = BuildResult[]
    for platform in platforms
        push!(build_results, build!(meta, src_name, src_version, sources, script, platform, dependencies; compilers))
    end
    package_results = package!(meta, build_results, src_name, "cp -a * \${prefix}", products)
    return meta
end
