export supported_platforms

"""
    downloads_dir(postfix::String = "")

Builds a path relative to the `downloads_cache`.
"""
function downloads_dir(postfix::String = "")
    global downloads_cache
    return joinpath(downloads_cache, postfix)
end

"""
    rootfs_dir(postfix::String = "")

Builds a path relative to the `rootfs_cache`.
"""
function rootfs_dir(postfix::String = "")
    global rootfs_cache
    return joinpath(rootfs_cache, postfix)
end


"""
    shards_dir(postfix::String = "")

Builds a path relative to the `shards_cache`.
"""
function shards_dir(postfix::String = "")
    global shards_cache
    return joinpath(shards_cache, postfix)
end

shard_path_squashfs(shard_name) = downloads_dir("rootfs-$(shard_name).squashfs")
rootfs_path_squashfs() = shard_path_squashfs("base")
ccache_dir() = shards_dir("ccache")

"""
    get_shard_url(target::String = "base"; squashfs::Bool = use_squashfs)

Returns the URL from which a rootfs image (tarball/squashfs) can be downloaded
"""
function get_shard_url(target::String = "base"; squashfs::Bool = use_squashfs)
    # These constants are what should be updated for a new rootfs build:
    rootfs_urlroot = "https://julialangmirror.s3.amazonaws.com/binarybuilder"
    rootfs_version = "2018-04-18"

    shard_name = "rootfs-$(target)"
    ext = squashfs ? "squashfs" : "tar.gz"

    return "$(rootfs_urlroot)-rootfs-$(target)-$(rootfs_version).$(ext)"
end

