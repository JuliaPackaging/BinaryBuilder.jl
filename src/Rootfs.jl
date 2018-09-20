export supported_platforms, expand_gcc_versions
using BinaryProvider: compiler_abi

## The build environment is broken up into multiple parts:
#
#  * RootFS - Host-only tools such as `bash`, `make`, `cmake`, etc....
#  * BaseCompilerShard - Target-specific binutils, libc, etc....
#  * GCC - Target-and-ABI-specific GCC compilers
#  * LLVM - Target-nonspecific clang compilers
#
# Given a `Platform`, we determine the set of shards to mount in to the
# sandbox for that `Platform`.  If there are multiple possible options,
# (e.g. the Platform sets no ABI requirement) the oldest compiler possible 
# is used by default, for libstdc++ compatibility reasons.  (Even though we
# ship a very recent version of libstdc++ with Julia, we need to ensure that
# our binaries are as compatible as possible for custom builds)
#
# Each chunk of the build environment (referred to as a `shard`) is served
# as either a `.tar.gz` file or a `.squashfs` file.  While `.squashfs` files
# are desirable for multiple reasons (smaller download size, no need to unpack
# on the host filesystem taking up disk space) they currently require `sudo`
# privileges to mount on Linux machines, and as such cannot be used in the
# unprivileged user namespace setting, which is what we most often use.
# We therefore support downloading `.squashfs` files when a privileged
# usernamespace or qemu runnre is being used.
#
# Shards are downloaded to `<storage_dir>/downloads`, unpacked (in the case
# of `.tar.gz` files) to `<storage_dir>/mounts` or mounted to
# `<storage_dir>/mounts`.  We must take a little care when dealing with this
# mixture of unpacked and mounted shards (especially when switching Runner
# backends, as they will often cause the shard storage type to change!) but
# it's still desirable as it cuts down on the complexity of needing to change
# which paths are being mounted based on the archive type of the shard, etc...



# This is a type that encompasses a shard; it makes it easy to pass it around,
# get its download url, extraction url, mounting url, etc...
struct CompilerShard
    # Something like "RootFS", or "GCC"
    name::String
    
    # Something like v"7.1.0"
    version::VersionNumber

    # Things like Windows(:x86_64; gcc_version=:gcc7)
    target::Union{Nothing,Platform}

    # Right now, always `Linux(:x86_64)`
    host::Platform
    
    # :squashfs or :targz.  Possibly more in the future.
    archive_type::Symbol

    function CompilerShard(name, version, host, archive_type; target = nothing)
        # Ensure we have the right archive type
        if !(archive_type in (:squashfs, :targz))
            error("Invalid archive type '$(archive_type)'")
        end

        # Ensure the platforms have no ABI portion (that is only used
        # by higher-level things to choose e.g. which version of GCC
        # to use, but once we're at this level we only care about the
        # larger-scale things, not the ABI).
        host = abi_agnostic(host)
        if target != nothing
            target = abi_agnostic(target)
        end

        # Construct our shiny new CompilerShard object
        return new(name, version, target, host, archive_type)
    end
end

"""
    abi_agnostic(p::Platform)

Strip out the CompilerABI portion of a Platform, making it "ABI agnostic".
"""
function abi_agnostic(p::P) where {P <: Platform}
    return P(arch(p), libc(p), call_abi(p))
end

"""
    filename(cs::CompilerShard)

Return the filename of this shard.  Used by e.g. `url()` or `download_path()`.
"""
function filename(cs::CompilerShard)
    ext = Dict(:squashfs => "squashfs", :targz => "tar.gz")[cs.archive_type]
    return string(dir_name(cs), ".", ext)
end

"""
    url(cs::CompilerShard)

Return the URL from which this shard can be downloaded.
"""
function url(cs::CompilerShard)
    urlroot = "https://julialangmirror.s3.amazonaws.com/binarybuilder"
    return joinpath(urlroot, filename(cs))
end

