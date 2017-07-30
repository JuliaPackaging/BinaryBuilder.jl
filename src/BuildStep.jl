immutable BuildStep
    name::String
    cmd::Cmd
    prefix::Prefix
    dr::DockerRunner
end

function BuildStep(name::String, cmd::Cmd, prefix::Prefix)
    return BuildStep(name, cmd, prefix, DockerRunner(prefix))
end


function logpath(step::BuildStep)
    return joinpath(logdir(step.prefix), "$(step.name).log")
end

"""
`build(step::BuildStep; verbose::Bool = false)`

Run the build step, storing output into the build prefix's `logs` directory and
optionally printing the result if `verbose` is set to `true`.
"""
function build(step::BuildStep; verbose::Bool = false)
    if verbose
        info("[BuildStep $(step.name)]")
        info("  $(step.cmd)")
    end

    # Run the buildstep with whatever runner we're using
    return run(step.dr, step.cmd, logpath(step); verbose=verbose)
end