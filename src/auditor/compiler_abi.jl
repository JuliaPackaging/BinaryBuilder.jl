import Pkg.BinaryPlatforms: detect_libgfortran_abi

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

    # If we find one, pass it off to Pkg.BinaryPlatforms.detect_libgfortran_abi()
    return detect_libgfortran_abi(first(fortran_libs), platform)
end

"""
    detect_libgfortran_abi(oh::ObjectHandle, platform::Platform)

Given an ObjectFile, examine its symbols to discover which (if any) C++11
std::string ABI it's using.  We do this by scanning the list of exported
symbols, triggering off of instances of `St7__cxx11` or `_ZNSs` to give
evidence toward a constraint on `cxx11`, `cxx03` or neither.
"""
function detect_cxx_abi(oh::ObjectHandle, platform::Platform)
    try
        # First, if this object doesn't link against `libstdc++`, it's a `:cxxany`
        if !any(occursin("libstdc++", l) for l in ObjectFile.path.(DynamicLinks(oh)))
            return :cxxany
        end

        symbol_names = symbol_name.(Symbols(oh))
        if any(occursin("St7__cxx11", c) for c in symbol_names)
            return :cxx11
        end
        # This finds something that either returns an `std::string` or takes it in as its last argument
        if any(occursin("Ss", c) for c in symbol_names)
            return :cxx03
        end
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        warn(io, "$(path(oh)) could not be scanned for cxx11 ABI!")
        warn(io, e)
    end
    return :cxxany
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
        each major version of GCC.  To do this, immediately after your `products`
        definition in your `build_tarballs.jl` file, add the line:
        """, '\n' => ' '))
        msg *= "\n\n    products = expand_gcc_versions(products)"
        warn(io, msg)
        return false
    end
    return true
end