"""
    get_shard_url(target::String = "base"; squashfs::Bool = use_squashfs)

Returns the sha256 hash for a rootfs image (tarball/squashfs).
"""
function get_shard_hash(triplet::String = "base"; squashfs::Bool = use_squashfs)
    # These constants are what should be updated for a new rootfs build.
    # You can get these dictionaries spat out by running `make print-hashes`
    # in `julia-docker/crossbuild`, after running `make shards`.  Alternatively,
    # run `make push-rootfs` to do both and upload to S3
    squashfs_hashes = Dict(
        "aarch64-linux-gnu" => "5d74076eee99e7b7999db32a5f8ecd44403645a4929cd5df520cdb03b02087e2",
        "aarch64-linux-musl" => "f55c57eeb877d2c045d32c2fc64e01738b3a4af64bbe39a11984a24b33a9c8d0",
        "arm-linux-gnueabihf" => "b99256205ba5698acbaa368a86d562048247ebd14b2b77e60dac4803970d0b24",
        "arm-linux-musleabihf" => "444fa9986406f33e36841403c5c207f2890dc8ec4f90ad7bd2ca0a83a9876770",
        "base" => "3f2fd58cc3bc5b23c50d8b395ddbd5d4df0e8a62d2c2f52f9323a20cb17553a6",
        "i686-linux-gnu" => "97041a593b2973ac24d0a9a4c677faebc57161b34a77ee2dfd8cd36c60ad2540",
        "i686-linux-musl" => "0230ccf69edf79964a5395219eb787ea55af3eb64f2fc74b25ad58e962fdd483",
        "i686-w64-mingw32" => "1d2b0b0f05c1c67fdeaefe8245e20c8ee24323c2a87e962b6a0ae3efd2b6671b",
        "powerpc64le-linux-gnu" => "697dbed010596cf2ebb2346dba2da56d71167287d7ce30ab98c8a9e3d3c195b9",
        "x86_64-apple-darwin14" => "183be0a9dcfaad28bf980e3ff04eae15fcf9571fea53827e47722e7e77664bfe",
        "x86_64-linux-gnu" => "35f95e2ec777d5b4cfd9dddb43beef12d2be6758a17624ac838d97ea3269f3f5",
        "x86_64-linux-musl" => "0c4ddd014949dc1a3332e03569d4b9fa8989fe5903c095ea580c05c22c8b9210",
        "x86_64-unknown-freebsd11.1" => "c6c4fc0106fe471da95d47e6706bd968160951cd58fe467694bca4eed8971c7a",
        "x86_64-w64-mingw32" => "2a3467d3aaf3780696ff4ca7b36da42f7de8065438f4c202db635eb3929eb4be",
    )
    tarball_hashes = Dict(
        "aarch64-linux-gnu" => "f8611c11b5fbb1453ca64714a625eabc186bee0d3471b87da635e41b22480c10",
        "aarch64-linux-musl" => "a6758c423c1d9c77724d90ec182eed9063becd882b3bdebf849913f4ec37365a",
        "arm-linux-gnueabihf" => "64aabdb6c300294f464a821d847b60d83054a2d89953c5d6a8648b01850f4a80",
        "arm-linux-musleabihf" => "9f2231dc90cb844ad10c17ff3284869744179871db75f776d4a0c933e4076c33",
        "base" => "ad16b4c514bf0b5efd6a3422c233f2b8c9e9a7afe647661c06618a9d963f73e8",
        "i686-linux-gnu" => "11f9b1193e140fd42e9d11aedbcaa6c9066a201771cebc0a55bad2f1a6357fe2",
        "i686-linux-musl" => "a06f2381058b718a56302921fc0a560a47d09f776f0c7caf9a4eee026762044d",
        "i686-w64-mingw32" => "f99c43b80906b1b6a3100d2b685aa3b40932bd299e78ce21ee922cceec31880b",
        "powerpc64le-linux-gnu" => "c9ccf51d18b34854c18a40f079381327016eeb631e5f3e578f5a3f39ba7de51b",
        "x86_64-apple-darwin14" => "077a3ab4465e1e90ae5111efb3a49a1427baa431ed5cecaf74e1449c19e2fae7",
        "x86_64-linux-gnu" => "c661c3b2d04face54ffec210b3abdb742b3dc77c9c5b53bfa75b25979410f45e",
        "x86_64-linux-musl" => "06628287f2bf567105a3ab2fa603796a595739891caeccde1ea2b5c9a2aca605",
        "x86_64-unknown-freebsd11.1" => "461ede7ef47b1d8a03d927c8a4bc780cdcfe2eefe84d3d679c5a1caf6274bfe6",
        "x86_64-w64-mingw32" => "7891c322d378f27741bd618465bce51770b919795c9d1ab739b8372d59b26271",
    )
    if squashfs
        return squashfs_hashes[triplet]
    else
        return tarball_hashes[triplet]
    end
end

"""
    supported_platforms()

Return the list of supported platforms as an array of `Platform`s.  These are the platforms we
officially support building for, if you see a mapping in `get_shard_hash()` that isn't
represented here, it's probably because that platform is still considered "in beta".
"""
function supported_platforms()
    return [
        # glibc Linuces
        Linux(:i686),
        Linux(:x86_64),
        Linux(:aarch64),
        Linux(:armv7l),
        Linux(:powerpc64le),

        # musl Linuces
        Linux(:i686, :musl),
        Linux(:x86_64, :musl),
        Linux(:aarch64, :musl),
        Linux(:armv7l, :musl),

        # BSDs
        MacOS(:x86_64),
        FreeBSD(:x86_64),

        # Windows
        Windows(:i686),
        Windows(:x86_64),
    ]
end

"""
    getuid()

Wrapper around libc's `getuid()` function
"""
function getuid()
    return ccall(:getuid, Cint, ())
end

# Note: produce these values by #including squashfs_fs.h from linux in Cxx.jl
# and running the indicated command
const offsetof_id_table_start = 0x30    # offsetof(struct suqashfs_super_block, id_table_start)
const offsetof_no_ids = 0x1a            # offsetof(struct suqashfs_super_block, no_ids)

