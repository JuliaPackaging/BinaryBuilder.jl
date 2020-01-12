import Base: strip
abstract type Runner; end

function nbits(p::Platform)
    if arch(p) in (:i686, :armv7l)
        return 32
    elseif arch(p) in (:x86_64, :aarch64, :powerpc64le)
        return 64
    else
        error("Unknown bitwidth for architecture $(arch(p))")
    end
end

function proc_family(p::Platform)
    if arch(p) in (:x86_64, :i686)
        return :intel
    elseif arch(p) in (:armv7l, :aarch64)
        return :arm
    elseif arch(p) == :powerpc64le
        return :power
    else
        error("Unknown processor family for architecture $(arch(p))")
    end
end

dlext(p::Windows) = "dll"
dlext(p::MacOS) = "dylib"
dlext(p::Union{Linux,FreeBSD}) = "so"
dlext(p::Platform) = error("Unknown dlext for platform $(p)")

exeext(p::Windows) = ".exe"
exeext(p::Union{Linux,FreeBSD,MacOS}) = ""
exeext(p::Platform) = error("Unknown exeext for platform $(p)")

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
function generate_compiler_wrappers!(platform::Platform; bin_path::AbstractString,
                                     host_platform::Platform = Linux(:x86_64; libc=:musl),
                                     rust_platform::Platform = Linux(:x86_64; libc=:glibc),
                                     compilers::Vector{Symbol} = [:c])
    global use_ccache

    # Wipe that directory out, in case it already had compiler wrappers
    rm(bin_path; recursive=true, force=true)
    mkpath(bin_path)

    # Convert platform to a triplet, but strip out the ABI parts
    target = triplet(abi_agnostic(platform))
    host_target = triplet(abi_agnostic(host_platform))
    rust_target = triplet(abi_agnostic(rust_platform))

    # If we should use ccache, prepend this to every compiler invocation
    ccache = use_ccache ? "ccache" : ""

    function wrapper(io::IO, prog::String;
                     allow_ccache::Bool = true,
                     hash_args::Bool = false,
                     extra_cmds::String = "",
                     link_only_flags::Vector = String[],
                     env::Dict{String,String} = Dict{String,String}())
        write(io, """
        #!/bin/bash
        # This compiler wrapper script brought into existence by `generate_compiler_wrappers()`

        if [ "x\${SUPER_VERBOSE}" = "x" ]; then
            vrun() { "\$@"; }
        else
            vrun() { echo -e "\\e[96m\$@\\e[0m" >&2; "\$@"; }
        fi

        PRE_FLAGS=()
        POST_FLAGS=()
        """)

        # Sometimes we need to look at the hash of our arguments
        if hash_args
            write(io, """
            ARGS_HASH="\$(echo -n "\$*" | sha1sum | cut -c1-8)"
            """)
        end

        # If we're given link-only flags, include them only if `-c` or other link-disablers are not provided.
        if !isempty(link_only_flags)
            println(io)
            println(io, "if [[ \" \$@ \" != *' -c '* ]] && [[ \" \$@ \" != *' -E '* ]] && [[ \" \$@ \" != *' -M '* ]] && [[ \" \$@ \" != *' -fsyntax-only '* ]]; then")
            for lf in link_only_flags
                println(io, "    POST_FLAGS+=( '$lf' )")
            end
            println(io, "fi")
            println(io)
        end

        # Insert extra commands from the user (usually some kind of conditional setting
        # of PRE_FLAGS and POST_FLAGS)
        println(io)
        write(io, extra_cmds)
        println(io)

        for (name, val) in env
            write(io, "export $(name)=\"$(val)\"\n")
        end

        if allow_ccache
            write(io, """
            if [ \${USE_CCACHE} == "true" ]; then
                vrun ccache $(prog) "\${PRE_FLAGS[@]}" "\$@" "\${POST_FLAGS[@]}"
            else
                vrun $(prog) "\${PRE_FLAGS[@]}" "\$@" "\${POST_FLAGS[@]}"
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
        FLAGS *= " -frandom-seed=0x\${ARGS_HASH}"
        return FLAGS
    end

    gcc_flags(p::Platform) = base_gcc_flags(p)
    clang_targeting_laser(p::Platform) = "-target $(triplet(p)) --sysroot=/opt/$(triplet(p))/$(triplet(p))/sys-root"
    fortran_flags(p::Platform) = ""

    function gcc_flags(p::MacOS)
        FLAGS = base_gcc_flags(p)

        # Always ask for a minimum macOS version of 10.8, as is default for the whole Julia world
        FLAGS *= " -mmacosx-version-min=10.8"

        # On macOS, if we're on an old GCC, the default -syslibroot that gets
        # passed to the linker isn't calculated correctly, so we have to manually set it.
        if select_gcc_version(p).major == 4
            FLAGS *= " -Wl,-syslibroot,/opt/$(triplet(p))/$(triplet(p))/sys-root"
        end
        return FLAGS
    end

    function fortran_flags(p::MacOS)
        FLAGS = ""

        # Always ask for a minimum macOS version of 10.8, as is default for the whole Julia world
        FLAGS *= " -mmacosx-version-min=10.8"

        # On macOS, if we're on an old GCC, the default -syslibroot that gets
        # passed to the linker isn't calculated correctly, so we have to manually set it.
        if select_gcc_version(p).major == 4
            FLAGS *= " -Wl,-syslibroot,/opt/$(triplet(p))/$(triplet(p))/sys-root"
        end
        return FLAGS
    end
        
    # For MacOS and FreeBSD, we don't set `-rtlib`, and FreeBSD is special-cased within the LLVM source tree
    # to not allow for -gcc-toolchain, which means that we have to manually add the location of libgcc_s.  LE SIGH.
    # We do that within `clang_linker_flags()`, so that we don't get "unused argument" warnings all over the place.
    # https://github.com/llvm-mirror/clang/blob/f3b7928366f63b51ffc97e74f8afcff497c57e8d/lib/Driver/ToolChains/FreeBSD.cpp
    function clang_flags(p::MacOS)
        FLAGS = ""

        # First, we target our platform, as usual
        FLAGS *= " $(clang_targeting_laser(p))"
        
        # Next, on MacOS, we need to override the typical C++ include search paths, because it always includes
        # the toolchain C++ headers first.  Valentin tracked this down to:
        # https://github.com/llvm/llvm-project/blob/0378f3a90341d990236c44f297b923a32b35fab1/clang/lib/Driver/ToolChains/Darwin.cpp#L1944-L1978
        FLAGS *= " -nostdinc++ -isystem /opt/$(triplet(p))/$(triplet(p))/sys-root/usr/include/c++/v1"
        return FLAGS
    end

    # On FreeBSD, our clang flags are simple
    clang_flags(p::FreeBSD) = clang_targeting_laser(p)

    # For everything else, there's MasterCard (TM) (.... also, we need to provide `-rtlib=libgcc` because clang-builtins are broken,
    # and we also need to provide `-stdlib=libstdc++` to match Julia on these platforms.)
    clang_flags(p::Platform) = "$(clang_targeting_laser(p)) --gcc-toolchain=/opt/$(triplet(p)) -rtlib=libgcc -stdlib=libstdc++"


    # On macos, we want to use a particular linker with clang.  But we want to avoid warnings about unused
    # flags when just compiling, so we put it into "linker-only flags".
    clang_link_flags(p::Platform) = String["-fuse-ld=$(triplet(p))"]
    clang_link_flags(p::Union{FreeBSD,MacOS}) = ["-L/opt/$(triplet(p))/$(triplet(p))/lib", "-fuse-ld=$(triplet(p))"]

    gcc_link_flags(p::Platform) = String[]
    function gcc_link_flags(p::Linux)
        if arch(p) == :powerpc64le && select_gcc_version(p).major == 4
            return ["-L/opt/$(triplet(p))/$(triplet(p))/sys-root/lib64", "-Wl,-rpath-link,/opt/$(triplet(p))/$(triplet(p))/sys-root/lib64"]
        end
        return String[]
    end

    # C/C++/Fortran
    gcc(io::IO, p::Platform)      = wrapper(io, "/opt/$(triplet(p))/bin/$(triplet(p))-gcc $(gcc_flags(p))"; hash_args=true, link_only_flags=gcc_link_flags(p))
    gxx(io::IO, p::Platform)      = wrapper(io, "/opt/$(triplet(p))/bin/$(triplet(p))-g++ $(gcc_flags(p))"; hash_args=true, link_only_flags=gcc_link_flags(p))
    gfortran(io::IO, p::Platform) = wrapper(io, "/opt/$(triplet(p))/bin/$(triplet(p))-gfortran $(fortran_flags(p))"; allow_ccache=false)
    clang(io::IO, p::Platform)    = wrapper(io, "/opt/$(host_target)/bin/clang $(clang_flags(p))"; link_only_flags=clang_link_flags(p))
    clangxx(io::IO, p::Platform)  = wrapper(io, "/opt/$(host_target)/bin/clang++ $(clang_flags(p))"; link_only_flags=clang_link_flags(p))
    objc(io::IO, p::Platform)     = wrapper(io, "/opt/$(host_target)/bin/clang -x objective-c $(clang_flags(p))"; link_only_flags=clang_link_flags(p))

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
    rust_flags(p::Platform) = "--target=$(map_rust_target(p)) -C linker=$(triplet(p))-gcc"
    rustc(io::IO, p::Platform) = wrapper(io, "/opt/$(rust_target)/bin/rustc $(rust_flags(p))"; allow_ccache=false)
    rustup(io::IO, p::Platform) = wrapper(io, "/opt/$(rust_target)/bin/rustup"; allow_ccache=false)
    cargo(io::IO, p::Platform) = wrapper(io, "/opt/$(rust_target)/bin/cargo"; allow_ccache=false)

    # Meson REQUIRES that `CC`, `CXX`, etc.. are set to the host utils.  womp womp.
    function meson(io::IO, p::Platform)
        meson_env = Dict(
            "AR"     => "$(host_target)-ar",
            "CC"     => "$(host_target)-cc",
            "CXX"    => "$(host_target)-c++",
            "FC"     => "$(host_target)-f77",
            "LD"     => "$(host_target)-ld",
            "NM"     => "$(host_target)-nm",
            "OBJC"   => "$(host_target)-objc",
            "RANLIB" => "$(host_target)-ranlib",
        )
        wrapper(io, "/usr/bin/meson"; allow_ccache=false, env=meson_env)
    end


    # Default these tools to the "target tool" versions, will override later
    for tool in (:ar, :as, :cpp, :ld, :nm, :libtool, :objcopy, :objdump, :otool,
                 :ranlib, :readelf, :strip, :install_name_tool, :dlltool, :windres, :winmc, :lipo)
        @eval $(tool)(io::IO, p::Platform) = $(wrapper)(io, string("/opt/", triplet(p), "/bin/", triplet(p), "-", $(string(tool))); allow_ccache=false)
    end
 
    # c++filt is hard to write in symbols
    cxxfilt(io::IO, p::Platform) = wrapper(io, "/opt/$(triplet(p))/bin/$(triplet(p))-c++filt"; allow_ccache=false)
    cxxfilt(io::IO, p::MacOS) = wrapper(io, string("/opt/", triplet(p), "/bin/llvm-cxxfilt"); allow_ccache=false)

    # Overrides for macOS binutils because Apple is always so "special"
    for tool in (:ar, :ranlib, :dsymutil)
        @eval $(tool)(io::IO, p::MacOS) = $(wrapper)(io, string("/opt/", triplet(p), "/bin/llvm-", $tool))
    end
    # macOS doesn't have a readelf; default to using the host version
    @eval readelf(io::IO, p::MacOS) = readelf(io, $(host_platform))

    function write_wrapper(wrappergen, p, fname)
        open(io -> Base.invokelatest(wrappergen, io, p), joinpath(bin_path, fname), "w")
        chmod(joinpath(bin_path, fname), 0o775)
    end

    ## Generate compiler wrappers for both our target and our host
    for p in unique(abi_agnostic.((platform, host_platform)))
        t = triplet(p)

        # Generate `:c` compilers
        if :c in compilers
            write_wrapper(cc, p, "$(t)-cc")
            write_wrapper(cxx, p, "$(t)-c++")

            # Generate `gcc`, `g++`, `clang` and `clang++`
            write_wrapper(gcc, p, "$(t)-gcc")
            write_wrapper(gxx, p, "$(t)-g++")
            write_wrapper(clang, p, "$(t)-clang")
            write_wrapper(clangxx, p, "$(t)-clang++")
            write_wrapper(objc, p, "$(t)-objc")

            # Someday, you will be split out
            write_wrapper(gfortran, p, "$(t)-f77")
            write_wrapper(gfortran, p, "$(t)-gfortran")
        end


        # Binutils (we always do these)
        write_wrapper(ar, p, "$(t)-ar")
        write_wrapper(as, p, "$(t)-as")
        write_wrapper(cpp, p, "$(t)-cpp")
        write_wrapper(cxxfilt, p, "$(t)-c++filt")
        write_wrapper(ld, p, "$(t)-ld")
        # ld wrappers for clang's `-fuse-ld=$(target)`
        if isa(p, MacOS)
            write_wrapper(ld, p, "ld64.$(t)")
        else
            write_wrapper(ld, p, "ld.$(t)")
        end
        write_wrapper(nm, p, "$(t)-nm")
        write_wrapper(libtool, p, "$(t)-libtool")
        write_wrapper(objcopy, p, "$(t)-objcopy")
        write_wrapper(objdump, p, "$(t)-objdump")
        write_wrapper(ranlib, p, "$(t)-ranlib")
        write_wrapper(readelf, p, "$(t)-readelf")
        write_wrapper(strip, p, "$(t)-strip")

        # Special mac stuff
        if isa(p, MacOS)
            write_wrapper(install_name_tool, p, "$(t)-install_name_tool")
            write_wrapper(lipo, p, "$(t)-lipo")
            write_wrapper(dsymutil, p, "$(t)-dsymutil")
            write_wrapper(otool, p, "$(t)-otool")
        end

        # Special Windows stuff
        if isa(p, Windows)
            write_wrapper(dlltool, p, "$(t)-dlltool")
            write_wrapper(windres, p, "$(t)-windres")
            write_wrapper(winmc, p, "$(t)-winmc")
        end

        # Generate go stuff
        if :go in compilers
            write_wrapper(go, p, "$(t)-go")
        end
    end

    # Rust stuff doesn't use the normal "host" platform, it uses x86_64-linux-gnu, so we always have THREE around,
    # because clever build systems like `meson` ask Rust what its native system is, and it truthfully answers
    # `x86_64-linux-gnu`, while other build systems might say `x86_64-linux-musl` with no less accuracy.  So for
    # safety, we just ship all three all the time.
    if :rust in compilers
        for p in unique(abi_agnostic.((platform, host_platform, rust_platform)))
            t = triplet(p)
            write_wrapper(rustc, p, "$(t)-rustc")
            write_wrapper(rustup, p, "$(t)-rustup")
            write_wrapper(cargo, p, "$(t)-cargo")
        end
    end

    # Write a single wrapper for `meson`
    write_wrapper(meson, host_platform, "meson")

    default_tools = [
        # Binutils
        "ar", "as", "c++filt", "ld", "nm", "libtool", "objcopy", "ranlib", "readelf", "strip",
    ]

    if platform isa MacOS
        append!(default_tools, ("dsymutil", "lipo", "otool", "install_name_tool"))
    elseif platform isa Windows
        append!(default_tools, ("dlltool", "windres", "winmc"))
    end

    if :c in compilers
        append!(default_tools, ("cc", "c++", "cpp", "f77", "gfortran", "gcc", "clang", "g++", "clang++", "objc"))
    end
    if :rust in compilers
        append!(default_tools, ("rustc","rustup","cargo"))
    end
    if :go in compilers
        append!(default_tools, ("go",))
    end
    # Create symlinks for default compiler invocations, invoke target toolchain
    for tool in default_tools
        symlink("$(target)-$(tool)", joinpath(bin_path, tool))
    end
end

# Translation mappers for our target names to cargo-compatible ones
map_rust_arch(p::Platform) = arch(p) == :armv7l ? :armv7 : arch(p)
map_rust_target(p::MacOS) = "x86_64-apple-darwin"
map_rust_target(p::FreeBSD) = "x86_64-unknown-freebsd"
map_rust_target(p::Windows) = "$(map_rust_arch(p))-pc-windows-gnu"
map_rust_target(p::Platform) = "$(map_rust_arch(p))-unknown-linux-$(libc(p) == :glibc ? "gnu" : libc(p))$(something(call_abi(p), ""))"

"""
    platform_envs(platform::Platform)

Given a `platform`, generate a `Dict` mapping representing all the environment
variables to be set within the build environment to force compiles toward the
defined target architecture.  Examples of things set are `PATH`, `CC`,
`RANLIB`, as well as nonstandard things like `target`.
"""
function platform_envs(platform::Platform, src_name::AbstractString; host_platform = Linux(:x86_64; libc=:musl), bootstrap::Bool=!isempty(bootstrap_list), verbose::Bool = false)
    global use_ccache

    # Convert platform to a triplet, but strip out the ABI parts
    target = triplet(abi_agnostic(platform))
    host_target = triplet(abi_agnostic(host_platform))
    rust_host = Linux(:x86_64; libc=:glibc)

    # Prefix, libdir, etc...
    prefix = "/workspace/destdir"
    if platform isa Windows
        libdir = "$(prefix)/bin"
    else
        libdir = "$(prefix)/lib"
    end

    if Base.have_color
        PS1 = string(
            raw"\[",
            Base.text_colors[:light_blue],
            raw"\]",
            "sandbox",
            raw"\[",
            Base.text_colors[:normal],
            raw"\]",
            ":",
            raw"\[",
            Base.text_colors[:yellow],
            raw"\]",
            raw"${PWD//$WORKSPACE/$\{WORKSPACE\}}",
            raw"\[",
            Base.text_colors[:normal],
            raw"\]",
            raw" \$ ",
        )
    else
        PS1 = raw"sandbox:${PWD//$WORKSPACE/$\{WORKSPACE\}} $ "
    end

    # Base mappings
    mapping = Dict(
        # Platform information (we save a `bb_target` because sometimes `target` gets
        # overwritten in `./configure`, and we want tools like `uname` to still see it)
        "bb_target" => target,
        "target" => target,
        "rust_target" => map_rust_target(platform),
        "rust_host" => map_rust_target(rust_host), # use glibc since musl is broken. :( https://github.com/rust-lang/rust/issues/59302
        "nproc" => "$(get(ENV, "BINARYBUILDER_NPROC", Sys.CPU_THREADS))",
        "nbits" => string(nbits(platform)),
        "proc_family" => string(proc_family(platform)),
        "dlext" => dlext(platform),
        "exeext" => exeext(platform),
        "PATH" => "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
        "MACHTYPE" => "x86_64-linux-musl",

        # Set location parameters
        "WORKSPACE" => "/workspace",
        "prefix" => prefix,
        "bindir" => "$(prefix)/bin",
        "libdir" => libdir,

        # Fancyness!
        "USER" => get(ENV, "USER", "julia"),
        # Docker filters out `PS1` so we route around it
        "HIDDEN_PS1" => PS1,
        "VERBOSE" => "$(verbose)",
        "V" => "$(verbose)",
        "HISTFILE"=>"/meta/.bash_history",
        "TERM" => "screen",
        "SRC_NAME" => src_name,
    )

    # If we're bootstrapping, that's it, quit out.
    if bootstrap
        return mapping
    end

    # Helper for generating the library include path for a target.  MacOS, as usual,
    # puts things in slightly different place.
    function target_lib_dir(p::Platform)
        t = triplet(abi_agnostic(p))
        return "/opt/$(t)/$(t)/lib64:/opt/$(t)/$(t)/lib"
    end
    function target_lib_dir(p::MacOS)
        t = triplet(abi_agnostic(p))
        return "/opt/$(t)/$(t)/lib:/opt/$(t)/lib"
    end

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
            # Add our loader directories
            "/lib64:/lib",
            # Add our target/host-specific library directories for compiler support libraries
            target_lib_dir(host_platform),
            target_lib_dir(rust_host),
            target_lib_dir(platform),
            # Finally, dependencies
            "$(prefix)/lib64:$(prefix)/lib",
        ), ":"),

        # Default mappings for some tools
        "CC" => "cc",
        "CXX" => "c++",
        "OBJC" => "objc",
        "FC" => "gfortran",
        "GO" => "go",
        "RUSTC" => "rustc",
        "CARGO" => "cargo",

        # Go stuff
        "GOCACHE" => "/workspace/.gocache",
        "GOPATH" => "/workspace/.gopath",
        "GOARM" => "7", # default to armv7

        # Rust stuff
        "CARGO_BUILD_TARGET" => map_rust_target(platform),
        "CARGO_HOME" => "/opt/$(triplet(rust_host))",
        "RUSTUP_HOME" => "/opt/$(triplet(rust_host))",
        "RUSTUP_TOOLCHAIN" => "stable-$(map_rust_target(rust_host))",

        # We conditionally add on some compiler flags; we'll cull empty ones at the end
        "USE_CCACHE" => "$(use_ccache)",
        "LLVM_TARGET" => target,
        "LLVM_HOST_TARGET" => host_target,

        # Let the user parameterize their scripts for toolchain locations
        "CMAKE_HOST_TOOLCHAIN" => "/opt/$(host_target)/$(host_target).cmake",
        "CMAKE_TARGET_TOOLCHAIN" => "/opt/$(target)/$(target).cmake",
        "MESON_HOST_TOOLCHAIN" => "/opt/$(host_target)/$(host_target).meson",
        "MESON_TARGET_TOOLCHAIN" => "/opt/$(target)/$(target).meson",

        # We should always be looking for packages already in the prefix
        "PKG_CONFIG_PATH" => "$(prefix)/lib/pkgconfig:$(prefix)/share/pkgconfig",
        "PKG_CONFIG_SYSROOT_DIR" => prefix,

        # ccache options
        "CCACHE_COMPILERCHECK" => "content",

        # Things to help us step closer to reproducible builds; eliminate timestamp
        # variability within our binaries.
        "SOURCE_DATE_EPOCH" => "0",
        "ZERO_AR_DATE" => "1",
    ))

    # If we're on macOS, we give a hint to things like `configure` that they should use this as the linker
    if isa(platform, MacOS)
        mapping["LD"] = "/opt/$(target)/bin/ld64.macos"
        mapping["MACOSX_DEPLOYMENT_TARGET"] = "10.8"
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
        elseif runner_override in ["docker"]
            return DockerRunner
        end
    end

    @static if Sys.islinux()
        return UserNSRunner
    else
        return DockerRunner
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
    run_interactive(r, `/bin/bash -l`, args...; kwargs...)
end

function runshell(::Type{R}, platform::Platform = platform_key_abi(); verbose::Bool=false,kwargs...) where {R <: Runner}
    return runshell(R(pwd(); cwd="/workspace/", platform=platform, verbose=verbose, kwargs...); verbose=verbose)
end
