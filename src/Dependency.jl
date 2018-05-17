import BinaryProvider: satisfied
export BuildStep, Dependency, satisfied, build

"""
    Dependency

A `Dependency` represents a set of `Product`s that must be satisfied before a
package can be run.  These `Product`s can be libraries, basic files,
executables, etc...

To build a `Dependency`, construct it and use `build()`.  To check to see if it
is already satisfied, use `satisfied()`.
"""
struct Dependency
    # The "name" of this dependency (e.g. "cairo")
    name::String

    # The resultant objects that must be present by this recipe's Products
    # have different rules that are automatically applied when verifying that
    # this dependency is satisfied
    results::Vector{Product}

    # The bash script to build this dependency
    script::String

    # The platform this dependency is built for
    platform::Platform

    # The parent "prefix" this dependency must be installed within
    prefix::Prefix

    """
        Dependency(name::AbstractString,
                   results::Vector{Product},
                   cmds::Vector{Cmd},
                   platform::Platform,
                   prefix::Prefix = global_prefix)

    Defines a new dependency that must be built by its name, the binary objects
    that will be built, the commands that must be run to build them, and the
    prefix within which all of this will be installed.

    You may also provide a `Vector` of tuples containing the URLs and hashes
    """
    function Dependency(name::AbstractString,
                    results::Vector{P},
                    script::AbstractString,
                    platform::Platform,
                    prefix::Prefix = BinaryProvider.global_prefix) where {P <: Product}
        return new(name, results, script, platform, prefix)
    end
end

"""
    satisfied(dep::Dependency; platform::Platform = platform_key(),
                               verbose::Bool = false)

Return true if all results are satisfied for this dependency.
"""
function satisfied(dep::Dependency; verbose::Bool = false)
    s = result -> satisfied(result; verbose=verbose, platform=dep.platform)
    return all(s(result) for result in dep.results)
end

"""
    build(runner, dep::Dependency; verbose::Bool = false, force::Bool = false,
                  autofix::Bool = false, ignore_audit_errors::Bool = true)

Build the dependency for given `platform` (defaulting to the host platform)
unless it is already satisfied.  If `force` is set to `true`, then the
dependency is always built.  Runs an audit of the built files, printing out
warnings if hints of unrelocatability are found.  These warnings are, by
default, ignored, unless `ignore_audit_errors` is set to `false`.  Some
warnings can be automatically fixed, and this will be attempted if `autofix` is
set to `true`.
"""
function build(runner, dep::Dependency; verbose::Bool = false, force::Bool = false,
               autofix::Bool = false, ignore_audit_errors::Bool = true,
               ignore_manifests::Vector = [])
    # First, look to see whether this dependency is satisfied or not
    should_build = !satisfied(dep)

    # If it is not satisfied, (or we're forcing the issue) build it
    if force || should_build
        # Verbose mode tells us what's going on
        if verbose
            if !should_build
                Compat.@info("Force-building $(dep.name) despite its satisfaction")
            else
                Compat.@info("Building $(dep.name) as it is unsatisfied")
            end
        end

        # Run the build script
        logpath = joinpath(logdir(dep.prefix), "$(dep.name).log")
        did_succeed = run(runner, `/bin/bash -c $(dep.script)`, logpath; verbose=verbose)
        if !did_succeed
            msg = "Build for $(dep.name) did not complete successfully\n"
            error(msg)
        end

        # Run an audit of the prefix to ensure it is properly relocatable
        audit_result = audit(dep.prefix; platform=dep.platform,
                             verbose=verbose, autofix=autofix,
                             ignore_manifests=ignore_manifests) 
        if !audit_result && !ignore_audit_errors
            msg = replace("""
            Audit failed for $(dep.prefix.path).
            Address the errors above to ensure relocatability.
            To override this check, set `ignore_audit_errors = true`.
            """, '\n' => ' ')
            error(strip(msg))
        end

        # Finally, check to see if we are now satisfied
        if !satisfied(dep; verbose=verbose)
            if verbose
                Compat.@warn("Built $(dep.name) but still unsatisfied!")
            end
        end
    elseif !should_build && verbose
        Compat.@info("Not building as $(dep.name) is already satisfied")
    end
    return true
end
