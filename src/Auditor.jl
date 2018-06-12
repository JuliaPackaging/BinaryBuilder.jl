export audit, collect_files, collapse_symlinks

include("auditor/instruction_set.jl")
include("auditor/dynamic_linkage.jl")
include("auditor/symlink_translator.jl")

# AUDITOR TODO LIST:
#
# * Auto-determine minimum glibc version (to sate our own curiosity)
# * Build dlopen() clone that inspects and tries to figure out why
#   something can't be opened.  Possibly use that within BinaryProvider too?

"""
    audit(prefix::Prefix; platform::Platform = platform_key();
                          verbose::Bool = false,
                          silent::Bool = false,
                          autofix::Bool = false)

Audits a prefix to attempt to find deployability issues with the binary objects
that have been installed within.  This auditing will check for relocatability
issues such as dependencies on libraries outside of the current `prefix`,
usage of advanced instruction sets such as AVX2 that may not be usable on many
platforms, linkage against newer glibc symbols, etc...

This method is still a work in progress, only some of the above list is
actually implemented, be sure to actually inspect `Auditor.jl` to see what is
and is not currently in the realm of fantasy.
"""
function audit(prefix::Prefix; io=stderr,
                               platform::Platform = platform_key(),
                               verbose::Bool = false,
                               silent::Bool = false,
                               autofix::Bool = false,
                               ignore_manifests::Vector = [])
    # This would be really weird, but don't let someone set `silent` and `verbose` to true
    if silent
        verbose = false
    end

    if verbose
        info(io, "Beginning audit of $(prefix.path)")
    end

    # If this is false then it's bedtime for bonzo boy
    all_ok = true

    # Translate absolute symlinks to relative symlinks, if possible
    translate_symlinks(prefix.path; verbose=verbose)

    # If a file exists within ignore_manifests, then we won't inspect it
    # as it belongs to some dependent package.
    ignore_files = vcat((readlines(f) for f in ignore_manifests)...)
    ignore_files = [abspath(joinpath(prefix, f)) for f in ignore_files]

    # Inspect binary files, looking for improper linkage
    predicate = f -> (filemode(f) & 0o111) != 0 || valid_dl_path(f, platform)
    bin_files = collect_files(prefix, predicate)
    for f in collapse_symlinks(bin_files)
        # If this file is contained within the `ignore_manifests`, skip it
        if f in ignore_files
            continue
        end

        # Peel this binary file open like a delicious tangerine
        try
            readmeta(f) do oh
                if !is_for_platform(oh, platform)
                    if verbose
                        warn(io, "Skipping binary analysis of $(relpath(f, prefix.path)) (incorrect platform)")
                    end
                else
                    all_ok &= check_dynamic_linkage(oh, prefix, bin_files;
                                                    io=io, platform=platform, silent=silent,
                                                    verbose=verbose, autofix=autofix)
                    all_ok &= check_isa(oh, prefix; io=io, verbose=verbose, silent=silent)
                end
            end
        catch e
            if !isa(e, ObjectFile.MagicMismatch)
                rethrow(e)
            end

            # If this isn't an actual binary file, skip it
            if verbose
                info(io, "Skipping binary analysis of $(relpath(f, prefix.path))")
            end
        end
    end

    # Inspect all shared library files for our platform (but only if we're
    # running native, don't try to load library files from other platforms)
    if platform == platform_key()
        # Find all dynamic libraries
        predicate = f -> valid_dl_path(f, platform) && !(f in ignore_files)
        shlib_files = collect_files(prefix, predicate)

        for f in shlib_files
            if verbose
                info(io, "Checking shared library $(relpath(f, prefix.path))")
            end

            # dlopen() this library in a separate Julia process so that if we
            # try to do something silly like `dlopen()` a .so file that uses
            # LLVM in interesting ways on startup, it doesn't kill our main
            # Julia process.
            if !success(`$(Base.julia_cmd()) -e "Libdl.dlopen(\"$f\")"`)
                # TODO: Use the relevant ObjFileBase packages to inspect why
                # this file is being nasty to us.

                if !silent
                    warn(io, "$(relpath(f, prefix.path)) cannot be dlopen()'ed")
                end
                all_ok = false
            end
        end
    end

    if platform isa Windows
        # If we're targeting a windows platform, check to make sure no .dll
        # files are sitting in `$prefix/lib`, as that's a no-no.  This is
        # not a fatal offense, but we'll yell about it.
        predicate = f -> f[end-3:end] == ".dll" && !(f in ignore_files)
        lib_dll_files = collect_files(joinpath(prefix, "lib"), predicate)
        for f in lib_dll_files
            if !silent
                warn(io, "$(relpath(f, prefix.path)) should be in `bin`!")
            end
        end

        # Even more than yell about it, we're going to automatically move
        # them if there are no `.dll` files outside of `lib`.  This is
        # indicative of a simplistic build system that just don't know any
        # better with regards to windows, rather than a complicated beast.
        all_dll_files = collect_files(prefix, predicate)
        outside_dll_files = [f for f in all_dll_files if !(f in lib_dll_files)]
        if autofix && isempty(outside_dll_files)
            if !silent
                warn(io, "Simple buildsystem detected; Moving all `.dll` files to `bin`!")
            end

            mkpath(joinpath(prefix, "bin"))
            for f in lib_dll_files
                mv(f, joinpath(prefix, "bin", basename(f)))
            end
        end
    end

    # Search _every_ file in the prefix path to find hardcoded paths
    predicate = f -> !startswith(f, joinpath(prefix, "logs")) &&
                     !startswith(f, joinpath(prefix, "manifests")) &&
                     !(f in ignore_files)
    all_files = collect_files(prefix, predicate)

    # Finally, check for absolute paths in any files.  This is not a "fatal"
    # offense, as many files have absolute paths.  We want to know about it
    # though, so we'll still warn the user.
    for f in all_files
        try
            file_contents = String(read(f))
            if contains(file_contents, prefix.path)
                if !silent
                    warn(io, "$(relpath(f, prefix.path)) contains an absolute path")
                end
            end
        except
            if !silent
                warn(io, "Skipping abspath scanning of $(f), as we can't open it")
            end
        end
    end

    return all_ok
