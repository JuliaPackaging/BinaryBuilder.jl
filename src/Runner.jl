import Base: strip
abstract type Runner; end

function target_nbits(target::AbstractString)
    if startswith(target, "i686-") || startswith(target, "arm-")
        return "32"
    else
        return "64"
    end
end

function target_proc_family(target::AbstractString)
    if startswith(target, "arm") || startswith(target, "aarch")
        return "arm"
    elseif startswith(target, "power")
        return "power"
    else
        return "intel"
    end
end

function target_dlext(target::AbstractString)
    if endswith(target, "-mingw32")
        return "dll"
    elseif occursin("-apple-", target)
        return "dylib"
    else
        return "so"
    end
end

function target_exeext(target::AbstractString)
    if endswith(target, "-mingw32")
        return ".exe"
    else
        return ""
    end
end

"""
    generate_compiler_wrappers(p::Platform, bin_path::AbstractString)

We generate a set of compiler wrapper scripts within our build environment to force all
build systems to honor the necessary sets of compiler flags to build for our systems.
Note that while `platform_envs()` sets many environment variables, those values are
intended to be optional/overridable.  These values, while still overridable by directly
invoking a compiler binary directly (e.g. /opt/{target}/bin/{target}-gcc), are much more
difficult to override, as the flags embedded in these wrappers are absolutely necessary,
and even simple programs will not compile without them.
"""
function generate_compiler_wrappers!(platform::Platform; bin_path::AbstractString, host_platform::Platform = Linux(:x86_64; libc=:musl))
    global use_ccache

    # Wipe that directory out, in case it already had compiler wrappers
    rm(bin_path; recursive=true, force=true)
    mkpath(bin_path)

    # Convert platform to a triplet, but strip out the ABI parts
    target = triplet(abi_agnostic(platform))
    host_target = triplet(abi_agnostic(host_platform))

    # If we should use ccache, prepend this to every compiler invocation
    ccache = use_ccache ? "ccache" : ""

    function wrapper(io::IO, prog::String;
                     allow_ccache::Bool = true,
                     hash_args::Bool = false,
                     env::Dict{String,String} = Dict{String,String}())
        write(io, """
        #!/bin/sh
        # This compiler wrapper script brought into existence by `generate_compiler_wrappers()`

        if [ "x\${SUPER_VERBOSE}" = "x" ]; then
            vrun() { "\$@"; }
        else
            vrun() { echo -e "\\e[96m\$@\\e[0m" >&2; "\$@"; }
        fi
        """)

        # Sometimes we need to look at the hash of our arguments
        if hash_args
            write(io, """
            ARGS_HASH="\$(echo -n "\$*" | sha1sum | cut -c1-8)"
            """)
        end

        for (name, val) in env
            write(io, "export $(name)=\"$(val)\"\n")
        end

        if allow_ccache
            write(io, """
            if [ \${USE_CCACHE} == "true" ]; then
                vrun ccache $(prog) "\$@"
            else
                vrun $(prog) "\$@"
            fi
            """)
        else
            write(io, """
            vrun $(prog) "\$@"
            """)
        end
    end
    
    # Helper invocations
    target_tool(io::IO, tool::String, args...; kwargs...) = wrapper(io, "/opt/$(target)/bin/$(target)-$(tool)", args...; kwargs...)
    llvm_tool(io::IO, tool::String, args...; kwargs...) = wrapper(io, "/opt/$(host_target)/bin/llvm-$(tool)", args...; kwargs...)

    ## Set up flag mappings
    function base_gcc_flags(p::Platform, FLAGS::String = "")
        # Force propler cxx11 string ABI usage w00t w00t
        if compiler_abi(p).cxxstring_abi == :cxx11
            FLAGS *= " -D_GLIBCXX_USE_CXX11_ABI=1"
        elseif compiler_abi(p).cxxstring_abi == :cxx03
            FLAGS *= " -D_GLIBCXX_USE_CXX11_ABI=0"
        end

        # Use hash of arguments to provide consistent, unique random seed
        FLAGS *= " -frandom-seed=0x\${ARG_HASH}"
        return FLAGS
    end

    gcc_flags(p::Platform) = base_gcc_flags(p)
    clang_targeting_laser(p::Platform) = "-target $(triplet(p)) --sysroot=/opt/$(triplet(p))/$(triplet(p))/sys-root"
    clang_flags(p::Platform) = clang_targeting_laser(p)
    fortran_flags(p::Platform) = ""
    flags(p::Platform) = ""

    # On macOS, we always sneak min version declaration in
    flags(p::MacOS) = "-mmacosx-version-min=10.8"

    function gcc_flags(p::MacOS)
        FLAGS = base_gcc_flags(p)

        # On macOS, if we're on an old GCC, the default -syslibroot that gets
        # passed to the linker isn't calculated correctly, so we have to manually set it.
        if select_gcc_version(p).major == 4
            FLAGS *= " -Wl,-syslibroot,/opt/$(target)/$(target)/sys-root"
        end
        return FLAGS
    end

    function fortran_flags(p::MacOS)
        FLAGS = ""
        
        # On macOS, if we're on an old GCC, the default -syslibroot that gets
        # passed to the linker isn't calculated correctly, so we have to manually set it.
        if select_gcc_version(p).major == 4
            FLAGS *= " -Wl,-syslibroot,/opt/$(target)/$(target)/sys-root"
        end
        return FLAGS
    end
        
    # FreeBSD is special-cased within the LLVM source tree to not allow for
    # things like the -gcc-toolchain option, which means that we have to manually add
    # the location of libgcc_s.  LE SIGH.
    # https://github.com/llvm-mirror/clang/blob/f3b7928366f63b51ffc97e74f8afcff497c57e8d/lib/Driver/ToolChains/FreeBSD.cpp
    clang_flags(p::FreeBSD) = "$(clang_targeting_laser(p)) -L/opt/$(target)/$(target)/lib"
    clang_flags(p::MacOS) = "$(clang_targeting_laser(p)) -fuse-ld=macos"


    # C/C++/Fortran
    gcc(io::IO, p::Platform)      = wrapper(io, "/opt/$(triplet(p))/bin/$(triplet(p))-gcc $(flags(p)) $(gcc_flags(p))"; hash_args=true)
    gxx(io::IO, p::Platform)      = wrapper(io, "/opt/$(triplet(p))/bin/$(triplet(p))-g++ $(flags(p)) $(gcc_flags(p))"; hash_args=true)
    gfortran(io::IO, p::Platform) = wrapper(io, "/opt/$(triplet(p))/bin/$(triplet(p))-gfortran $(flags(p)) $(fortran_flags(p))")
    clang(io::IO, p::Platform)    = wrapper(io, "/opt/$(host_target)/bin/clang $(flags(p)) $(clang_flags(p))")
    clangxx(io::IO, p::Platform)  = wrapper(io, "/opt/$(host_target)/bin/clang++ $(flags(p)) $(clang_flags(p))")
    objc(io::IO, p::Platform)     = wrapper(io, "/opt/$(host_target)/bin/clang -x objective-c $(flags(p)) $(clang_flags(p))")

    # Our general `cc`  points to `gcc` for most systems, but `clang` for MacOS and FreeBSD
    cc(io::IO, p::Platform) = gcc(io, p)
    cxx(io::IO, p::Platform) = gxx(io, p)
    fc(io::IO, p::Platform) = gfortran(io, p)
    cc(io::IO, p::Union{MacOS,FreeBSD}) = clang(io, p)
    cxx(io::IO, p::Union{MacOS,FreeBSD}) = clangxx(io, p)
    
    # Go stuff where we build an environment mapping each time we invoke `go-${target}`
    GOOS(p::Linux) = "linux"
    GOOS(p::MacOS) = "darwin"
    GOOS(p::Windows) = "windows"
    GOOS(p::FreeBSD) = "freebsd"
    function GOARCH(p::Platform)
        arch_mapping = Dict(
            :armv7l => "arm",
            :aarch64 => "arm64",
            :x86_64 => "amd64",
            :i686 => "386",
            :powerpc64le => "ppc64le",
        )
        return arch_mapping[arch(p)]
    end
    function go(io::IO, p::Platform)
        env = Dict(
            "GOOS" => GOOS(p),
            "GOARCH" => GOARCH(p),
        )
        return wrapper(io, "/opt/$(host_target)/go/bin/go"; env=env, allow_ccache=false)
    end

    # Rust stuff
    rust_env(p::Platform) = Dict("CARGO_HOME" => "/opt/$(triplet(p))", "RUSTUP_HOME" => "/opt/$(triplet(p))")
    rustc(io::IO, p::Platform) = wrapper(io, "/opt/$(host_target)/bin/rustc"; allow_ccache=false, env=rust_env(p))
    rustup(io::IO, p::Platform) = wrapper(io, "/opt/$(host_target)/bin/rustup"; allow_ccache=false, env=rust_env(p))
    cargo(io::IO, p::Platform) = wrapper(io, "/opt/$(host_target)/bin/cargo"; allow_ccache=false, env=rust_env(p))

    # Default binutils to the "target tool" versions, will override later
    for tool in (:ar, :as, :cpp, :ld, :nm, :libtool, :objcopy, :objdump, :ranlib, :readelf, :strip, :install_name_tool, :windres, :winmc)
        @eval $(tool)(io::IO, p::Platform) = $target_tool(io, $(string(tool)); allow_ccache=false)
    end
 
    # c++filt is hard to write in symbols
    cxxfilt(io::IO, p::Platform) = target_tool(io, "c++filt"; allow_ccache=false)

    # Overrides for macOS binutils because Apple is always so "special"
    for tool in (:ar, :ranlib)
        @eval $(tool)(io::IO, p::MacOS) = $(wrapper)(io, string("/opt/", triplet(p), "/bin/llvm-", $tool))
    end

    function write_wrapper(wrappergen, p, fname)
        open(io -> Base.invokelatest(wrappergen, io, p), joinpath(bin_path, fname), "w")
        chmod(joinpath(bin_path, fname), 0o775)
    end

    ## Generate compiler wrappers for both our target and our host
    for p in unique(abi_agnostic.((platform, host_platform)))
        t = triplet(p)

        # Generate `cc` and `c++`
        write_wrapper(cc, p, "$(t)-cc")
        write_wrapper(cxx, p, "$(t)-c++")
        write_wrapper(gfortran, p, "$(t)-f77")

        # Generate `gcc`, `g++`, `clang` and `clang++`
        write_wrapper(gcc, p, "$(t)-gcc")
        write_wrapper(gxx, p, "$(t)-g++")
        write_wrapper(gfortran, p, "$(t)-gfortran")
        write_wrapper(clang, p, "$(t)-clang")
        write_wrapper(clangxx, p,"$(t)-clang++")
        write_wrapper(objc, p,"$(t)-objc")

        # Binutils
        write_wrapper(ar, p, "$(t)-ar")
        write_wrapper(as, p, "$(t)-as")
        write_wrapper(cpp, p, "$(t)-cpp")
        write_wrapper(cxxfilt, p, "$(t)-c++filt")
        write_wrapper(ld, p, "$(t)-ld")
        write_wrapper(nm, p, "$(t)-nm")
        write_wrapper(libtool, p, "$(t)-libtool")
        write_wrapper(objcopy, p, "$(t)-objcopy")
        write_wrapper(objdump, p, "$(t)-objdump")
        write_wrapper(ranlib, p, "$(t)-ranlib")
        write_wrapper(readelf, p, "$(t)-readelf")
        write_wrapper(strip, p, "$(t)-strip")
        write_wrapper(windres, p, "$(t)-windres")
        write_wrapper(winmc, p, "$(t)-winmc")

        # Special mac stuff
        write_wrapper(install_name_tool, p, "$(t)-install_name_tool")

        # Generate rust stuff
        write_wrapper(rustc, p, "$(t)-rustc")
        write_wrapper(rustup, p, "$(t)-rustup")
        write_wrapper(cargo, p, "$(t)-cargo")

        # Generate go stuff
        write_wrapper(go, p, "$(t)-go")
    end
   

    default_tools = [
        # C/C++/Fortran
        "cc", "c++", "cpp", "f77", "gfortran", "gcc", "clang", "g++", "clang++", "objc",

        # Rust
        "rustc", "rustup", "cargo",

        # Go
        "go",

        # Binutils
        "ar", "as", "c++filt", "ld", "nm", "libtool", "objcopy", "ranlib", "readelf", "strip",
    ]

    if platform isa MacOS
        append!(default_tools, ("dsymutil", "lipo", "otool", "install_name_tool"))
    elseif platform isa Windows
        append!(default_tools, ("windres", "winmc"))
    end
 
    # Create symlinks for default compiler invocations, invoke target toolchain
    for tool in default_tools
        symlink("$(target)-$(tool)", joinpath(bin_path, tool))
    end
