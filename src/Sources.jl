export ArchiveSource, FileSource, GitSource, DirectorySource

"""
An `AbstractSource` is something used as source to build the package.  Sources
are installed to `\${WORKSPACE}/srcdir` in the build environment.

Concrete subtypes of `AbstractSource` are:

* [`ArchiveSource`](@ref): a remote archive to download from the Internet;
* [`FileSource`](@ref): a remote file to download from the Internet;
* [`GitSource`](@ref): a remote Git repository to clone;
* [`DirectorySource`](@ref): a local directory to mount.
"""
abstract type AbstractSource end

"""
    ArchiveSource(url::String, hash::String; unpack_target::String = "")

Specify a remote archive in one of the supported archive formats (e.g., TAR or
ZIP balls) to be downloaded from the Internet from `url`.  `hash` is the
64-character SHA256 checksum of the file.

In the builder environment, the archive will be automatically unpacked to
`\${WORKSPACE}/srcdir`, or in its subdirectory pointed to by the optional
keyword `unpack_target`, if provided.
"""
struct ArchiveSource <: AbstractSource
    url::String
    hash::String
    unpack_target::String
end
ArchiveSource(url::String, hash::String; unpack_target::String = "") =
    ArchiveSource(url, hash, unpack_target)

# List of optionally compressed TAR archives that we know how to deal with
const tar_extensions = [".tar", ".tar.gz", ".tgz", ".tar.bz", ".tar.bz2",
                        ".tar.xz", ".tar.Z", ".txz"]
# List of general archives that we know about
const archive_extensions = vcat(tar_extensions, ".zip")

"""
    FileSource(url::String, hash::String; filename::String = basename(url))

Specify a remote file to be downloaded from the Internet from `url`.  `hash` is
the 64-character SHA256 checksum of the file.

In the builder environment, the file will be saved under `\${WORKSPACE}/srcdir`
with the same name as the basename of the originating URL, unless the the
keyword argument `filename` is specified.
"""
struct FileSource <: AbstractSource
    url::String
    hash::String
    filename::String
end
FileSource(url::String, hash::String; filename::String = basename(url)) =
    FileSource(url, hash, filename)

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
    DirectorySource(path::String; target::String = basename(path))

Specify a local directory to mount from `path`.

The content of the directory will be mounted in `\${WORKSPACE}/srcdir`, or in its
subdirectory pointed to by the optional keyword `target`, if provided.
"""
struct DirectorySource <: AbstractSource
    path::String
    target::String
end
DirectorySource(path::String; target::String = "") =
    DirectorySource(path, target)

# This is not meant to be used as source in the `build_tarballs.jl` scripts but
# only to set up the source in the workspace.
struct SetupSource{T<:AbstractSource}
    path::String
    hash::String
    target::String
end
# This is used in wizard/obtain_source.jl to automatically guess the parameter
# of SetupSource from the URL
function SetupSource(url::String, path::String, hash::String, target::String)
    if endswith(url, ".git")
        return SetupSource{GitSource}(path, hash, target)
    elseif any(endswith(url, ext) for ext in archive_extensions)
        return SetupSource{ArchiveSource}(path, hash, target)
    else
        return SetupSource{FileSource}(path, hash, target)
    end
end

struct PatchSource
    name::String
    patch::String
end

function download_source(source::T; verbose::Bool = false) where {T<:Union{ArchiveSource,FileSource}}
    gettarget(s::ArchiveSource) = s.unpack_target
    gettarget(s::FileSource) = s.filename
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
    return SetupSource{T}(src_path, source.hash, gettarget(source))
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
    return SetupSource{GitSource}(src_path, source.hash, source.unpack_target)
end

function download_source(source::DirectorySource; verbose::Bool = false)
    if !isdir(source.path)
        error("Could not find directory \"$(source.path)\".")
    end
    return SetupSource{DirectorySource}(abspath(source.path), "", source.target)
end

"""
    download_source(source::AbstractSource; verbose::Bool = false)

Download the given `source`.  All downloads are cached within the
BinaryBuilder `downloads` storage directory.
"""
download_source

# Add JSON serialization to sources
JSON.lower(fs::ArchiveSource) = Dict("type" => "archive", extract_fields(fs)...)
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
    elseif d["type"] == "archive"
        return ArchiveSource(d["url"], d["hash"])
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
    elseif any(endswith(src_url, ext) for ext in archive_extensions)
        @warn "Using a pair as source is deprecated, use ArchiveSource instead"
        return ArchiveSource(src_url, src_hash)
    else
        @warn "Using a pair as source is deprecated, use FileSource instead"
        return FileSource(src_url, src_hash)
    end
end
