using REPL
using REPL.Terminals
using REPL.TerminalMenus
using ObjectFile.ELF
using HTTP
import PkgLicenses
using JSON
using MbedTLS

# It's Magic!
export run_wizard

include("wizard/state.jl")
include("wizard/utils.jl")
include("wizard/obtain_source.jl")
include("wizard/interactive_build.jl")
include("wizard/deploy.jl")

# This is here so that if the wizard crashes, we may have a shot at resuming.
last_wizard_state = WizardState()

function run_wizard(state::Union{Nothing,WizardState} = nothing)
    global last_wizard_state

    if state === nothing
        # If we weren't given a state, check to see if we'd like to resume a
        # previous run or start from scratch again.
        if last_wizard_state.step != :done && last_wizard_state.step != :step1
            terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
            choice = request(terminal,
                "Would you like to resume the previous incomplete wizard run?",
                RadioMenu([
                    "Resume previous run",
                    "Start from scratch",
                ]),
            )

            if choice == 1
                state = last_wizard_state
            else
                state = WizardState()
            end
        else
            state = WizardState()
        end
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
        end
    catch err
        last_wizard_state = state
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

    println(state.outs, "\nWizard Complete. Press any key to exit...")
    read(state.ins, Char)

    state
end
