export Product, LibraryProduct, FileProduct, ExecutableProduct, FrameworkProduct, satisfied,
       locate, write_deps_file, variable_name
import Base: repr

"""
A `Product` is an expected result after building or installation of a package.

Examples of `Product`s include [`LibraryProduct`](@ref), [`FrameworkProduct`](@ref),
[`ExecutableProduct`](@ref) and [`FileProduct`](@ref). All `Product` types must
define the following minimum set of functionality:

* [`locate(::Product)`](@ref): given a `Product`, locate it within
  the wrapped `Prefix` returning its location as a string

* [`satisfied(::Product)`](@ref): given a `Product`, determine whether it has
  been successfully satisfied (e.g. it is locateable and it passes all
  callbacks)

* [`variable_name(::Product)`](@ref): return the variable name assigned to a
  `Product`

* `repr(::Product)`: Return a representation of this `Product`, useful for
  auto-generating source code that constructs `Products`, if that's your thing.
"""
abstract type Product end

# We offer some simple platform-based templating
function template(x::String, p::Platform)
    libdir(p::Platform) = "lib"
    libdir(p::Windows) = "bin"
    for (var, val) in [
            ("libdir", libdir(p)),
            ("target", triplet(p)),
            ("nbits", wordsize(p)),
            ("arch", arch(p)),
        ]
        x = replace(x, "\$$(var)" => val)
        x = replace(x, "\${$(var)}" => val)
    end
    return x
end

"""
    satisfied(p::Product;
              platform::Platform = platform_key_abi(),
              verbose::Bool = false,
              isolate::Bool = false)

Given a [`Product`](@ref), return `true` if that `Product` is satisfied,
e.g. whether a file exists that matches all criteria setup for that `Product`.
If `isolate` is set to `true`, will isolate all checks from the main Julia
process in the event that `dlopen()`'ing a library might cause issues.
"""
function satisfied(p::Product, prefix::Prefix; kwargs...)
    return locate(p, prefix; kwargs...) != nothing
end


"""
    variable_name(p::Product)

Return the variable name associated with this [`Product`](@ref) as a string
"""
function variable_name(p::Product)
    return string(p.variable_name)
end


"""
A `LibraryProduct` is a special kind of [`Product`](@ref) that not only needs to
exist, but needs to be `dlopen()`'able.  You must know which directory the
library will be installed to, and its name, e.g. to build a `LibraryProduct`
that refers to `"/lib/libnettle.so"`, the "directory" would be "/lib", and the
"libname" would be "libnettle".  Note that a `LibraryProduct` can support
multiple libnames, as some software projects change the libname based on the
build configuration.
"""
struct LibraryProduct <: Product
    libnames::Vector{String}
    variable_name::Symbol
    dir_paths::Vector{String}
    dont_dlopen::Bool
    dlopen_flags::Vector{Symbol}

    """
        LibraryProduct(libnames, varname::Symbol)

    Declares a [`LibraryProduct`](@ref) that points to a library located within
    the `libdir` of the given `Prefix`, with a name containing `libname`.  As an
    example, given that `libdir(prefix)` is equal to `usr/lib`, and `libname` is
    equal to `libnettle`, this would be satisfied by the following paths:

        usr/lib/libnettle.so
        usr/lib/libnettle.so.6
        usr/lib/libnettle.6.dylib
        usr/lib/libnettle-6.dll

    Libraries matching the search pattern are rejected if they are not
    `dlopen()`'able.
    """
    LibraryProduct(libname::AbstractString, varname, args...; kwargs...) = LibraryProduct([libname], varname, args...; kwargs...)
    function LibraryProduct(libnames::Vector{<:AbstractString}, varname::Symbol,
                            dir_paths::Vector{<:AbstractString}=String[];
                            dont_dlopen::Bool=false,
                            dlopen_flags::Vector{Symbol}=Symbol[])
        if isdefined(Base, varname)
            error("`$(varname)` is already defined in Base")
        end
        # catch invalid flags as early as possible
        for flag in dlopen_flags
            isdefined(Libdl, flag) || error("Libdl.$flag is not a valid flag")
        end
        # If some other kind of AbstractString is passed in, convert it
        return new([string(l) for l in libnames], varname, string.(dir_paths), dont_dlopen, dlopen_flags)
    end

    LibraryProduct(meta_obj::Dict) = new(
        String.(meta_obj["libnames"]),
        Symbol(meta_obj["variable_name"]),
        String.(meta_obj["dir_paths"]),
        meta_obj["dont_dlopen"],
        Symbol.(meta_obj["dlopen_flags"]),
    )
