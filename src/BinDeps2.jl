# You know it's getting real when this is uncommented
# __precompile__()

module BinDeps2
using Compat
using BinaryProvider

# Re-export important stuff from BinaryProvider so that we don't have to
# explicitly `using BinaryProvider` in every script that uses BinDeps2
export Prefix, bindir, libdir, logdir, activate, deactivate,
       extract_platform_key, install, uninstall, manifest_for_file,
       list_tarball_files, verify, temp_prefix, package,
       Product, LibraryResult, FileResult, satisfied,
       supported_platforms, platform_triplet, platform_key,
       gen_download_cmd, gen_unpack_cmd, gen_package_cmd, gen_list_tarball_cmd,
       parse_tarball_listing, gen_bash_cmd, parse_7z_list, parse_tar_list,
       download_verify_unpack, OutputCollector, merge, stdout, stderr, tail,
       tee


include("Auditor.jl")
include("DockerRunner.jl")
include("Dependency.jl")

function __init__()
    # Nothing to see here folks
end

end # module