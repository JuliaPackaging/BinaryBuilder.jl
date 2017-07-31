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
    name::AbstractString

    # The resultant objects that must be present by this recipe BuildResults
    # have different rules that are automatically applied when verifying that
    # this dependency is satisfied
    results::Vector{BuildResult}

    # The build steps in order to build this dependency.
    steps::Vector{BuildStep}

    # The parent "prefix" this dependency must be installed within
    prefix::Prefix

    # Dependencies (e.g. ["gdk-pixbuf", "pango"], etc...)
    dependencies::Vector{Dependency}

    # The platform this dependency gets built for
    platform::Symbol
end

"""
`Dependency(prefix, name, dependencies, cmds, results)`

Defines a new dependency that can be 
"""
function Dependency{R <: BuildResult}(name::AbstractString,
                    results::Vector{R},
                    cmds::Vector{Cmd},
                    platform::Symbol,
                    prefix::Prefix = global_prefix,
                    dependencies::Vector{Dependency} = Dependency[])
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
    return Dependency(name, results, steps, prefix, dependencies, platform)
end


"""
`satisfied(dep::Dependency)`

Return true if all results are satisfied for this dependency.
"""
function satisfied(dep::Dependency; verbose::Bool = false)
    return all(satisfied(result; verbose=verbose) for result in dep.results)
end

"""
`build(dep::Dependency; verbose::Bool = false, force::Bool = false)`

Build the dependency unless it is already satisfied.  If `force` is set to
`true`, then the dependency is always built.
"""
function build(dep::Dependency; verbose::Bool = false, force::Bool = false)
    # First things first, build all dependencies
    for d in dep.dependencies
        build(d; verbose = verbose, force = force)
    end

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
        runner = DockerRunner(dep.prefix, dep.platform)

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
    elseif !should_build && verbose
        info("Not building as $(dep.name) is already satisfied")
    end
    return true
end