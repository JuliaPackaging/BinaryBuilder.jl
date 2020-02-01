export FileSource, GitSource, DirectorySource

"""
An `AbstractSource` is something used as source to build the package.  Sources
are installed to `\${WORKSPACE}/srcdir` in the build environment.

Concrete subtypes of `AbstractSource` are:

* [`FileSource`](@ref): a remote file to download from the Internet;
* [`GitSource`](@ref): a remote Git repository to clone;
* [`DirectorySource`](@ref): a local directory to mount.
"""
abstract type AbstractSource end

"""
    FileSource(url::String, hash::String; unpack_target::String = "")

Specify a remote file to be downloaded from the Internet from `url`.  `hash` is
the 64-character SHA256 checksum of the file.

If the file is an archive in one of the supported archive formats (e.g., TAR or
ZIP balls), it will be automatically unpacked to `\${WORKSPACE}/srcdir`, or in
its subdirectory pointed to by the optional keyword `unpack_target`, if
provided.
"""
struct FileSource <: AbstractSource
    url::String
    hash::String
    unpack_target::String
end
FileSource(url::String, hash::String; unpack_target::String = "") =
    FileSource(url, hash, unpack_target)

"""
    GitSource(url::String, hash::String; unpack_target::String = "")

Specify a remote Git repository to clone form `url`.  `hash` is the 40-character
SHA1 revision to checkout after cloning.

The repository will be cloned in `\${WORKSPACE}/srcdir`, or in its subdirectory
pointed to by the optional keyword `unpack_target`, if provided.
"""
struct GitSource <: AbstractSource
    url::String
    hash::String
    unpack_target::String
end
GitSource(url::String, hash::String; unpack_target::String = "") =
    GitSource(url, hash, unpack_target)

"""
    DirectorySource(path::String; unpack_target::String = "")

Specify a local directory to mount from `path`.

The content of the directory will be mounted in `\${WORKSPACE}/srcdir`, or in its
subdirectory pointed to by the optional keyword `unpack_target`, if provided.
"""
struct DirectorySource <: AbstractSource
    path::String
    unpack_target::String
end
DirectorySource(path::String; unpack_target::String = "") =
    DirectorySource(path, unpack_target)

# This is not meant to be used as source in the `build_tarballs.jl` scripts but
# only to set up the source in the workspace.
struct SetupSource
    path::String
    hash::String
    unpack_target::String
end
SetupSource(path::String, hash::String; unpack_target::String = "") =
    SetupSource(path, hash, unpack_target)

function download_source(source::FileSource; verbose::Bool = false)
    if isfile(source.url)
        # Immediately abspath() a src_url so we don't lose track of
        # sources given to us with a relative path
        src_path = abspath(source.url)

        # And if this is a locally-sourced tarball, just verify
        verify(src_path, source.hash; verbose=verbose)
    else
        # Otherwise, download and verify
        src_path = storage_dir("downloads", string(source.hash, "-", basename(source.url)))
        download_verify(source.url, source.hash, src_path; verbose=verbose)
    end
    return SetupSource(src_path, source.hash, source.unpack_target)
end

function download_source(source::GitSource; verbose::Bool = false)
    src_path = storage_dir("downloads", basename(source.url))

    # If this git repository already exists, ensure that its origin remote actually matches
    if isdir(src_path)
        origin_url = LibGit2.with(LibGit2.GitRepo(src_path)) do repo
            LibGit2.url(LibGit2.get(LibGit2.GitRemote, repo, "origin"))
        end

        # If the origin url doesn't match, wipe out this git repo.  We'd rather have a
        # thrashed cache than an incorrect cache.
        if origin_url != source.url
            rm(src_path; recursive=true, force=true)
        end
    end

    if isdir(src_path)
        # If we didn't just mercilessly obliterate the cached git repo, use it!
        LibGit2.with(LibGit2.GitRepo(src_path)) do repo
            LibGit2.fetch(repo)
        end
    else
        # If there is no src_path yet, clone it down.
        repo = LibGit2.clone(source.url, src_path; isbare=true)
    end
    return SetupSource(src_path, source.hash, source.unpack_target)
end

function download_source(source::DirectorySource; verbose::Bool = false)
    if !isdir(source.path)
        error("Could not find directory \"$(source.path)\".")
    end

    # Package up this directory and calculate its hash
    tarball_pathv = ""
    tarball_hash  = ""
    mktempdir() do tempdir
        tarball_path = joinpath(tempdir, basename(source.path) * ".tar.gz")
        package(source.path, tarball_path)
        tarball_hash = open(tarball_path, "r") do f
            bytes2hex(sha256(f))
        end

        # Move it to a filename that has the hash as a part of it (to avoid name collisions)
        tarball_pathv = storage_dir("downloads", string(tarball_hash, "-", basename(source.path), ".tar.gz"))
        mv(tarball_path, tarball_pathv; force=true)
    end
    return SetupSource(tarball_pathv, tarball_hash, source.unpack_target)
end

"""
    download_source(source::AbstractSource; verbose::Bool = false)

Download the given `source`.  All downloads are cached within the
BinaryBuilder `downloads` storage directory.
"""
download_source

# Add JSON serialization to sources
JSON.lower(fs::FileSource) = Dict("type" => "file", extract_fields(fs)...)
JSON.lower(gs::GitSource) = Dict("type" => "git", extract_fields(gs)...)
JSON.lower(ds::DirectorySource) = Dict("type" => "directory", extract_fields(ds)...)

# When deserialiasing the JSON file, the sources are in the form of
# dictionaries.  This function converts the dictionary back to the appropriate
# AbstractSource.
function sourcify(d::Dict)
    if d["type"] == "directory"
        return DirectorySource(d["path"])
    elseif d["type"] == "git"
        return GitSource(d["url"], d["hash"])
    elseif d["type"] == "file"
        return FileSource(d["url"], d["hash"])
    else
        error("Cannot convert to source")
    end
end

# XXX: compatibility functions.  These are needed until we support old-style
# Pair/String sources specifications.
coerce_source(source::AbstractSource) = source
function coerce_source(source::AbstractString)
    @warn "Using a string as source is deprecated, use DirectorySource instead"
    return DirectorySource(source)
end
function coerce_source(source::Pair)
    src_url, src_hash = source
    if endswith(src_url, ".git")
        @warn "Using a pair as source is deprecated, use GitSource instead"
        return GitSource(src_url, src_hash)
    else
        @warn "Using a pair as source is deprecated, use FileSource instead"
        return FileSource(src_url, src_hash)
    end
end
