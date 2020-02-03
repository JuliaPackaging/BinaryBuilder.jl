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

# XXX: compatibility functions.  These are needed until we support old-style
# dependencies.
coerce_dependency(dep::AbstractDependency) = dep
function coerce_dependency(dep)
    @warn "Using PackageSpec or string as dependency is deprecated, use Dependency instead"
    Dependency(dep)
end
