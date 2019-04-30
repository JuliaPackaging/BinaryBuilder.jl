# Not everything has an SONAME
get_soname(oh::ObjectHandle) = nothing

# Auto-open a path into an ObjectHandle
get_soname(path::AbstractString) = readmeta(get_soname, path)

function get_soname(oh::ELFHandle)
    # Get the dynamic entries, see if it contains a DT_SONAME
    es = ELFDynEntries(oh)
    soname_idx = findfirst(e -> e.entry.d_tag == ELF.DT_SONAME, es)
    if soname_idx === nothing
        return nothing
    end

    # Look up the SONAME from the string table
    return basename(strtab_lookup(es[soname_idx]))
end

function get_soname(oh::MachOHandle)
    # Get the dynamic entries, see if it contains an ID_DYLIB_CMD
    lcs = MachOLoadCmds(oh)
    id_idx = findfirst(lc -> typeof(lc) <: MachOIdDylibCmd, lcs)
    if id_idx === nothing
        return nothing
    end

    # Return the Dylib ID
    return basename(dylib_name(lcs[id_idx]))
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
    soname_path = joinpath(dirname(path), soname)
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