export audit, collect_files, collapse_symlinks

include("auditor/instruction_set.jl")
include("auditor/dynamic_linkage.jl")
include("auditor/symlink_translator.jl")
include("auditor/compiler_abi.jl")
include("auditor/soname_matching.jl")
include("auditor/filesystems.jl")

# AUDITOR TODO LIST:
#
# * Build dlopen() clone that inspects and tries to figure out why
#   something can't be opened.  Possibly use that within BinaryProvider too?

"""
    audit(prefix::Prefix; platform::Platform = platform_key_abi();
                          verbose::Bool = false,
                          silent::Bool = false,
                          autofix::Bool = false,
                          require_license::Bool = true)

Audits a prefix to attempt to find deployability issues with the binary objects
that have been installed within.  This auditing will check for relocatability
issues such as dependencies on libraries outside of the current `prefix`,
usage of advanced instruction sets such as AVX2 that may not be usable on many
platforms, linkage against newer glibc symbols, etc...

This method is still a work in progress, only some of the above list is
actually implemented, be sure to actually inspect `Auditor.jl` to see what is
and is not currently in the realm of fantasy.
"""
function audit(prefix::Prefix, src_name::AbstractString = "";
                               io=stderr,
                               platform::Platform = platform_key_abi(),
                               verbose::Bool = false,
                               silent::Bool = false,
                               autofix::Bool = false,
                               require_license::Bool = true)
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
    bin_files = collect_files(prefix, predicate; exclude_externalities=false)
    for f in collapse_symlinks(bin_files)
        # If `f` is outside of our prefix, ignore it.  This happens with files from our dependencies
        if !startswith(f, prefix.path)
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
                    # Check that the ISA isn't too high
                    all_ok &= check_isa(oh, platform, prefix; io=io, verbose=verbose, silent=silent)
                    # Check that the libgfortran version matches
                    all_ok &= check_libgfortran_version(oh, platform; io=io, verbose=verbose)
                    # Check that the libstdcxx string ABI matches
                    all_ok &= check_cxxstring_abi(oh, platform; io=io, verbose=verbose)
                    # Check that this binary file's dynamic linkage works properly.  Note to always
                    # DO THIS ONE LAST as it can actually mutate the file, which causes the previous
                    # checks to freak out a little bit.
                    all_ok &= check_dynamic_linkage(oh, prefix, bin_files;
                                                    io=io, platform=platform, silent=silent,
                                                    verbose=verbose, autofix=autofix)
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

    # Find all dynamic libraries
    shlib_files = filter(f -> valid_dl_path(f, platform), bin_files)

    for f in shlib_files
        # Inspect all shared library files for our platform (but only if we're
        # running native, don't try to load library files from other platforms)
        if Pkg.BinaryPlatforms.platforms_match(platform, platform_key_abi())
            if verbose
                info(io, "Checking shared library $(relpath(f, prefix.path))")
            end

            # dlopen() this library in a separate Julia process so that if we
            # try to do something silly like `dlopen()` a .so file that uses
            # LLVM in interesting ways on startup, it doesn't kill our main
            # Julia process.
            dlopen_cmd = """
                using Libdl
                try
                    dlopen($(repr(f)))
                    return 0
                catch e
                    if $(repr(verbose))
                        Base.display_error(e)
                    end
                    return 1
                end
            """
            try
                p = open(`$(Base.julia_cmd()) -e $dlopen_cmd`)
                wait(p)
                if p.exitcode != 0
                    throw("Invalid exit code!")
                end
            catch
                # TODO: Use the relevant ObjFileBase packages to inspect why
                # this file is being nasty to us.
                if !silent
                    warn(io, "$(relpath(f, prefix.path)) cannot be dlopen()'ed")
                end
                all_ok = false
            end
        end

        # Ensure that all libraries have at least some kind of SONAME, if we're
        # on that kind of platform
        if !(platform isa Windows)
            all_ok &= ensure_soname(prefix, f, platform; verbose=verbose, autofix=autofix)
        end

        # Ensure that this library is available at its own SONAME
        all_ok &= symlink_soname_lib(f; verbose=verbose, autofix=autofix)
    end

    if platform isa Windows
        # We also cannot allow any symlinks in Windows because it requires
        # Admin privileges to create them.  Orz
        symlinks = collect_files(prefix, islink)
        for f in symlinks
            try
                src_path = realpath(f)
                if isfile(src_path) || isdir(src_path)
                    rm(f; force=true)
                    cp(src_path, f)
                end
            catch
            end
        end
        
        # If we're targeting a windows platform, check to make sure no .dll
        # files are sitting in `$prefix/lib`, as that's a no-no.  This is
        # not a fatal offense, but we'll yell about it.
        lib_dll_files =  filter(f -> valid_dl_path(f, platform), collect_files(joinpath(prefix, "lib"), predicate))
        for f in lib_dll_files
            if !silent
                warn(io, "$(relpath(f, prefix.path)) should be in `bin`!")
            end
        end

        # Even more than yell about it, we're going to automatically move
        # them if there are no `.dll` files outside of `lib`.  This is
        # indicative of a simplistic build system that just don't know any
        # better with regards to windows, rather than a complicated beast.
        outside_dll_files = [f for f in shlib_files if !(f in lib_dll_files)]
        if autofix && !isempty(lib_dll_files) && isempty(outside_dll_files)
            if !silent
                warn(io, "Simple buildsystem detected; Moving all `.dll` files to `bin`!")
            end

            mkpath(joinpath(prefix, "bin"))
            for f in lib_dll_files
                mv(f, joinpath(prefix, "bin", basename(f)))
            end
        end
    end

    # Check that we're providing a license file
    if require_license
        all_ok &= check_license(prefix, src_name; verbose=verbose, io=io, silent=silent)
    end

    # Perform filesystem-related audit passes    predicate = f -> !startswith(f, joinpath(prefix, "logs"))
    all_files = collect_files(prefix, predicate)

    # Search for absolute paths in this prefix
    all_ok &= check_absolute_paths(prefix, all_files; io=io, silent=silent)

    # Search for case-sensitive ambiguities
    all_ok &= check_case_sensitivity(prefix; io=io)
    return all_ok
