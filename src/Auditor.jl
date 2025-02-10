module Auditor

using BinaryBuilderBase
using Base.BinaryPlatforms
using Pkg
using ObjectFile

using BinaryBuilderBase: march

export audit, collect_files, collapse_symlinks

# Some functions need to run commands in sandboxes mounted on the same prefix and we
# can't allow them to clash, otherwise one may be unmounting the filesystem while
# another is still operating.
const AUDITOR_SANDBOX_LOCK = ReentrantLock()
# Logging is reportedly not thread-safe but guarding it with locks should help.
const AUDITOR_LOGGING_LOCK = ReentrantLock()

# Helper function to run a command and print to `io` its invocation and full
# output (mimim what the sandbox does normally, but outside of it).
function run_with_io(io::IO, cmd::Cmd; wait::Bool=true)
    println(io, "---> $(join(cmd.exec, " "))")
    run(pipeline(cmd; stdout=io, stderr=io); wait)
end

include("auditor/instruction_set.jl")
include("auditor/dynamic_linkage.jl")
include("auditor/symlink_translator.jl")
include("auditor/compiler_abi.jl")
include("auditor/soname_matching.jl")
include("auditor/filesystems.jl")
include("auditor/extra_checks.jl")
include("auditor/codesigning.jl")

# AUDITOR TODO LIST:
#
# * Build dlopen() clone that inspects and tries to figure out why
#   something can't be opened.  Possibly use that within BinaryProvider too?

