## This file contains functionality related to the actual layout of the files
#  on disk.  Things like the name of where downloads are stored, and what
#  environment variables must be updated to, etc...
import Base: convert, joinpath, show, withenv
using SHA

export Prefix, bindir, libdirs, includedir, logdir, activate, deactivate,
       isinstalled,
       install, uninstall, list_tarball_files, verify, temp_prefix
import Pkg.PlatformEngines: package

# Temporary hack around https://github.com/JuliaLang/julia/issues/26685
function safe_isfile(path)
    try
        return isfile(path)
    catch e
        if typeof(e) <: Base.IOError && e.code == Base.UV_EINVAL
            return false
        end
        rethrow(e)
    end
end

"""
    temp_prefix(func::Function)

Create a temporary prefix, passing the prefix into the user-defined function so
that build/packaging operations can occur within the temporary prefix, which is
then cleaned up after all operations are finished.  If the path provided exists
already, it will be deleted.

Usage example:

    out_path = abspath("./libfoo")
    temp_prefix() do p
        # <insert build steps here>

        # tarball up the built package
        tarball_path, tarball_hash = package(p, out_path)
    end
"""
function temp_prefix(func::Function)
    # Helper function to create a docker-mountable temporary directory
    function _tempdir()
        @static if Sys.isapple()
            # Docker, on OSX at least, can only mount from certain locations by
            # default, so we ensure all our temporary directories live within
            # those locations so that they are accessible by Docker.
            return realpath("/tmp")
        else
            return realpath(tempdir())
        end
    end

    mktempdir(_tempdir()) do path
        prefix = Prefix(path)

        # Run the user function
        func(prefix)
    end
end

# This is the default prefix that things get saved to, it is initialized within
# __init__() on first module load.
global_prefix = nothing
struct Prefix
    path::String

    """
        Prefix(path::AbstractString)

    A `Prefix` represents a binary installation location.
    """
    function Prefix(path::AbstractString)
        # Canonicalize immediately, create the overall prefix, then return
        path = abspath(path)
        mkpath(path)
        return new(path)
    end
end

# Make it easy to bandy about prefixes as paths.  There has got to be a better
# way to do this, but it's hackin' time, so just go with the flow.
joinpath(prefix::Prefix, args...) = joinpath(prefix.path, args...)
joinpath(s::AbstractString, prefix::Prefix, args...) = joinpath(s, prefix.path, args...)

convert(::Type{AbstractString}, prefix::Prefix) = prefix.path
show(io::IO, prefix::Prefix) = show(io, "Prefix($(prefix.path))")

"""
    bindir(prefix::Prefix)

Returns the binary directory for the given `prefix`.
"""
function bindir(prefix::Prefix)
    return joinpath(prefix, "bin")
end

"""
    libdirs(prefix::Prefix, platform = platform_key_abi())

Returns the library directories for the given `prefix` (note that this differs
between unix systems and windows systems, and between 32- and 64-bit systems).
"""
function libdirs(prefix::Prefix, platform = platform_key_abi())
    if Sys.iswindows(platform)
        return [joinpath(prefix, "bin")]
    else
        if wordsize(platform) == 64
            return [joinpath(prefix, "lib64"), joinpath(prefix, "lib")]
        else
            return [joinpath(prefix, "lib")]
        end
    end
end

"""
    includedir(prefix::Prefix)

Returns the include directory for the given `prefix`
"""
function includedir(prefix::Prefix)
    return joinpath(prefix, "include")
end

"""
    logdir(prefix::Prefix)

Returns the logs directory for the given `prefix`.
"""
function logdir(prefix::Prefix)
    return joinpath(prefix, "logs")
end

"""
    package(prefix::Prefix, output_base::AbstractString,
            version::VersionNumber;
            platform::Platform = platform_key_abi(),
            verbose::Bool = false, force::Bool = false)

Build a tarball of the `prefix`, storing the tarball at `output_base`,
appending a version number, a platform-dependent suffix and a file extension.
If no platform is given, defaults to current platform. Runs an `audit()` on the
`prefix`, to ensure that libraries can be `dlopen()`'ed, that all dependencies
are located within the prefix, etc... See the [`audit()`](@ref) documentation
for a full list of the audit steps.  Returns the full path to and hash of the
generated tarball.
"""
function package(prefix::Prefix,
                 output_base::AbstractString,
                 version::VersionNumber;
                 platform::Platform = platform_key_abi(),
                 verbose::Bool = false,
                 force::Bool = false)
    # Calculate output path
    out_path = "$(output_base).v$(version).$(triplet(platform)).tar.gz"

    if isfile(out_path)
        if force
            if verbose
                @info("$(out_path) already exists, force-overwriting...")
            end
            rm(out_path; force=true)
        else
            msg = replace(strip("""
            $(out_path) already exists, refusing to package into it without
            `force` being set to `true`.
            """), "\n" => " ")
            error(msg)
        end
    end

    # Copy our build prefix into an Artifact
    tree_hash = create_artifact() do art_path
        for f in readdir(prefix.path)
            cp(joinpath(prefix.path, f), joinpath(art_path, f))
        end

        # Attempt to maintain permissions of original owning dir
        try
            chmod(art_path, stat(prefix.path).mode)
        catch e
            if verbose
                @warn("Could not chmod $(art_path):", e)
            end
        end
    end

    # Calculate git tree hash
    if verbose
        @info("Tree hash of contents of $(basename(out_path)): $(tree_hash)")
    end

    tarball_hash = archive_artifact(tree_hash, out_path; honor_overrides=false)
    if verbose
        @info("SHA256 of $(basename(out_path)): $(tarball_hash)")
    end

    return out_path, tarball_hash, tree_hash
