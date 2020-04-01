export Dependency, BuildDependency

# Pkg.PackageSpec return different types in different Julia versions so...
const PkgSpec = typeof(Pkg.PackageSpec(name="dummy"))

"""
An `AbstractDependency` is a binary dependency of the JLL package.  Dependencies
are installed to `\${prefix}` in the build environment.

Concrete subtypes of `AbstractDependency` are

* [`Dependency`](@ref): a JLL package that is necessary for to build the package
  and to load the generated JLL package.
* [`BuildDependency`](@ref): a JLL package that is necessary only t obuild the
  package.  This will not be a dependency of the generated JLL package.
"""
abstract type AbstractDependency end

"""
    Dependency(dep::Union{PackageSpec,String})

Define a binary dependency that is necessary to build the package and load the
generated JLL package.  The argument can be either a string with the name of the
JLL package or a `Pkg.PackageSpec`.
"""
struct Dependency <: AbstractDependency
    pkg::PkgSpec
end
Dependency(dep::AbstractString) = Dependency(PackageSpec(; name = dep))

"""
    BuildDependency(dep::Union{PackageSpec,String})

Define a binary dependency that is necessary only to build the package.  The
argument can be either a string with the name of the JLL package or a
`Pkg.PackageSpec`.
"""
struct BuildDependency <: AbstractDependency
    pkg::PkgSpec
end
BuildDependency(dep::AbstractString) = BuildDependency(PackageSpec(; name = dep))

getpkg(d::AbstractDependency) = d.pkg

getname(x::PkgSpec) = x.name
getname(x::AbstractDependency) = getname(getpkg(x))

# compatibility for Julia 1.3-
if VERSION < v"1.4"
    Pkg.Types.registry_resolve!(ctx::Pkg.Types.Context, deps) = Pkg.Types.registry_resolve!(ctx.env, deps)
end

# Wrapper around `Pkg.Types.registry_resolve!` which keeps the type of the
# dependencies.  TODO: improve this
function registry_resolve!(ctx, dependencies::Vector{<:AbstractDependency})
    resolved_dependencies = Pkg.Types.registry_resolve!(ctx, getpkg.(dependencies))
    for idx in eachindex(dependencies)
        dependencies[idx] = typeof(dependencies[idx])(resolved_dependencies[idx])
    end
    return dependencies
end

function resolve_jlls(dependencies::Vector; ctx = Pkg.Types.Context(), outs=stdout)
    if isempty(dependencies)
        return true, Dependency[]
    end

    # Don't clobber caller
    # XXX: Coercion is needed as long as we support old-style dependencies.
    dependencies = deepcopy(coerce_dependency.(dependencies))

    # If all dependencies already have a UUID, return early
    if all(x->getpkg(x).uuid !== nothing, dependencies)
        return true, dependencies
    end

    # Resolve, returning the newly-resolved dependencies
    update_registry(ctx)
    dependencies = registry_resolve!(ctx, dependencies)

    # But first, check to see if anything failed to resolve, and warn about it:
    all_resolved = true
    for dep in getpkg.(dependencies)
        if dep.uuid === nothing
            @warn("Unable to resolve $(getname(dep))")
            all_resolved = false
        end
    end
    return all_resolved, dependencies
end

# Add JSON serialization of dependencies
string_or_nothing(x) = isnothing(x) ? x : string(x)

major(v::VersionNumber) = v.major
minor(v::VersionNumber) = v.minor
patch(v::VersionNumber) = v.patch
major(v::Pkg.Types.VersionBound) = v.t[1]
minor(v::Pkg.Types.VersionBound) = v.t[2]
patch(v::Pkg.Types.VersionBound) = v.t[3]
__version(v::VersionNumber) = v
__version(v::Pkg.Types.VersionSpec) = v.ranges[1].lower
version(d::Union{Dependency, BuildDependency}) = __version(d.pkg.version)

JSON.lower(d::Dependency) = Dict("type" => "dependency", "name" => d.pkg.name, "uuid" => string_or_nothing(d.pkg.uuid),
                                 "version-major" => major(version(d)),
                                 "version-minor" => minor(version(d)),
                                 "version-patch" => patch(version(d)))
JSON.lower(d::BuildDependency) = Dict("type" => "builddependency", "name" => d.pkg.name, "uuid" => string_or_nothing(d.pkg.uuid),
                                      "version-major" => major(version(d)),
                                      "version-minor" => minor(version(d)),
                                      "version-patch" => patch(version(d)))

# When deserialiasing the JSON file, the dependencies are in the form of
# dictionaries.  This function converts the dictionary back to the appropriate
# AbstractDependency.
function dependencify(d::Dict)
    if d["type"] == "dependency"
        uuid = isnothing(d["uuid"]) ? d["uuid"] : UUID(d["uuid"])
        version = VersionNumber(d["version-major"], d["version-minor"], d["version-patch"])
        version = version == v"0" ? nothing : version
        return Dependency(PackageSpec(; name = d["name"], uuid = uuid, version = version))
    elseif d["type"] == "builddependency"
        uuid = isnothing(d["uuid"]) ? d["uuid"] : UUID(d["uuid"])
        version = VersionNumber(d["version-major"], d["version-minor"], d["version-patch"])
        version = version == v"0" ? nothing : version
        return BuildDependency(PackageSpec(; name = d["name"], uuid = uuid, version = version))
    else
        error("Cannot convert to dependency")
    end
end


# XXX: compatibility functions.  These are needed until we support old-style
# dependencies.
coerce_dependency(dep::AbstractDependency) = dep
function coerce_dependency(dep)
    @warn "Using PackageSpec or string as dependency is deprecated, use Dependency instead"
    Dependency(dep)
end
