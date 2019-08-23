using BinaryBuilder, Pkg, Pkg.Artifacts, Pkg.BinaryPlatforms

artifacts_toml = joinpath(dirname(@__DIR__),"Artifacts.toml")
mutable_artifacts_toml = joinpath(dirname(@__DIR__),"Artifacts.toml")
if uperm(artifacts_toml) & 0x02 != 0x02
    error("dev BinaryBuilder first!")
end

function cull_old_artifacts(artifacts_toml::String)
    dict = Pkg.Artifacts.load_artifacts_toml(artifacts_toml)

    # Convert names to CompilerShards
    css = BinaryBuilder.CompilerShard.(names)

    # Eliminate duplicates
    css = 
end
