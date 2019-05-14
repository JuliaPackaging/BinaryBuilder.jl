import Pkg: detect_libgfortran_version, detect_libstdcxx_version, detect_cxxstring_abi
using ObjectFile

"""
    detect_libgfortran_version(oh::ObjectHandle, platform::Platform)

Given an ObjectFile, examine its dynamic linkage to discover which (if any)
`libgfortran` it's linked against.  The major SOVERSION will determine which
GCC version we're restricted to.
"""
function detect_libgfortran_version(oh::ObjectHandle, platform::Platform)
    # We look for linkage to libgfortran
    libs = basename.(path.(DynamicLinks(oh)))
    fortran_libs = filter(l -> occursin("libgfortran", l), libs)
    if isempty(fortran_libs)
        return nothing
    end

    # If we find one, pass it off to Pkg.detect_libgfortran_version()
    return detect_libgfortran_version(first(fortran_libs), platform)
end

function check_libgfortran_version(oh::ObjectHandle, platform::Platform; io::IO = stdout, verbose::Bool = false)
    libgfortran_version = nothing
    try
        libgfortran_version = detect_libgfortran_version(oh, platform)
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        warn(io, "$(path(oh)) could not be scanned for libgfortran dependency!")
        warn(io, e)
        return true
    end

    if verbose && libgfortran_version != nothing
        info(io, "$(path(oh)) locks us to libgfortran v$(libgfortran_version)")
    end

    if compiler_abi(platform).libgfortran_version === nothing && libgfortran_version != nothing
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
    detect_libstdcxx_version(oh::ObjectHandle, platform::Platform)

Given an ObjectFile, examine its dynamic linkage to discover which (if any)
`libgfortran` it's linked against.  The major SOVERSION will determine which
GCC version we're restricted to.
"""
function detect_libstdcxx_version(oh::ObjectHandle, platform::Platform)
    # We look for linkage to libstdc++
    libs = basename.(path.(DynamicLinks(oh)))
    libstdcxx_libs = filter(l -> occursin("libstdc++", l), libs)
    if isempty(libstdcxx_libs)
        return nothing
    end

    # Extract all pieces of `.gnu.version_d` from libstdc++.so, find the `GLIBCXX_*`
    # symbols, and use the maximum version of that to find the GLIBCXX ABI version number
    version_symbols = readmeta(first(libstdcxx_libs)) do oh
        unique(vcat((x -> x.names).(ELFVersionData(oh))...))
    end
    version_symbols = filter(x -> startswith(x, "GLIBCXX_"), version_symbols)
    if isempty(version_symbols)
        # This would be weird, but let's be prepared
        return nothing
    end
    return maximum([VersionNumber(split(v, "_")[2]) for v in version_symbols])
end

function check_libstdcxx_version(oh::ObjectHandle, platform::Platform; io::IO = stdout, verbose::Bool = false)
    libstdcxx_version = nothing

    try
        libstdcxx_version = detect_libstdcxx_version(oh, platform)
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        warn(io, "$(path(oh)) could not be scanned for libstdcxx dependency!")
        warn(io, e)
        return true
    end

    if verbose && libstdcxx_version != nothing
        info(io, "$(path(oh)) locks us to libstdc++ v$(libstdcxx_version)+")
    end

    # This actually isn't critical, so we don't complain.  Yet.
    # if compiler_abi(platform).libstdcxx_version === nothing && libstdcxx_version != nothing
    #     msg = strip(replace("""
    #     $(path(oh)) links to libstdc++!  This causes incompatibilities across
    #     major versions of GCC.  To remedy this, you must build a tarball for
    #     each major version of GCC.  To do this, immediately after your `products`
    #     definition in your `build_tarballs.jl` file, add the line:
    #     """, '\n' => ' '))
    #     msg *= "\n\n    products = expand_cxx_versions(products)"
    #     warn(io, msg)
    #     return false
    # end
    return true
end


"""
    detect_cxxstring_abi(oh::ObjectHandle, platform::Platform)

Given an ObjectFile, examine its symbols to discover which (if any) C++11
std::string ABI it's using.  We do this by scanning the list of exported
symbols, triggering off of instances of `St7__cxx11` or `_ZNSs` to give
evidence toward a constraint on `cxx11`, `cxx03` or neither.
"""
function detect_cxxstring_abi(oh::ObjectHandle, platform::Platform)
    try
        # First, if this object doesn't link against `libstdc++`, it's a `:cxxany`
        if !any(occursin("libstdc++", l) for l in ObjectFile.path.(DynamicLinks(oh)))
            return nothing
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
    return nothing
end


function check_cxxstring_abi(oh::ObjectHandle, platform::Platform; io::IO = stdout, verbose::Bool = false)
    # First, check the stdlibc++ string ABI to see if it is a superset of `platform`.  If it's
    # not, then we have a problem!
    cxx_abi = nothing

    try
        cxx_abi = detect_cxxstring_abi(oh, platform)
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        warn(io, "$(path(oh)) could not be scanned for cxx11 string ABI!")
        warn(io, e)
        return true
    end

    if verbose && cxx_abi != nothing
        info(io, "$(path(oh)) locks us to $(cxx_abi)")
    end

    if compiler_abi(platform).cxxstring_abi == nothing && cxx_abi != nothing
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