end


"""
    platform_envs(platform::Platform)

Given a `platform`, generate a `Dict` mapping representing all the environment
variables to be set within the build environment to force compiles toward the
defined target architecture.  Examples of things set are `PATH`, `CC`,
`RANLIB`, as well as nonstandard things like `target`.
"""
function platform_envs(platform::Platform; host_platform = Linux(:x86_64; libc=:musl), bootstrap::Bool=!isempty(bootstrap_list), verbose::Bool = false)
    global use_ccache

    # Convert platform to a triplet, but strip out the ABI parts
    target = triplet(abi_agnostic(platform))
    host_target = triplet(abi_agnostic(platform))

    # Prefix, libdir, etc...
    prefix = "/workspace/destdir"
    if platform isa Windows
        libdir = "$(prefix)/bin"
    else
        libdir = "$(prefix)/lib"
    end

    if Base.have_color
        PS1 = string(
            Base.text_colors[:light_blue],
            "sandbox",
            Base.text_colors[:normal],
            ":",
            Base.text_colors[:yellow],
            "\${PWD//\$WORKSPACE/\\\\\$\\{WORKSPACE\\}}",
            Base.text_colors[:normal],
            " \\\$ ",
        )
    else
        PS1 = "sandbox:\${PWD//\$WORKSPACE/\\\\\$\\{WORKSPACE\\}} \\\$ "
    end

    # Map our target names to cargo-compatible ones
    rust_arch(p::Platform) = arch(p) == :armv7l ? :armv7 : arch(p)
    rust_target(p::MacOS) = "x86_64-apple-darwin"
    rust_target(p::FreeBSD) = "x86_64-unknown-freebsd"
    rust_target(p::Windows) = "$(rust_arch(p))-pc-windows-gnu"
    rust_target(p::Platform) = "$(rust_arch(p))-unknown-linux-$(libc(p) == :glibc ? "gnu" : libc(p))$(something(call_abi(p), ""))"

    # Base mappings
    mapping = Dict(
        # Platform information (we save a `bb_target` because sometimes `target` gets
        # overwritten in `./configure`, and we want tools like `uname` to still see it)
        "bb_target" => target,
        "target" => target,
        "rust_target" => rust_target(platform),
        "rust_host" => rust_target(host_platform),
        "nproc" => "$(Sys.CPU_THREADS)",
        "nbits" => target_nbits(target),
        "proc_family" => target_proc_family(target),
        "dlext" => target_dlext(target),
        "exeext" => target_exeext(target),
        "PATH" => "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
        "MACHTYPE" => "x86_64-linux-musl",

        # Set location parameters
        "WORKSPACE" => "/workspace",
        "prefix" => prefix,
        "bindir" => "$(prefix)/bin",
        "libdir" => libdir,

        # Fancyness!
        "PS1" => PS1,
        "VERBOSE" => "$(verbose)",
        "V" => "$(verbose)",
        "HISTFILE"=>"/meta/.bash_history",
        "TERM" => "screen",
    )

    # If we're bootstrapping, that's it, quit out.
    if bootstrap
        return mapping
    end

    # Helper for generating the library include path for a target
    target_lib_dir(t) = "/opt/$(t)/lib64:/opt/$(t)/lib:/opt/$(t)/$(t)/lib64:/opt/$(t)/$(t)/lib"

    merge!(mapping, Dict(
        "PATH" => join((
            # First things first, our compiler wrappers trump all
            "/opt/bin",
            # Allow users to use things like x86_64-linux-gnu here
            "/opt/$(target)/bin",
            "/opt/$(host_target)/bin",
            # Default alpine PATH
            mapping["PATH"],
            # Finally, dependency tools
            "$(prefix)/bin",
        ), ":"),

        "LD_LIBRARY_PATH" => join((
           # Start with the default musl ld path
           "/usr/local/lib64:/usr/local/lib:/usr/local/lib:/usr/lib",
            # Add our glibc directory
            "/lib64:/lib",
            # Add our target/host-specific library directories for compiler support libraries
            target_lib_dir(host_target),
            target_lib_dir(target),
            # Finally, dependencies
            "$(prefix)/lib64:$(prefix)/lib",
        ), ":"),

        # Default mappings for some tools
        "CC" => "cc",
        "CXX" => "c++",
        "OBJC" => "objc",
        "FC" => "gfortran",
        "GO" => "go",

        # Go stuff
        "GOROOT" => prefix,
        "GOPATH" => "/workspace/.gopath",
        "GOARM" => "7", # default to armv7

        # We conditionally add on some compiler flags; we'll cull empty ones at the end
        "USE_CCACHE" => "$(use_ccache)",
        "LLVM_TARGET" => target,
        "LLVM_HOST_TARGET" => host_target,

        # We should always be looking for packages already in the prefix
        "PKG_CONFIG_PATH" => "$(prefix)/lib/pkgconfig:$(prefix)/share/pkgconfig",
        "PKG_CONFIG_SYSROOT_DIR" => prefix,

        # Things to help us step closer to reproducible builds; eliminate timestamp
        # variability within our binaries.
        "SOURCE_DATE_EPOCH" => "0",
        "ZERO_AR_DATE" => "1",
    ))

    # If we're on macOS, we give a hint to things like `configure` that they should use this as the linker
    if isa(platform, MacOS)
        mapping["LD"] = "/opt/$(target)/bin/ld64.macos"
    end

    # There is no broad agreement on what host compilers should be called,
    # so we set all the environment variables that we've seen them called
    # and hope for the best.
    for host_map in (tool -> "HOST$(tool)", tool -> "$(tool)_FOR_BUILD", tool -> "BUILD_$(tool)", tool -> "$(tool)_BUILD")
        # First, do the simple tools where it's just X => $(host_target)-x:
        for tool in ("AR", "AS", "LD", "LIPO", "NM", "RANLIB", "READELF", "OBJCOPY", "OBJDUMP", "STRIP")
            mapping[host_map(tool)] = "$(host_target)-$(lowercase(tool))"
        end

        # Next, the more custom tool mappings
        for (env_name, tool) in (
            "CC" => "$(host_target)-gcc",
            "CXX" => "$(host_target)-g++",
            "DSYMUTIL" => "llvm-dsymutil",
            "FC" => "$(host_target)-gfortran"
           )
            mapping[host_map(env_name)] = tool
        end
    end

    return mapping
end

runner_override = ""
function preferred_runner()
    global runner_override
    if runner_override != ""
        if runner_override in ["userns", "privileged"]
            return UserNSRunner
        elseif runner_override in ["qemu"]
            return QemuRunner
        elseif runner_override in ["docker"]
            return DockerRunner
        end
    end

    @static if Sys.islinux()
        return UserNSRunner
    else
        return QemuRunner
    end
end

"""
    runshell(platform::Platform = platform_key_abi())

Launch an interactive shell session within the user namespace, with environment
setup to target the given `platform`.
"""
function runshell(platform::Platform = platform_key_abi(); kwargs...)
    runshell(preferred_runner(), platform; kwargs...)
end

function runshell(r::Runner, args...; kwargs...)
    run_interactive(r, `/bin/bash`, args...; kwargs...)
end

function runshell(::Type{R}, platform::Platform = platform_key_abi(); kwargs...) where {R <: Runner}
    return runshell(R(pwd(); cwd="/workspace/", platform=platform, kwargs...))
end
