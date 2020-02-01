import Base: show

abstract type AbstractWizardDependency; end
struct InlineBuildDependency <: AbstractWizardDependency
    script::String
end
struct RemoteBuildDependency <: AbstractWizardDependency
    url::String
    script::Union{String, Nothing}
end
struct TarballDependency <: AbstractWizardDependency
    url::String
    hash::String
end

"""
    WizardState

Building large dependencies can take a lot of time. This state object captures
all relevant state of this function. It can be passed back to the function to
resume where we left off. This can aid debugging when code changes are
necessary.  It also holds all necessary metadata such as input/output streams.
"""
@Base.kwdef mutable struct WizardState
    step::Symbol = :step1
    ins::IO = stdin
    outs::IO = stdout

    # Filled in by step 1
    platforms::Union{Nothing, Vector{Platform}} = nothing
    
    # Filled in by step 2
    workspace::Union{Nothing, String} = nothing
    source_urls::Union{Nothing, Vector{String}} = nothing
    source_files::Union{Nothing, Vector{SetupSource}} = nothing
    dependencies::Union{Nothing, Vector{Dependency{PkgSpec}}} = nothing
    compilers::Union{Nothing, Vector{Symbol}} = nothing
    preferred_gcc_version::Union{Nothing, VersionNumber} = nothing
    preferred_llvm_version::Union{Nothing, VersionNumber} = nothing

    # Filled in by step 3
    history::Union{Nothing, String} = nothing
    files::Union{Nothing, Vector{String}} = nothing
    file_kinds::Union{Nothing, Vector{Symbol}} = nothing
    file_varnames::Union{Nothing, Vector{Symbol}} = nothing

    # Filled in by step 5c
    failed_platforms::Set{Platform} = Set{Platform}()
    # Used to keep track of which platforms we already visited
    visited_platforms::Set{Platform} = Set{Platform}()
    # Used to keep track of which platforms we have shown to work
    # with the current script. This gets reset if the script is edited.
    validated_platforms::Set{Platform} = Set{Platform}()

    # Filled in by step 7
    name::Union{Nothing, String} = nothing
    version::Union{Nothing, VersionNumber} = nothing
    github_api::GitHub.GitHubAPI = GitHub.DEFAULT_API
    travis_endpoint::String = "https://api.travis-ci.org/"
end

function serializeable_fields(::WizardState)
    # We can't serialize TTY's, in general.
    bad_fields = [:ins, :outs, :github_api]
    return [f for f in fieldnames(WizardState) if !(f in bad_fields)]
end

# Serialize a WizardState out into a JLD2 dictionary-like object
function serialize(io, x::WizardState)
    for field in serializeable_fields(x)
        io[string(field)] = getproperty(x, field)
    end

    # For unnecessarily complicated fields (such as `x.github_api`) store the internal data raw:
    io["github_api"] = string(x.github_api.endpoint)

    # For non-serializable fields (such as `x.ins` and `x.outs`) we just recreate them in unserialize().
end

function unserialize(io)
    x = WizardState()

    for field in serializeable_fields(x)
        setproperty!(x, field, io[string(field)])
    end

    # Manually recreate `ins` and `outs`.  Note that this just sets them to their default values
    x.ins = stdin
    x.outs = stdout
    x.github_api = GitHub.GitHubWebAPI(HTTP.URI(io["github_api"]))

    return x
end

function show(io::IO, x::WizardState)
    print(io, "WizardState [$(x.step)]")
end
