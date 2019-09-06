export supported_platforms, expand_gcc_versions, expand_gfortran_versions, expand_cxxstring_abis

import Pkg.Artifacts: load_artifacts_toml, ensure_all_artifacts_installed

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

    # Things like Windows(:x86_64; compiler_abi=CompilerABI(libgfortran_version=v"3"))
    target::Union{Nothing,Platform}

    # Usually `Linux(:x86_64, libc=:musl)`, but for things like QEMU could be MacOS(:x86_64)
    host::Platform
    
    # :unpacked or :squashfs.  Possibly more in the future.
    archive_type::Symbol

    function CompilerShard(name, version, host, archive_type; target = nothing)
        # Ensure we have the right archive type
        if !(archive_type in (:squashfs, :unpacked))
            error("Invalid archive type '$(archive_type)'")
        end

        # If host or target are unparsed, parse them:
        if isa(host, AbstractString)
            host = platform_key_abi(host)
        end
        if isa(target, AbstractString)
            target = platform_key_abi(target)
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
    return P(arch(p); libc=libc(p), call_abi=call_abi(p))
end

"""
    artifact_name(cs::CompilerShard)

Return the bound artifact name for a particular shard.
"""
function artifact_name(cs::CompilerShard)
    target_str = ""
    if cs.target != nothing
        target_str = "-$(triplet(cs.target))"
    end
    ext = Dict(:squashfs => "squashfs", :unpacked => "unpacked")[cs.archive_type]
    return "$(cs.name)$(target_str).v$(cs.version).$(triplet(cs.host)).$(ext)"
end

# The inverse of `artifact_name(cs)`
function CompilerShard(art_name::String)
    m = match(r"^([^-]+)(?:-(.+))?\.(v[\d\.]+)\.([^0-9].+-.+)\.(\w+)", art_name)
    if m === nothing
        error("Unable to parse '$(art_name)'")
    end
    return CompilerShard(
        m.captures[1],
        VersionNumber(m.captures[3]),
        m.captures[4],
        Symbol(m.captures[5]);
        target=m.captures[2]
    )
end

const ALL_SHARDS = Ref{Union{Vector{CompilerShard},Nothing}}(nothing)
function all_compiler_shards()
    if ALL_SHARDS[] === nothing
        artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
        artifact_dict = load_artifacts_toml(artifacts_toml)

        ALL_SHARDS[] = CompilerShard[]
        for name in keys(artifact_dict)
            cs = try
                CompilerShard(name)
            catch
                continue
            end
            push!(ALL_SHARDS[], cs)
        end
    end
    return ALL_SHARDS[]
end

"""
    shard_path(cs::CompilerShard)

Return the path to this shard on-disk; for unpacked shards, this is a directory.
For squashfs shards, this is a file.  This will not cause a shard to be downloaded.
"""
function shard_path(cs::CompilerShard)
    if cs.shard_type == :squashfs
        mutable_artifacts_toml = joinpath(dirname(@__DIR__), "MutableArtifacts.toml")
        artifacts_dict = artifact_meta(
            artifact_name(cs),
            artifacts_toml;
            platform=something(cs.target, cs.host),
        )
    end

    artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
    artifacts_dict = artifact_meta(
        artifact_name(cs),
        artifacts_toml;
        platform=something(cs.target, cs.host),
    )
    if artifacts_dict == nothing
        error("CompilerShard $(artifact_name(cs)) not registered in Artifacts.toml!")
    end
    
    return artifact_path(artifacts_dict["git-tree-sha1"])
end

"""
    map_target(cs::CompilerShard)

Return the location this compiler shard should be mounted at.  We basically
analyze the name and platform of this shard and return a path based on that.
"""
function map_target(cs::CompilerShard)
    if lowercase(cs.name) == "rootfs"
        return "/"
    else
        return joinpath("/opt", triplet(something(cs.target, cs.host)), "$(cs.name)-$(cs.version)")
    end
end

function mount_path(cs::CompilerShard, build_prefix::AbstractString)
    if cs.archive_type == :squashfs
        return joinpath(build_prefix, "mounts", artifact_name(cs))
    else
        name = artifact_name(cs)
        artifacts_toml = joinpath(@__DIR__, "..", "Artifacts.toml")
        return artifact_path(artifact_hash(name, artifacts_toml; platform=cs.host))
    end
end