# From squashfs_fs.h
const SQUASHFS_COMPRESSED_BIT = UInt16(1) << 15
const SQUASHFS_MAGIC = 0x73717368

"""
    rewrite_squashfs_uids(path, new_uid)

In order for the sandbox to work well, we need to have the uids of the squashfs
images match the uid of the current unpriviledged user. Unfortunately there is
no mount-time option to do this for us. However, fortunately, squashfs is simple
enough that if the id table is uncompressed, we can just manually patch the uids
to be what we need. This functions performs this operation, by rewriting all
uids/gids to new_uid.
"""
function rewrite_squashfs_uids(path, new_uid)
    open(path, "r+") do file
       # Check magic
       if read(file, UInt32) != SQUASHFS_MAGIC
           error("`$path` is not a squashfs file")
       end
       # Check that the image contains only one id (which we will rewrite)
       seek(file, offsetof_no_ids)
       if read(file, UInt16) != 1
           error("`$path` uses more than one uid/gid")
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
       if uid != 0
          error("Expected all uids to be 0 inside the image")
       end
       seek(file, p)
       write(file, UInt32(new_uid))
    end
end

"""
    update_rootfs(triplets::Vector{AbstractString};
                  automatic::Bool = automatic_apple, verbose::Bool = true,
                  squashfs::Bool = use_squashfs)

Updates the stored rootfs containing all cross-compilers and other compilation
machinery for the given triplets.  If `automatic` is set, when downloading Apple
SDKs, you will automatically accept the Apple license agreement and download the
macOS SDK for usage in targeting macOS.  See the help for `download_osx_sdk()`
for more details on this.
"""
function update_rootfs(triplets::Vector{S}; automatic::Bool = automatic_apple,
                       verbose::Bool = false, squashfs::Bool = use_squashfs,
                       mount::Bool=use_squashfs && Compat.Sys.islinux()) where {S <: AbstractString}
    # Check to make sure we have the latest version of both the base and the
    # given shard downloaded properly, and extracted if it's not a squashfs.
    for shard_name in ["base", triplets...]
        url = get_shard_url(shard_name; squashfs=squashfs)
        hash = get_shard_hash(shard_name; squashfs=squashfs)

        if shard_name == "base"
            dest_dir = rootfs_dir()
        else
            dest_dir = shards_dir(shard_name)
        end

        if squashfs
            squashfs_path = shard_path_squashfs(shard_name)
            file_existed = isfile(squashfs_path)

            # If squashfs, verify/redownload the squashfs image
            if !(download_verify(
                url,
                hash,
                squashfs_path;
                verbose = verbose,
                force = true
            ) && file_existed)
                if mount && Compat.Sys.islinux()
                    # Unmount the mountpoint. It may point to a previous version
                    # of the file. Also, we're about to mess with it
                    if success(`mountpoint $(dest_dir)`)
                        println("Running `sudo umount $(dest_dir)`")
                        run(`sudo umount $(dest_dir)`)
                    end

                    # Patch squashfs files for current uid
                    rewrite_squashfs_uids(squashfs_path, getuid())

                    # Touch SHA file to prevent re-verifcation from blowing the
                    # fs away
                    touch(string(squashfs_path,".sha256"))
                end
            end

            # Then mount it, if it hasn't already been mounted:
            if mount && Compat.Sys.islinux() && !success(`mountpoint $(dest_dir)`)
                mkpath(dest_dir)
                println("Running `sudo mount $(squashfs_path) $(dest_dir) -o ro,loop`")
                run(`sudo mount $(squashfs_path) $(dest_dir) -o ro,loop`)
            end
        else
            # If it has been mounted previously, unmount here
            if Compat.Sys.islinux() && success(`mountpoint $(dest_dir)`)
                println("Running `sudo umount $(dest_dir)`")
                run(`sudo umount $(dest_dir)`)
            end

             # If tarball, verify/redownload/reunpack the tarball
            download_verify_unpack(
                url,
                hash,
                dest_dir;
                tarball_path = downloads_dir("rootfs-$(shard_name).tar.gz"),
                verbose = verbose,
                force = true,
            )
        end
    end

    # If we're targeting the macOS SDK here, make sure it's ready to go.
    if any(triplets .== "x86_64-apple-darwin14")
        download_osx_sdk(;automatic=automatic, verbose=verbose)
    end
