immutable BuildStep
    name::String
    cmd::Cmd
    prefix::Prefix
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
    
    oc = OutputCollector(step.cmd; verbose=verbose)
    
    did_succeed = false
    try
        # Wait for the command to finish
        did_succeed = wait(oc)
    finally
        # Make the path, if we need to
        mkpath(dirname(logpath(step)))

        # Write out the logfile
        open(logpath(step), "w") do f
            # First write out the actual command
            println(f, step.cmd)

            # Then write out the actual output
            print(f, merge(oc))
        end
    end

    # Remember, the `oc` will automagically spit out any failing output.
    if !did_succeed
        msg = "Build step $(step.name) did not complete successfully\n"
        print_color(:red, msg; bold=true)
        error()
    end

    return did_succeed
end