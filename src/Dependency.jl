import BinaryProvider: satisfied
export BuildStep, Dependency, satisfied, build

# A `BuildStep` is just a `Cmd` with some helper data bundled along, such as a
# unique (from within a `Dependency`) name, a link to its prefix for
# auto-calculating the `logpath()` for a `BuildStep`, etc....
immutable BuildStep
    name::String
    cmd::Cmd
    prefix::Prefix
end

function logpath(step::BuildStep)
    return joinpath(logdir(step.prefix), "$(step.name).log")
end

# A dependency is something that must be satisfied before a package can be run.
# These dependencies can be Libraries, basic files, etc...
immutable Dependency
    # The "name" of this dependency (e.g. "cairo")
    name::String

    # The resultant objects that must be present by this recipe's Products
    # have different rules that are automatically applied when verifying that
    # this dependency is satisfied
    results::Vector{Product}

    # The build steps in order to build this dependency.
    steps::Vector{BuildStep}

    # The platform this dependency is built for
    platform::Symbol

    # The parent "prefix" this dependency must be installed within
    prefix::Prefix
end


"""
Dependency(name::AbstractString,
           results::Vector{Product},
           cmds::Vector{Cmd},
           platform::Symbol,
           prefix::Prefix = global_prefix)

Defines a new dependency that must be built by its name, the binary objects
that will be built, the commands that must be run to build them, and the prefix
within which all of this will be installed.

You may, alternately, provide a `Vector` of tuples containing the URLs and hashes
"""
function Dependency{P <: Product}(name::AbstractString,
                    results::Vector{P},
                    cmds::Vector{Cmd},
                    platform::Symbol,
                    prefix::Prefix = BinaryProvider.global_prefix)
    name_idxs = Dict{String,Int64}()

    function build_step(prefix, cmd)
        step_name = basename(cmd.exec[1])
        if !haskey(name_idxs, step_name)
            name_idxs[step_name] = 0
        end
        postfixed_step_name = "$(name)/$(step_name)_$(name_idxs[step_name])"
        name_idxs[step_name] += 1
        return BuildStep(postfixed_step_name, cmd, prefix)
    end

    steps = [build_step(prefix, cmd) for cmd in cmds]
    return Dependency(name, results, steps, platform, prefix)
end


"""
satisfied(dep::Dependency; platform::Symbol = platform_key(),
                           verbose::Bool = false)

Return true if all results are satisfied for this dependency.
"""
function satisfied(dep::Dependency; verbose::Bool = false)
    s = result -> satisfied(result; verbose=verbose)
    return all(s(result) for result in dep.results)
end

"""
build(dep::Dependency; verbose::Bool = false, force::Bool = false,
                       ignore_audit_errors::Bool = true)

Build the dependency for given `platform` (defaulting to the host platform)
unless it is already satisfied.  If `force` is set to `true`, then the
dependency is always built.  Runs an audit of the built files, printing out
warnings if hints of unrelocatability are found.  These warnings are, by
default, ignored, unless `ignore_audit_errors` is set to `false`.
"""
function build(dep::Dependency; verbose::Bool = false, force::Bool = false,
               ignore_audit_errors::Bool = true)
    # First, look to see whether this dependency is satisfied or not
    should_build = !satisfied(dep)

    # If it is not satisfied, (or we're forcing the issue) build it
    if force || should_build
        # Verbose mode tells us what's going on
        if verbose
            if !should_build
                info("Force-building $(dep.name) despite its satisfaction")
            else
                info("Building $(dep.name) as it is unsatisfied")
            end
        end

        # Construct the runner object that we'll use to actually run the commands
        runner = DockerRunner(prefix=dep.prefix, platform=dep.platform)

        # Run the build recipe one step at a time
        for step in dep.steps
            if verbose
                info("[BuildStep $(step.name)]")
                info("  $(step.cmd)")
            end

            did_succeed = run(runner, step.cmd, logpath(step); verbose=verbose)
            # If we were not successful, fess up
            if !did_succeed
                msg = "Build step $(step.name) did not complete successfully\n"
                error(msg)
            end
        end

        # Run an audit of the prefix to ensure it is properly relocatable
        if !audit(dep.prefix; platform=dep.platform, verbose=verbose) && !ignore_audit_errors
            msg  = "Audit failed for $(dep.prefix.path). "
            msg *= "Address the errors above to ensure relocatability. "
            msg *= "To override this check, set `ignore_audit_errors = true`."
            error(msg)
        end
    elseif !should_build && verbose
        info("Not building as $(dep.name) is already satisfied")
    end
    return true
end