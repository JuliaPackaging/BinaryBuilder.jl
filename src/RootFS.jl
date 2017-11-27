# These globals store important information such as where we're downloading
# the rootfs to, and where we're unpacking it.  These constants are initialized
# by `__init__()` to allow for environment variable overrides from the user.
downloads_cache = ""
rootfs_cache = ""
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
    get_shard_url(target::String = "base"; squashfs::Bool = use_squashfs)

Returns the URL from which a rootfs image (tarball/squashfs) can be downloaded
"""
function get_shard_url(target::String = "base"; squashfs::Bool = use_squashfs)
    # These constants are what should be updated for a new rootfs build:
    rootfs_urlroot = "https://julialangmirror.s3.amazonaws.com/binarybuilder"
    rootfs_version = "2017-11-26"

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
        "aarch64-linux-gnu" => "28bcd50d957827d209f0275be23e8ea020b25223f890c43fd823a5b77ecac524",
        "arm-linux-gnueabihf" => "74e2e8b49c0eccc088024cbfa0fbe10cdb82b203ff965ce205c96d48e5ca33e9",
        "base" => "ea477e0ff7e57986c36af8a092a80aefb45840f15b27d9528842ea09d7979f02",
        "i686-linux-gnu" => "efc56b8dd407adb8b329fb834ce3784e6e9d99e910b86bda3f5b71732183139a",
        "i686-w64-mingw32" => "0a6b585f4a64a637fea05a27f2543cbd3f59fa3ce325016044310a8c6001b88b",
        "powerpc64le-linux-gnu" => "761397db415d0a76228324a80e11d1befdecb6562dab11fdd153c071c6029b83",
        "x86_64-apple-darwin14" => "3c7dfd90eb7c27019c276bbe1053e9a0484c86b1963a8812e0d99f6ffc328d69",
        "x86_64-linux-gnu" => "2c5d5faf5896230af1e0048422baf27692946c1aa3bd9403c071f97d5c223b66",
        "x86_64-w64-mingw32" => "67db51ad61a1d59ccc35d31d4862781bfa00baa59207feaacb1cf84677b207d5",
    )
    tarball_hashes = Dict(
        "aarch64-linux-gnu" => "62d16d4e2c7af85751d9c6eabb4f0753c3e941cad4240a9057e20dce45436ccb",
        "arm-linux-gnueabihf" => "c0c899af8dab8ac9ebd4f5af69d9187a849adbf952f9088fc5d8a2302a6b0856",
        "base" => "f8833727de887934c9fd5fb00027a188529e9c1a6c6de57cb0b75ba76b9c53d4",
        "i686-linux-gnu" => "7fb21a34b5f573429646325dbab9b71a68db468e56ba8da3d29c66e408e32dbc",
        "i686-w64-mingw32" => "e9863d2658a73260f5deac50f7015023c97fda45b76ff3d2ac6c52f72c121b71",
        "powerpc64le-linux-gnu" => "fd9119324e03c6a007a336351893f0fa208a836b08a1cd9a4756bcb04209a8a6",
        "x86_64-apple-darwin14" => "ed5c1d2ba8cc0fd7840dc63918d00d18b812a80d68652420a4104a35af9109b9",
        "x86_64-linux-gnu" => "fc7ff95071a91ed879713717524fe20781db6f171e9711f21b827a4515835c77",
        "x86_64-w64-mingw32" => "2eebe8ad409c85d627ba74cfea680dfe46112a681c17c32b495f6cc32d962182",
    )
    
    if squashfs
        return squashfs_hashes[triplet]
    else
        return tarball_hashes[triplet]
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
                       verbose::Bool = true, squashfs::Bool = use_squashfs) where {S <: AbstractString}
    # Check to make sure we have the latest version of both the base and the
    # given shard downloaded properly, and extracted if it's not a squashfs.
    for shard_name in ["base", triplets...]
        url = get_shard_url(shard_name; squashfs=squashfs)
        hash = get_shard_hash(shard_name; squashfs=squashfs)

        # Actually make the destination directory
        if shard_name == "base"
            dest_dir = rootfs_dir()
        else
            dest_dir = rootfs_dir("opt/$(shard_name)")
        end

        if squashfs
            # If squashfs, verify/redownload the squashfs image
            squashfs_path = downloads_dir("rootfs-$(shard_name).squashfs")
            download_verify(
                url,
                hash,
                squashfs_path;
                verbose = verbose,
            )

            # Then mount it, if it hasn't already been mounted:
            if !success(`mountpoint $(dest_dir)`)
                mkpath(dest_dir)
                run(`sudo mount $(squashfs_path) $(dest_dir) -o ro,loop`)
            end
        else
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
            rootfs_dir("opt/x86_64-apple-darwin14/MacOSX10.10.sdk"),
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
                `gcc -o $(sandbox_path) $(src_path)`;
                verbose=verbose,
            )
            wait(oc)
        end
    end
end

