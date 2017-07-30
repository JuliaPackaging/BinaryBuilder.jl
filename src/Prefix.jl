## This file contains functionality related to the actual layout of the files
#  on disk.  Things like the name of where downloads are stored, and what
#  environment variables must be updated to, etc...
import Base: convert, joinpath, show
using SHA

# This is the default prefix that things get saved to, it is initialized within
# __init__() on first module load.
global_prefix = nothing
immutable Prefix
    path::String

    """
    `Prefix(path::AbstractString)`
    
    A `Prefix` represents a binary installation location.  There is a default
    global `Prefix` (available at `BinDeps2.global_prefix`) that packages are
    installed into by default, however custom prefixes can be created trivially
    by simply constructing a `Prefix` with a given `path` to install binaries
    into, likely including folders such as `bin`, `lib`, etc...
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

function _tempdir()
    @static if is_apple()
        # Docker, on OSX at least, can only mount from certain locations by
        # default, so we ensure all our temporary directories live within
        # those locations so that they are accessible by Docker.
        return "/tmp"
    else
        return tempdir()
    end
end

"""
`temp_prefix(func::Function)`

Create a temporary prefix, passing the prefix into the user-defined function so
that build/packaging operations can occur within the temporary prefix, which is
then cleaned up after all operations are finished.  If the path provided exists
already, it will be deleted.

Usage example:

    out_path = abspath("./libfoo")
    temp_prefix() do p
        # <insert build steps here>

        # tarball up the built package
        package(p, out_path)
    end
"""
function temp_prefix(func::Function)
    mktempdir(_tempdir()) do path
        prefix = Prefix(path)
        
        # Run the user function
        func(prefix)
    end
end

"""
`split_PATH(PATH::AbstractString = ENV["PATH"])`

Splits a string such as the  `PATH` environment variable into a list of strings
according to the path separation rules for the current platform.
"""
function split_PATH(PATH::AbstractString = ENV["PATH"])
    @static if is_windows()
        return split(PATH, ";")
    else
        return split(PATH, ":")
    end
end

"""
`join_PATH(PATH::Vector{AbstractString})`

Given a list of strings, return a joined string suitable for the `PATH`
environment variable appropriate for the current platform.
"""
function join_PATH{S<:AbstractString}(paths::Vector{S})
    @static if is_windows()
        return join(paths, ";")
    else
        return join(paths, ":")
    end
end

"""
`bindir(prefix::Prefix)`

Returns the binary directory for the given `prefix`.
"""
function bindir(prefix::Prefix)
    return joinpath(prefix, "bin")
end

"""
`libdir(prefix::Prefix)`

Returns the library directory for the given `prefix` (not ethat this differs
between unix systems and windows systems).
"""
function libdir(prefix::Prefix)
    @static if is_windows()
        return joinpath(prefix, "bin")
    else
        return joinpath(prefix, "lib")
    end
end

"""
`logdir(prefix::Prefix)`

Returns the logs directory for the given `prefix`.
"""
function logdir(prefix::Prefix)
    return joinpath(prefix, "logs")
end

"""
`activate(prefix::Prefix)`

Prepends paths to environment variables so that binaries and libraries are
available to Julia.
"""
function activate(prefix::Prefix)
    # Add to PATH
    paths = split_PATH()
    if !(bindir(prefix) in paths)
        prepend!(paths, [bindir(prefix)])
    end
    ENV["PATH"] = join_PATH(paths)

    # Add to DL_LOAD_PATH
    if !(libdir(prefix) in Libdl.DL_LOAD_PATH)
        prepend!(Libdl.DL_LOAD_PATH, [libdir(prefix)])
    end
    return nothing
end

"""
`activate(func::Function, prefix::Prefix)`