end




function symlink_tree(src::AbstractString, dest::AbstractString)
    for (root, dirs, files) in walkdir(src)
        # Create all directories
        for d in dirs
            # If `d` is itself a symlink, recreate that symlink
            d_path = joinpath(root, d)
            if islink(d_path)
                symlink(readlink(d_path), joinpath(dest, relpath(root, src), d))
            else
                mkpath(joinpath(dest, relpath(root, src), d))
            end
        end

        # Symlink all files
        for f in files
            src_file = joinpath(root, f)
            dest_file = joinpath(dest, relpath(root, src), f)
            if isfile(dest_file)
                # Find source artifact that this pre-existent destination file belongs to
                dest_artifact_source = realpath(dest_file)
                while occursin("artifacts", dest_artifact_source) && basename(dirname(dest_artifact_source)) != "artifacts"
                    dest_artifact_source = dirname(dest_artifact_source)
                end
                @warn("Symlink $(f) from artifact $(basename(src)) already exists in artifact $(basename(dest_artifact_source))")
            else
                # If it's already a symlink, copy over the exact symlink target
                if islink(src_file)
                    symlink(readlink(src_file), dest_file)
                else
                    # Otherwise, point it at the proper location
                    symlink(relpath(src_file, dirname(dest_file)), dest_file)
                end
            end
        end
    end
end

function unsymlink_tree(src::AbstractString, dest::AbstractString)
    for (root, dirs, files) in walkdir(src)
        # Unsymlink all symlinked directories, non-symlink directories will be culled in audit.
        for d in dirs
            dest_dir = joinpath(dest, relpath(root, src), d)
            if islink(dest_dir)
                rm(dest_dir)
            end
        end

        # Unsymlink all symlinked files
        for f in files
            dest_file = joinpath(dest, relpath(root, src), f)
            if islink(dest_file)
                rm(dest_file)
            end
        end
    end
end

function setup(source::SetupSource{GitSource}, targetdir, verbose)
    mkpath(targetdir)
    # Chop off the `.git` at the end of the source.path
    repo_dir = joinpath(targetdir, basename(source.path)[1:end-4])
    if verbose
        @info "Cloning $(basename(source.path)) to $(basename(targetdir))..."
    end
    LibGit2.with(LibGit2.clone(source.path, repo_dir)) do repo
        LibGit2.checkout!(repo, source.hash)
    end
end

function setup(source::SetupSource{ArchiveSource}, targetdir, verbose)
    mkpath(targetdir)
    # Extract with host tools because it is _much_ faster on e.g. OSX.
    # If this becomes a compatibility problem, we'll just have to install
    # our own `tar` and `unzip` through BP as dependencies for BB.
    cd(targetdir) do
        if any(endswith(source.path, ext) for ext in tar_extensions)
            if verbose
                @info "Extracting tarball $(basename(source.path))..."
            end
            tar_flags = verbose ? "xvof" : "xof"
            run(`tar -$(tar_flags) $(source.path)`)
        elseif endswith(source.path, ".zip")
            if verbose
                @info "Extracting zipball $(basename(source.path))..."
            end
            run(`unzip -q $(source.path)`)
        else
            error("Unknown archive format")
        end
    end
end

function setup(source::SetupSource{FileSource}, target, verbose)
    if verbose
        @info "Copying $(basename(source.path)) in $(basename(target))..."
    end
    cp(source.path, target)
end

function setup(source::SetupSource{DirectorySource}, targetdir, verbose)
    # Need to strip the trailing separator also here
    srcpath = isdirpath(source.path) ? dirname(source.path) : source.path
    if verbose
        @info "Copying content of $(basename(srcpath)) in $(basename(targetdir))..."
    end
    for file_dir in readdir(srcpath)
        # Copy the content of the source directory to the destination. Note that we DO follow symlinks here!
        # This is to support symlink patchsets across multiple versions of GCC, etc...
        cp(joinpath(srcpath, file_dir), joinpath(targetdir, basename(file_dir)); follow_symlinks=true)
    end
end

function setup(source::PatchSource, targetdir, verbose)
    if verbose
        @info "Adding patch $(source.name)..."
    end
    patches_dir = joinpath(targetdir, "patches")
    mkdir(patches_dir)
    open(f->write(f, source.patch), joinpath(patches_dir, source.name), "w")
