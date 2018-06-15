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

function ccache_dir()
    global ccache_override

    if ccache_override != ""
        return ccache_override
    else
        return shards_dir("ccache")
    end
end

function sandbox_path()
    global sandbox_override

    if sandbox_override != ""
        return sandbox_override
    else
        return rootfs_dir("sandbox")
    end
end

"""
    get_shard_url(target::String = "base"; squashfs::Bool = use_squashfs)

Returns the URL from which a rootfs image (tarball/squashfs) can be downloaded
"""
function get_shard_url(target::String = "base"; squashfs::Bool = use_squashfs)
    # These constants are what should be updated for a new rootfs build:
    rootfs_urlroot = "https://julialangmirror-s3.julialang.org/binarybuilder"
    rootfs_version = "2018-05-26"

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
    # You can get these dictionaries spat out by running `make buildall && make push-rootfs`
    # in `julia-docker/crossbuild`
    squashfs_hashes = Dict(
        "aarch64-linux-gnu" => "05ee1834cc5d5d4f5d2864b9d47aea894ccfe984f151f6cef802c707aae14aff",
        "aarch64-linux-musl" => "631c6acd70a32b07d6c202369bea24ece17a1a09f85257f3a88a3dc6cd9ff281",
        "arm-linux-gnueabihf" => "e74ec696b2396267f4ca9b4ac04abe94d092f994435234ac4503d13a20aaaa04",
        "arm-linux-musleabihf" => "1c9d3c6e3f082459b70ea49370641ee8f00c5b058732d140bf10e445d65fbca5",
        "base" => "154a39efdefe67d680184869a15c9322594e93ce4c03621c81a35b17bd392e4b",
        "i686-linux-gnu" => "75cad3c1e5566edd6e162aadee5e54c45db49ae984abeed165a3c0fe36463eb6",
        "i686-linux-musl" => "7488e2c6e810b6c738d3af07a4c43e49d0018dd5ab613bc838de9692b8e63543",
        "i686-w64-mingw32" => "7eeeee6959f5d411941b17539b0bee07d2a1523930a1ec6e17dc45d08ae1a940",
        "powerpc64le-linux-gnu" => "36bb3449e5ec810905f08f68f9ea68a3f082e4dcd63505c469121108b8d2d47c",
        "x86_64-apple-darwin14" => "bc33d23a7c5974c6c2d310ef01eb9098cbf49618a07f6488bae89b8c80d1105b",
        "x86_64-linux-gnu" => "60d42526c76c19066d67b716173ac64fe29f93222e36c295c04e5ee5e9ab317a",
        "x86_64-linux-musl" => "725a3fbe875b068b3ee4a2536ed1c7bfda4a2bde1ff8aaa3422aa9bbd51e5556",
        "x86_64-unknown-freebsd11.1" => "538c077fab1977514aa49de54e4b6ddcde6ce036668d68cbc3cc14cc164c710d",
        "x86_64-w64-mingw32" => "c4c8015d8f8ed84ae5162902072093037ff9364d372ba03e33fcaf1938c9f6af",
    )
    tarball_hashes = Dict(
        "aarch64-linux-gnu" => "4b6a9d4fce1dfc1c4bfc6a439ea377225e493b29b4cbc4b5f312e9841611156f",
        "aarch64-linux-musl" => "3b0b832c7a498b6c778045038efedcc8f06778f0d653e093fc29d6fa4feb3f58",
        "arm-linux-gnueabihf" => "2b4f224c3c7f43b4ecdc63edd37ab73cd42411b9288bf3cc0d01599ea53541e1",
        "arm-linux-musleabihf" => "04b2a8a26721fc07045a67e4f867f715fe48a7d2e0e29636ece62e2e243fd3d9",
        "base" => "ecc87a85e79d3a64e853634678ce8e182a12367fdc062dbd046164f2ba0dbd3d",
        "i686-linux-gnu" => "848726ca7acc7dc23f5b43f9992d8235761b694260ae4336ff177b6952e3f759",
        "i686-linux-musl" => "b7a429b48cafd5fada36af52b24492f08ff67579211ee7c6854489ee214858df",
        "i686-w64-mingw32" => "7c64955cc3d1bc70bdeed05cdd0d4df140d2ec68ebb3e4c907db74f7370d1616",
        "powerpc64le-linux-gnu" => "34a1f375464d9a7269a8ff3eefb95e8f4c2711ab851dec38c959685adb7724b9",
        "x86_64-apple-darwin14" => "896a8b7ff4c423c189448041cbda6b7124076893bc66158eb78b79541f8647db",
        "x86_64-linux-gnu" => "757a695d8cbe2d62ba3b75f9a0ff568d172bf63db8ff6fde3ad757b86aee1f8e",
        "x86_64-linux-musl" => "f7b23fa8d799f553679d5bd5cb8149975e1a930740cadb2ceb721d360d490482",
        "x86_64-unknown-freebsd11.1" => "34ac437cea654fc92b64fea713673ba2dd47c721e0cd30df037d74a48fff32a1",
        "x86_64-w64-mingw32" => "35b5bbbab349e14590454dfec32d9b4bff1ea150d7cbb7d1d7ce83622876ee31",
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
           error("Expected all uids to be 0 (not $(uid)) inside the image")
       end
       seek(file, p)
       write(file, UInt32(new_uid))
    end
    return nothing
end

_sudo_cmd = nothing
function sudo_cmd()
    global _sudo_cmd

    # Use cached value if we've already run this
    if _sudo_cmd != nothing
        return _sudo_cmd
    end

    if getuid() == 0
        # If we're already root, don't use any kind of sudo program
        _sudo_cmd = ``
    elseif success(`sudo -V`)
        # If `sudo` is available, use that
        _sudo_cmd = `sudo`
    else
        # Fall back to `su` if all else fails
        _sudo_cmd = `su root -c`
    end
    return _sudo_cmd
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
                    unmount_shard(dest_dir)

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
                Compat.@info("Mounting $(squashfs_path) to $(dest_dir)")
                run(`$(sudo_cmd()) mount $(squashfs_path) $(dest_dir) -o ro,loop`)
            end
        else
            # If it has been mounted previously, unmount here
            unmount_shard(dest_dir)

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

# Helper to unmount any shards that may be mounted, so as not to exhaust the number of loopback devices
function unmount_shard(dest_dir::AbstractString; fail_on_error::Bool = false)
    # This function only matters on Linux
    @static if !Compat.Sys.islinux()
        return
    end

    if success(`mountpoint $(dest_dir)`)
        Compat.@info("Unmounting $(dest_dir)`")
        try
            run(pipeline(cmd, stdin=devnull, stdout=devnull, stderr=devnull))
        catch e
            # By default we don't error out if this unmounting fails
            if fail_on_error
                rethrow(e)
            end
        end
    end
    return
end

function unmount_all_shards(;fail_on_error::Bool = false)
    # This function only matters on Linux
    @static if !Compat.Sys.islinux()
        return
    end

    dest_dirs = shards_dir.(triplet.(supported_platforms()))
    push!(dest_dirs, rootfs_dir())

    for dest_dir in dest_dirs
        unmount_shard(dest_dir; fail_on_error = fail_on_error)
    end
    return
end

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
