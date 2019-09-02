## This file contains functionality related to the actual layout of the files
#  on disk.  Things like the name of where downloads are stored, and what
#  environment variables must be updated to, etc...
import Base: convert, joinpath, show, withenv
using SHA

export Prefix, bindir, libdir, includedir, logdir, activate, deactivate,
       extract_name_version_platform_key, extract_platform_key, isinstalled,
       install, uninstall, list_tarball_files, verify, temp_prefix
import Pkg.PlatformEngines: package

# Temporary hack around https://github.com/JuliaLang/julia/issues/26685
function safe_isfile(path)
    try
        return isfile(path)
    catch e
        if typeof(e) <: Base.IOError && e.code == Base.UV_EINVAL
            return false
        end
        rethrow(e)
    end
end

"""
    temp_prefix(func::Function)

Create a temporary prefix, passing the prefix into the user-defined function so
that build/packaging operations can occur within the temporary prefix, which is
then cleaned up after all operations are finished.  If the path provided exists
already, it will be deleted.

Usage example:

    out_path = abspath("./libfoo")
    temp_prefix() do p
        # <insert build steps here>

        # tarball up the built package
        tarball_path, tarball_hash = package(p, out_path)
    end
"""
function temp_prefix(func::Function)
    # Helper function to create a docker-mountable temporary directory
    function _tempdir()
        @static if Sys.isapple()
            # Docker, on OSX at least, can only mount from certain locations by
            # default, so we ensure all our temporary directories live within
            # those locations so that they are accessible by Docker.
            return "/tmp"
        else
            return tempdir()
        end
    end

    mktempdir(_tempdir()) do path
        prefix = Prefix(path)

        # Run the user function
        func(prefix)
    end
end

# This is the default prefix that things get saved to, it is initialized within
# __init__() on first module load.
global_prefix = nothing
struct Prefix
    path::String

    """
        Prefix(path::AbstractString)

    A `Prefix` represents a binary installation location.
    """
    function Prefix(path::AbstractString)
        # Canonicalize immediately, create the overall prefix, then return
        path = abspath(path)
        mkpath(path)
        return new(path)
    end
end

# Make it easy to bandy about prefixes as paths.  There has got to be a better
# way to do this, but it's hackin' time, so just go with the flow.
joinpath(prefix::Prefix, args...) = joinpath(prefix.path, args...)
joinpath(s::AbstractString, prefix::Prefix, args...) = joinpath(s, prefix.path, args...)

convert(::Type{AbstractString}, prefix::Prefix) = prefix.path
show(io::IO, prefix::Prefix) = show(io, "Prefix($(prefix.path))")

"""
    bindir(prefix::Prefix)

Returns the binary directory for the given `prefix`.
"""
function bindir(prefix::Prefix)
    return joinpath(prefix, "bin")
end

"""
    libdirs(prefix::Prefix, platform = platform_key_abi())

Returns the library directories for the given `prefix` (note that this differs
between unix systems and windows systems, and between 32- and 64-bit systems).
"""
function libdirs(prefix::Prefix, platform = platform_key_abi())
    if Sys.iswindows(platform)
        return [joinpath(prefix, "bin")]
    else
        if wordsize(platform) == 64
            return [joinpath(prefix, "lib64"), joinpath(prefix, "lib")]
        else
            return [joinpath(prefix, "lib")]
        end
    end
end

"""
    includedir(prefix::Prefix)

Returns the include directory for the given `prefix`
"""
function includedir(prefix::Prefix)
    return joinpath(prefix, "include")
end

"""
    logdir(prefix::Prefix)

Returns the logs directory for the given `prefix`.
"""
function logdir(prefix::Prefix)
    return joinpath(prefix, "logs")
end

"""
    extract_platform_key(path::AbstractString)

Given the path to a tarball, return the platform key of that tarball. If none
can be found, prints a warning and return the current platform suffix.
"""
function extract_platform_key(path::AbstractString)
    try
        return extract_name_version_platform_key(path)[3]
    catch
        @warn("Could not extract the platform key of $(path); continuing...")
        return platform_key_abi()
    end
end

"""
    extract_name_version_platform_key(path::AbstractString)

Given the path to a tarball, return the name, platform key and version of that
tarball. If any of those things cannot be found, throw an error.
"""
function extract_name_version_platform_key(path::AbstractString)
    m = match(r"^(.*?)\.v(.*?)\.([^\.\-]+-[^\.\-]+-([^\-]+-){0,2}[^\-]+).tar.gz$", basename(path))
    if m === nothing
        error("Could not parse name, platform key and version from $(path)")
    end
    name = m.captures[1]
    version = VersionNumber(m.captures[2])
    platkey = platform_key_abi(m.captures[3])
    return name, version, platkey
end

"""
    git_tree_sha1(prefix::Prefix)

Calculate an equivalent `git-tree-sha1` for a given `Prefix`.
"""
function git_tree_sha1(prefix::Prefix)
    moved_git_dir = nothing
    if isdir(joinpath(prefix, ".git"))
        moved_git_dir = tempdir()
        mv(joinpath(prefix, ".git"), moved_git_dir)
    end

    try
        return cd(prefix.path) do
            success(`git init`)
            success(`git add .`)
            success(`git commit -m "null"`)
            return chomp(String(read(`git log -1 --pretty='%T' HEAD`)))
        end
    finally
        if moved_git_dir != nothing
            mv(moved_git_dir, joinpath(prefix, ".git"))
        else
            rm(joinpath(prefix, ".git"); force=true, recursive=true)
        end
    end
end

"""
    package(prefix::Prefix, output_base::AbstractString,
            version::VersionNumber;
            platform::Platform = platform_key_abi(),
            verbose::Bool = false, force::Bool = false)

Build a tarball of the `prefix`, storing the tarball at `output_base`,
appending a version number, a platform-dependent suffix and a file extension.
If no platform is given, defaults to current platform. Runs an `audit()` on the
`prefix`, to ensure that libraries can be `dlopen()`'ed, that all dependencies
are located within the prefix, etc... See the `audit()` documentation for a
full list of the audit steps.  Returns the full path to and hash of the
generated tarball.
"""
function package(prefix::Prefix,
                 output_base::AbstractString,
                 version::VersionNumber;
                 platform::Platform = platform_key_abi(),
                 verbose::Bool = false,
                 force::Bool = false)
    # Calculate output path
    out_path = "$(output_base).v$(version).$(triplet(platform)).tar.gz"

    if isfile(out_path)
        if force
            if verbose
                @info("$(out_path) already exists, force-overwriting...")
            end
            rm(out_path; force=true)
        else
            msg = replace(strip("""
            $(out_path) already exists, refusing to package into it without
            `force` being set to `true`.
            """), "\n" => " ")
            error(msg)
        end
    end

    # Copy our build prefix into an Artifact
    tree_hash = create_artifact() do art_path
        for f in readdir(prefix.path)
            cp(joinpath(prefix.path, f), joinpath(art_path, f))
        end
    end

    # Calculate git tree hash
    if verbose
        @info("Tree hash of contents of $(basename(out_path)): $(tree_hash)")
    end

    tarball_hash = archive_artifact(tree_hash, out_path; honor_overrides=false)
    if verbose
        @info("SHA256 of $(basename(out_path)): $(tarball_hash)")
    end

    return out_path, tarball_hash, tree_hash
end