Prepends paths to environment variables so that binaries and libraries are
available to Julia, calls the user function `func`, then `deactivate()`'s
the `prefix`` again.
"""
function activate(func::Function, prefix::Prefix)
    activate(prefix)
    func()
    deactivate(prefix)
end

"""
`deactivate(prefix::Prefix)`

Removes paths added to environment variables by `activate()`
"""
function deactivate(prefix::Prefix)
    # Remove from PATH
    paths = split_PATH()
    filter!(p -> p != bindir(prefix), paths)
    ENV["PATH"] = join_PATH(paths)

    # Remove from DL_LOAD_PATH
    filter!(p -> p != libdir(prefix), Libdl.DL_LOAD_PATH)
    return nothing
end

"""
`platform_suffix(kernel::Symbol = Sys.KERNEL, arch::Symbol = Sys.ARCH)`

Returns the platform-dependent suffix of a packaging tarball for the current
platform, or any other though the use of the `kernel` and `arch` parameters.
"""
function platform_suffix(kernel::Symbol = Sys.KERNEL, arch::Symbol = Sys.ARCH)
    const kern_dict = Dict(
        :Darwin => "mac",
        :Apple => "mac",
        :Linux => "linux",
        :FreeBSD => "bsd",
        :OpenBSD => "bsd",
        :NetBSD => "bsd",
        :DragonFly => "bsd",
        :Windows => "win",
        :NT => "win",
    )

    const arch_dict = Dict(
        :x86_64 => "64",
        :i686 => "32",
        :powerpc64le => "ppc64le",
        :ppc64le => "ppc64le",
        :arm => "arm",
        :aarch64 => "arm64",
    )    
    return "$(kern_dict[kernel])$(arch_dict[arch])"
end

"""
`extract_platform_suffix(path::AbstractString)`

Given the path to a tarball, return the platform suffix of that tarball.
If none can be found, prints a warning and return the current platform
suffix.
"""
function extract_platform_suffix(path::AbstractString)
    idx = rsearch(path, '_')
    if idx == 0
        warn("Could not extract the platform suffix of $(path); continuing...")
        return platform_suffix()
    end
    if endswith(path, ".tar.gz")
        return path[idx+1:end-7]
    else
        return path[idx+1:end]
    end
end

"""
`package(prefix::Prefix, tarball_base::AbstractString,
         ignore_audit_errors::Bool = false, verbose::Bool = false)`

Build a tarball of the `prefix`, storing the tarball at `tarball_base` plus a
platform-dependent suffix and a file extension.  Runs an `audit()` on the
`prefix`, to ensure that libraries can be `dlopen()`'ed, that all dependencies
are located within the prefix, etc... See the `audit()` documentation for a
full list of the audit steps.

Returns the full path to the generated tarball.
"""
function package(prefix::Prefix, tarball_base::AbstractString;
                 ignore_audit_errors::Bool = false, verbose::Bool = false)
    # First calculate the output path given our tarball_base
    platfix = platform_suffix()
    out_path = "$(tarball_base)_$(platfix).tar.gz"
    
    if isfile(out_path)
        error("$(out_path) already exists, refusing to package into it")
    end

    # Run an audit of the prefix to ensure it is properly relocatable
    if !audit(prefix) && !ignore_audit_errors
        msg  = "Audit failed for $(prefix.path). "
        msg *= "Address the errors above to ensure relocatability. "
        msg *= "To override this check, set `ignore_audit_errors = true`."
        error(msg)
    end
    
    withenv("GZIP" => "-9") do
        package_cmd = gen_package_cmd(prefix.path, out_path)
        oc = OutputCollector(package_cmd; verbose=verbose)

        # Actually run the `tar` command
        try
            if !wait(oc)
                error()
            end
        catch
            # If we made a boo-boo, fess up.  Remember that the `oc` will auto-
            # `tail()` failing commands.
            error("Packaging of $(prefix.path) did not complete successfully")
        end
    end
    
    # Also spit out the hash of the archive file
    if verbose
        hash = open(out_path, "r") do f
            return bytes2hex(sha256(f))
        end
        info("SHA256 of $(basename(out_path)): $(hash)")
    end

    return out_path
end

"""
`install(prefix::Prefix, tarball_url::AbstractString,
         hash::AbstractString; force::Bool = false, verbose::Bool = false)`

Given a `prefix`, a `tarball_url` and a `hash, download that tarball into the
prefix, verify its integrity with the `hash`, and install it into the `prefix`.
Also save a manifest of the files into the prefix for uninstallation later.
"""
function install(tarball_url::AbstractString,
                 hash::AbstractString;
                 prefix::Prefix = global_prefix,
                 force::Bool = false,
                 ignore_platform::Bool = false,
                 verbose::Bool = false)

    # Get the platform suffix from the tarball and complain if it doesn't match
    platfix = extract_platform_suffix(tarball_url)
    if !ignore_platform && platform_suffix() != platfix
        msg  = "Will not install a tarball of platform $(platfix) on a system "
        msg *= "of platform $(platform_suffix()) unless `ignore_platform` is "
        msg *= "explicitly set to `true`."
        error(msg)
    end
    
    tarball_path = joinpath(prefix, "downloads", basename(tarball_url))
    if !isfile(tarball_path)
        if isfile(tarball_url)
            tarball_path = tarball_url
        else
            if verbose
                info("Downloading $(tarball_url) to $(tarball_path)")
            end
            
            # Create the downloads directory if it does not already exist
            mkpath(dirname(tarball_path))

            # Then download the tarball
            download_cmd = gen_download_cmd(tarball_url, tarball_path)
            oc = OutputCollector(download_cmd; verbose=verbose)
            try
                if !wait(oc)
                    error()
                end
            catch
                error("Could not download $(tarball_url) to $(tarball_path)")
            end
        end
    elseif verbose
        info("Not downloading $(tarball_url) as it is already downloaded")
    end

    # If `verify()` finds a problem, it's gonna error()
    verify(tarball_path, hash; verbose=verbose)

    if verbose
        info("Installing $(tarball_path) into $(prefix.path)")
    end
    
    # First, get list of files that are contained within the tarball
    file_list = list_tarball_files(tarball_path)

    # Check to see if any files are already present
    for file in file_list
        if isfile(joinpath(prefix, file))
            if !force
                msg  = "$(file) already exists and would be overwritten while"
                msg *= "installing $(basename(tarball_path))\n"
                msg *= "Will not overwrite unless `force = true` is set."
                error(msg)
            else
                if verbose
                    info("$(file) already exists, force-removing")
                end
                rm(file; force=true)
            end
        end
    end

    # Get our unpacking command
    unpack_cmd = gen_unpack_cmd(tarball_path, prefix.path)
    # Run the unpacking
    oc = OutputCollector(unpack_cmd; verbose=verbose)
    try 
        if !wait(oc)
            error()
        end
    catch
        error("Could not unpack $(tarball_path) into $(prefix.path)")
    end

    # Save installation manifest
    manifest_path = joinpath(prefix, "manifests", basename(tarball_path)[1:end-7] * ".list")
    mkpath(dirname(manifest_path))
    open(manifest_path, "w") do f
        write(f, join(file_list, "\n"))
    end

    return true
end

"""
`uninstall(manifest::AbstractString; verbose::Bool = false)`