end

"""
    setup_workspace(build_path::String, sources::Vector{SetupSource};
                    verbose::Bool = false)

Sets up a workspace within `build_path`, creating the directory structure
needed by further steps, unpacking the source within `build_path`, and defining
the environment variables that will be defined within the sandbox environment.

This method returns the `Prefix` to install things into, and the runner
that can be used to launch commands within this workspace.
"""
function setup_workspace(build_path::AbstractString, sources::Vector;
                         verbose::Bool = false)
    # Use a random nonce to make detection of paths in embedded binary easier
    nonce = randstring()
    workspace = joinpath(build_path, nonce)
    mkdir(workspace)

    # We now set up two directories, one as a source dir, one as a dest dir
    srcdir = joinpath(workspace, "srcdir")
    destdir = joinpath(workspace, "destdir")
    metadir = joinpath(workspace, "metadir")
    wrapperdir = joinpath(workspace, "compiler_wrappers")
    mkdir.((srcdir, destdir, metadir))

    # Setup all sources
    for source in sources
        if isa(source, SetupSource)
            target = joinpath(srcdir, source.target)
            # Trailing directory separator matters for `basename`, so let's strip it
            # to avoid confusion
            target = isdirpath(target) ? dirname(target) : target
            setup(source, target, verbose)
        else
            setup(source, srcdir, verbose)
        end
    end

    # Return the build prefix
    return Prefix(realpath(workspace))
end


"""
    setup_dependencies(prefix::Prefix, dependencies::Vector{PackageSpec})

Given a list of JLL package specifiers, install their artifacts into the build prefix.
The artifacts are installed into the global artifact store, then copied into a temporary location,
then finally symlinked into the build prefix.  This allows us to (a) save download bandwidth by not
downloading the same artifacts over and over again, (b) maintain separation in the event of
catastrophic containment failure, avoiding hosing the main system if a build script decides to try
to modify the dependent artifact files, and (c) keeping a record of what files are a part of
dependencies as opposed to the package being built, in the form of symlinks to a specific artifacts
directory.
"""
function setup_dependencies(prefix::Prefix, dependencies::Vector{PkgSpec}, platform::Platform)
    artifact_paths = String[]
    if isempty(dependencies)
        return artifact_paths
    end

    # Immediately copy so we don't clobber the caller's dependencies
    dependencies = deepcopy(dependencies)

    # We're going to create a project and install all dependent packages within
    # it, then create symlinks from those installed products to our build prefix

    # Update registry first, in case the jll packages we're looking for have just been registered/updated
    Pkg.Registry.update()

    mkpath(joinpath(prefix, "artifacts"))
    deps_project = joinpath(prefix, ".project")
    Pkg.activate(deps_project) do
        # Find UUIDs for all dependencies
        ctx = Pkg.Types.Context()
        # Fredrik thinks this is unnecessary, and he's probably right
        #Pkg.Operations.resolve_versions!(ctx, dependencies)

        # Add all dependencies
        Pkg.add(dependencies; platform=platform)

        # Filter out everything that doesn't end in `_jll`
        dependencies = filter(x -> endswith(getname(x), "_jll"), dependencies)

        # Load their Artifacts.toml files
        for dep in dependencies
            if VERSION >= v"1.4.0-rc2.0"
                dep_path = Pkg.Operations.source_path(ctx, dep)
            else
                dep_path = Pkg.Operations.source_path(dep)
            end
            name = getname(dep)

            # Skip dependencies that didn't get installed?
            if dep_path === nothing
                @warn("Dependency $(name) not installed, depsite our best efforts!")
                continue
            end

            # Load the Artifacts.toml file
            artifacts_toml = joinpath(dep_path, "Artifacts.toml")
            if !isfile(artifacts_toml)
                @warn("Dependency $(name) does not have an Artifacts.toml at $(artifacts_toml)!")
                continue
            end

            # Get the path to the main artifact
            artifact_hash = Pkg.Artifacts.artifact_hash(name[1:end-4], artifacts_toml; platform=platform)
            if artifact_hash === nothing
                @warn("Dependency $(name) does not have a mapping for $(name[1:end-4])!")
                continue
            end

            # Copy the artifact from the global installation location into this build-specific artifacts collection
            src_path = Pkg.Artifacts.artifact_path(artifact_hash)
            dest_path = joinpath(prefix, "artifacts", basename(src_path))
            cp(src_path, dest_path)

            # Keep track of our dep paths for later symlinking
            push!(artifact_paths, dest_path)
        end
    end

    # Symlink all the deps into the prefix
    for art_path in artifact_paths
        symlink_tree(art_path, joinpath(prefix, "destdir"))
    end

    # Return the artifact_paths so that we can clean them up later
    return artifact_paths
end

function cleanup_dependencies(prefix::Prefix, artifact_paths)
    for art_path in artifact_paths
        unsymlink_tree(art_path, joinpath(prefix, "destdir"))
    end
end