end

function dlopen_flags_str(p::LibraryProduct)
    if length(p.dlopen_flags) > 0
        return ", $(join(p.dlopen_flags, " | "))"
    else
        return ""
    end
end

function Base.:(==)(a::LibraryProduct, b::LibraryProduct)
    return a.libnames == b.libnames && a.variable_name == b.variable_name &&
           a.dir_paths == b.dir_paths && a.dont_dlopen == b.dont_dlopen
end

function repr(p::LibraryProduct)
    libnames = repr(p.libnames)
    varname = repr(p.variable_name)
    if isempty(p.dir_paths)
        return "LibraryProduct($(libnames), $(varname))"
    else
        return "LibraryProduct($(libnames), $(varname), $(repr(p.dir_paths)))"
    end
end

"""
    locate(lp::LibraryProduct, prefix::Prefix;
           verbose::Bool = false,
           platform::Platform = platform_key_abi())

If the given library exists (under any reasonable name) and is `dlopen()`able,
(assuming it was built for the current platform) return its location.  Note
that the `dlopen()` test is only run if the current platform matches the given
`platform` keyword argument, as cross-compiled libraries cannot be `dlopen()`ed
on foreign platforms.
"""
function locate(lp::LibraryProduct, prefix::Prefix; platform::Platform = platform_key_abi(),
                verbose::Bool = false, isolate::Bool = true, skip_dlopen::Bool=false, kwargs...)
    dir_paths = joinpath.(prefix.path, template.(lp.dir_paths, Ref(platform)))
    append!(dir_paths, libdirs(prefix, platform))

    for dir_path in dir_paths
        if !isdir(dir_path)
            continue
        end

        for f in readdir(dir_path)
            # Skip any names that aren't a valid dynamic library for the given
            # platform (note this will cause problems if something compiles a `.so`
            # on OSX, for instance)
            if !valid_dl_path(f, platform)
                continue
            end

            if verbose
                @info("Found a valid dl path $(f) while looking for $(join(lp.libnames, ", "))")
            end

            # If we found something that is a dynamic library, let's check to see
            # if it matches our libname:
            for libname in lp.libnames
                libname = template(libname, platform)

                parsed_libname, parsed_version = parse_dl_name_version(basename(f), platform)
                if parsed_libname == libname
                    dl_path = abspath(joinpath(dir_path), f)
                    if verbose
                        @info("$(dl_path) matches our search criteria of $(libname)")
                    end

                    # If it does, try to `dlopen()` it if the current platform is good
                    if (!lp.dont_dlopen && !skip_dlopen) && platforms_match(platform, platform_key_abi())
                        if isolate
                            # Isolated dlopen is a lot slower, but safer
                            if success(`$(Base.julia_cmd()) --startup-file=no -e "import Libdl; Libdl.dlopen(\"$dl_path\")"`)
                                return dl_path
                            end
                        else
                            hdl = Libdl.dlopen_e(dl_path)
                            if !(hdl in (C_NULL, nothing))
                                Libdl.dlclose(hdl)
                                return dl_path
                            end
                        end

                        if verbose
                            @info("$(dl_path) cannot be dlopen'ed")
                        end
                    else
                        # If the current platform doesn't match, then just trust in our
                        # cross-compilers and go with the flow
                        return dl_path
                    end
                end
            end
        end
    end

    if verbose
        @info("Could not locate $(join(lp.libnames, ", ")) inside $(dir_paths)")
    end
    return nothing
end

