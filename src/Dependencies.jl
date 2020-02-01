export Dependency, BuildDependency

# Pkg.PackageSpec return different types in different Julia versions so...
const PkgSpec = typeof(Pkg.PackageSpec(name="dummy"))

abstract type AbstractDependency{T<:Union{PkgSpec,String}} end

struct Dependency{T<:Union{PkgSpec,String}} <: AbstractDependency{T}
    pkg::T
end
Dependency(d::AbstractString) = Dependency(String(d))

struct BuildDependency{T<:Union{PkgSpec,String}} <: AbstractDependency{T}
    pkg::T
end
BuildDependency(d::AbstractString) = BuildDependency(String(d))

getpkg(d::AbstractDependency) = d.pkg

dep_name(x::AbstractDependency) = x
dep_name(x::String) = Dependency(x)
dep_name(x::PkgSpec) = Dependency(x.name)

# compatibility for Julia 1.3-
if VERSION < v"1.4"
    Pkg.Types.registry_resolve!(ctx::Pkg.Types.Context, deps) = Pkg.Types.registry_resolve!(ctx.env, deps)
end

pkgspecify(name::AbstractString) = PkgSpec(;name=name)
pkgspecify(ps::PkgSpec) = ps
pkgspecify(dependency::Dependency) = Dependency(pkgspecify(getpkg(dependency)))
pkgspecify(dependency::BuildDependency) = BuildDependency(pkgspecify(getpkg(dependency)))

# Wrapper around `Pkg.Types.registry_resolve!` which keeps the type of the
# dependencies.  TODO: improve this
function registry_resolve!(ctx, dependencies::Vector{<:AbstractDependency{PkgSpec}})
    resolved_dependencies = Pkg.Types.registry_resolve!(ctx, getpkg.(dependencies))
    for idx in eachindex(dependencies)
        dependencies[idx] = typeof(dependencies[idx])(resolved_dependencies[idx])
    end
    return dependencies
end

function resolve_jlls(dependencies::Vector; ctx = Pkg.Types.Context(), outs=stdout)
    if isempty(dependencies)
        return true, Dependency{PkgSpec}[]
    end

    # Don't clobber caller
    # XXX: Coercion is needed as long as we support old-style dependencies.
    dependencies = deepcopy(coerce_dependency.(dependencies))

    # Convert all dependencies to `AbstractDependency{PackageSpec}`s
    dependencies = pkgspecify.(dependencies)

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
            @warn("Unable to resolve $(dep.name)")
            all_resolved = false
        end
    end
    return all_resolved, dependencies
end

# XXX: compatibility functions.  These are needed until we support old-style
# dependencies.
coerce_dependency(dep::AbstractDependency) = dep
function coerce_dependency(dep)
    @warn "Using PackageSpec or string as source is deprecated, use Dependency instead"
    Dependency(dep)
end