"""
    mount(cs::CompilerShard, build_prefix::String)

Mount a compiler shard, if possible.  Uses `run()` so will error out if
something goes awry.  Note that this function only does something when
using a `.squashfs` shard, with a UserNS or Docker runner, on Linux.
All other combinations of shard archive type, runner and platform result
in a no-op from this function.
"""
function mount(cs::CompilerShard, build_prefix::AbstractString; verbose::Bool = false)
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
            @error(msg)
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

    # Easy out if we're not Linux with a UserNSRunner trying to use a .squashfs
    if !Sys.islinux() || (preferred_runner() != UserNSRunner &&
                          preferred_runner() != DockerRunner) ||
                         cs.archive_type != :squashfs
        # We'll just give back the artifact path in this case
        return mount_path(cs, build_prefix)
    end

    # If it's already mounted, also just return the mount path
    if is_mounted(cs, build_prefix)
        return mount_path(cs, build_prefix)
    end

    # Ensure that we've got a UID-appropriate .squashfs
    squashfs_path = generate_per_uid_squashfs(cs; verbose=verbose)

    # Signal to the user what's going on, since this might require sudo.
    mpath = mount_path(cs, build_prefix)
    if verbose
        @debug("Mounting $(squashfs_path) to $(mpath)")
    end

    # If the destination directory does not already exist, create it
    mkpath(mpath)

    # Run the mountaining
    run(`$(sudo_cmd()) mount $(squashfs_path) $(mpath) -o ro,loop`)

    # Give back the mount path
    return mpath
end

"""
    is_mounted(cs::CompilerShard, build_prefix::String)

Return true if the given shard is mounted.  Uses `run()` so will error out if
something goes awry.
"""
function is_mounted(cs::CompilerShard, build_prefix::AbstractString)
    return success(`mountpoint $(mount_path(cs, build_prefix))`)
end

"""
    unmount(cs::CompilerShard, build_prefix::String)

Unmount a compiler shard from a given build prefix, if possible.  Uses `run()`
so will error out if something goes awry.  Note that this function only does
something when using a squashfs shard on Linux.  All other combinations of
shard archive type and platform result in a no-op.
"""
function unmount(cs::CompilerShard, build_prefix::String; verbose::Bool = false, fail_on_error::Bool = false)
    # Only try to unmount if it's mounted
    if is_mounted(cs, build_prefix)
        mpath = mount_path(cs, build_prefix)
        if verbose
            @debug("Unmounting $(mpath)`")
        end
        try
            cmd = `$(sudo_cmd()) umount $(mpath)`
            run(cmd, (devnull, devnull, devnull))

            # Remove mountpoint directory
            rm(mpath; force=true, recursive=false)
        catch e
            # By default we don't error out if this unmounting fails
            if e isa InterruptException || fail_on_error
                rethrow(e)
            end
        end
    end
end

function macos_sdk_already_installed()
    artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
    # We just check to see if there are any BaseCompilerShard downloads for
    # macOS in our downloads directory.  If so, say we have already installed it.
    files = filter(x -> occursin("BaseCompilerShard", x) || occursin("GCC", x), readdir(storage_dir("downloads")))
    return !isempty(filter(x -> occursin("-darwin", x), files))
end

function select_gcc_version(p::Platform,
             GCC_builds::Vector{VersionNumber} = [v"4.8.5", v"5.2.0", v"6.1.0", v"7.1.0", v"8.1.0"],
             preferred_gcc_version::VersionNumber = GCC_builds[1],
         )
    # Determine which GCC build we're going to match with this CompilerABI:
    GCC_builds = Pkg.BinaryPlatforms.gcc_version(compiler_abi(p), GCC_builds)

    if isempty(GCC_builds)
        error("Impossible CompilerABI constraints $(cabi)!")
    end

    # Otherwise, choose the version that is closest to our preferred version
    ver_to_tuple(v) = (Int(v.major), Int(v.minor), Int(v.patch))
    pgv = ver_to_tuple(preferred_gcc_version)
    closest_idx = findmin([abs.(pgv .- ver_to_tuple(x)) for x in GCC_builds])[2]
    return GCC_builds[closest_idx]
end


