# In this file, we setup the `gen_download_cmd()`, `gen_unpack_cmd()` and
# `gen_package_cmd()` functions by providing methods to probe the environment
# and determine the most appropriate platform binaries to call.

"""
`gen_download_cmd(url::AbstractString, out_path::AbstractString)`

Return a `Cmd` that will download resource located at `url` and store it at
the location given by `out_path`.

This method is initialized by `probe_platform_engines()`, which should be
automatically called upon first import of `BinDeps2`.
"""
gen_download_cmd = (url::AbstractString, out_path::AbstractString) ->
    error("Call `probe_platform_engines()` before `gen_download_cmd()`")

"""
`gen_unpack_cmd(tarball_path::AbstractString, out_path::AbstractString)`

Return a `Cmd` that will unpack the given `tarball_path` into the given
`out_path`.  If `out_path` is not already a directory, it will be created.

This method is initialized by `probe_platform_engines()`, which should be
automatically called upon first import of `BinDeps2`.
"""
gen_unpack_cmd = (tarball_path::AbstractString, out_path::AbstractString) ->
    error("Call `probe_platform_engines()` before `gen_unpack_cmd()`")

"""
`gen_package_cmd(in_path::AbstractString, tarball_path::AbstractString)`

Return a `Cmd` that will package up the given `in_path` directory into a
tarball located at `tarball_path`.

This method is initialized by `probe_platform_engines()`, which should be
automatically called upon first import of `BinDeps2`.
"""
gen_package_cmd = (in_path::AbstractString, tarball_path::AbstractString) ->
    error("Call `probe_platform_engines()` before `gen_package_cmd()`")

"""
`gen_list_tarball_cmd(tarball_path::AbstractString)`

Return a `Cmd` that will list the files contained within the tarball located at
`tarball_path`.  The list will not include directories contained within the
tarball.

This method is initialized by `probe_platform_engines()`, which should be
automatically called upon first import of `BinDeps2`.
"""
gen_list_tarball_cmd = (tarball_path::AbstractString) ->
    error("Call `probe_platform_engines()` before `gen_list_tarball_cmd()`")

"""
`parse_tarball_listing(output::AbstractString)`

Parses the result of `gen_list_tarball_cmd()` into something useful.

This method is initialized by `probe_platform_engines()`, which should be
automatically called upon first import of `BinDeps2`.
"""
parse_tarball_listing = (output::AbstractString) ->
    error("Call `probe_platform_engines()` before `parse_tarball_listing()`")

"""
`probe_cmd(cmd::Cmd; verbose::Bool = false)`

Returns `true` if the given command executes successfully, `false` otherwise.
"""
function probe_cmd(cmd::Cmd; verbose::Bool = false)
    if verbose
        info("Probing $(cmd.exec[1]) as a possible download engine...")
    end
    try
        if verbose
            info("  Probe successful for $(cmd.exec[1])")
        end
        return success(cmd)
    catch
        return false
    end
end

