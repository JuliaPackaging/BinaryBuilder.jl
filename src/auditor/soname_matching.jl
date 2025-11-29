using Patchelf_jll: patchelf

# Not everything has an SONAME
get_soname(oh::ObjectHandle) = nothing

# Auto-open a path into an ObjectHandle
function get_soname(path::AbstractString)
    try
        only(readmeta(ns -> get_soname.(ns), path))
    catch e
        @lock AUDITOR_LOGGING_LOCK @warn "Could not probe $(path) for an SONAME!" exception=(e, catch_backtrace())
        return nothing
    end
end

function get_soname(oh::ELFHandle)
    # Get the dynamic entries, see if it contains a DT_SONAME
    es = ELFDynEntries(oh)
    soname_idx = findfirst(e -> e.entry.d_tag == ELF.DT_SONAME, es)
    if soname_idx === nothing
        # If all else fails, just return the filename.
        return nothing
    end

    # Look up the SONAME from the string table
    return strtab_lookup(es[soname_idx])
end

function get_soname(oh::MachOHandle)
    # Get the dynamic entries, see if it contains an ID_DYLIB_CMD
    lcs = MachOLoadCmds(oh)
    id_idx = findfirst(lc -> typeof(lc) <: MachOIdDylibCmd, lcs)
    if id_idx === nothing
        # If all else fails, just return the filename.
        return nothing
    end

    # Return the Dylib ID
    return dylib_name(lcs[id_idx])
end


function ensure_soname(prefix::Prefix, path::AbstractString, platform::AbstractPlatform;
                       verbose::Bool = false, autofix::Bool = false, subdir::AbstractString="")
    # Skip any kind of Windows platforms
    if Sys.iswindows(platform)
        return true
    end

    # macOS uses install_name_tool (check first since Sys.isbsd is true for macOS too)
    if Sys.isapple(platform)
        return _ensure_soname_macho(prefix, path, platform; verbose, autofix, subdir)
    end

    # For Linux/FreeBSD, wrap the entire read-modify-verify cycle in the file lock
    return with_patchelf_lock(path) do
        _ensure_soname_elf(prefix, path, platform; verbose, autofix, subdir)
    end
end

function _ensure_soname_macho(prefix::Prefix, path::AbstractString, platform::AbstractPlatform;
                              verbose::Bool = false, autofix::Bool = false, subdir::AbstractString="")
    # Skip if this file already contains an SONAME
    rel_path = relpath(realpath(path), realpath(prefix.path))
    soname = get_soname(path)
    if soname != nothing
        if verbose
            @lock AUDITOR_LOGGING_LOCK @info("$(rel_path) already has SONAME \"$(soname)\"")
        end
        return true
    else
        soname = basename(path)
    end

    # If we're not allowed to fix it, fail out
    if !autofix
        return false
    end

    # Otherwise, set the SONAME
    retval = with_logfile(prefix, "set_soname_$(basename(rel_path))_$(soname).log"; subdir) do io
        ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
        install_name_tool = "/opt/bin/$(triplet(ur.platform))/install_name_tool"
        set_soname_cmd = `$install_name_tool -id $(soname) $(rel_path)`
        @lock AUDITOR_SANDBOX_LOCK run(ur, set_soname_cmd, io; verbose=verbose)
    end

    if !retval
        @lock AUDITOR_LOGGING_LOCK @warn("Unable to set SONAME on $(rel_path)")
        return false
    end

    # Read the SONAME back in and ensure it's set properly
    new_soname = get_soname(path)
    if new_soname != soname
        @lock AUDITOR_LOGGING_LOCK @warn("Set SONAME on $(rel_path) to $(soname), but read back $(string(new_soname))!")
        return false
    end

    if verbose
        @lock AUDITOR_LOGGING_LOCK @info("Set SONAME of $(rel_path) to \"$(soname)\"")
    end

    return true
end

# This function is called with the patchelf lock already held
function _ensure_soname_elf(prefix::Prefix, path::AbstractString, platform::AbstractPlatform;
                            verbose::Bool = false, autofix::Bool = false, subdir::AbstractString="")
    # Skip if this file already contains an SONAME
    rel_path = relpath(realpath(path), realpath(prefix.path))
    soname = get_soname(path)
    if soname != nothing
        if verbose
            @lock AUDITOR_LOGGING_LOCK @info("$(rel_path) already has SONAME \"$(soname)\"")
        end
        return true
    else
        soname = basename(path)
    end

    # If we're not allowed to fix it, fail out
    if !autofix
        return false
    end

    # Otherwise, set the SONAME
    retval = with_logfile(prefix, "set_soname_$(basename(rel_path))_$(soname).log"; subdir) do io
        success(run_with_io(io, `$(patchelf()) $(patchelf_flags(platform)) --set-soname $(soname) $(realpath(path))`; wait=false))
    end

    if !retval
        @lock AUDITOR_LOGGING_LOCK @warn("Unable to set SONAME on $(rel_path)")
        return false
    end

    # Read the SONAME back in and ensure it's set properly
    new_soname = get_soname(path)
    if new_soname != soname
        @lock AUDITOR_LOGGING_LOCK @warn("Set SONAME on $(rel_path) to $(soname), but read back $(string(new_soname))!")
        return false
    end

    if verbose
        @lock AUDITOR_LOGGING_LOCK @info("Set SONAME of $(rel_path) to \"$(soname)\"")
    end

    return true
end

"""
    symlink_soname_lib(path::AbstractString)

We require that all shared libraries are accessible on disk through their
SONAME (if it exists).  While this is almost always true in practice, it
doesn't hurt to make doubly sure.
"""
function symlink_soname_lib(path::AbstractString; verbose::Bool = false,
                                                  autofix::Bool = false)
    # If this library doesn't have an SONAME, then just quit out immediately
    soname = get_soname(path)
    if soname === nothing
        return true
    end

    # Absolute path to where the SONAME-named file should be
    soname_path = joinpath(dirname(path), basename(soname))
    if !isfile(soname_path)
        if autofix
            target = basename(path)
            if verbose
                @lock AUDITOR_LOGGING_LOCK @info("Library $(soname) does not exist, creating link to $(target)...")
            end
            symlink(target, soname_path)
        else
            if verbose
                @lock AUDITOR_LOGGING_LOCK @info("Library $(soname) does not exist, failing out...")
            end
            return false
        end
    end
    return true
end