"""
    hash(cs::CompilerShard)

Return the integrity hash for this compiler shard, for ensuring it has been
downloaded properly/has not been tampered with.
"""
function hash(cs::CompilerShard)
    global shard_hash_table
    try
        return shard_hash_table[cs]
    catch
        throw(ArgumentError("Compiler shard $(cs) is not found in our hash table!"))
    end
end

"""
    dir_name(cs::CompilerShard)

Return a "directory name" for a compiler shard; used by e.g. `extraction_path()`
or `mount_path()`, to create names like "Rootfs.v2018.08.27-x86_64-linux-gnu".
"""
function dir_name(cs::CompilerShard)
    target = ""
    if cs.target != nothing
        target = "-$(triplet(cs.target))"
    end
    return "$(cs.name)$(target).v$(cs.version).$(triplet(cs.host))"
end

"""
    map_target(cs::CompilerShard)

Return the location this compiler shard should be mounted at.  We basically
analyze the name and platform of this shard and return a path based on that.
"""
function map_target(cs::CompilerShard)
    if lowercase(cs.name) == "rootfs"
        return "/"
    elseif lowercase(cs.name) in ("gcc", "basecompilershard")
        return joinpath("/opt", triplet(cs.target), "$(cs.name)-$(cs.version)")
    elseif lowercase(cs.name) == "llvm"
        return joinpath("/opt", triplet(cs.host), "$(cs.name)-$(cs.version)")
    else
        error("Unknown mapping for shard named $(cs.name)")
    end
end

"""
    download_path(cs::CompilerShard)

Return the location this shard will be downloaded to.
"""
download_path(cs::CompilerShard) = storage_dir("downloads", filename(cs))
"""
    mount_path(cs::CompilerShard)

Return the location this shard will be mounted to.  For `.tar.gz` shards,
this is also the location it will be extracted to.
"""
mount_path(cs::CompilerShard) = storage_dir("mounts", dir_name(cs))

"""
    mount(cs::CompilerShard)

Mount a compiler shard, if possible.  Uses `run()` so will error out if
something goes awry.  Note that this function only does something when
using a `.squashfs` shard, with a UserNS or Docker runner, on Linux.
All other combinations of shard archive type, runner and platform result
in a no-op from this function.
"""
function mount(cs::CompilerShard)
    # Skip out if we're not Linux with a UserNSRunner trying to use a .squashfs
    if !Sys.islinux() || (preferred_runner() != UserNSRunner &&
                          preferred_runner() != DockerRunner) ||
                         cs.archive_type != :squashfs ||
                         is_mounted(cs)
        return
    end

    # Signal to the user what's going on, since this probably requires sudo.
    @info("Mounting $(download_path(cs)) to $(mount_path(cs))", maxlog=5)

    # If the destination directory does not already exist, create it
    mkpath(mount_path(cs))

    # Run the mountaining
    run(`$(sudo_cmd()) mount $(download_path(cs)) $(mount_path(cs)) -o ro,loop`)
end

"""
    is_mounted(cs::CompilerShard)

Return true if the given shard is mounted.  Uses `run()` so will error out if
something goes awry.  Note that if you ask if a `.tar.gz` shard is mounted,
this method will return true if the `.squashfs` version is mounted.  This is
actually desirable, as we use this to see if we should unmount the `.squashfs`
version before unpacking the `.tar.gz` version into the same place.
"""
function is_mounted(cs::CompilerShard)
    # Note that unlike `mount()`, we don't care about the current runner,
    # because it is possible that we're checking if something is mounted
    # after switching runners.
    if !Sys.islinux()
        return false
    end

    return success(`mountpoint $(mount_path(cs))`)
end

"""
    unmount(cs::CompilerShard)

Unmount a compiler shard, if possible.  Uses `run()` so will error out if
something goes awry.  Note that this function only does something when using a
`.squashfs` shard, on Linux.  All other combinations of shard archive type
and platform result in a no-op from this function.
"""
function unmount(cs::CompilerShard; verbose::Bool = false, fail_on_error::Bool = false)
    # Only try to unmount if it's mounted
    if is_mounted(cs)
        if verbose
            @info("Unmounting $(mount_path(cs))`", maxlog=5)
        end
        try
            cmd = `$(sudo_cmd()) umount $(mount_path(cs))`
            run(pipeline(cmd, stdin=devnull, stdout=devnull, stderr=devnull))

            # Remove mountpoint directory
            rm(mount_path(cs); force=true, recursive=false)
        catch e
            # By default we don't error out if this unmounting fails
            if fail_on_error
                rethrow(e)
            end
        end
    end
