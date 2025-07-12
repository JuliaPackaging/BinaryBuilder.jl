import Base.BinaryPlatforms: detect_libstdcxx_version, detect_cxxstring_abi
using ObjectFile
using Binutils_jll: Binutils_jll

csl_warning(lib) = @lock AUDITOR_LOGGING_LOCK @warn(
    """
    To ensure that the correct version of $(lib) is found at runtime, add the following entry to the list of dependencies of this builder

        Dependency(PackageSpec(name="CompilerSupportLibraries_jll", uuid="e66e0078-7015-5450-92f7-15fbd957f2ae"))
    """)

"""
    detect_libgfortran_version(oh::ObjectHandle, platform::AbstractPlatform)

Given an ObjectFile, examine its dynamic linkage to discover which (if any)
`libgfortran` it's linked against.  The major SOVERSION will determine which
GCC version we're restricted to.
"""
function detect_libgfortran_version(oh::ObjectHandle, platform::AbstractPlatform)
    # We look for linkage to libgfortran
    libs = basename.(path.(DynamicLinks(oh)))
    fortran_libs = filter(l -> occursin("libgfortran", l), libs)
    if isempty(fortran_libs)
        return nothing
    end

    # If we find one, pass it off to `parse_dl_name_version`
    name, version = parse_dl_name_version(first(fortran_libs), os(platform))
    return version
end

function check_libgfortran_version(oh::ObjectHandle, platform::AbstractPlatform; verbose::Bool = false,
                                   has_csl::Bool = true)
    version = nothing
    try
        version = detect_libgfortran_version(oh, platform)
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        @lock AUDITOR_LOGGING_LOCK @warn "$(path(oh)) could not be scanned for libgfortran dependency!" exception=(e, catch_backtrace())
        return true
    end

    if verbose && version !== nothing
        @lock AUDITOR_LOGGING_LOCK @info("$(path(oh)) locks us to libgfortran v$(version)")
    end

    if !has_csl && version !== nothing
        csl_warning("libgfortran")
    end

    if libgfortran_version(platform) === nothing && version !== nothing
        msg = strip(replace("""
        $(path(oh)) links to libgfortran!  This causes incompatibilities across
        major versions of GCC.  To remedy this, you must build a tarball for
        each major version of GCC.  To do this, immediately after your `platforms`
        definition in your `build_tarballs.jl` file, add the line:
        """, '\n' => ' '))
        msg *= "\n\n    platforms = expand_gfortran_versions(platforms)"
        @lock AUDITOR_LOGGING_LOCK @warn(msg)
        return false
    end

    if libgfortran_version(platform) !== nothing !== version && libgfortran_version(platform) != version
        msg = strip(replace("""
        $(path(oh)) links to libgfortran$(version.major), but we are supposedly building
        for libgfortran$(libgfortran_version(platform).major). This usually indicates that
        the build system is somehow ignoring our choice of compiler!
        """, '\n' => ' '))
        @lock AUDITOR_LOGGING_LOCK @warn(msg)
        return false
    end
    return true
end

function check_csl_libs(oh::ObjectHandle, platform::AbstractPlatform; verbose::Bool=false,
                        has_csl::Bool=true, csl_libs::Vector{String}=["libgomp", "libatomic"])
    if has_csl
        # No need to do any check, CompilerSupportLibraries_jll is already a dependency
        return true
    end

    # Collect list of dependencies
    libs = try
        basename.(path.(DynamicLinks(oh)))
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        @lock AUDITOR_LOGGING_LOCK @warn "$(path(oh)) could not be scanned for $(lib) dependency!" exception=(e, catch_backtrace())
        return true
    end

    # If any of the libs is a library provided by
    # `CompilerSupportLibraries_jll`, suggest to add the package as dependency
    for lib in csl_libs
        if length(filter(l -> occursin(lib, l), libs)) >= 1
            csl_warning(lib)
            return false
        end
    end

    return true
end

