module BinaryBuilder
using Libdl, LibGit2, Random, JSON
using BinaryBuilderBase
using ObjectFile
using GitHub
using Pkg, Base.BinaryPlatforms, Pkg.Artifacts
using ghr_jll

# Re-export useful stuff from Base.BinaryPlatforms:
export HostPlatform, platform_dlext, valid_dl_path, arch, libc, nbits,
       libgfortran_version, libstdcxx_version, cxxstring_abi, detect_libgfortran_version,
       detect_libstdcxx_version, detect_cxxstring_abi, call_abi, wordsize, triplet,
       select_platform, platforms_match, AbstractPlatform, Platform, os
# BinaryBuilderBase/src/Prefix.jl
export Prefix, bindir, libdirs, includedir, logdir, activate, deactivate,
       isinstalled, install, uninstall, list_tarball_files, verify, temp_prefix
# BinaryBuilderBase/src/Rootfs.jl
export supported_platforms, expand_gfortran_versions, expand_cxxstring_abis, expand_microarchitectures
# BinaryBuilderBase/src/Platforms.jl
export AnyPlatform
# BinaryBuilderBase/src/Products.jl
export Product, LibraryProduct, FileProduct, ExecutableProduct, FrameworkProduct, satisfied,
       locate, write_deps_file, variable_name
# BinaryBuilderBase/src/Dependency.jl
export Dependency, RuntimeDependency, BuildDependency, HostBuildDependency
# BinaryBuilderBase/src/Sources.jl
export ArchiveSource, FileSource, GitSource, DirectorySource
# Auditor.jl
export audit, collect_files, collapse_symlinks

# Autocomplete BinaryBuilder.runshell
const runshell = BinaryBuilderBase.runshell

include("Auditor.jl")
include("Wizard.jl")

using OutputCollectors, BinaryBuilderBase, .Auditor, .Wizard

# Autocomplete BinaryBuilder.run_wizard
const run_wizard = Wizard.run_wizard

include("AutoBuild.jl")
include("Declarative.jl")
include("Logging.jl")

function __init__()
    # If we're running on Azure, enable azure logging:
    if !isempty(get(ENV, "AZP_TOKEN", ""))
        enable_azure_logging()
    elseif parse(Bool, get(ENV, "BUILDKITE", "false"))
        enable_buildkite_logging()
    end
end

get_bb_version() =
    BinaryBuilderBase.get_bbb_version(@__DIR__, "12aac903-9f7c-5d81-afc2-d9565ea332ae")
versioninfo() = BinaryBuilderBase.versioninfo(; name=@__MODULE__, version=get_bb_version())

# Precompilation ahoy!
# include("../deps/SnoopCompile/precompile/precompile_BinaryBuilder.jl")
# _precompile_()

end # module
