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
    rootfs_version = "2017-11-25"

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
        "base" => "fceb9b17f74ad2983aca0b029464e6c9015e5b8d0d30ea75ec344787dce3b0c5",
        "aarch64-linux-gnu" => "c08b0fd297cefb2881427dd315651d2b63023717d280f49938980a736579f5e4",
        "arm-linux-gnueabihf" => "f8316607b805eaf8366b343bdcf7547a016a23c17d4ba015a18a3acdaec13490",
        "i686-linux-gnu" => "01151e6a612ed9416089619b6cea90b0eeac3299663dec9ab0c99b093c3ca5d6",
        "i686-w64-mingw32" => "085872f45e7af5d446e6ddb49ff80a8ec2e651f1bfddae26523f1facdfb06ea6",
        "powerpc64le-linux-gnu" => "d06f195109d472111e09a25bf39b8671f0a30e5c13c0ec8a94acb3a86e925b0d",
        "x86_64-apple-darwin14" => "7cf96e3afe07e8a5a10afa2239ad6b4eb23bee8606e003019579c02fe3d305d2",
        "x86_64-linux-gnu" => "edc5bf34671af97890da4b8541b0b2acc30bb8a6da2b4a9953fb6ce07f8142c9",
        "x86_64-w64-mingw32" => "e0ada28ed6bdadef31983bbaea3e9dc8b7073345f02b64d63f90bad3ca3c5ce2",
    )

    tarball_hashes = Dict(
        "base" => "e5ee4bbcf56c99465615ce7e5f197b9323563ce81c1f962d35c2e599619a0df0",
        "aarch64-linux-gnu" => "c2a561fbffbbf9ded848506ce09e763c54d88a3c1fcd246a5e7fd3134e4a26d8",
        "arm-linux-gnueabihf" => "9fe189893d3c1c7edd41c8617aaae0baa10b70ce4330239fc6ce32d94671c350",
        "i686-linux-gnu" => "94b67c132c0b0b56bc3d332fda9307758a18f4d4e547ea001fdddc0fe6e90d05",
        "i686-w64-mingw32" => "2298fe2c53b3ff3b24e633bbce1520d0b3c729d18230c6ce8440adeec567df30",
        "powerpc64le-linux-gnu" => "aa8a1f2d7bd9c2cad41bac9dc157a1797441c71cc187970f2062bfd401b46a6d",
        "x86_64-apple-darwin14" => "3c970a63e9036d1a2a626ba5e9fe09cf04c3e2a97c889ea825e4541869b321da",
        "x86_64-linux-gnu" => "515de90254f3f7931b26100cd25158154c6a3c9ade36bd09639ffcfbe2e45c71",
        "x86_64-w64-mingw32" => "c1ec079e22cfcd42181c75ca7fad2119daa36b9444f7375ef1d1f0f8af556e15",
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

            # Then mount it
            run(`sudo mount $(squashfs_path) $(dest_dir) -o ro,loop`)
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
    
    download_verify_unpack(url, hash, dest, verbose=verbose, force=true)

    # These macOS tarballs have a nasty habit of nesting, let's fix that:
    dir_in_dir = joinpath(dest, basename(dest))
    if isdir(dir_in_dir)
        mv(dir_in_dir, dest)
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