end

function check_isa(oh, platform, prefix;
                   io::IO = stderr,
                   verbose::Bool = false,
                   silent::Bool = false)
    # If it's an x86/x64 binary, check its instruction set for SSE, AVX, etc...
    if arch(platform_for_object(oh)) in [:x86_64, :i686]
        instruction_set = analyze_instruction_set(oh, platform; verbose=verbose, io=io)
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
                               platform::Platform = platform_key_abi(),
                               verbose::Bool = false,
                               silent::Bool = false,
                               autofix::Bool = true)
    all_ok = true
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
                    if kidx !== nothing
                        # If it is, point to that file instead!
                        new_link = update_linkage(prefix, platform, path(oh), libs[libname], bin_files[kidx]; verbose=verbose)

                        if verbose && new_link !== nothing
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

        if verbose && !isempty(ignored_libraries)
            info(io, "Ignored system libraries $(join(ignored_libraries, ", "))")
        end
        
        # If there is an identity mismatch (which only happens on macOS) fix it
        if autofix
            fix_identity_mismatch(prefix, platform, path(oh), oh; verbose=verbose)
        end
    end
    return all_ok
end


"""
    collect_files(path::AbstractString, predicate::Function = f -> true)

Find all files that satisfy `predicate()` when the full path to that file is
passed in, returning the list of file paths.
"""
function collect_files(path::AbstractString, predicate::Function = f -> true;
                       exclude_externalities::Bool = true)
    # Sometimes `path` doesn't actually live where we think it does, so canonicalize it immediately
    path = Pkg.Types.safe_realpath(path)

    if !isdir(path)
        return String[]
    end
    # If we are set to exclude externalities, then filter out symlinks that point
    # outside of our given `path`.
    if exclude_externalities
        old_predicate = predicate
        predicate = f -> old_predicate(f) && !(islink(f) && !startswith(Pkg.Types.safe_realpath(f), path))
    end
    collected = String[]
    for (root, dirs, files) in walkdir(path)
        for f in files
            f_path = joinpath(root, f)

            if predicate(f_path)
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
        catch
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

"""
    check_license(prefix, src_name; io::IO = stderr,
                  verbose::Bool = false,, silent::Bool = false)

Check that there are license files for the project called `src_name` in the `prefix`.
"""
function check_license(prefix::Prefix, src_name::AbstractString = "";
                       io::IO = stderr, verbose::Bool = false, silent::Bool = false)
    if verbose
        info(io, "Checking license file")
    end
    license_dir = joinpath(prefix.path, "share", "licenses", src_name)
    if isdir(license_dir) && length(readdir(license_dir)) >= 1
        if verbose
            info(io, "Found license file(s): " * join(readdir(license_dir), ", "))
        end
        return true
    else
        if !silent
            warn(io, "Unable to find valid license file in \"\${prefix}/share/licenses/$(src_name)\"")
        end
        # This is pretty serious; don't let us get through without a license
        return false
    end
end
