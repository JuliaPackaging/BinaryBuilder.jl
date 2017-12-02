import Base: show

"""
    WizardState

Building large dependencies can take a lot of time. This state object captures
all relevant state of this function. It can be passed back to the function to
resume where we left off. This can aid debugging when code changes are
necessary.  It also holds all necessary metadata such as input/output streams.
"""
mutable struct WizardState
    step::Symbol
    ins::IO
    outs::IO
    # Filled in by step 1
    platforms::Union{Void, Vector{P}} where {P <: Platform}
    # Filled in by step 2
    workspace::Union{Void, String}
    source_urls::Union{Void, Vector{String}}
    source_files::Union{Void, Vector{String}}
    source_hashes::Union{Void, Vector{String}}
    # Filled in by step 3
    history::Union{Void, String}
    files::Union{Void, Vector{String}}
    file_kinds::Union{Void, Vector{Symbol}}
    # Filled in by step 5c
    failed_platforms::Set{Any}
    # Used to keep track of which platforms we already visited
    visited_platforms::Set{Any}
    # Used to keep track of which platforms we have shown to work
    # with the current script. This gets reset if the script is edited.
    validated_platforms::Set{Any}
    # Filled in by step 7
    name::Union{Void, String}
end

function WizardState()
    WizardState(
        :step1,
        STDIN,
        STDOUT,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        Set{Any}(),
        Set{Any}(),
        Set{Any}(),
        nothing
    )
end

function show(io::IO, x::WizardState)
    print(io, "WizardState [$(x.step)]")
end
