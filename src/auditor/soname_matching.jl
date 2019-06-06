# Not everything has an SONAME
get_soname(oh::ObjectHandle) = nothing

# Auto-open a path into an ObjectHandle
get_soname(path::AbstractString) = readmeta(get_soname, path)

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


function ensure_soname(prefix::Prefix, path::AbstractString, platform::Platform;
                       verbose::Bool = false, autofix::Bool = false)
    # Skip any kind of Windows platforms
    if platform isa Windows
        return true
    end

    # Skip if this file already contains an SONAME
    rel_path = relpath(path, prefix.path)
    soname = get_soname(path)
    if soname != nothing
        if verbose
            @info("$(rel_path) already has SONAME \"$(soname)\"")
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
    ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
    set_soname_cmd = ``
    
    if Sys.isapple(platform)
        install_name_tool = "/opt/x86_64-apple-darwin14/bin/install_name_tool"
        set_soname_cmd = `$install_name_tool -id $(soname) $(rel_path)`
    elseif Sys.islinux(platform) || Sys.isbsd(platform)
        patchelf = "/usr/bin/patchelf"
        set_soname_cmd = `$patchelf --set-soname $(soname) $(rel_path)`
    end

    # Create a new linkage that looks like @rpath/$lib on OSX, 
    logpath = joinpath(logdir(prefix), "set_soname_$(basename(rel_path))_$(soname).log")
    retval = run(ur, set_soname_cmd, logpath; verbose=verbose)

    if !retval
        @warn("Unable to set SONAME on $(rel_path)")
        return false
    end

    # Read the SONAME back in and ensure it's set properly
    new_soname = get_soname(path)
    if new_soname != soname
        @warn("Set SONAME on $(rel_path) to $(soname), but read back $(string(new_soname))!")
        return false
    end

    if verbose
        @info("Set SOANME of $(rel_path) to \"$(soname)\"")
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
            if verbose
                @info("Library $(soname) does not exist, creating...")
            end
            symlink(soname_path, path)
        else
            if verbose
                @info("Library $(soname) does not exist, failing out...")
            end
            return false
        end
    end
    return true
end