end

# Helper for when you're only asking for a single triplet
update_rootfs(triplet::AbstractString; kwargs...) = update_rootfs([triplet]; kwargs...)

"""
    download_osx_sdk(;automatic::Bool = automatic_apple, verbose::Bool = false,
                      version::AbstractString = "10.10")

Apple restricts distribution and usage of the macOS SDK, a necessary component
to build software for macOS targets.  Please read the Apple and Xcode SDK
agreement for more information on the restrictions and legal terms you agree to
when using the SDK to build software for Apple operating systems:
https://images.apple.com/legal/sla/docs/xcode.pdf.

If `automatic` is set, this method will automatically agree to the Apple usage
terms and download the macOS SDK, enabling building for macOS.

To set this on an environment level, set the `BINARYBUILDER_AUTOMATIC_APPLE`
environment variable to `"true"`.
"""
function download_osx_sdk(;automatic::Bool = automatic_apple,
                           verbose::Bool = false,
                           version::AbstractString = "10.10")
    urlbase = "https://github.com/phracker/MacOSX-SDKs/releases/download/10.13"

    # Right now, we only support one version, but in the future, we may need
    # to support multiple macOS SDK versions
    sdk_metadata = Dict(
        "10.10" => (
            "$(urlbase)/MacOSX10.10.sdk.tar.xz",
            "4a08de46b8e96f6db7ad3202054e28d7b3d60a3d38cd56e61f08fb4863c488ce",
            shards_dir("MacOSX10.10.sdk"),
        ),
    )

    if !haskey(sdk_metadata, version)
        error("Unknown macOS version $(version); cannot download SDK!")
    end
    url, hash, dest = sdk_metadata[version]

    # If it already exists, return out
    if isdir(dest)
        if verbose
            Compat.@info("macOS SDK $(dest) already exists")
        end
        return
    end

    # Ask if we should download it, unless we're automated
    if !automatic
        if !isinteractive()
            msg = strip("""
            This is not an interactive Julia session, so we will not prompt you
            to download and install the macOS SDK, see the docstring for the
            `download_osx_sdk()` method for more details.
            """)
            Compat.@warn(msg)
            return
        end
        msg = strip("""
        macOS SDK not yet downloaded!

        Apple restricts distribution and usage of the macOS SDK, a necessary
        component to build software for macOS targets.  Please read the Apple
        and Xcode SDK agreement for more information on the restrictions and
        legal terms you agree to when using the SDK to build software for Apple
        operating systems: https://images.apple.com/legal/sla/docs/xcode.pdf.
        """)
        printstyled(msg, bold=true)
        println()
        while true
            print("Would you like to download and use the macOS SDK? [y/N]: ")
            answer = lowercase(strip(readline(stdin)))
            if answer == "y" || answer == "yes"
                break
            elseif answer == "n" || answer == "no"
                return
            else
                println("Unrecognized answer. Answer `y` or `n`.")
            end
        end
    else
        if verbose
            Compat.@info("Automatic macOS SDK install initiated")
        end
    end

    download_verify_unpack(
        url,
        hash,
        dest;
        tarball_path=downloads_dir(basename(url)),
        verbose=verbose,
        force=true
    )

    # These macOS tarballs have a nasty habit of nesting, let's fix that:
    dir_in_dir = joinpath(dest, basename(dest))
    if isdir(dir_in_dir)
        mv(dir_in_dir, "$(dirname(dir_in_dir))2")
        mv("$(dirname(dir_in_dir))2", dest; remove_destination=true)
    end
end
