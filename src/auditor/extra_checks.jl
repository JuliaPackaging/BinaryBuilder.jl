# This file contains some extra checks that don't fall into the other
# categories, for example because they're very platform-specific.

check_os_abi(::ObjectHandle, ::Platform, rest...; verbose::Bool = false, kwargs...) = true

function check_os_abi(oh::ELFHandle, ::FreeBSD, rest...; verbose::Bool = false, kwargs...)
    if oh.ei.osabi != 0x09
        # The dynamic loader should not have problems in this case, but the
        # linker may not appreciate.  Let the user know about this.
        if verbose
            @warn "OS/ABI is not set to FreeBSD (0x09) in the file header, this may be an issue at linking time"
        end
        return false
    end
    return true
end