"""
A `FrameworkProduct` is a  [`Product`](@ref) that encapsulates a macOS Framework.
It behaves mostly as a [`LibraryProduct`](@ref) for now, but is a distinct type.
This implies that for cross-platform builds where a library is provided as a Framework
on macOS and as a normal library on other platforms, two calls to [`build_tarballs`](@ref)
are needed: one with the `LibraryProduct` and all non-macOS platforms, and one with the `FrameworkProduct`
and the `MacOS` platforms.
"""
struct FrameworkProduct <: Product
    libraryproduct::LibraryProduct

    """
        FrameworkProduct(fwnames, varname::Symbol)

    Declares a macOS [`FrameworkProduct`](@ref) that points to a framework located within
    the `libdir` of the given `Prefix`, with a name containing `fwname` appended with `.framework`.  As an
    example, given that `libdir(prefix)` is equal to `usr/lib`, and `fwname` is
    equal to `QtCore`, this would be satisfied by the following paths:

        usr/lib/QtCore.framework
    """
    FrameworkProduct(fwname::AbstractString, varname, args...; kwargs...) = FrameworkProduct([fwname], varname, args...; kwargs...)
    function FrameworkProduct(fwnames::Vector{<:AbstractString}, varname::Symbol,
                            dir_paths::Vector{<:AbstractString}=String[];
                            kwargs...)
        # If some other kind of AbstractString is passed in, convert it
        return new(LibraryProduct(fwnames, varname, dir_paths; kwargs...))
    end

    FrameworkProduct(meta_obj::Dict) = new(LibraryProduct(meta_obj))
end

Base.:(==)(a::FrameworkProduct, b::FrameworkProduct) = (a.libraryproduct == b.libraryproduct)

repr(p::FrameworkProduct) = "Framework" * repr(p.libraryproduct)[8:end]

variable_name(fp::FrameworkProduct) = variable_name(fp.libraryproduct)

function locate(fp::FrameworkProduct, prefix::Prefix; platform::Platform = platform_key_abi(), verbose::Bool = false, kwargs...)
    dir_paths = joinpath.(prefix.path, template.(fp.libraryproduct.dir_paths, Ref(platform)))
    append!(dir_paths, libdirs(prefix, platform))
    for dir_path in dir_paths
        if !isdir(dir_path)
            continue
        end
        for libname in fp.libraryproduct.libnames
            framework_dir = joinpath(dir_path,libname*".framework")
            if isdir(framework_dir)
                currentversion = joinpath(framework_dir, "Versions", "Current")
                if islink(currentversion)
                    currentversion = joinpath(framework_dir, "Versions", readlink(currentversion))
                end
                if isdir(currentversion)
                    dl_path = abspath(joinpath(currentversion, libname))
                    if isfile(dl_path)
                        if verbose
                            @info("$(dl_path) matches our search criteria of framework $(libname)")
                        end
                        return dl_path
                    end
                end
            end
        end
    end

    if verbose
        @info("No match found for $fp")
    end
    return nothing
end

dlopen_flags_str(p::FrameworkProduct) = dlopen_flags_str(p.libraryproduct)

"""
An `ExecutableProduct` is a [`Product`](@ref) that represents an executable file.

On all platforms, an ExecutableProduct checks for existence of the file.  On
non-Windows platforms, it will check for the executable bit being set.  On
Windows platforms, it will check that the file ends with ".exe", (adding it on
automatically, if it is not already present).
"""
struct ExecutableProduct <: Product
    binnames::Vector{String}
    variable_name::Symbol
    dir_path::Union{String, Nothing}

    """
        ExecutableProduct(binnames::Vector{String}, varname::Symbol)

    Declares an `ExecutableProduct` that points to an executable located within
    the `bindir` of the given `Prefix`, named one of the given `binname`s.
    """
    function ExecutableProduct(binnames::Vector{String}, varname::Symbol, dir_path::Union{AbstractString, Nothing}=nothing)
        if isdefined(Base, varname)
            error("`$(varname)` is already defined in Base")
        end
        # If some other kind of AbstractString is passed in, convert it
        if dir_path != nothing
            dir_path = string(dir_path)
        end
        return new(binnames, varname, dir_path)
    end
    ExecutableProduct(binname::AbstractString, varname::Symbol, args...) = ExecutableProduct([string(binname)], varname, args...)

    ExecutableProduct(meta_obj::Dict) = new(
        String.(meta_obj["binnames"]),
        Symbol(meta_obj["variable_name"]),
        meta_obj["dir_path"],
    )
end
function Base.:(==)(a::ExecutableProduct, b::ExecutableProduct)
    return a.binnames == b.binnames && a.variable_name == b.variable_name &&
           a.dir_path == b.dir_path
end

function repr(p::ExecutableProduct)
    varname = repr(p.variable_name)
    binnames = repr(p.binnames)
    if p.dir_path != nothing
        return "ExecutableProduct($(binnames), $(varname), $(repr(p.dir_path))"
    else
        return "ExecutableProduct($(binnames), $(varname))"
    end
