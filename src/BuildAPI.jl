export build!, package!

function build!(meta::BuildMeta,
                src_name::String,
                src_version::VersionNumber,
                sources::Vector{<:AbstractSource},
                script::String,
                platforms::Vector{<:AbstractPlatform},
                dependencies::Vector{<:Dependency})
    # First, construct a `BuildConfig` representing this 
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
                        kwargs...)
    meta = BuildMeta(ARGS)
    for platform in platforms
        compilers = [:c]
        build_config = BuildConfig(src_name, src_version, sources, dependencies, compilers)
    end
    build_results = build!(meta, src_name, src_version, sources, script, platforms, dependencies)
    package_results = package!(meta, build_results, src_name, "cp -a * \${prefix}", products)
    return meta
end