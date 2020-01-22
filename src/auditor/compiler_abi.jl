import Pkg.BinaryPlatforms: detect_libgfortran_version, detect_libstdcxx_version, detect_cxxstring_abi
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

function check_libgfortran_version(oh::ObjectHandle, platform::Platform; verbose::Bool = false)
    libgfortran_version = nothing
    try
        libgfortran_version = detect_libgfortran_version(oh, platform)
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        audit_warn("$(path(oh)) could not be scanned for libgfortran dependency!",
                   @__FILE__, @__LINE__; show_long = false)
        @warn "$(path(oh)) could not be scanned for libgfortran dependency!" exception=(e, catch_backtrace())
        return true
    end

    if verbose && libgfortran_version != nothing
        @info("$(path(oh)) locks us to libgfortran v$(libgfortran_version)")
    end

    if compiler_abi(platform).libgfortran_version === nothing && libgfortran_version != nothing
        msg = strip(replace("""
        $(path(oh)) links to libgfortran!  This causes incompatibilities across
        major versions of GCC.  To remedy this, you must build a tarball for
        each major version of GCC.  To do this, immediately after your `platforms`
        definition in your `build_tarballs.jl` file, add the line:
        """, '\n' => ' '))
        msg *= "\n\n    platforms = expand_gfortran_versions(platforms)"
        audit_warn(msg, @__FILE__, @__LINE__)
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

function check_libstdcxx_version(oh::ObjectHandle, platform::Platform; verbose::Bool = false)
    libstdcxx_version = nothing

    try
        libstdcxx_version = detect_libstdcxx_version(oh, platform)
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        audit_warn("$(path(oh)) could not be scanned for libstdcxx dependency!",
                   @__FILE__, @__LINE__; show_long = false)
        @warn "$(path(oh)) could not be scanned for libstdcxx dependency!" exception=(e, catch_backtrace())
        return true
    end

    if verbose && libstdcxx_version != nothing
        @info("$(path(oh)) locks us to libstdc++ v$(libstdcxx_version)+")
    end

    # This actually isn't critical, so we don't complain.  Yet.
    # if compiler_abi(platform).libstdcxx_version === nothing && libstdcxx_version != nothing
    #     msg = strip(replace("""
    #     $(path(oh)) links to libstdc++!  This causes incompatibilities across
    #     major versions of GCC.  To remedy this, you must build a tarball for
    #     each major version of GCC.  To do this, immediately after your `platforms`
    #     definition in your `build_tarballs.jl` file, add the line:
    #     """, '\n' => ' '))
    #     msg *= "\n\n    platforms = expand_cxxstring_abis(platforms)"
    #     warn(io, msg)
    #     return false
    # end
    return true
end

function cppfilt(symbol_names::Vector, platform::Platform)
    input = IOBuffer()
    for name in symbol_names
        println(input, name)
    end
    seekstart(input)

    output = IOBuffer()
    mktemp() do t, io
        ur = preferred_runner()(dirname(t); cwd="/workspace/", platform=platform)
        run_interactive(ur, `/opt/bin/c++filt`; stdin=input, stdout=output)
    end

    return filter!(s -> !isempty(s), split(String(take!(output)), "\n"))
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

        symbol_names = cppfilt(symbol_name.(Symbols(oh)), platform)
        # Shove the symbol names through c++filt (since we don't want to have to
        # reimplement the parsing logic in Julia).  If anything has `cxx11` tags,
        # then mark it as such.
        if any(occursin("[abi:cxx11]", c) || occursin("std::__cxx11", c) for c in symbol_names)
            return :cxx11
        end
        # Otherwise, if we still have `std::string`'s or `std::list`'s in there, it's implicitly a
        # `cxx03` binary, even though we don't have a __cxx03 namespace or something.  Mark it.
        if any(occursin("std::string", c) || occursin("std::basic_string", c) ||
               occursin("std::list", c) for c in symbol_names)
            return :cxx03
        end
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        audit_warn("$(path(oh)) could not be scanned for cxx11 ABI!",
                   @__FILE__, @__LINE__; show_long = false)
        @warn "$(path(oh)) could not be scanned for cxx11 ABI!" exception=(e, catch_backtrace())
    end
    return nothing
end


function check_cxxstring_abi(oh::ObjectHandle, platform::Platform; io::IO = stdout, verbose::Bool = false)
    # First, check the stdlibc++ string ABI to see if it is a superset of `platform`.  If it's
    # not, then we have a problem!
    cxx_abi = detect_cxxstring_abi(oh, platform)

    # If no std::string symbols found, just exit out immediately
    if cxx_abi == nothing
        return true
    end

    if verbose && cxx_abi != nothing
        @info("$(path(oh)) locks us to $(cxx_abi)")
    end

    if compiler_abi(platform).cxxstring_abi == nothing && cxx_abi != nothing
        msg = strip(replace("""
        $(path(oh)) contains std::string values!  This causes incompatibilities across
        the GCC 4/5 version boundary.  To remedy this, you must build a tarball for
        both GCC 4 and GCC 5.  To do this, immediately after your `platforms`
        definition in your `build_tarballs.jl` file, add the line:
        """, '\n' => ' '))
        msg *= "\n\n    platforms = expand_cxxstring_abis(platforms)"
        audit_warn("Need to expand C++ string ABIs", msg, @__FILE__, @__LINE__)
        return false
    end

    if compiler_abi(platform).cxxstring_abi != cxx_abi
        msg = strip(replace("""
        $(path(oh)) contains $(cxx_abi) ABI std::string values within its public interface,
        but we are supposedly building for $(compiler_abi(platform).cxxstring_abi) ABI. This usually
        indicates that the build system is somehow ignoring our choice of compiler, as we manually
        insert the correct compiler flags for this ABI choice!
        """, '\n' => ' '))
        audit_warn("Requested C++ string ABI has been ignored", msg, @__FILE__, @__LINE__)
        return false
    end
    return true
end