end

function macos_sdk_already_installed()
    # We just check to see if there are any BaseCompilerShard downloads for
    # macOS in our downloads directory.  If so, say we have already installed it.
    files = filter(x -> occursin("BaseCompilerShard", x), readdir(storage_dir("downloads")))
    return !isempty(filter(x -> occursin("-darwin", x), files))
end


"""
    prepare_shard(cs::CompilerShard; mount_squashfs = true, verbose = false)

Download and mount the given compiler shard.  If it is a `.tar.gz` shard, it
will be unpacked into the directory given by `mount_path(cs)`.  If it is a
`.squashfs` shard, it will be mounted into the directory given by
`mount_path(cs)` (unless `mount_squashfs` is set to `false`.  This is done by
the QEMU runner, for instance, as it prefers to read the `.squashfs` files
directly, so no need to try mounting things).

If it is a macOS shard, you must have accepted the Xcode license before it will
be downloaded or mounted.
"""
function prepare_shard(cs::CompilerShard; mount_squashfs::Bool = true, verbose::Bool = false)
    # Before doing anything with a MacOS shard, make sure the user knows that
    # they must accept the Xcode EULA.  This will be skipped if either the
    # environment variable BINARYBUILDER_AUTOMATIC_APPLE has been set to `true`
    # or if the SDK has been downloaded in the past.
    global automatic_apple
    if typeof(cs.target) <: MacOS && !automatic_apple && !macos_sdk_already_installed()
        if !isinteractive()
            msg = strip("""
            This is not an interactive Julia session, so we will not prompt you
            to download and install the macOS SDK.  Because you have not agreed
            to the Xcode license terms, we will not be able to build for MacOS.
            """)
            @warn(msg)
            error("macOS SDK not installable")
        else
            msg = strip("""
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
                    error("macOS SDK not installable")
                else
                    println("Unrecognized answer. Answer `y` or `n`.")
                end
            end
        end
    end

    # Unmount previously mounted `.squashfs` version of this file if it existed.
    # If we're switching to a `.tar.gz` this is desirable because we want to
    # unpack into that direcftory.  If we're updating a `.squashfs` file, this
    # is also desirable as we're about to 
    unmount(cs; verbose=verbose)

    # For .tar.gz shards, we unpack as well
    if cs.archive_type == :targz
        # verify/redownload/reunpack the tarball, if necessary
        download_verify_unpack(
            url(cs),
            hash(cs),
            mount_path(cs);
            tarball_path = download_path(cs),
            verbose = verbose,
            force = true,
        )

        # Finally, mount this shard (if we need to)
        mount(cs)
    elseif cs.archive_type == :squashfs
        download_verify(
            url(cs),
            hash(cs),
            download_path(cs);
            verbose = verbose,
            force = true
        )

        rewrite_squashfs_uids(download_path(cs), getuid(); verbose=verbose)
        touch(string(download_path(cs), ".sha256"))

        # Finally, mount this shard (if we need to)
        if mount_squashfs
            mount(cs)
        end
    end
end


"""
    choose_shards(p::Platform; rootfs_build, bcs_build, GCC_builds,
                               LLVM_builds, archive_type)

This method chooses, given a `Platform`, which shards to download, extract and
mount, returning a list of `CompilerShard` objects.  At the moment, this always
consists of four shards, but that may not always be the case.
"""
function choose_shards(p::Platform;
            rootfs_build::VersionNumber=v"2018.09.18",
            bcs_build::VersionNumber=v"2018.09.18",
            GCC_builds::Vector{VersionNumber}=[v"4.8.5", v"7.1.0", v"8.1.0"],
            LLVM_build::VersionNumber=v"6.0.1",
            archive_type::Symbol = (use_squashfs ? :squashfs : :targz),
        )

    # If GCC version is not specificed by `p`, choose earliest possible.
    if compiler_abi(p).gcc_version == :gcc_any
        GCC_build = GCC_builds[1]
    else
        # Otherwise, match major versions with a delightfully convoluted line:
        GCC_build = GCC_builds[Dict(:gcc4 => 1, :gcc7 => 2, :gcc8 => 3)[compiler_abi(p).gcc_version]]
    end

    host_platform = Linux(:x86_64)
    shards = [
        # We always need our Rootfs for Linux(:x86_64)
        CompilerShard("Rootfs", rootfs_build, host_platform, archive_type),
        # BCS contains our binutils, libc, etc...
        CompilerShard("BaseCompilerShard", bcs_build, host_platform, archive_type; target=p),
        # GCC gets a particular version that was chosen above
        CompilerShard("GCC", GCC_build, host_platform, archive_type; target=p),
        # God bless LLVM; a single binary that targets all platforms!
        CompilerShard("LLVM", LLVM_build, host_platform, archive_type),
    ]

    # If we're not building for the host platform, then add host shard for things
    # like HOSTCC, HOSTCXX, etc...
    if !(typeof(p) <: typeof(host_platform)) || (arch(p) != arch(host_platform) || libc(p) != libc(host_platform))
        push!(shards, CompilerShard("BaseCompilerShard", bcs_build, host_platform, archive_type; target=host_platform))
        push!(shards, CompilerShard("GCC", GCC_build, host_platform, archive_type; target=host_platform))
    end
    return shards
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
    expand_gcc_versions(p::Platform)

Given a `Platform`, returns an array of `Platforms` with a spread of identical
entries with the exception of the `gcc_version` member of the `CompilerABI`
struct within the `Platform`.  This is used to take, for example, a list of
supported platforms and expand them to include all possible GCC versions for
the purposes of ABI matching.  If the given `Platform` already specifies a
GCC version (as opposed to `:gcc_any`) only that `Platform` is returned.
"""
function expand_gcc_versions(p::Platform)
    # If this platform cannot be expanded, then exit out fast here.
    if compiler_abi(p).gcc_version != :gcc_any
        return [p]
    end

    # Otherwise, generate new versions!
    gcc_versions = [:gcc4, :gcc7, :gcc8]
    function replace_gcc(p, gcc_version)
        new_cabi = CompilerABI(gcc_version, compiler_abi(p).cxx_abi)
        return typeof(p)(arch(p); libc=libc(p), call_abi=call_abi(p), compiler_abi=new_cabi)
    end
    return replace_gcc.(Ref(p), gcc_versions)
end

function expand_gcc_versions(ps::Vector{P}) where {P <: Platform}
    expanded_ps = Platform[]
    for p in ps
        append!(expanded_ps, expand_gcc_versions(p))
    end
    return expanded_ps
end

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
    rewrite_squashfs_uids(path, new_uid)

In order for the sandbox to work well, we need to have the uids of the squashfs
images match the uid of the current unpriviledged user. Unfortunately there is
no mount-time option to do this for us. However, fortunately, squashfs is simple
enough that if the id table is uncompressed, we can just manually patch the uids
to be what we need. This functions performs this operation, by rewriting all
uids/gids to new_uid.
"""
function rewrite_squashfs_uids(path, new_uid; verbose::Bool = false)
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
       if uid == new_uid
           return
       end
       if verbose
           @info("Rewriting $(basename(path)) from UID $(uid) -> $(new_uid)")
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
    shard_mappings(shards::Vector{CompilerShard})

Return the default mappings for a set of compiler shards
"""
function shard_mappings(shards::Vector{CompilerShard})
    mappings = Pair{String,String}[]
    for shard in shards
        # No mapping for the main rootfs shard
        if lowercase(shard.name) == "rootfs"
            continue
        end

        # For everything else, map it into its proper place
        push!(mappings, mount_path(shard) => map_target(shard))
    end

    # Reverse mapping order, because `sandbox` reads them backwards
    reverse!(mappings)
    return mappings
end
