# This file contains some extra checks that don't fall into the other
# categories, for example because they're very platform-specific.

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
                @warn(strip(msg))
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
                @error("$(basename(path(oh))) does not match the hard-float ABI")
            end
            return false
        end
    end
    return true
end
