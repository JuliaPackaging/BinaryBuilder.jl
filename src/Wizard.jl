using Base.Terminals
using TerminalMenus
using ObjectFile.ELF
using HTTP
import PkgDev
using GitHub
using JSON
using MbedTLS

# It's Magic!
export run_wizard

include("wizard/state.jl")
include("wizard/utils.jl")
include("wizard/obtain_source.jl")
include("wizard/interactive_build.jl")
include("wizard/deploy.jl")

function run_wizard(state::WizardState = WizardState())
    print_wizard_logo(state.outs)

    println(state.outs,
            "Welcome to the BinaryBuilder wizard.\n"*
            "We'll get you set up in no time.\n")

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
        if isa(err, InterruptException)
            msg = "\n\nWizard stopped, use run_wizard(ans) to resume.\n\n"
            print_with_color(:red, state.outs, msg, bold=true)
        else
            bt = catch_backtrace()
            Base.showerror(STDERR, err, bt)
            println(state.outs, "\n")
        end
        return state
    end

    println(state.outs, "\nWizard Complete. Press any key to exit...")
    read(state.ins, Char)

    state
end