"""
    audit(prefix::Prefix, src_name::AbstractString = "";
                          io=stderr,
                          platform::AbstractPlatform = HostPlatform(),
                          verbose::Bool = false,
                          silent::Bool = false,
                          autofix::Bool = false,
                          has_csl::Bool = true,
                          require_license::Bool = true,
          )

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
                               platform::AbstractPlatform = HostPlatform(),
                               verbose::Bool = false,
                               silent::Bool = false,
                               autofix::Bool = false,
                               has_csl::Bool = true,
                               require_license::Bool = true,
               )
    # This would be really weird, but don't let someone set `silent` and `verbose` to true
    if silent
        verbose = false
    end

    # Canonicalize immediately
    prefix = Prefix(realpath(prefix.path))
    if verbose
        @info("Beginning audit of $(prefix.path)")
    end

    # If this is false then it's bedtime for bonzo boy
    all_ok = Threads.Atomic{Bool}(true)

    # Translate absolute symlinks to relative symlinks, if possible
    translate_symlinks(prefix.path; verbose=verbose)

    # Inspect binary files, looking for improper linkage
    predicate = f -> (filemode(f) & 0o111) != 0 || valid_library_path(f, platform)
    bin_files = collect_files(prefix, predicate; exclude_externalities=false)
    Threads.@threads for f in collapse_symlinks(bin_files)
        # If `f` is outside of our prefix, ignore it.  This happens with files from our dependencies
        if !startswith(f, prefix.path)
            continue
        end

        # Peel this binary file open like a delicious tangerine
        try
            readmeta(f) do ohs
                foreach(ohs) do oh
                    if !is_for_platform(oh, platform)
                        if verbose
                            @warn("Skipping binary analysis of $(relpath(f, prefix.path)) (incorrect platform)")
                        end
                    else
                        # Check that the ISA isn't too high
                        all_ok[] &= check_isa(oh, platform, prefix; verbose, silent)
                        # Check that the OS ABI is set correctly (often indicates the wrong linker was used)
                        all_ok[] &= check_os_abi(oh, platform; verbose)
                        # Make sure all binary files are executables, if libraries aren't
                        # executables Julia may not be able to dlopen them:
                        # https://github.com/JuliaLang/julia/issues/38993.  In principle this
                        # should be done when autofix=true, but we have to run this fix on MKL
                        # for Windows, for which however we have to set autofix=false:
                        # https://github.com/JuliaPackaging/Yggdrasil/pull/922.
                        all_ok[] &= ensure_executability(oh; verbose, silent)
                    
                        # If this is a dynamic object, do the dynamic checks
                        if isdynamic(oh)
                            # Check that the libgfortran version matches
                            all_ok[] &= check_libgfortran_version(oh, platform; verbose, has_csl)
                            # Check whether the library depends on any of the most common
                            # libraries provided by `CompilerSupportLibraries_jll`.
                            all_ok[] &= check_csl_libs(oh, platform; verbose, has_csl)
                            # Check that the libstdcxx string ABI matches
                            all_ok[] &= check_cxxstring_abi(oh, platform; verbose)
                            # Check that this binary file's dynamic linkage works properly.  Note to always
                            # DO THIS ONE LAST as it can actually mutate the file, which causes the previous
                            # checks to freak out a little bit.
                            all_ok[] &= check_dynamic_linkage(oh, prefix, bin_files;
                                                              platform, silent, verbose, autofix, src_name)
                        end
                    end
                end
            end

            # Ensure this file is codesigned (currently only does something on Apple platforms)
            all_ok[] &= ensure_codesigned(f, prefix, platform; verbose, subdir=src_name)
        catch e
            if !isa(e, ObjectFile.MagicMismatch)
                rethrow(e)
            end

            # If this isn't an actual binary file, skip it
            if verbose
                @info("Skipping binary analysis of $(relpath(f, prefix.path))")
            end
        end
    end

    # Find all dynamic libraries
    shlib_files = filter(f -> startswith(f, prefix.path) && valid_library_path(f, platform), collapse_symlinks(bin_files))

    Threads.@threads for f in shlib_files
        # Inspect all shared library files for our platform (but only if we're
        # running native, don't try to load library files from other platforms)
        if platforms_match(platform, HostPlatform())
            if verbose
                @info("Checking shared library $(relpath(f, prefix.path))")
            end

            # dlopen() this library in a separate Julia process so that if we
            # try to do something silly like `dlopen()` a .so file that uses
            # LLVM in interesting ways on startup, it doesn't kill our main
            # Julia process.
            dlopen_cmd = """
                using Libdl
                try
                    dlopen($(repr(f)))
                    exit(0)
                catch e
                    if $(repr(verbose))
                        Base.display_error(e)
                    end
                    exit(1)
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
                    @warn("$(relpath(f, prefix.path)) cannot be dlopen()'ed")
                end
                all_ok[] = false
            end
        end

        # Ensure that all libraries have at least some kind of SONAME, if we're
        # on that kind of platform
        if !Sys.iswindows(platform)
            all_ok[] &= ensure_soname(prefix, f, platform; verbose, autofix, subdir=src_name)
        end

        # Ensure that this library is available at its own SONAME
        all_ok[] &= symlink_soname_lib(f; verbose=verbose, autofix=autofix)
    end

    # remove *.la files generated by GNU libtool
    la_files = collect_files(prefix, endswith(".la"))
    for f in la_files
        # Make sure the file still exists on disk
        if isfile(f)
            # sanity check: first byte should be '#', first line should contain 'libtool'
            line = readline(f)
            if length(line) == 0 || line[1] != '#' || !occursin("libtool", line)
                continue
            end
        elseif !islink(f)
            # If the file doesn't exist on disk but it's a symlink, it's a broken link to a
            # no-longer-existing libtool file, we still want to remove it.  In any other
            # case, continue.
            continue
        end
        # remove it
        if verbose
            @info("Removing libtool file $f")
        end
        rm(f; force=true)
    end

    # Make sure that `(exec_)prefix` in pkg-config files use a relative prefix
    pc_files = collect_files(prefix, endswith(".pc"))
    Threads.@threads for f in pc_files
        for var in ["prefix", "exec_prefix"]
            pc_re = Regex("^$var=(/.*)\$")
            # We want to replace every instance of `prefix=...` with
            # `prefix=${pcfiledir}/../..`
            changed = false
            buf = IOBuffer()
            for l in readlines(f)
                m = match(pc_re, l)
                if m !== nothing
                    # dealing with an absolute path we need to relativize;
                    # determine how many directories we need to go up.
                    dir = m.captures[1]
                    f_rel = relpath(f, prefix.path)
                    ndirs = count('/', f_rel)
                    prefix_rel = join([".." for _ in 1:ndirs], "/")
                    l = "$var=\${pcfiledir}/$prefix_rel"
                    changed = true
                end
                println(buf, l)
            end
            str = String(take!(buf))

            if changed
                # Overwrite file
                if verbose
                    @info("Relocatize pkg-config file $f")
                end
                write(f, str)
            end
        end
    end

    if Sys.iswindows(platform)
        # We also cannot allow any symlinks in Windows because it requires
        # Admin privileges to create them.  Orz
        symlinks = collect_files(prefix, islink, exclude_dirs = false)
        Threads.@threads for f in symlinks
            try
                src_path = realpath(f)
                if isfile(src_path) || isdir(src_path)
                    rm(f; force=true)
                    cp(src_path, f, follow_symlinks = true)
                end
            catch
            end
        end

        # If we're targeting a windows platform, check to make sure no .dll
        # files are sitting in `$prefix/lib`, as that's a no-no.  This is
        # not a fatal offense, but we'll yell about it.
        lib_dll_files =  filter(f -> valid_library_path(f, platform), collect_files(joinpath(prefix, "lib"), predicate))
        for f in lib_dll_files
            if !silent
                @warn("$(relpath(f, prefix.path)) should be in `bin`!")
            end
        end

        # Even more than yell about it, we're going to automatically move
        # them if there are no `.dll` files outside of `lib`.  This is
        # indicative of a simplistic build system that just don't know any
        # better with regards to windows, rather than a complicated beast.
        outside_dll_files = [f for f in shlib_files if !(f in lib_dll_files)]
        if autofix && !isempty(lib_dll_files) && isempty(outside_dll_files)
            if !silent
                @warn("Simple buildsystem detected; Moving all `.dll` files to `bin`!")
            end

            mkpath(joinpath(prefix, "bin"))
            for f in lib_dll_files
                mv(f, joinpath(prefix, "bin", basename(f)))
            end
        end

        # Normalise timestamp of Windows import libraries.
        import_libraries = collect_files(prefix, endswith(".dll.a"))
        Threads.@threads for implib in import_libraries
            if verbose
                @info("Normalising timestamps in import library $(implib)")
            end
            normalise_implib_timestamp(implib)
        end

    end

    # Check that we're providing a license file
    if require_license
        all_ok[] &= check_license(prefix, src_name; verbose=verbose, silent=silent)
    end

    # Perform filesystem-related audit passes
    predicate = f -> !startswith(f, joinpath(prefix, "logs"))
    all_files = collect_files(prefix, predicate)

    # Search for absolute paths in this prefix
    all_ok[] &= check_absolute_paths(prefix, all_files; silent=silent)

    # Search for case-sensitive ambiguities
    all_ok[] &= check_case_sensitivity(prefix)
    return all_ok[]
