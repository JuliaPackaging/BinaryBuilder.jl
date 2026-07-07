import Base.BinaryPlatforms: detect_libstdcxx_version, detect_cxxstring_abi
using ObjectFile
using ObjectFile.ELF
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

"""
    detect_libstdcxx_version(oh::ObjectHandle, platform::AbstractPlatform)

Given an ObjectFile, examine its dynamic linkage to discover which (if any)
`libgfortran` it's linked against.  The major SOVERSION will determine which
GCC version we're restricted to.
"""
function detect_libstdcxx_version(oh::ObjectHandle, platform::AbstractPlatform)
    # We look for linkage to libstdc++
    libs = basename.(path.(DynamicLinks(oh)))
    libstdcxx_libs = filter(l -> occursin("libstdc++", l), libs)
    if isempty(libstdcxx_libs)
        return nothing
    end

    # Extract all pieces of `.gnu.version_d` from libstdc++.so, find the `GLIBCXX_*`
    # symbols, and use the maximum version of that to find the GLIBCXX ABI version number
    version_symbols = readmeta(first(libstdcxx_libs)) do ohs
        unique(vcat((x -> x.names).(vcat(ELFVersionData.(ohs)...))...))
    end
    version_symbols = filter(x -> startswith(x, "GLIBCXX_"), version_symbols)
    if isempty(version_symbols)
        # This would be weird, but let's be prepared
        return nothing
    end
    return maximum([VersionNumber(split(v, "_")[2]) for v in version_symbols])
end

function check_libstdcxx_version(oh::ObjectHandle, platform::AbstractPlatform; verbose::Bool = false)
    libstdcxx_version = nothing

    try
        libstdcxx_version = detect_libstdcxx_version(oh, platform)
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        @lock AUDITOR_LOGGING_LOCK @warn "$(path(oh)) could not be scanned for libstdcxx dependency!" exception=(e, catch_backtrace())
        return true
    end

    if verbose && libstdcxx_version != nothing
        @lock AUDITOR_LOGGING_LOCK @info("$(path(oh)) locks us to libstdc++ v$(libstdcxx_version)+")
    end

    # This actually isn't critical, so we don't complain.  Yet.
    # if libstdcxx_version(platform) === nothing && libstdcxx_version != nothing
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

function dynamic_abi_symbols(oh::ELFHandle)
    dyn_sections = findall(Sections(oh), ".dynsym")
    if !isempty(dyn_sections)
        return Symbols(first(dyn_sections))
    end
    return nothing
end

abi_symbol_names(syms) = symbol_name.(syms)

function lookup_strtab(strtab::AbstractVector{UInt8}, index::Integer)
    i = Int(index) + 1
    j = findnext(==(0x00), strtab, i)
    j === nothing && return String(strtab[i:end])
    return String(strtab[i:j-1])
end

function abi_symbol_names(syms::ELFSymbols)
    strtab = read(StrTab(syms).section_ref)
    return [lookup_strtab(strtab, deref(sym).st_name) for sym in syms]
end

has_cxx11_marker(symbol_name::AbstractString) = occursin("St7__cxx11", symbol_name) ||
                                                occursin("B5cxx11", symbol_name) ||
                                                occursin("std::__cxx11", symbol_name) ||
                                                occursin("[abi:cxx11]", symbol_name)
has_cxx03_marker(symbol_name::AbstractString) = startswith(symbol_name, "_ZNSs") || startswith(symbol_name, "_ZNSb")

function detect_cxxstring_abi(symbol_names::Vector{<:AbstractString}, platform::AbstractPlatform)
    # Fast paths on mangled names.  These avoid invoking c++filt for large C++
    # libraries when the ABI evidence is already visible in the raw symbol names.
    if any(has_cxx11_marker, symbol_names)
        return "cxx11"
    end
    if any(has_cxx03_marker, symbol_names)
        return "cxx03"
    end

    demangled_names = cppfilt(symbol_names, platform; strip_underscore=Sys.isapple(platform))
    if any(occursin("[abi:cxx11]", c) || occursin("std::__cxx11", c) for c in demangled_names)
        return "cxx11"
    end
    if any(occursin("std::string", c) || occursin("std::basic_string", c) ||
           occursin("std::list", c) for c in demangled_names)
        return "cxx03"
    end
    return nothing
end

detect_cxxstring_abi_from_symbols(syms, platform::AbstractPlatform) = detect_cxxstring_abi(abi_symbol_names(syms), platform)

function detect_dynamic_cxx11_abi(oh::ELFHandle)
    syms = dynamic_abi_symbols(oh)
    syms === nothing && return nothing

    strtab = read(StrTab(syms).section_ref)
    for sym in syms
        symbol_name = lookup_strtab(strtab, deref(sym).st_name)
        has_cxx11_marker(symbol_name) && return "cxx11"
    end
    return nothing
end

function detect_cxxstring_abi_from_symbols(syms::ELFSymbols, platform::AbstractPlatform)
    strtab = read(StrTab(syms).section_ref)
    symbol_names = String[]
    found_cxx03 = false
    for sym in syms
        symbol_name = lookup_strtab(strtab, deref(sym).st_name)
        if has_cxx11_marker(symbol_name)
            return "cxx11"
        end
        found_cxx03 |= has_cxx03_marker(symbol_name)
        push!(symbol_names, symbol_name)
    end
    found_cxx03 && return "cxx03"
    return detect_cxxstring_abi(symbol_names, platform)
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

        if isa(oh, ELFHandle)
            cxx_abi = detect_dynamic_cxx11_abi(oh)
            cxx_abi === nothing || return cxx_abi
        end

        return detect_cxxstring_abi_from_symbols(Symbols(oh), platform)
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
