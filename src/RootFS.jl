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
    global shards_dir
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
    rootfs_version = "2018-03-08"

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
        "aarch64-linux-gnu" => "b61f1959bcb2f704689cc2b70e8c2cce968a720aadd03f01dda20e107f04bf96",
        "arm-linux-gnueabihf" => "69d76ddd06791382a34c289ff98d2b568b926b7d7233469429c2db1b52a150d3",
        "base" => "002ebdadcfe9feea18d26a03e5494c0fa92611e109e9f8f3d7639ddaed11680e",
        "i686-linux-gnu" => "f72e6ef77120bc11804e117fc282ef3e49a28d9b0577f2d602c23b6fcee9bf8f",
        "i686-linux-musl" => "fae46b426fe7fb570da12d9c7c7e52a4a9f490cc3363864bf7465e8e0eb7364c",
        "i686-w64-mingw32" => "5c5a6b65165c0935f2bf915412d5e582b7da211b0263154150a6194fc4fca4b6",
        "powerpc64le-linux-gnu" => "cfaf19af0db4cb8dc08aa097b3df78c90e5124864086b51bae643e230cff5bb7",
        "x86_64-apple-darwin14" => "b59d3ded28a1e539c29f1b1086afac6fcaa6fc97e89fb26547645cf19c43ec29",
        "x86_64-linux-gnu" => "f16d9602c7c973f76f8206a484b159692ad9944e4f1c997b6461bba3f7a9091c",
        "x86_64-linux-musl" => "d8e2e8a45f4e10dcd67981f5a6f88dbb7fe889ace28aada6dee7f483924c6042",
        "x86_64-w64-mingw32" => "20e87497cdb05803a0682cca3565af03ea81b347592c8aad78afaaec65362d63",
    )
    tarball_hashes = Dict(
        "aarch64-linux-gnu" => "b5a6fbf2ffa4b182a5ae8372d22c01381b390a27f7414f76bb1c69c5a782ecff",
        "arm-linux-gnueabihf" => "4f8276caf942f3953ae5efaad3bf93ebc5863aab036e9d187a51f1c33fdc9041",
        "base" => "34451edd768a13a61f0fb832c3d68cb1af4121d36d5f46e6988766a2ca409290",
        "i686-linux-gnu" => "01b1e58bc40103cb6790a6cf462494985c123840a9046694fb97363f25e30813",
        "i686-linux-musl" => "f11fb77f865f58cec70b26817f52cf6a2de480961dcf1c2bb18b6bc4c8d2028d",
        "i686-w64-mingw32" => "1458ca2ad5498f08a2bf32677931286f168b9a54df44120c7d1ed171caacd069",
        "powerpc64le-linux-gnu" => "b224c8baaab2c29d613bb778291ca8e169d7efc677e513367e5bcccbfbc1515e",
        "x86_64-apple-darwin14" => "73347d21f279bc82d140cd6ad56cf501f6a798324f8372af616a1505cdd3b9c1",
        "x86_64-linux-gnu" => "00bb414668f438b5bf58441115bddbbaf433b5af6897d03b34879bd60799c5c0",
        "x86_64-linux-musl" => "dacfebd1207f9c69bf60cb756be52c8186fdeb857e1cc3c93f9e3691bd7cf407",
        "x86_64-w64-mingw32" => "0fce770966e506ec818dbcb9c19206243c72017f3d19543dec6fcca8eda92c44",
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
                    rewrite_squashfs_uids(squashfs_path, ccall(:getuid, Cint, ()))

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
