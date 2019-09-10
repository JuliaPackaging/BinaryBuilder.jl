# Utilities to rewrite UIDs in .squashfs files.

"""
    getuid()

Wrapper around libc's `getuid()` function
"""
function getuid()
    return ccall(:getuid, Cint, ())
end

"""
    getgid()

Wrapper around libc's `getgid()` function
"""
function getgid()
    return ccall(:getgid, Cint, ())
end


# Note: produce these values by #including squashfs_fs.h from linux in Cxx.jl
# and running the indicated command
const offsetof_id_table_start = 0x30    # offsetof(struct suqashfs_super_block, id_table_start)
const offsetof_no_ids = 0x1a            # offsetof(struct suqashfs_super_block, no_ids)

# From squashfs_fs.h
const SQUASHFS_COMPRESSED_BIT = UInt16(1) << 15
const SQUASHFS_MAGIC = 0x73717368

"""
    generate_per_uid_squashfs(cs, new_uid = getuid())

In order for the sandbox to work well, we need to have the uids of the squashfs
images match the uid of the current unpriviledged user.  Unfortunately there is
no mount-time option to do this for us.  Fortunately, squashfs is simple enough
that if the ID table is uncompressed, we can just manually patch the uids to be
what we need.  This function performs this operation, by rewriting all UIDs and
GIDs to the given `new_uid` (which defaults to the current user's UID)..
"""
function generate_per_uid_squashfs(cs, new_uid = getuid(); verbose::Bool = false)
    # Because the source .squashfs file comes as an immutable artifact, we will create
    # a new artifact that is based off of the progenitor .squashfs artifact, but with
    # rewritten UIDs.  We do this by maintaining a separate `MutableArtifacts.toml`
    # file that is explicitly `.gitignore`'d.
    artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
    name = artifact_name(cs)
    progenitor_hash = artifact_hash(name, artifacts_toml; platform=cs.host)
    if progenitor_hash == nothing
        error("Compiler shard $(name) not found in $(artifacts_toml)")
    end

    # We now generate a name that will be bound within the current artifacts_toml file
    # This name encodes not only which artifact we're using, but also the source hash
    # and the desired UID.  This allows us to intelligently cache output from a name
    # that is tied to a specific version of the input, and all build options.
    mutable_artifacts_toml = joinpath(dirname(@__DIR__), "MutableArtifacts.toml")
    cache_name = "$(name)_$(bytes2hex(progenitor_hash.bytes[end-8:end]))_$(new_uid)"
    cache_hash = artifact_hash(cache_name, mutable_artifacts_toml)

    # If this name isn't bound to anything, then create it by remapping the UIDs
    if cache_hash === nothing
        # Grab the progenitor path, downloading it if necessary
        progenitor_path = joinpath(artifact_path(progenitor_hash), name)

        if !isfile(progenitor_path)
            error("Compiler shard $(name) missing from disk at $(progenitor_path)")
        end

        # Create a new artifact that has the modified `.squashfs` file within it
        cache_hash = create_artifact() do dir
            # Copy .squashfs file over to our local directory, make it writable
            cp(progenitor_path, joinpath(dir, name))
            chmod(joinpath(dir, name), 0o644)

            squash_path = joinpath(dir, name)
            open(squash_path, "r+") do file
               # Check magic
               if read(file, UInt32) != SQUASHFS_MAGIC
                   error("`$squash_path` is not a squashfs file")
               end
               # Check that the image contains only one id (which we will rewrite)
               seek(file, offsetof_no_ids)
               if read(file, UInt16) != 1
                   error("`$squash_path` uses more than one uid/gid")
               end
               # Find the index table
               seek(file, offsetof_id_table_start)
               offset = read(file, UInt64)
               seek(file, offset)
               # Find the correct metdata block
               index = read(file, UInt64)
               seek(file, index)
               # Read the metadata block
               size = read(file, UInt16)
               # Make sure it's uncompressed (yes, I know that flag is terribly
               # named - it indicates that the data is uncompressed)
               if ((size & SQUASHFS_COMPRESSED_BIT) == 0)
                   error("Metadata block is compressed")
               end
               p = position(file)
               uid = read(file, UInt32)
               if uid == new_uid
                   return
               end
               if verbose
                   @info("Rewriting $(basename(squash_path)) from UID $(uid) -> $(new_uid)")
               end
               seek(file, p)
               write(file, UInt32(new_uid))
            end
        end

        # Then, bind the encoded name to this hash within the MutableArtifacts.toml mapping
        bind_artifact!(mutable_artifacts_toml, cache_name, cache_hash; force=true)
    end

    # Finally, get the path to that cached artifact
    return joinpath(artifact_path(cache_hash), name)
end