"""
`probe_platform_engines!(;verbose::Bool = false)`

Searches the environment for various tools needed to download, unpack, and
package up binaries.  Searches for a download engine to be used by
`gen_download_cmd()` and a compression engine to be used by `gen_unpack_cmd()`,
`gen_package_cmd()` and `gen_list_tarball_cmd()`.  Running this function will
set the global functions to their appropriate implementations given the
environment this package is running on.

This probing function will automatically search for download engines using a
particular ordering; if you wish to override this ordering and use one over all
others, set the `BINDEPS2_DOWNLOAD_ENGINE` environment variable to its name,
and it will be the only engine searched for. For example, put:

    ENV["BINDEPS2_DOWNLOAD_ENGINE"] = "fetch"

within your `~/.juliarc.jl` file to force `fetch` to be used over `curl`.  If
the given override does not match any of the download engines known to this
function, a warning will be printed and the typical ordering will be performed.

Similarly, if you wish to override the compression engine used, set the
`BINDEPS2_COMPRESSION_ENGINE` environment variable to its name (either `7z` or
`tar`) and it will be the only engine searched for.  If the given override does
not match any of the compression engines known to this function, a warning will
be printed and the typical searching will be performed.

If `verbose` is `true`, print out the various engines as they are searched.
"""
function probe_platform_engines!(;verbose::Bool = false)
    global gen_download_cmd, gen_list_tarball_cmd, gen_package_cmd
    global gen_unpack_cmd, parse_tarball_listing
    
    # download_engines is a list of (test_cmd, download_opts_functor)
    # The probulator will check each of them by attempting to run `$test_cmd`,
    # and if that works, will set the global download functions appropriately.
    const download_engines = [
        (`curl --help`, (url, path) -> `curl -f -o $path -L $url`),
        (`wget --help`, (url, path) -> `wget -O $path $url`),
        (`fetch --help`, (url, path) -> `fetch -f $path $url`),
    ]
    
    const exe7z = Sys.iswindows() ? joinpath(JULIA_HOME, "7z.exe") : "7z"
    # 7z is rather intensely verbose
    unpack_7z = (tarball_path, out_path) ->
        pipeline(`$exe7z x $(tarball_path) -y -so`,
                 `$exe7z x -si -y -ttar -o$(out_path)`)
    package_7z = (in_path, tarball_path) ->
        pipeline(`$exe7z a -ttar -so a.tar "$(joinpath(".", in_path, "*"))"`,
                 `$exe7z a -si $(tarball_path)`)
    list_7z = (in_path) -> pipeline(`$exe7z x $in_path -so`, `7z l -ttar -y -si`)

    # Tar is rather less verbose
    unpack_tar = (tarball_path, out_path) ->
        `tar xzf $(tarball_path) --directory=$(out_path)`
    package_tar = (in_path, tarball_path) ->
        `tar -czvf $tarball_path -C $(in_path) .`
    list_tar = (in_path) -> `tar tzf $in_path`

    # compression_engines is a list of (test_cmd, unpack_opts_functor,
    # package_opts_functor, list_opts_functor, parse_functor).  The probulator
    # will check each of them by attempting to run `$test_cmd`, and if that
    # works, will set the global compression functions appropriately.
    const compression_engines = [
        (`tar --help`, unpack_tar, package_tar, list_tar, parse_tar_list),
        (`$exe7z --help`, unpack_7z, package_7z, list_7z, parse_7z_list),
    ]

    if verbose
        info("Probing for download engine...")
    end

    # For windows, let's add powershell onto the front of the list of things
    # we will search for.
    @static if is_windows()
        # We hardcode in the path to powershell here, just in case it's not on
        # the path, but is still installed
        psh_path = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell"
        psh_copts = `-NoProfile -Command`
        psh_download = (url, path) -> begin
            webclient = "(new-object net.webclient)"
            return `$psh_copts "$webclient.DownloadFile(\"$url\", \"$path\")"`
        end

        # Push these guys onto the top of our download_engines search list
        prepend!(download_engines, [
            (psh_path,     `$psh_path $psh_copts ""`, psh_download)
        ])
        prepend!(download_engines, [
            ("powershell", `powershell $psh_copts ""`, psh_download)
        ])
    end

    # Allow environment override
    if haskey(ENV, "BINDEPS2_DOWNLOAD_ENGINE")
        engine = ENV["BINDEPS2_DOWNLOAD_ENGINE"]
        dl_ngs = filter(e -> e[1].exec[1] == engine, download_engines)
        if isempty(dl_ngs)
            all_engines = join([d[1].exec[1] for d in download_engines], ", ")
            warn_msg  = "Ignoring BINDEPS2_DOWNLOAD_ENGINE as its value of "
            warn_msg *= "`$(engine)` does not match any known valid engines. "
            warn_msg *= "Try one of `$(all_engines)`."
            warn(warn_msg)
        else
            # If BINDEPS2_DOWNLOAD_ENGINE matches one of our download engines,
            # then restrict ourselves to looking only at that engine
            download_engines = dl_ngs
        end
    end

    if haskey(ENV, "BINDEPS2_COMPRESSION_ENGINE")
        engine = ENV["BINDEPS2_COMPRESSION_ENGINE"]
        comp_ngs = filter(e -> e[1].exec[1] == engine, compression_engines)
        if isempty(comp_ngs)
            all_engines = join([c[1].exec[1] for c in compression_engines], ", ")
            warn_msg  = "Ignoring BINDEPS2_COMPRESSION_ENGINE as its value of "
            warn_msg *= "`$(engine)` does not match any known valid engines. "
            warn_msg *= "Try one of `$(all_engines)`."
            warn(warn_msg)
        else
            # If BINDEPS2_COMPRESSION_ENGINE matches one of our download
            # engines, then restrict ourselves to looking only at that engine
            compression_engines = comp_ngs
        end
    end

    download_found = false
    compression_found = false

    # Search for a download engine
    for (test, dl_func) in download_engines
        if probe_cmd(`$test`; verbose=verbose)
            # Set our download command generator
            gen_download_cmd = dl_func
            download_found = true
            break
        end
    end

    # Search for a compression engine
    for (test, unpack, package, list, parse) in compression_engines
        if probe_cmd(`$test`; verbose=verbose)
            # Set our compression command generators
            gen_unpack_cmd = unpack
            gen_package_cmd = package
            gen_list_tarball_cmd = list
            parse_tarball_listing = parse

            compression_found = true
            break
        end
    end

    # Build informative error messages in case things go sideways
    errmsg = ""
    if !download_found
        errmsg *= "No download engines found. We looked for: "
        errmsg *= join([d[1] for d in download_engines], ", ")
        errmsg *= ". Install one and ensure it is available on the path.\n"
    end

    if !compression_found
        errmsg *= "No compression engines found. We looked for: "
        errmsg *= join([d[1] for d in compression_engines], ", ")
        errmsg *= ". Install one and ensure it is available on the path.\n"
    end

    # Error out if we couldn't find something
    if !download_found || !compression_found
        error(errmsg)
    end
