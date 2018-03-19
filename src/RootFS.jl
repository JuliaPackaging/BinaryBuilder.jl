# These globals store important information such as where we're downloading
# the rootfs to, and where we're unpacking it.  These constants are initialized
# by `__init__()` to allow for environment variable overrides from the user.
downloads_cache = ""
rootfs_cache = ""
shards_cache = ""
qemu_cache = ""
automatic_apple = false
use_squashfs = false

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

"""
    get_shard_url(target::String = "base"; squashfs::Bool = use_squashfs)

Returns the URL from which a rootfs image (tarball/squashfs) can be downloaded
"""
function get_shard_url(target::String = "base"; squashfs::Bool = use_squashfs)
    # These constants are what should be updated for a new rootfs build:
    rootfs_urlroot = "https://julialangmirror.s3.amazonaws.com/binarybuilder"
    rootfs_version = "2018-03-12"

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
        "aarch64-linux-gnu" => "927df1ef10c8b7766778f2599c05fe50cf06f3593149ffcfaa524ea3d8891f00",
        "aarch64-linux-musl" => "c9f70c83dae67a34c8aaca2547e763424c2cfa4b031dfae670aaef2c6fe40096",
        "arm-linux-gnueabihf" => "d9a612c9dd73cdcca4cc8124b42937ad08c9ebd787bc5e1032f79af3971363bf",
        "arm-linux-musleabihf" => "fceab621ca4e822ddfbd77cc5db1c4939ab928cc2656ff9520e5b2c413385661",
        "base" => "30efce7faabd866dd2466976ff87f76177c947c6b64e9664ca82c543101d429b",
        "i686-linux-gnu" => "4c2f13ed31195ea72ae3467e413b1a08e47302414b31af3f248eb2cad14b26e8",
        "i686-linux-musl" => "f4e0eba716786046087e76d632fd01aea0338ae28966ce07c8f206de592ee2b9",
        "i686-w64-mingw32" => "cd4d0b3ad0d95b2c06ae812a7c77cf354da8a873334a9170bd08261d7b7e580d",
        "powerpc64le-linux-gnu" => "3445c77a88701ab03a0d728a3a008d7d3fd7112a975c0373597e58a25904e976",
        "x86_64-apple-darwin14" => "89cf0b5153d33a315228f69ed8e266453c145112e6e093062df5c9695b79118c",
        "x86_64-linux-gnu" => "4003548ac1f99dd0699017247178037bb2f4780802489d5d29e19a56acca5f19",
        "x86_64-linux-musl" => "6e2d010e69e2a439f269b2859ad884c3fcd403b2c5f91dbf1aa193dff13c2302",
        "x86_64-w64-mingw32" => "e2a967eadf52d2424e6378bdd7e25f50a14b33e39d36464128f1102dc1bd6558",
    )
    tarball_hashes = Dict(
        "aarch64-linux-gnu" => "fb4168982d041f45234e9f5b7284470ca9a609c448b31035208c5f605173f300",
        "aarch64-linux-musl" => "f0e877cf6fe868f567afa1e93ba57a68e3d1715dbd66fc5ffad3aaa0aa2e9eac",
        "arm-linux-gnueabihf" => "3c1813545b9e41cd77f58292aabdbe7b0cdea8b9eff3dc6ae618649a41394def",
        "arm-linux-musleabihf" => "5241fac99b35586f87de52382d3ba0e13583fb7d56dedc50bc55d1bfb54cf615",
        "base" => "8b525d0f2d4fe97e477b028863d903f456f76f782bf666e6e2a1d18d989d4020",
        "i686-linux-gnu" => "2ad7632ba9457cbbd6f2b2b8565f7565410ea64fdffb89c01974a02177870b7e",
        "i686-linux-musl" => "7cdac591c209e0b40c0c7077bd23dcc00eecb960967f990f84583618df646d82",
        "i686-w64-mingw32" => "bec69b3382b6c3f5c3bd769217528dba11aaa9e6ef4843db9ef4f61b506b6287",
        "powerpc64le-linux-gnu" => "9349e0c2e1b8f01dcd41a890dde2bc5ea9c33c033307e965de18555aaf0546e1",
        "x86_64-apple-darwin14" => "d97cb6e2b828abd14b35847dbbea9bbfc3f0c5663292559189f9c57f0b89fd8c",
        "x86_64-linux-gnu" => "2a64fc3b8af60e0460b87494cf50e431a51e00b3ba9f382cb4d4492eccb9b186",
        "x86_64-linux-musl" => "31dbf329d716ae13b1a99598e733ac9cd0a42385ff72919464481ff0a685470d",
        "x86_64-w64-mingw32" => "b9ac6f09b6691332f5fb07decdd69170ed13ed0c6cc1a9a282d3930e4d4a5b09",
    )

    if squashfs
        return squashfs_hashes[triplet]
    else
        return tarball_hashes[triplet]
    end
end

# Note: produce these values by #including squashfs_fs.h from linux in Cxx.jl
# and running the indicated command
const offsetof_id_table_start = 0x30    # offsetof(struct suqashfs_super_block, id_table_start)
const offsetof_no_ids = 0x1a            # offsetof(struct suqashfs_super_block, no_ids)

# From squashfs_fs.h
const SQUASHFS_COMPRESSED_BIT = UInt16(1) << 15
const SQUASHFS_MAGIC = 0x73717368

"""
    getuid()

Wrapper around libc's `getuid()` function
"""
function getuid()
    return ccall(:getuid, Cint, ())
end

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
