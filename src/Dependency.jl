# A dependency is something that must be satisfied before a
# package can be run.  These dependencies can be Libraries,
# basic files, etc...
immutable Dependency
    # The "name" of this dependency (e.g. "cairo")
    name::AbstractString

    # The resultant objects that must be present by this recipe
    # BuildResults have different rules that are automatically
    # applied when verifying that this dependency is satisfied
    results::Vector{BuildResult}

    # The build steps in order to build this dependency
    steps::Vector{BuildStep}

    # The parent "prefix" this dependency must be installed within
    prefix::Prefix

    # Dependencies (e.g. ["gdk-pixbuf", "pango"], etc...)
    dependencies::Vector{Dependency}
end

"""
`Dependency(prefix, name, dependencies, cmds, results)`

Defines a new dependency that can be 
"""
function Dependency{R <: BuildResult}(name::AbstractString,
                    results::Vector{R},
                    cmds::Vector{Cmd},
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
    return Dependency(name, results, steps, prefix, dependencies)
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

        # Apply the build environment (set `prefix`, `CC`, etc...)
        withenv(default_env(dep.prefix)...) do
            for step in dep.steps
                build(step; verbose=verbose)
            end
        end
    elseif !should_build && verbose
        info("Not building as $(dep.name) is already satisfied")
    end
    return true
end


"""
`default_env(prefix::Prefix)`

Returns an array of pairs of default environment variables to be used as a set
of sane defaults including `prefix`, `bindir`, `libdir`, etc...

TODO: We need to provide cross-compiler configuration here.
"""
function default_env(prefix::Prefix)
    const def_vars = [
        "prefix" => prefix.path,
        "bindir" => bindir(prefix),
        "libdir" => libdir(prefix),
    ]

    return def_vars
end