"""
    choose_shards(p::Platform; rootfs_build, ps_build, GCC_builds,
                               LLVM_builds, archive_type)

This method chooses, given a `Platform`, which shards to download, extract and
mount, returning a list of `CompilerShard` objects.  At the moment, this always
consists of four shards, but that may not always be the case.
"""
function choose_shards(p::Platform;
            compilers::Vector{Symbol} = [:c],
            rootfs_build::VersionNumber=v"2019.9.5",
            ps_build::VersionNumber=v"2019.8.30",
            GCC_builds::Vector{VersionNumber}=[v"4.8.5", v"5.2.0", v"6.1.0", v"7.1.0", v"8.1.0"],
            LLVM_build::VersionNumber=v"8.0.0",
            Rust_build::VersionNumber=v"1.18.3",
            Go_build::VersionNumber=v"1.13",
            archive_type::Symbol = (use_squashfs ? :squashfs : :unpacked),
            bootstrap_list::Vector{Symbol} = bootstrap_list,
            # We prefer the oldest GCC version by default
            preferred_gcc_version::VersionNumber = GCC_builds[1],
        )

    GCC_build = select_gcc_version(p, GCC_builds, preferred_gcc_version)
    # Our host platform is x86_64-linux-musl
    host_platform = Linux(:x86_64; libc=:musl)

    shards = CompilerShard[]
    if isempty(bootstrap_list)
        append!(shards, [
            CompilerShard("Rootfs", rootfs_build, host_platform, archive_type),
            # Shards for the target architecture
            CompilerShard("PlatformSupport", ps_build, host_platform, archive_type; target=p),
        ])

        target_is_host = (typeof(p) <: typeof(host_platform)) && (arch(p) == arch(host_platform) && libc(p) == libc(host_platform))

        if :c in compilers
            append!(shards, [
                CompilerShard("GCCBootstrap", GCC_build, host_platform, archive_type; target=p),
                CompilerShard("LLVMBootstrap", LLVM_build, host_platform, archive_type),
            ])
            # If we're not building for the host platform, then add host shard for host tools
            if !target_is_host
                append!(shards, [
                    CompilerShard("PlatformSupport", ps_build, host_platform, archive_type; target=host_platform),
                    CompilerShard("GCCBootstrap", GCC_build, host_platform, archive_type; target=host_platform),
                ])
            end
        end

        if :rust in compilers
            append!(shards, [
                CompilerShard("RustBase", Rust_build, host_platform, archive_type),
                CompilerShard("RustToolchain", Rust_build, p, archive_type),
            ])

            if !target_is_host
                push!(shards, CompilerShard("RustToolchain", Rust_build, host_platform, archive_type))
            end
        end

        if :go in compilers
            push!(shards, CompilerShard("Go", Go_build, host_platform, archive_type))
        end
    else
        function find_latest_version(name)
            versions = [cs.version for cs in all_compiler_shards()
                if cs.name == name && cs.archive_type == archive_type && (something(cs.target, p) == p)
            ]
            return maximum(versions)
        end

        if :rootfs in bootstrap_list
            push!(shards, CompilerShard("Rootfs", find_latest_version("Rootfs"), host_platform, archive_type))
        end
        if :platform_support in bootstrap_list
            push!(shards, CompilerShard("PlatformSupport", find_latest_version("PlatformSupport"), host_platform, archive_type; target=p))
        end
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
        Linux(:i686, libc=:musl),
        Linux(:x86_64, libc=:musl),
        Linux(:aarch64, libc=:musl),
        Linux(:armv7l, libc=:musl),

        # BSDs
        MacOS(:x86_64),
        FreeBSD(:x86_64),

        # Windows
        Windows(:i686),
        Windows(:x86_64),
    ]
end

function replace_libgfortran_version(p::Platform, libgfortran_version::VersionNumber)
    new_cabi = CompilerABI(compiler_abi(p); libgfortran_version=libgfortran_version)
    return typeof(p)(arch(p); libc=libc(p), call_abi=call_abi(p), compiler_abi=new_cabi)
end

function replace_cxxstring_abi(p::Platform, cxxstring_abi::Symbol)
    new_cabi = CompilerABI(compiler_abi(p), cxxstring_abi=cxxstring_abi)
    return typeof(p)(arch(p); libc=libc(p), call_abi=call_abi(p), compiler_abi=new_cabi)
end

"""
    expand_gfortran_versions(p::Platform)

Given a `Platform`, returns an array of `Platforms` with a spread of identical
entries with the exception of the `gcc_version` member of the `CompilerABI`
struct within the `Platform`.  This is used to take, for example, a list of
supported platforms and expand them to include multiple GCC versions for
the purposes of ABI matching.  If the given `Platform` already specifies a
GCC version (as opposed to `nothing`) only that `Platform` is returned.
"""
function expand_gfortran_versions(p::Platform)
    # If this platform cannot be expanded, then exit out fast here.
    if compiler_abi(p).libgfortran_version != nothing
        return [p]
    end

    # Otherwise, generate new versions!
    libgfortran_versions = [v"3", v"4", v"5"]
    return replace_libgfortran_version.(Ref(p), libgfortran_versions)
end
function expand_gfortran_versions(ps::Vector{P}) where {P <: Platform}
    return collect(Iterators.flatten(expand_gfortran_versions.(ps)))
end
@deprecate expand_gcc_versions expand_gfortran_versions

"""
    expand_cxxstring_abis(p::Platform)

Given a `Platform`, returns an array of `Platforms` with a spread of identical
entries with the exception of the `cxxstring_abi` member of the `CompilerABI`
struct within the `Platform`.  This is used to take, for example, a list of
supported platforms and expand them to include multiple GCC versions for
the purposes of ABI matching.  If the given `Platform` already specifies a
GCC version (as opposed to `nothing`) only that `Platform` is returned.
"""
function expand_cxxstring_abis(p::Platform)
    # If this platform cannot be expanded, then exit out fast here.
    if compiler_abi(p).cxxstring_abi != nothing
        return [p]
    end

    # Otherwise, generate new versions!
    gcc_versions = [:cxx03, :cxx11]
    return replace_cxxstring_abi.(Ref(p), gcc_versions)
end
function expand_cxxstring_abis(ps::Vector{P}) where {P <: Platform}
    return collect(Iterators.flatten(expand_cxxstring_abis.(ps)))
end

"""
    download_all_shards(; verbose::Bool=false)

Helper function to download all shards/helper binaries so that no matter what
happens, you don't need an internet connection to build your precious, precious
binaries.
"""
function download_all_artifacts(; verbose::Bool = false)
    artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
    ensure_all_artifacts_installed(artifacts_toml; include_lazy=true)
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
