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
`temp_prefix(func::Function, path::AbstractString = tempdir())`

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
    mktempdir() do path
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
function activate(prefix::Prefix = global_prefix)
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
`deactivate(prefix::Prefix)`

Removes paths added to environment variables by `activate()`
"""
function deactivate(prefix::Prefix = global_prefix)
    # Remove from PATH
    paths = split_PATH()
    filter!(p -> p != bindir(prefix), paths)
    ENV["PATH"] = join_PATH(paths)

    # Remove from DL_LOAD_PATH
    filter!(p -> p != libdir(prefix), Libdl.DL_LOAD_PATH)
    return nothing
end

"""
`package(prefix::Prefix; force::Bool = false, verbose::Bool = false)`

Build a tarball of the `prefix`.  Runs an `audit()` on the `prefix`, to ensure
that libraries can be `dlopen()`'ed, that all dependencies are located within
the prefix, etc...
"""
function package(prefix::Prefix, out_path::AbstractString;
                 ignore_audit_errors::Bool = false, verbose::Bool = false)
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

    tar_cmd = @static if is_windows()
        pipeline(`7z a -ttar -so a.tar "$(joinpath(".", prefix, "*"))"`,
                 `7z a -si $(out_path)`)
    else
        `tar -czvf $out_path -C $(prefix.path) .`
    end

    oc = nothing
    did_succeed = false
    withenv("GZIP" => "-9") do
        oc = OutputCollector(tar_cmd; verbose=verbose)

        # Actually run the `tar` command
        try
            did_succeed = wait(oc)
        end
    end
    
    # If we made a boo-boo, fess up
    if !did_succeed
        if !verbose
            println(tail(oc; colored=Base.have_color))
        end
        msg = "Packaging of $(prefix.path) did not complete successfully"
        print_color(:red, msg; bold = true)
        println()
    end

    # Also spit out the hash of the archive file
    if verbose
        hash = open(out_path, "r") do f
            return bytes2hex(sha256(f))
        end
        info("SHA256 of $(basename(out_path)): $(hash)")
    end

    return did_succeed
end

"""
`install(prefix::Prefix, tarball_url::AbstractString,
         hash::AbstractString; force::Bool = false, verbose::Bool = false)`

Given a `prefix`, a `tarball_url` and a `hash, download that tarball into the
prefix, verify its integrity with the `hash`, and install it into the `prefix`.
Also save a manifest of the files into the prefix for uninstallation later.
"""
function install(prefix::Prefix,
                 tarball_url::AbstractString,
                 hash::AbstractString;
                 force::Bool = false,
                 verbose::Bool = false)
    tarball_path = joinpath(prefix, "downloads", basename(tarball_url))
    if !isfile(tarball_path)
        if isfile(tarball_url)
            tarball_path = tarball_url
        else
            if verbose
                info("Downloading $(tarball_url) to $(tarball_path)")
            end
            
            if !download(tarball_url, tarball_path; verbose=verbose)
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
    cmd = @static if is_windows()
        pipeline(`7z x $(tarball_path) -y -so`, `7z x -si -y -ttar -o$(prefix.path)`)
    else
        `tar xzf $(tarball_path) --directory=$(prefix.path)`
    end

    # Run the unpacking
    oc = OutputCollector(cmd; verbose=verbose)
    try
        wait(oc)
    end

    # Save installation manifest
    manifest_path = joinpath(prefix, "manifests", basename(tarball_path)[1:end-7] * ".list")
    mkpath(dirname(manifest_path))
    open(manifest_path, "w") do f
        write(f, join(file_list, "\n"))
    end
end

"""
`uninstall(prefix::Prefix, manifest::AbstractString; verbose::Bool = false)`

Uninstall a package from `prefix` by providing the `manifest_path` that was
generated during `install()`.  To find the `manifest_file` for a particular
installed file, use `manifest_for_file(prefix, file_path)`.
"""
function uninstall(prefix::Prefix, manifest::AbstractString; verbose::Bool = false)
    # Load in the manifest path
    if !isfile(manifest)
        error("Manifest path $(manifest) does not exist")
    end

    relmanipath = relpath(manifest, prefix.path)

    if verbose
        info("Removing files installed by $(relmanipath)")
    end

    files_to_remove = readlines(manifest)
    for path in files_to_remove
        delpath = joinpath(prefix, path)
        if !isfile(delpath)
            if verbose
                info("  $delpath does not exist, but ignoring")
            end
        else
            if verbose
                delrelpath = relpath(delpath, prefix.path)
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

function manifest_for_file(prefix::Prefix, path::AbstractString)
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
`parse_7z_list(output::AbstractString)`

Given the output of `7z l`, parse out the listed filenames.  This funciton used
by  `list_tarball_files`.
"""
function parse_7z_list(output::AbstractString)
    lines = split(output, "\n")
    # Remove extraneous "\r" for windows platforms
    for idx in 1:length(lines)
        if endswith(lines[idx], '\r')
            lines[idx] = lines[idx][1:end-1]
        end
    end

    # Find index of " Name". (can't use `findfirst(generator)` until this is
    # closed: https://github.com/JuliaLang/julia/issues/16884
    header_row = find(contains(l, " Name") && contains(l, " Attr") for l in lines)[1]
    name_idx = search(lines[header_row], "Name")[1]
    attr_idx = search(lines[header_row], "Attr")[1] - 1

    # Filter out only the names of files, ignoring directories
    lines = [l[name_idx:end] for l in lines if length(l) > name_idx && l[attr_idx] != 'D']
    if isempty(lines)
        return []
    end

    # Extract within the bounding lines of ------------
    bounds = [i for i in 1:length(lines) if all([c for c in lines[i]] .== '-')]
    lines = lines[bounds[1]+1:bounds[2]-1]

    return lines
end

"""
`list_tarball_files(path::AbstractString)`

Given a `.tar.gz` filepath, list the compressed contents.
"""
function list_tarball_files(path::AbstractString)
    if !isfile(path)
        error("Tarball path $(path) does not exist")
    end

    lines = @static if is_windows()
        parse_7z_list(readchomp(pipeline(`7z x $path -so`, `7z l -ttar -y -si`)))
    else
        [f for f in split(readchomp(`tar tzf $path`), "\n") if !endswith(f, '/')]
    end

    # If there are `./` prefixes on our files, remove them
    for idx in 1:length(lines)
        if startswith(lines[idx], "./")
            lines[idx] = lines[idx][3:end]
        end
    end

    return lines
end