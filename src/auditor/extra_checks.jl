# This file contains some extra checks that don't fall into the other
# categories, for example because they're very platform-specific.

using Dates: DateTime, datetime2unix

function check_os_abi(oh::ObjectHandle, p::AbstractPlatform, rest...; verbose::Bool = false, kwargs...)
    if Sys.isfreebsd(p)
        if oh.ei.osabi != ELF.ELFOSABI_FREEBSD
            # The dynamic loader should not have problems in this case, but the
            # linker may not appreciate.  Let the user know about this.
            if verbose
                msg = replace("""
                $(basename(path(oh))) has an ELF header OS/ABI value that is not set to FreeBSD
                ($(ELF.ELFOSABI_FREEBSD)), this may be an issue at link time
                """, '\n' => ' ')
                @lock AUDITOR_LOGGING_LOCK @warn(strip(msg))
            end
            return false
        end
    elseif call_abi(p) == "eabihf"
        # Make sure the object file has the hard-float ABI.  See Table 4-2 of
        # "ELF for the ARM Architecture" document
        # (https://developer.arm.com/documentation/ihi0044/e/).  Note: `0x000`
        # means "no specific float ABI", `0x400` == EF_ARM_ABI_FLOAT_HARD.
        if header(oh).e_flags & 0xF00 ∉ (0x000, 0x400)
            if verbose
                @lock AUDITOR_LOGGING_LOCK @error("$(basename(path(oh))) does not match the hard-float ABI")
            end
            return false
        end
    end
    return true
end

# Problem: import libraries on Windows embed information about temporary object files,
# including their modification time on disk, which makes import libraries non-reproducible:
# <https://github.com/JuliaPackaging/BinaryBuilder.jl/issues/1245>.
function normalise_implib_timestamp(path::AbstractString)
    # Format of the object file info is something like
    #     /      1674301251  0     0     644     286       `
    # where `1674301251` is the Unix timestamp of the modification time of the library, we
    # normalise it to another timestamp.  NOTE: it appears that changing the timestamp width
    # would break the library, so we use another fixed 10-digit wide timestamp.  10-digit
    # Unix timestamps span between 2001 and 2286, so we should be good for a while.
    timestamp = trunc(Int, datetime2unix(DateTime(2013, 2, 13, 0, 49, 0))) # Easter egg
    newlib = replace(read(path, String), r"(?<HEAD>/ +)(\d{10})(?<TAIL> +\d+ +\d+ +\d+ +\d+ +`)" => SubstitutionString("\\g<HEAD>$(timestamp)\\g<TAIL>"))
    # Write back the file to disk.
    write(path, newlib)
end
