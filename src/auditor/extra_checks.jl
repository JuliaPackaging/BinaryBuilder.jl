# This file contains some extra checks that don't fall into the other
# categories, for example because they're very platform-specific.

check_os_abi(::ObjectHandle, ::Platform, rest...; verbose::Bool = false, kwargs...) = true

function check_os_abi(oh::ELFHandle, ::FreeBSD, rest...; verbose::Bool = false, kwargs...)
    if oh.ei.osabi != ELF.ELFOSABI_FREEBSD
        # The dynamic loader should not have problems in this case, but the
        # linker may not appreciate.  Let the user know about this.
        if verbose
            msg = replace("""
            $(basename(path(oh))) has an ELF header OS/ABI value that is not set to FreeBSD
            ($(ELF.ELFOSABI_FREEBSD)), this may be an issue at link time"
            """, '\n' => ' ')
            @warn(strip(msg))
        end
        return false
    end
    return true
end
