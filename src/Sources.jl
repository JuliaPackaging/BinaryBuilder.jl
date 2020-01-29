export FileSource, GitSource, DirectorySource

abstract type AbstractSource end

struct FileSource <: AbstractSource
    url::String
    hash::String
end

struct GitSource <: AbstractSource
    url::String
    hash::String
end

struct DirectorySource <: AbstractSource
    path::String
end

function download_source(source::FileSource; verbose::Bool = false)
    if isfile(source.url)
        # Immediately abspath() a src_url so we don't lose track of
        # sources given to us with a relative path
        src_path = abspath(source.url)

        # And if this is a locally-sourced tarball, just verify
        verify(src_path, source.hash; verbose=verbose)
    else
        # Otherwise, download and verify
        src_path = storage_dir("downloads", string(src_hash, "-", basename(source.url)))
        download_verify(source.url, source.hash, src_path; verbose=verbose)
    end
    return src_path => source.hash
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
    return src_path => source.hash
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
    return tarball_pathv => tarball_hash
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
coerce_source(source::AbstractString) = DirectorySource(source)
function coerce_source(source::Pair)
    src_url, src_hash = source
    if endswith(src_url, ".git")
        return GitSource(src_url, src_hash)
    else
        return FileSource(src_url, src_hash)
    end
end
