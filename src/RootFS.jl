# These globals store important information such as where we're downloading
# the rootfs to, and where we're unpacking it.  These constants are initialized
# by `__init__()` to allow for environment variable overrides from the user.
downloads_cache = ""
rootfs_cache = ""
shards_cache = ""
automatic_apple = false
use_squashfs = false

# This is where the `sandbox` binary lives
const sandbox_path = joinpath(dirname(@__FILE__), "..", "deps", "sandbox")

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
    rootfs_version = "2018-01-03"

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
    # in `julia-docker/crossbuild`, after running `make shards`.
    squashfs_hashes = Dict(
        "aarch64-linux-gnu" => "7bbfdd33633a8c841531fe7f7827bd6e1532b2fd9853ca840dc789a9455b8709",
        "arm-linux-gnueabihf" => "c91614844c5573f2405252161a0589873e676abe71bac5b369e9badb565ba664",
        "base" => "e47578c1f6bf335bb784629511dcdb44b481fac8dac7937e96d069b3bf67f52e",
        "i686-linux-gnu" => "948f36b198381743b5fdd812ab5c2e169d89fe0dd80abd0b983f62d9548b876c",
        "i686-w64-mingw32" => "6f14372c8374b0a0154d29451838b7162d154385dc9bcfc2943bc5dcd9adde4f",
        "powerpc64le-linux-gnu" => "cce04a6d76c061f3e7f0d93bfe5f1e8e648e390530d5db0ac0c6bab9c0a9945d",
        "x86_64-apple-darwin14" => "6d90010fd9940d4f8ab3783e0376bf6445919ee3fcf0ec4318631c31cdb9c946",
        "x86_64-linux-gnu" => "a9ad2be3b670af5a744c6e107968ff296527bfef6985ccf3c92d54f7f2361211",
        "x86_64-w64-mingw32" => "1d14541376c536a0084cea3da40666619aa2aee87824f01c134c4c7bf2fba907",
    )
    tarball_hashes = Dict(
        "aarch64-linux-gnu" => "d2e5c132f4abab23a7739e55dc22d70d679ca7438dd18ab3115b7579f43ce5f1",
        "arm-linux-gnueabihf" => "93d25bd98cb57904b22d9757e9d178f6298ac36e49a7d65cecd9971cd3224e84",
        "base" => "98f2343e4ba8c2a58543fca3c51861c09be716ca2ee6a34f97932ff82fa1b78c",
        "i686-linux-gnu" => "2db66927c305a145d8e7208727a7efdd4e6161e264782843556a63c30a938fe7",
        "i686-w64-mingw32" => "b80a8459b65a336c800578dac13109105f20574856dda066238fb23b44d8d6ed",
        "powerpc64le-linux-gnu" => "1eeb29bb998f2839e7e4b0f69aa50c29651840f298eec4e9a7d7436603cdb26a",
        "x86_64-apple-darwin14" => "06542d899688b6c5a7a77f6da7457055bd5a9b3bdc6f0e432d00daf22e5c8f16",
        "x86_64-linux-gnu" => "98d08ed68d912e979d5c019cd42c9bd1427bc68879b175e0e0767caf390768fd",
        "x86_64-w64-mingw32" => "5a985fedd09e968f26447d114c816eb24216cfcbdab8fcffb5aa5f7be49e0c0a",
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
                       verbose::Bool = true, squashfs::Bool = use_squashfs,
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
            info("macOS SDK $(dest) already exists")
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
            warn(msg)
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
        print_with_color(:bold, msg)
        println()
        while true
            print("Would you like to download and use the macOS SDK? [y/N]: ")
            answer = lowercase(strip(readline(STDIN)))
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
            info("Automatic macOS SDK install initiated")
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


"""
    update_sandbox_binary(;verbose::Bool = true)

Builds/updates the `sandbox` binary that launches all commands within the
rootfs, storing the binary within the `deps` folder.
"""
function update_sandbox_binary(;verbose::Bool = true)
    global sandbox_path

    src_path = joinpath(dirname(@__FILE__), "..", "deps", "sandbox.c")
    if !isfile(sandbox_path) || stat(sandbox_path).mtime < stat(src_path).mtime
        if verbose
            info("Rebuilding sandbox binary...")
        end

        cd() do
            oc = OutputCollector(
                `gcc -std=c99 -o $(sandbox_path) $(src_path)`;
                verbose=verbose,
            )
            wait(oc)
        end
    end
end