end

"""
    locate(ep::ExecutableProduct, prefix::Prefix;
           platform::Platform = platform_key_abi(),
           verbose::Bool = false,
           isolate::Bool = false)

If the given executable file exists and is executable, return its path.

On all platforms, an [`ExecutableProduct`](@ref) checks for existence of the
file.  On non-Windows platforms, it will check for the executable bit being set.
On Windows platforms, it will check that the file ends with ".exe", (adding it
on automatically, if it is not already present).
"""
function locate(ep::ExecutableProduct, prefix::Prefix; platform::Platform = platform_key_abi(),
                verbose::Bool = false, isolate::Bool = false, kwargs...)
    for binname in ep.binnames
        # On windows, we always slap an .exe onto the end if it doesn't already
        # exist, as Windows won't execute files that don't have a .exe at the end.
        binname = if platform isa Windows && !endswith(binname, ".exe")
            "$(binname).exe"
        else
            binname
        end

        # Join into the `dir_path` given by the executable product
        if ep.dir_path != nothing
            path = joinpath(prefix.path, template(joinpath(ep.dir_path, binname), platform))
        else
            path = joinpath(bindir(prefix), template(binname, platform))
        end

        if isfile(path)
            # If the file is not executable, fail out (unless we're on windows since
            # windows doesn't honor these permissions on its filesystems)
            @static if !Sys.iswindows()
                if uperm(path) & 0x1 == 0
                    if verbose
                        @info("$(path) is not executable")
                    end
                    continue
                end
            end
            if verbose
                @info("$(path) matches our search criteria of $(ep.binnames)")
            end
            return path
        end
    end

    if verbose
        @info("$(ep.binnames) does not exist, reporting unsatisfied")
    end
    return nothing
end

"""
    FileProduct(path::AbstractString, varname::Symbol, dir_path = nothing)

Declares a [`FileProduct`](@ref) that points to a file located relative to the root of
a `Prefix`, must simply exist to be satisfied.
"""
struct FileProduct <: Product
    paths::Vector{String}
    variable_name::Symbol
    function FileProduct(paths::Vector{String}, varname::Symbol)
        if isdefined(Base, varname)
            error("`$(varname)` is already defined in Base")
        end
        return new(paths, varname)
    end
end

FileProduct(path::AbstractString, variable_name::Symbol) = FileProduct([path], variable_name)
FileProduct(meta_obj::Dict) = FileProduct(String.(meta_obj["paths"]), Symbol(meta_obj["variable_name"]))
Base.:(==)(a::FileProduct, b::FileProduct) = a.paths == b.paths && a.variable_name == b.variable_name

repr(p::FileProduct) = "FileProduct($(repr(p.paths)), $(repr(p.variable_name)))"

"""
    locate(fp::FileProduct, prefix::Prefix;
           platform::Platform = platform_key_abi(),
           verbose::Bool = false,
           isolate::Bool = false)

If the given file exists, return its path.  The `platform` and `isolate`
arguments are is ignored here, but included for uniformity.  For ease of use,
we support a limited number of custom variable expansions such as `\${target}`,
and `\${nbits}`, so that the detection of files within target-specific folders
named things like `/lib32/i686-linux-musl` is simpler.
"""
function locate(fp::FileProduct, prefix::Prefix; platform::Platform = platform_key_abi(),
                verbose::Bool = false, isolate::Bool = false, kwargs...)
    for path in fp.paths
        expanded = joinpath(prefix, template(path, platform))

        if ispath(expanded)
            if verbose
                @info("FileProduct $(path) found at $(realpath(expanded))")
            end
            return expanded
        end
    end
    if verbose
        @info("FileProduct $(fp.paths) not found")
    end
    return nothing
end

# Add JSON serialization to products
JSON.lower(ep::ExecutableProduct) = Dict("type" => "exe", extract_fields(ep)...)
JSON.lower(lp::LibraryProduct) = Dict("type" => "lib", extract_fields(lp)...)
JSON.lower(fp::FrameworkProduct) = Dict("type" => "framework", extract_fields(fp.libraryproduct)...)
JSON.lower(fp::FileProduct) = Dict("type" => "file", extract_fields(fp)...)