end


"""
    compatible_marchs(p::AbstractPlatform)

Return a (sorted) list of compatible microarchitectures, starting from the most
compatible to the most highly specialized.  If no microarchitecture is specified within
`p`, returns the most generic microarchitecture possible for the given architecture.
"""
function compatible_marchs(platform::AbstractPlatform)
    if !haskey(BinaryPlatforms.arch_march_isa_mapping, arch(platform))
        throw(ArgumentError("Architecture \"$(arch(platform))\" does not contain any known microarchitectures!"))
    end

    # This is the list of microarchitecture names for this architecture
    march_list = String[march for (march, features) in BinaryPlatforms.arch_march_isa_mapping[arch(platform)]]

    # Fast-path a `march()` of `nothing`, which defaults to only the most compatible microarchitecture
    if march(platform) === nothing
        return march_list[begin:begin]
    end

    # Search for this platform's march in the march list
    idx = findfirst(m -> m == march(platform), march_list)
    if idx === nothing
        throw(ArgumentError("Microarchitecture \"$(march(platform))\" not valid for architecture \"$(arch(platform))\""))
    end

    # Return all up to that index
    return march_list[begin:idx]
end

function check_isa(oh, platform, prefix;
                   verbose::Bool = false,
                   silent::Bool = false)
    detected_march = analyze_instruction_set(oh, platform; verbose=verbose)
    platform_marchs = compatible_marchs(platform)
    if detected_march ∉ platform_marchs
        # The object file is for a microarchitecture not compatible with
        # the desired one
        if !silent
            msg = replace("""
            Minimum instruction set detected for $(relpath(path(oh), prefix.path)) is
            $(detected_march), not $(last(platform_marchs)) as desired.
            """, '\n' => ' ')
            @warn(strip(msg))
        end
        return false
    elseif detected_march != last(platform_marchs)
        # The object file is compatible with the desired
        # microarchitecture, but using a lower instruction set: inform
        # the user that they may be missing some optimisation, but there
        # is no incompatibility, so return true.
        if !silent
            msg = replace("""
            Minimum instruction set detected for $(relpath(path(oh), prefix.path)) is
            $(detected_march), not $(last(platform_marchs)) as desired.
            You may be missing some optimization flags during compilation.
            """, '\n' => ' ')
            @warn(strip(msg))
        end
    end
    return true