end

"""
`parse_7z_list(output::AbstractString)`

Given the output of `7z l`, parse out the listed filenames.  This funciton used
by  `list_tarball_files`.
"""
function parse_7z_list(output::AbstractString)
    lines = [chomp(l) for l in split(output, "\n")]
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
`parse_7z_list(output::AbstractString)`

Given the output of `tar -t`, parse out the listed filenames.  This funciton
used by `list_tarball_files`.
"""
function parse_tar_list(output::AbstractString)
    lines = [chomp(l) for l in split(output, "\n")]

    # Drop empty lines and and directories
    lines = [l for l in lines if !isempty(l) && !endswith(l, '/')]

    return lines
end

"""
`download_verify_unpack(url::AbstractString, hash::AbstractString, dest::AbstractString)`

Helper method to download tarball located at `url`, verify it matches the
given `hash`, then unpack it into folder `dest`.
"""
function download_verify_unpack(url::AbstractString,
                                hash::AbstractString,
                                dest::AbstractString;
                                verbose::Bool = false)
    mktempdir(_tempdir()) do path
        # download to temporary path
        tarball_path = joinpath(path, "download.tar.gz")
        download_cmd = gen_download_cmd(url, tarball_path)
        oc = OutputCollector(download_cmd; verbose=verbose)
        try
            if !wait(oc)
                error()
            end
        catch
            error("Could not download $(tarball_url) to $(tarball_path)")
        end

        # verify download
        verify(tarball_path, hash; verbose=verbose)

        # unpack into dest
        try mkpath(dest) end
        unpack_cmd = gen_unpack_cmd(tarball_path, dest)
        oc = OutputCollector(unpack_cmd; verbose=verbose)
        try 
            if !wait(oc)
                error()
            end
        catch
            error("Could not unpack $(tarball_path) into $(dest)")
        end
    end
end