Uninstall a package from a prefix by providing the `manifest_path` that was
generated during `install()`.  To find the `manifest_file` for a particular
installed file, use `manifest_for_file(file_path; prefix=prefix)`.
"""
function uninstall(manifest::AbstractString;
                   verbose::Bool = false)
    # Load in the manifest path
    if !isfile(manifest)
        error("Manifest path $(manifest) does not exist")
    end

    prefix_path = dirname(dirname(manifest))
    relmanipath = relpath(manifest, prefix_path)

    if verbose
        info("Removing files installed by $(relmanipath)")
    end

    files_to_remove = [chomp(l) for l in readlines(manifest)]
    for path in files_to_remove
        delpath = joinpath(prefix_path, path)
        if !isfile(delpath)
            if verbose
                info("  $delpath does not exist, but ignoring")
            end
        else
            if verbose
                delrelpath = relpath(delpath, prefix_path)
                info("  $delrelpath removed")
            end
            rm(delpath; force=true)
        end
    end

    if verbose
        info("  $(relmanipath) removed")
    end
    rm(manifest; force=true)
    return true
end

"""
`manifest_for_file(path::AbstractString; prefix::Prefix = global_prefix)`

Returns the manifest file containing the installation receipt for the given
`path`, throws an error if it cannot find a matching manifest.
"""
function manifest_for_file(path::AbstractString;
                           prefix::Prefix = global_prefix)
    if !isfile(path)
        error("File $(path) does not exist")
    end

    search_path = relpath(path, prefix.path)
    if startswith(search_path, "..")
        error("Cannot search for paths outside of the given Prefix!")
    end

    manidir = joinpath(prefix, "manifests")
    for fname in [f for f in readdir(manidir) if endswith(f, ".list")]
        manifest_path = joinpath(manidir, fname)
        if search_path in [chomp(l) for l in readlines(manifest_path)]
            return manifest_path
        end
    end

    error("Could not find $(search_path) in any manifest files")
end

"""
`list_tarball_files(path::AbstractString; verbose::Bool = false)`

Given a `.tar.gz` filepath, list the compressed contents.
"""
function list_tarball_files(path::AbstractString; verbose::Bool = false)
    if !isfile(path)
        error("Tarball path $(path) does not exist")
    end

    # Run the listing command, then parse the output
    oc = OutputCollector(gen_list_tarball_cmd(path); verbose=verbose)
    try
        if !wait(oc)
            error()
        end
    catch
        error("Could not list contents of tarball $(path)")
    end
    lines = parse_tarball_listing(stdout(oc))

    # If there are `./` prefixes on our files, remove them
    for idx in 1:length(lines)
        if startswith(lines[idx], "./")
            lines[idx] = lines[idx][3:end]
        end
    end

    return lines
end

"""
`verify(path::String, hash::String; verbose::Bool)`

Given a file `path` and a `hash`, calculate the SHA256 of the file and compare
it to `hash`.  If an error occurs, `verify()` will throw an error.
"""
function verify(path::AbstractString, hash::AbstractString; verbose::Bool = false)
    if length(hash) != 64
        msg  = "Hash must be 256 bits (64 characters) long, "
        msg *= "given hash is $(length(hash)) characters long"
        error(msg)
    end
    
    open(path) do file
        calc_hash = bytes2hex(sha256(file))
        if verbose
            info("Calculated hash $calc_hash for file $path")
        end

        if calc_hash != hash
            msg  = "Hash Mismatch!\n"
            msg *= "  Expected sha256:   $hash\n"
            msg *= "  Calculated sha256: $calc_hash"
            error(msg)
        end
    end
end