end

function check_dynamic_linkage(oh, prefix, bin_files;
                               platform::AbstractPlatform = HostPlatform(),
                               verbose::Bool = false,
                               silent::Bool = false,
                               autofix::Bool = true,
                               src_name::AbstractString = "",
                               )
    all_ok = Threads.Atomic{Bool}(true)
    # If it's a dynamic binary, check its linkage
    if isdynamic(oh)
        rp = RPath(oh)

        filename = relpath(path(oh), prefix.path)
        if verbose
            @info("Checking $(filename) with RPath list $(rpaths(rp))")
        end

        # Look at every dynamic link, and see if we should do anything about that link...
        libs = find_libraries(oh)
        ignored_libraries = String[]
        Threads.@threads for libname in collect(keys(libs))
            if should_ignore_lib(libname, oh, platform)
                push!(ignored_libraries, libname)
                continue
            end

            # If this is a default dynamic link, then just rewrite to use rpath and call it good.
            if is_default_lib(libname, oh)
                if autofix
                    if verbose
                        @info("$(filename): Rpathify'ing default library $(libname)")
                    end
                    relink_to_rpath(prefix, platform, path(oh), libs[libname]; verbose, subdir=src_name)
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
                        new_link = update_linkage(prefix, platform, path(oh), libs[libname], bin_files[kidx]; verbose, subdir=src_name)

                        if verbose && new_link !== nothing
                            @info("$(filename): Linked library $(libname) has been auto-mapped to $(new_link)")
                        end
                    else
                        if !silent
                            @warn("$(filename): Linked library $(libname) could not be resolved and could not be auto-mapped")
                            if is_troublesome_library_link(libname, platform)
                                @warn("$(filename): Depending on $(libname) is known to cause problems at runtime, make sure to link against the JLL library instead")
                            end
                        end
                        all_ok[] = false
                    end
                else
                    if !silent
                        @warn("$(filename): Linked library $(libname) could not be resolved within the given prefix")
                    end
                    all_ok[] = false
                end
            elseif !startswith(libs[libname], prefix.path)
                if !silent
                    @warn("$(filename): Linked library $(libname) (resolved path $(libs[libname])) is not within the given prefix")
                end
                all_ok[] = false
            end
        end

        if verbose && !isempty(ignored_libraries)
            @info("$(filename): Ignored system libraries $(join(ignored_libraries, ", "))")
        end

        # If there is an identity mismatch (which only happens on macOS) fix it
        if autofix
            fix_identity_mismatch(prefix, platform, path(oh), oh; verbose, subdir=src_name)
        end
    end
    return all_ok[]
end

"""
    collect_files(path::AbstractString, predicate::Function = f -> true)

Find all files that satisfy `predicate()` when the full path to that file is
passed in, returning the list of file paths.
"""
function collect_files(path::AbstractString, predicate::Function = f -> true;
                       exclude_externalities::Bool = true, exclude_dirs::Bool = true)
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
        if exclude_dirs
            list = files
        else
            list = append!(files, dirs)
        end
        for f in list
            f_path = joinpath(root, f)

            if predicate(f_path)
                push!(collected, f_path)
            end
        end
    end
    return unique!(collected)
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
    return unique!(filter(predicate, files))
end

"""
    check_license(prefix, src_name; verbose::Bool = false,, silent::Bool = false)

Check that there are license files for the project called `src_name` in the `prefix`.
"""
function check_license(prefix::Prefix, src_name::AbstractString = "";
                       verbose::Bool = false, silent::Bool = false)
    if verbose
        @info("Checking license file")
    end
    license_dir = joinpath(prefix.path, "share", "licenses", src_name)
    if isdir(license_dir) && length(readdir(license_dir)) >= 1
        if verbose
            @info("Found license file(s): " * join(readdir(license_dir), ", "))
        end
        return true
    else
        if !silent
            @error("Unable to find valid license file in \"\${prefix}/share/licenses/$(src_name)\"")
        end
        # This is pretty serious; don't let us get through without a license
        return false
    end
end

end # module Auditor