end

function check_isa(oh, prefix;
                   io::IO = stderr,
                   verbose::Bool = false,
                   silent::Bool = false)
    # If it's an x86/x64 binary, check its instruction set for SSE, AVX, etc...
    if arch(platform_for_object(oh)) in [:x86_64, :i686]
        instruction_set = analyze_instruction_set(oh; verbose=verbose, io=io)
        if is64bit(oh) && instruction_set != :core2
            if !silent
                msg = replace("""
                Minimum instruction set for $(relpath(path(oh), prefix.path)) is
                $(instruction_set), not core2 as desired.
                """, '\n' => ' ')
                warn(io, strip(msg))
            end
            return false
        elseif !is64bit(oh) && instruction_set != :pentium4
            if !silent
                msg = replace("""
                Minimum instruction set for $(relpath(path(oh), prefix.path)) is
                $(instruction_set), not pentium4 as desired.
                """, '\n' => ' ')
                warn(io, strip(msg))
            end
            return false
        end
    end
    return true
end

function check_dynamic_linkage(oh, prefix, bin_files;
                               io::IO = stderr,
                               platform::Platform = platform_key(),
                               verbose::Bool = false,
                               silent::Bool = false,
                               autofix::Bool = true)
    # If it's a dynamic binary, check its linkage
    if isdynamic(oh)
        rp = RPath(oh)

        if verbose
            msg = strip("""
                        Checking $(relpath(path(oh), prefix.path)) with RPath list $(rpaths(rp))
            """)
            info(io, msg)
        end

        # Look at every dynamic link, and see if we should do anything about that link...
        libs = find_libraries(oh)
        ignored_libraries = String[]
        for libname in keys(libs)
            if should_ignore_lib(libname, oh)
                push!(ignored_libraries, libname)
                continue
            end

            # If this is a default dynamic link, then just rewrite to use rpath and call it good.
            if is_default_lib(libname, oh)
                relink_to_rpath(prefix, platform, path(oh), libs[libname])
                if verbose
                    info(io, "Rpathify'ing default library $(libname)")
                end
                continue
            end

            if !isfile(libs[libname])
                # If we couldn't resolve this library, let's try autofixing,
                # if we're allowed to by the user
                if autofix
                    # First, is this a library that we already know about?
                    known_bins = lowercase.(basename.(bin_files))
                    kidx = findfirst(known_bins .== lowercase(basename(libname)))
                    if kidx !== nothing && kidx > 0 # The second condition is redundant in julia 0.7
                        # If it is, point to that file instead!
                        new_link = update_linkage(prefix, platform, path(oh), libs[libname], bin_files[kidx]; verbose=verbose)

                        if verbose
                            msg = replace("""
                            Linked library $(libname) has been auto-mapped to
                            $(new_link)
                            """, '\n' => ' ')
                            info(io, strip(msg))
                        end
                    else
                        msg = replace("""
                        Linked library $(libname) could not be resolved and
                        could not be auto-mapped
                        """, '\n' => ' ')
                        if !silent
                            warn(io, strip(msg))
                        end
                        return false
                    end
                else
                    msg = replace("""
                    Linked library $(libname) could not be resolved within
                    the given prefix
                    """, '\n' => ' ')
                    if !silent
                        warn(io, strip(msg))
                    end
                    return false
                end
            elseif !startswith(libs[libname], prefix.path)
                msg = replace("""
                Linked library $(libname) (resolved path $(libs[libname]))
                is not within the given prefix
                """, '\n' => ' ')
                if !silent
                    warn(io, strip(msg))
                end
                return false
            end
        end

        if verbose && !isempty(ignored_libraries)
            info(io, "Ignored system libraries $(join(ignored_libraries, ", "))")
        end
    end
    return true
end


"""
    collect_files(path::AbstractString, predicate::Function = f -> true)

Find all files that satisfy `predicate()` when the full path to that file is
passed in, returning the list of file paths.
"""
function collect_files(path::AbstractString, predicate::Function = f -> true; exculuded_files=Set{String}())
    if !isdir(path)
        return String[]
    end
    collected = String[]
    for (root, dirs, files) in walkdir(path)
        for f in files
            f_path = joinpath(root, f)

            if predicate(f_path) && !(f_path in exculuded_files)
                push!(collected, f_path)
            end
        end
    end
    return collected
end
# Unwrap Prefix objects automatically
collect_files(prefix::Prefix, args...; kwargs...) = collect_files(prefix.path, args...; kwargs...)

"""
    collapse_symlinks(files::Vector{String})

Given a list of files, prune those that are symlinks pointing to other files
within the list.
"""
function collapse_symlinks(files::Vector{String})
    abs_files = String[]
    # Collapse symlinks down to real files, but don't die if we've got a broken symlink
    for f in files
        try
            push!(abs_files, realpath(f))
        end
    end

    # Return true if it's not a link and the real path exists in abs_files
    predicate = f -> begin
        try
            return !(islink(f) && realpath(f) in abs_files)
        catch
            return false
        end
    end
    return filter(predicate, files)
end