function cppfilt(symbol_names::Vector, platform::AbstractPlatform; strip_underscore::Bool=false)
    input = IOBuffer()
    for name in symbol_names
        println(input, name)
    end
    seekstart(input)

    output = IOBuffer()
    cmd = if Binutils_jll.is_available()
        ignorestatus(Binutils_jll.cxxfilt())
    else
        Cmd(`/opt/bin/$(triplet(platform))/c++filt`; ignorestatus=true)
    end
    if strip_underscore
        cmd = `$(cmd) --strip-underscore`
    end

    if Binutils_jll.is_available()
        run(pipeline(cmd; stdin=input, stdout=output))
    else
        mktempdir() do dir
            # No need to acquire a sandbox lock here because we use a (hopefully)
            # different temporary directory for each run.
            ur = preferred_runner()(dir; cwd="/workspace/", platform=platform)
            run_interactive(ur, cmd; stdin=input, stdout=output)
        end
    end

    return filter!(s -> !isempty(s), split(String(take!(output)), "\n"))
end

"""
    detect_cxxstring_abi(oh::ObjectHandle, platform::AbstractPlatform)

Given an ObjectFile, examine its symbols to discover which (if any) C++11
std::string ABI it's using.  We do this by scanning the list of exported
symbols, triggering off of instances of `St7__cxx11` or `_ZNSs` to give
evidence toward a constraint on `cxx11`, `cxx03` or neither.
"""
function detect_cxxstring_abi(oh::ObjectHandle, platform::AbstractPlatform)
    try
        # First, if this object doesn't link against `libstdc++`, it's a `:cxxany`
        if !any(occursin("libstdc++", l) for l in ObjectFile.path.(DynamicLinks(oh)))
            return nothing
        end

        # GCC on macOS prepends an underscore to symbols, strip it.
        symbol_names = cppfilt(symbol_name.(Symbols(oh)), platform; strip_underscore=Sys.isapple(platform))
        # Shove the symbol names through c++filt (since we don't want to have to
        # reimplement the parsing logic in Julia).  If anything has `cxx11` tags,
        # then mark it as such.
        if any(occursin("[abi:cxx11]", c) || occursin("std::__cxx11", c) for c in symbol_names)
            return "cxx11"
        end
        # Otherwise, if we still have `std::string`'s or `std::list`'s in there, it's implicitly a
        # `cxx03` binary, even though we don't have a __cxx03 namespace or something.  Mark it.
        if any(occursin("std::string", c) || occursin("std::basic_string", c) ||
               occursin("std::list", c) for c in symbol_names)
            return "cxx03"
        end
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        @lock AUDITOR_LOGGING_LOCK @warn "$(path(oh)) could not be scanned for cxx11 ABI!" exception=(e, catch_backtrace())
    end
    return nothing
end


function check_cxxstring_abi(oh::ObjectHandle, platform::AbstractPlatform; io::IO = stdout, verbose::Bool = false)
    # First, check the stdlibc++ string ABI to see if it is a superset of `platform`.  If it's
    # not, then we have a problem!
    cxx_abi = detect_cxxstring_abi(oh, platform)

    # If no std::string symbols found, just exit out immediately
    if cxx_abi == nothing
        return true
    end

    if verbose && cxx_abi != nothing
        @lock AUDITOR_LOGGING_LOCK @info("$(path(oh)) locks us to $(cxx_abi)")
    end

    if cxxstring_abi(platform) == nothing && cxx_abi != nothing
        msg = strip(replace("""
        $(path(oh)) contains std::string values!  This causes incompatibilities across
        the GCC 4/5 version boundary.  To remedy this, you must build a tarball for
        both GCC 4 and GCC 5.  To do this, immediately after your `platforms`
        definition in your `build_tarballs.jl` file, add the line:
        """, '\n' => ' '))
        msg *= "\n\n    platforms = expand_cxxstring_abis(platforms)"
        @lock AUDITOR_LOGGING_LOCK @warn(msg)
        return false
    end

    if cxxstring_abi(platform) != cxx_abi
        msg = strip(replace("""
        $(path(oh)) contains $(cxx_abi) ABI std::string values within its public interface,
        but we are supposedly building for $(cxxstring_abi(platform)) ABI. This usually
        indicates that the build system is somehow ignoring our choice of compiler, as we manually
        insert the correct compiler flags for this ABI choice!
        """, '\n' => ' '))
        @lock AUDITOR_LOGGING_LOCK @warn(msg)
        return false
    end
    return true
end
