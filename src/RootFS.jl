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


"""
    get_shard_url(target::String = "base"; squashfs::Bool = use_squashfs)

Returns the URL from which a rootfs image (tarball/squashfs) can be downloaded
"""
function get_shard_url(target::String = "base"; squashfs::Bool = use_squashfs)
    # These constants are what should be updated for a new rootfs build:
    rootfs_urlroot = "https://julialangmirror.s3.amazonaws.com/binarybuilder"
    rootfs_version = "2017-12-01"

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
        "aarch64-linux-gnu" => "c8cba1303de05de755278b124c96c13f5ebf11af749648fb4843482a54737570",
        "arm-linux-gnueabihf" => "f1ea9c7425569563fb94073c5b87adba243a3aacc71b2475a2156e4765e51558",
        "base" => "7b726a8cee6439e2eb56eb878a55ea6d553db1b2715b07be0734a3c5351076fd",
        "i686-linux-gnu" => "fd6237972d2af2488dc56fb8a26e48ad44bf77aaa27615319e29bde7240185b6",
        "i686-w64-mingw32" => "f31599e5b711f439dafa934a7ae1ed742648726650e3d70fa73bd97aabdb7010",
        "powerpc64le-linux-gnu" => "474b154c492ee29e6513e6ac222b96034bf60c2391c916f740d601a3e1c3c91c",
        "x86_64-apple-darwin14" => "85893ce12a319d773e8ac01ad69ec9bbff88f3363eeab608bd49e9ce98fc658f",
        "x86_64-linux-gnu" => "54cbdf2a950bf2558cb9f24bba9cacad7469b167ea7d4920389089bc7153a82f",
        "x86_64-w64-mingw32" => "2015eabb1785c25f1d1b231cdad3855cb7d77150e7dc87a985bab1e68bb983e0",
    )
    tarball_hashes = Dict(
        "aarch64-linux-gnu" => "dbe276b0053bd7c965e961d2ce4677fb43c61ffb883c584cd086a44986e7bb68",
        "arm-linux-gnueabihf" => "21b193a959ee6113be40a28a934029595a1ead9792f9e87505cb894d2ee03c7c",
        "base" => "c1e4815daf88e6bc05e88992a562b414ee2da587ed5080d81d8210b3f4be8d73",
        "i686-linux-gnu" => "8d6840a48af6ca125c897351d026b4266e916b062ece944bb9e51f516341cbdb",
        "i686-w64-mingw32" => "404a6c58c750ddeaa21c96f953b113a8e15f3c32ef27d83d7b869a7d4905f4da",
        "powerpc64le-linux-gnu" => "c802bb63887916376964002b4f45091bf7f295dd4624b7a8dd0ca3f83ccdf6c5",
        "x86_64-apple-darwin14" => "df28427afbed8a96d8d25a3519e104fe5e75ffc6c71de614c32325b14ccf21f8",
        "x86_64-linux-gnu" => "e87473dad9bf4f2f6a150883273f087bda3737d9835f5fa1d35caafa20b5a2a1",
        "x86_64-w64-mingw32" => "6d6b30fe07c59fafff3a68fe359756a193c87eb8da6d32339004ca4aed354d2a",
    )

    if squashfs
        return squashfs_hashes[triplet]
    else
        return tarball_hashes[triplet]
    end
end

# Note: produce these values by #including squashfs_fs.h from linux in a Cxx
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
                       verbose::Bool = true, squashfs::Bool = use_squashfs) where {S <: AbstractString}
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
            squashfs_path = downloads_dir("rootfs-$(shard_name).squashfs")
            
            file_existed = isfile(squashfs_path)
            
            # If squashfs, verify/redownload the squashfs image
            if !(download_verify(
                url,
                hash,
                squashfs_path;
                verbose = verbose,
                force = true
            ) && file_existed)
                # Unmount the mountpoint. It may point to a previous version
                # of the file. Also, we're about to mess with it
                if success(`mountpoint $(dest_dir)`)
                    run(`sudo umount $(dest_dir)`)
                end

                # Patch squashfs files for current uid
                rewrite_squashfs_uids(squashfs_path, ccall(:getuid, Cint, ()))
                
                # Touch SHA file to prevent re-verifcation from blowing the
                # fs away
                touch(string(squashfs_path,".sha256"))
            end
            
            # Then mount it, if it hasn't already been mounted:
            if !success(`mountpoint $(dest_dir)`)
                mkpath(dest_dir)
                run(`sudo mount $(squashfs_path) $(dest_dir) -o ro,loop`)
            end
        else
            # If it has been mounted previously, unmount here
            if success(`mountpoint $(dest_dir)`)
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
                `gcc -o $(sandbox_path) $(src_path)`;
                verbose=verbose,
            )
            wait(oc)
        end
    end
end
