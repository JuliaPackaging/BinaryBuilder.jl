using REPL
using REPL.Terminals
using REPL.TerminalMenus
using ObjectFile.ELF
using HTTP
import PkgLicenses
using JSON
using MbedTLS
using JLD2

# It's Magic!
export run_wizard

include("wizard/state.jl")
include("wizard/utils.jl")
include("wizard/obtain_source.jl")
include("wizard/interactive_build.jl")
include("wizard/deploy.jl")

# This is here so that if the wizard crashes, we may have a shot at resuming.
wizard_cache_path = joinpath(dirname(dirname(pathof(@__MODULE__))), "deps", "wizard.state")
function save_last_wizard_state(state::WizardState)
    global wizard_cache_path
    jldopen(wizard_cache_path, "w") do f
        serialize(f, state)
    end

    return state
end

function load_last_wizard_state()
    global wizard_cache_path
    try
        state = jldopen(wizard_cache_path, "r") do f
            return unserialize(f)
        end

        if !(state.step in (:done, :step1))
            # Looks like we had an incomplete build; ask the user if they want to continue it
            terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
            choice = request(terminal,
                "Would you like to resume the previous incomplete wizard run?",
                RadioMenu([
                    "Resume previous run",
                    "Start from scratch",
                ]),
            )

            if choice == 1
                return state
            else
                return WizardState()
            end
        end
    catch
    end
    # Either something went wrong, or there was nothing interesting stored.
    # Either way, just return a blank slate.
    return WizardState()
end

function run_wizard(state::Union{Nothing,WizardState} = nothing)
    global last_wizard_state

    if state === nothing
        # If we weren't given a state, check to see if we'd like to resume a
        # previous run or start from scratch again.
        state = load_last_wizard_state()
    end

    if state.step == :step1
        print_wizard_logo(state.outs)

        println(state.outs,
            "Welcome to the BinaryBuilder wizard.\n"*
            "We'll get you set up in no time.\n")
    end

    try
        while state.step != :done
            if state.step == :step1
                step1(state)
                state.step = :step2
            elseif state.step == :step2
                step2(state)
                state.step = :step3
            elseif state.step == :step3
                step34(state)
            elseif state.step == :step3_retry
                step3_retry(state)
            elseif state.step == :step5a
                step5a(state)
            elseif state.step == :step5b
                step5b(state)
            elseif state.step == :step5c
                step5c(state)
                state.step = :step6
            elseif state.step == :step6
                step6(state)
            elseif state.step == :step7
                step7(state)
                state.step = :done
            end

            # Save it every step along the way
            save_last_wizard_state(state)
        end
    catch err
        # If anything goes wrong, immediately save the current wizard state
        save_last_wizard_state(state)
        if isa(err, InterruptException)
            msg = "\n\nWizard stopped, use run_wizard() to resume.\n\n"
            printstyled(state.outs, msg, bold=true, color=:red)
        else
            bt = catch_backtrace()
            Base.showerror(stderr, err, bt)
            println(state.outs, "\n")
        end
        return state
    end

    # We did it!
    save_last_wizard_state(state)

    println(state.outs, "\nWizard Complete. Press any key to exit...")
    read(state.ins, Char)

    state
end
