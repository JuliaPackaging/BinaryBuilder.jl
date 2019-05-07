import Pkg: detect_libgfortran_abi

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
        return :libgfortran_any
    end

    # If we find one, pass it off to Pkg.detect_libgfortran_abi()
    return detect_libgfortran_abi(first(fortran_libs), platform)
end

function check_libgfortran_version(oh::ObjectHandle, platform::Platform; io::IO = stdout, verbose::Bool = false)
    # First, check the GCC version to see if it is a superset of `platform`.  If it's
    # not, then we have a problem!
    libgfortran_version = :libgfortran_any

    try
        libgfortran_version = detect_libgfortran_abi(oh, platform)
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        warn(io, "$(path(oh)) could not be scanned for libgfortran dependency!")
        warn(io, e)
        return true
    end

    if verbose && libgfortran_version != :libgfortran_any
        info(io, "$(path(oh)) locks us to $(libgfortran_version)")
    end

    if compiler_abi(platform).libgfortran_version == :libgfortran_any && libgfortran_version != :libgfortran_any
        msg = strip(replace("""
        $(path(oh)) links to libgfortran!  This causes incompatibilities across
        major versions of GCC.  To remedy this, you must build a tarball for
        each major version of GCC.  To do this, immediately after your `products`
        definition in your `build_tarballs.jl` file, add the line:
        """, '\n' => ' '))
        msg *= "\n\n    products = expand_gfortran_versions(products)"
        warn(io, msg)
        return false
    end
    return true
end


"""
    detect_cxx_abi(oh::ObjectHandle, platform::Platform)

Given an ObjectFile, examine its symbols to discover which (if any) C++11
std::string ABI it's using.  We do this by scanning the list of exported
symbols, triggering off of instances of `St7__cxx11` or `_ZNSs` to give
evidence toward a constraint on `cxx11`, `cxx03` or neither.
"""
function detect_cxx_abi(oh::ObjectHandle, platform::Platform)
    try
        # First, if this object doesn't link against `libstdc++`, it's a `:cxxany`
        if !any(occursin("libstdc++", l) for l in ObjectFile.path.(DynamicLinks(oh)))
            return :cxx_any
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
    return :cxx_any
end


function check_cxx_string_abi(oh::ObjectHandle, platform::Platform; io::IO = stdout, verbose::Bool = false)
    # First, check the stdlibc++ string ABI to see if it is a superset of `platform`.  If it's
    # not, then we have a problem!
    cxx_abi = :cxx_any

    try
        cxx_abi = detect_cxx_abi(oh, platform)
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        warn(io, "$(path(oh)) could not be scanned for cxx11 string ABI!")
        warn(io, e)
        return true
    end

    if verbose && cxx_abi != :cxx_any
        info(io, "$(path(oh)) locks us to $(cxx_abi)")
    end

    if compiler_abi(platform).cxxstring_abi == :cxx_any && cxx_abi != :cxx_any
        msg = strip(replace("""
        $(path(oh)) contains std::string values!  This causes incompatibilities across
        the GCC 4/5 version boundary.  To remedy this, you must build a tarball for
        both GCC 4 and GCC 5.  To do this, immediately after your `products`
        definition in your `build_tarballs.jl` file, add the line:
        """, '\n' => ' '))
        msg *= "\n\n    products = expand_cxx_versions(products)"
        warn(io, msg)
        return false
    end
    return true
end
