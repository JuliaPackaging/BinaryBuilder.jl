export audit, collect_files, collapse_symlinks

include("auditor/instruction_set.jl")
include("auditor/dynamic_linkage.jl")
include("auditor/symlink_translator.jl")

# AUDITOR TODO LIST:
#
# * Auto-determine minimum glibc version (to sate our own curiosity)

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
                               autofix::Bool = false)
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

    # Inspect binary files, looking for improper linkage
    predicate = f -> (filemode(f) & 0o111) != 0 || valid_dl_path(f, platform)
    bin_files = collect_files(prefix, predicate)
    for f in collapse_symlinks(bin_files)
        # Peel this binary file open like a delicious tangerine
        oh = try
            h = readmeta(f)
            if !is_for_platform(h, platform)
                if verbose
                    warn(io, "Skipping binary analysis of $(relpath(f, prefix.path)) (incorrect platform)")
                end
                continue
            end
            h
        catch
            # If this isn't an actual binary file, skip it
            if verbose
                info(io, "Skipping binary analysis of $(relpath(f, prefix.path))")
            end
            continue
        end

        # If it's a dynamic binary, check its linkage
        if isdynamic(oh)
            rp = RPath(oh)

            if verbose
                msg = strip("""
                Checking $(relpath(f, prefix.path)) with RPath list $(rpaths(rp))
                """)
                info(io, msg)
            end

            # Look at every dynamic link, and see if we should do anything about that link...
            libs = find_libraries(oh)
            for libname in keys(libs)
                if should_ignore_lib(libname, oh)
                    if verbose
                        info(io, "Ignoring system library $(libname)")
                    end
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
                        if kidx > 0
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
                            all_ok = false
                        end
                    else
                        msg = replace("""
                        Linked library $(libname) could not be resolved within
                        the given prefix
                        """, '\n' => ' ')
                        if !silent
                            warn(io, strip(msg))
                        end
                        all_ok = false
                    end
                elseif !startswith(libs[libname], prefix.path)
                    msg = replace("""
                    Linked library $(libname) (resolved path $(libs[libname]))
                    is not within the given prefix
                    """, '\n' => ' ')
                    if !silent
                        warn(io, strip(msg))
                    end
                    all_ok = false
                end
            end
        end

        # If it's an x86/x64 binary, check its instruction set for SSE, AVX, etc...
        if arch(platform_for_object(oh)) in [:x86_64, :i686]
            if verbose
                info(io, "Analyzing minimum instruction set for $(relpath(f, prefix.path))")
            end
            instruction_set = analyze_instruction_set(oh; verbose=verbose, io=io)
            if is64bit(oh) && instruction_set != :core2
                if !silent
                    msg = replace("""
                    Minimum instruction set is $(instruction_set), not core2
                    """, '\n' => ' ')
                    warn(io, strip(msg))
                end
                all_ok = false
            elseif !is64bit(oh) && instruction_set != :pentium4
                if !silent
                    msg = replace("""
                    Minimum instruction set is $(instruction_set), not pentium4
                    """, '\n' => ' ')
                    warn(io, strip(msg))
                end
                all_ok = false
            end
        end
    end

    # Inspect all shared library files for our platform (but only if we're
    # running native, don't try to load library files from other platforms)
    if platform == platform_key()
        # Find all dynamic libraries
        predicate = f -> valid_dl_path(f, platform)
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
        predicate = f -> f[end-2:end] == "dll"
        lib_dll_files = collect_files(joinpath(prefix, "lib"), predicate)
        for f in lib_dll_files
            if !silent
                warn(io, "$(relpath(f, prefix.path)) should be in `bin`!")
            end
        end
    end

    # Search _every_ file in the prefix path to find hardcoded paths
    predicate = f -> !startswith(f, joinpath(prefix, "logs")) &&
                     !startswith(f, joinpath(prefix, "manifests"))
    all_files = collect_files(prefix, predicate)

    # Finally, check for absolute paths in any files.  This is not a "fatal"
    # offense, as many files have absolute paths.  We want to know about it
    # though, so we'll still warn the user.
    for f in all_files
        file_contents = String(read(f))
        if contains(file_contents, prefix.path)
            if !silent
                warn(io, "$(relpath(f, prefix.path)) contains an absolute path")
            end
        end
    end

    return all_ok
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
    abs_files = realpath.(files)
    predicate = f -> begin
        try
            return !(islink(f) && realpath(f) in abs_files)
        catch
            return false
        end
    end
    return filter(predicate, files)
end

