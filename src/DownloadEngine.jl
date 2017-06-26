# In this file, we define the machinery for setting up the `download()`
# function (we evaluate a few different download engines such as `curl`,
# `powershell`, `wget`, etc...)
using SHA


"""
`download(url, filename)`

Download resource located at `url` and store it within the file located at
`filename`.  This method is initialized by `probe_download_engine()`, which
should be automatically called upon first import of `BinaryProvider`.
"""
download = (url, filename; verbose=false) -> begin
    error("Must `probe_download_engine()` before calling `download()`")
end

"""
`probe_cmd(cmd::Cmd)`

Returns `true` if the given command executes successfully, `false` otherwise.
"""
function probe_cmd(cmd::Cmd)
    try
        return success(cmd)
    catch
        return false
    end
end

"""
`probe_download_engine(;verbose::Bool = false)`

Searches for a download engine to be used by `download()`, returning an
anonymous function that can be used to replace `download()`, which takes in two
parameters; the `url` to download and the `filename` to store it at.

This probing function will automatically search for download engines using a
particular ordering; if you wish to override this ordering and use one over all
others, set the `JULIA_DOWNLOAD_ENGINE` environment variable to its name, and
it will be the only engine searched for. For example, put:

    ENV["JULIA_DOWNLOAD_ENGINE"] = "fetch"

within your `~/.juliarc.jl` file to force `fetch` to be used over `curl`.  If
the given override does not match any of the download engines known to this
function, a warning will be printed and the typical ordering will be used.

If `verbose` is `true`, print out the download engines as they are searched.
"""
function probe_download_engine(;verbose::Bool = false)
    # download_engines is a list of (path, test_opts, download_opts_functor)
    # The probulator will check each of them by attempting to run
    # `$path $test_opts`, and if that works, will return a download()
    # function that runs `$name $(download_opts_functor(filename, url))`
    download_engines = [
        ("curl",  `--help`, (url, path) -> `-f -o $path -L $url`),
        ("wget",  `--help`, (url, path) -> `-O $path $url`),
        ("fetch", `--help`, (url, path) -> `-f $path $url`),
    ]

    if verbose
        info("Probing for download engine...")
    end

    # For windows, let's check real quick to see if we've got powershell
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
            (psh_path,     `$psh_copts ""`, psh_download)
        ])
        prepend!(download_engines, [
            ("powershell", `$psh_copts ""`, psh_download)
        ])
    end

    # Allow environment override
    if haskey(ENV, "JULIA_DOWNLOAD_ENGINE")
        engine = ENV["JULIA_DOWNLOAD_ENGINE"]
        dl_ngs = filter(e -> e[1] == engine, download_engines)
        if isempty(dl_ngs)
            warn_msg  = "Ignoring JULIA_DOWNLOAD_ENGINE value of \"$engine\" "
            warn_msg *= "as it does not match any known download engine"
            warn(warn_msg)
        else
            # If JULIA_DOWNLOAD_ENGINE matches one of our download engines,
            # then restrict ourselves to looking only at that engine
            download_engines = dl_ngs
        end
    end

    for (path, test_opts, dl_func) in download_engines
        if verbose
            info("Probing $path...")
        end
        if probe_cmd(`$path $test_opts`)
            if verbose
                info("  Probe Successful for $path")
            end
            # Return a function that actually runs our download engine
            return (url, filename; verbose = false) -> begin
                if verbose
                    info("$(basename(path)): downloading $url to $filename")
                end
                oc = OutputCollector(`$path $(dl_func(url, filename))`; verbose=verbose)
                return wait(oc)
            end
        end
    end

    # If nothing worked, error out
    errmsg  = "No download agents found. We looked for: "
    errmsg *= join([d[1] for d in download_engines], ", ")
    errmsg *= ". Install one and ensure it is available on the path."
    error(errmsg)
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