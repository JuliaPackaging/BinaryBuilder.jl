import BinaryProvider: detect_libgfortran_abi

"""
    detect_libgfortran_abi(oh::ObjectHandle, platform::Platform)

Given an ObjectFile, examine its dynamic linkage to discover which (if any)
`libgfortran` it's linked against.  The major SOVERSION will determine which
GCC version we're restricted to.
"""
function detect_libgfortran_abi(oh::ObjectHandle, platform::Platform)
    # We look for linkage to libgfortran
    libs = basename.(path.(DynamicLinks(oh)))
    fortran_libs = filter(l -> occursin("libgfortran", l), libs)
    if isempty(fortran_libs)
        return :gcc_any
    end

    # If we find one, pass it off to BinaryProvider.detect_libgfortran_abi()
    return detect_libgfortran_abi(first(fortran_libs), platform)
end

function check_gcc_version(oh::ObjectHandle, platform::Platform; io::IO = stdout, verbose::Bool = false)
    # First, check the GCC version to see if it is a superset of `platform`.  If it's
    # not, then we have a problem!
    gcc_version = :gcc_any

    try
        gcc_version = detect_libgfortran_abi(oh, platform)
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        warn(io, "$(path(oh)) could not be scanned for libgfortran dependency!")
        warn(io, e)
        return true
    end

    if verbose && gcc_version != :gcc_any
        info(io, "$(path(oh)) locks us to $(gcc_version)")
    end

    if compiler_abi(platform).gcc_version == :gcc_any && gcc_version != :gcc_any
        msg = strip(replace("""
        $(path(oh)) links to libgfortran!  This causes incompatibilities across
        major versions of GCC.  To remedy this, you must build a tarball for
        each major version of GCC.  To do this, immediately after your `platforms`
        definition in your `build_tarballs.jl` file, add the line:
        """, '\n' => ' '))
        msg *= "\n\n    platforms = expand_gcc_versions(platforms)"
        warn(io, msg)
        return false
    end
    return true
end
