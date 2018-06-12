import Base: show

abstract type AbstractDependency; end
struct InlineBuildDependency <: AbstractDependency
    script::String
end
struct RemoteBuildDependency <: AbstractDependency
    url::String
    script::Union{String, Nothing}
end

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
    global_git_cfg::LibGit2.GitConfig
    # Filled in by step 1
    platforms::Union{Nothing, Vector{P}} where {P <: Platform}
    # Filled in by step 2
    workspace::Union{Nothing, String}
    source_urls::Union{Nothing, Vector{String}}
    source_files::Union{Nothing, Vector{String}}
    source_hashes::Union{Nothing, Vector{String}}
    dependencies::Vector{AbstractDependency}
    # Filled in by step 3
    history::Union{Nothing, String}
    dependency_files::Union{Nothing, Set{String}}
    files::Union{Nothing, Vector{String}}
    file_kinds::Union{Nothing, Vector{Symbol}}
    file_varnames::Union{Nothing, Vector{Symbol}}
    # Filled in by step 5c
    failed_platforms::Set{Any}
    # Used to keep track of which platforms we already visited
    visited_platforms::Set{Any}
    # Used to keep track of which platforms we have shown to work
    # with the current script. This gets reset if the script is edited.
    validated_platforms::Set{Any}
    # Filled in by step 7
    name::Union{Nothing, String}
    github_api::GitHub.GitHubAPI
    travis_endpoint::String
end

const DEFAULT_TRAVIS_ENDPOINT = "https://api.travis-ci.org/"
function WizardState()
    WizardState(
        :step1,
        stdin,
        stdout,
        LibGit2.GitConfig(),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        Vector{AbstractDependency}(),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        Set{Any}(),
        Set{Any}(),
        Set{Any}(),
        nothing,
        GitHub.DEFAULT_API,
        DEFAULT_TRAVIS_ENDPOINT
    )
end

function show(io::IO, x::WizardState)
    print(io, "WizardState [$(x.step)]")
end
