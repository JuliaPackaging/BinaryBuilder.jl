const __bodyfunction__ = Dict{Method,Any}()

# Find keyword "body functions" (the function that contains the body
# as written by the developer, called after all missing keyword-arguments
# have been assigned values), in a manner that doesn't depend on
# gensymmed names.
# `mnokw` is the method that gets called when you invoke it without
# supplying any keywords.
function __lookup_kwbody__(mnokw::Method)
    function getsym(arg)
        isa(arg, Symbol) && return arg
        @assert isa(arg, GlobalRef)
        return arg.name
    end

    f = get(__bodyfunction__, mnokw, nothing)
    if f === nothing
        fmod = mnokw.module
        # The lowered code for `mnokw` should look like
        #   %1 = mkw(kwvalues..., #self#, args...)
        #        return %1
        # where `mkw` is the name of the "active" keyword body-function.
        ast = Base.uncompressed_ast(mnokw)
        if isa(ast, Core.CodeInfo) && length(ast.code) >= 2
            callexpr = ast.code[end-1]
            if isa(callexpr, Expr) && callexpr.head == :call
                fsym = callexpr.args[1]
                if isa(fsym, Symbol)
                    f = getfield(fmod, fsym)
                elseif isa(fsym, GlobalRef)
                    if fsym.mod === Core && fsym.name === :_apply
                        f = getfield(mnokw.module, getsym(callexpr.args[2]))
                    elseif fsym.mod === Core && fsym.name === :_apply_iterate
                        f = getfield(mnokw.module, getsym(callexpr.args[3]))
                    else
                        f = getfield(fsym.mod, fsym.name)
                    end
                else
                    f = missing
                end
            else
                f = missing
            end
        else
            f = missing
        end
        __bodyfunction__[mnokw] = f
    end
    return f
end

function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    isdefined(Base.Broadcast, Symbol("#31#32")) && precompile(Tuple{getfield(Base.Broadcast, Symbol("#31#32")),DirectorySource})
    isdefined(Base.Broadcast, Symbol("#31#32")) && precompile(Tuple{getfield(Base.Broadcast, Symbol("#31#32")),FileSource})
    isdefined(BinaryBuilder, Symbol("#155#161")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#155#161")),String})
    isdefined(BinaryBuilder, Symbol("#170#173")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#170#173")),String})
    isdefined(BinaryBuilder, Symbol("#170#173")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#170#173")),String})
    isdefined(BinaryBuilder, Symbol("#20#21")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#20#21"))})
    isdefined(BinaryBuilder, Symbol("#20#21")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#20#21"))})
    isdefined(BinaryBuilder, Symbol("#222#227")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#222#227")),String})
    isdefined(BinaryBuilder, Symbol("#223#228")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#223#228")),String})
    isdefined(BinaryBuilder, Symbol("#224#229")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#224#229")),String})
    isdefined(BinaryBuilder, Symbol("#282#283")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#282#283"))})
    isdefined(BinaryBuilder, Symbol("#7#9")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#7#9"))})
    isdefined(BinaryBuilder, Symbol("#8#10")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#8#10"))})
    isdefined(BinaryBuilder, Symbol("#98#111")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#98#111")),String})
    isdefined(BinaryBuilder, Symbol("#99#112")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#99#112")),String})
    isdefined(BinaryBuilder, Symbol("#99#112")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#99#112")),SubString{String}})
    isdefined(BinaryBuilder, Symbol("#GOOS#208")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#GOOS#208")),Linux})
    isdefined(BinaryBuilder, Symbol("#base_gcc_flags#191")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#base_gcc_flags#191")),Linux})
    isdefined(BinaryBuilder, Symbol("#cargo#215")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#cargo#215")),IOStream,Linux})
    isdefined(BinaryBuilder, Symbol("#cc#205")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#cc#205")),IOStream,Linux})
    isdefined(BinaryBuilder, Symbol("#check_set#150")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#check_set#150")),String,Array{String,1}})
    isdefined(BinaryBuilder, Symbol("#clang#202")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#clang#202")),IOStream,Linux})
    isdefined(BinaryBuilder, Symbol("#clang_compile_flags#196")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#clang_compile_flags#196")),Linux})
    isdefined(BinaryBuilder, Symbol("#clang_flags#195")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#clang_flags#195")),Linux})
    isdefined(BinaryBuilder, Symbol("#clang_link_flags#197")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#clang_link_flags#197")),Linux})
    isdefined(BinaryBuilder, Symbol("#clangxx#203")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#clangxx#203")),IOStream,Linux})
    isdefined(BinaryBuilder, Symbol("#cxx#206")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#cxx#206")),IOStream,Linux})
    isdefined(BinaryBuilder, Symbol("#cxxfilt#217")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#cxxfilt#217")),IOStream,Linux})
    isdefined(BinaryBuilder, Symbol("#fortran_flags#193")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#fortran_flags#193")),Linux})
    isdefined(BinaryBuilder, Symbol("#gcc_flags#192")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#gcc_flags#192")),Linux})
    isdefined(BinaryBuilder, Symbol("#gcc_link_flags#198")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#gcc_link_flags#198")),Linux})
    isdefined(BinaryBuilder, Symbol("#gfortran#201")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#gfortran#201")),IOStream,Linux})
    isdefined(BinaryBuilder, Symbol("#go#210")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#go#210")),IOStream,Linux})
    isdefined(BinaryBuilder, Symbol("#meson#216")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#meson#216")),IOStream,Linux})
    isdefined(BinaryBuilder, Symbol("#objc#204")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#objc#204")),IOStream,Linux})
    isdefined(BinaryBuilder, Symbol("#rust_flags#212")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#rust_flags#212")),Linux})
    isdefined(BinaryBuilder, Symbol("#rustc#213")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#rustc#213")),IOStream,Linux})
    isdefined(BinaryBuilder, Symbol("#rustup#214")) && precompile(Tuple{getfield(BinaryBuilder, Symbol("#rustup#214")),IOStream,Linux})
    let fbody = try __lookup_kwbody__(which(BinaryBuilder.audit, (Prefix,String,))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Base.TTY,Linux,Bool,Bool,Bool,Bool,typeof(audit),Prefix,String,))
        end
    end
    let fbody = try __lookup_kwbody__(which(BinaryBuilder.build_tarballs, (Any,Any,Any,Any,Any,Any,Any,Any,))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Any,typeof(build_tarballs),Any,Any,Any,Any,Any,Any,Any,Any,))
        end
    end
    let fbody = try __lookup_kwbody__(which(BinaryBuilder.check_cxxstring_abi, (ObjectFile.ELF.ELFHandle{IOStream},Linux,))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Base.TTY,Bool,typeof(BinaryBuilder.check_cxxstring_abi),ObjectFile.ELF.ELFHandle{IOStream},Linux,))
        end
    end
    let fbody = try __lookup_kwbody__(which(BinaryBuilder.resolve_jlls, (Array{Dependency,1},))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Pkg.Types.Context,Base.TTY,typeof(BinaryBuilder.resolve_jlls),Array{Dependency,1},))
        end
    end
    let fbody = try __lookup_kwbody__(which(OutputCollector, (Cmd,))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Bool,Bool,Base.TTY,Type{OutputCollector},Cmd,))
        end
    end
    let fbody = try __lookup_kwbody__(which(run, (BinaryBuilder.UserNSRunner,Cmd,IOStream,))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Bool,Base.TTY,typeof(run),BinaryBuilder.UserNSRunner,Cmd,IOStream,))
        end
    end
    precompile(Tuple{Core.kwftype(typeof(Base.Broadcast.broadcasted_kwsyntax)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(Base.Broadcast.broadcasted_kwsyntax),Function,Array{BinaryBuilder.AbstractSource,1}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Type)),NamedTuple{(:cwd, :platform),Tuple{String,Linux}},Type{BinaryBuilder.UserNSRunner},String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Type)),NamedTuple{(:cwd, :platform, :verbose),Tuple{String,Linux,Bool}},Type{BinaryBuilder.UserNSRunner},String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Type)),NamedTuple{(:cwd, :platform, :verbose, :workspaces, :compiler_wrapper_dir, :src_name, :shards, :compilers),Tuple{String,Linux,Bool,Array{Pair{String,String},1},String,String,Array{BinaryBuilder.CompilerShard,1},Array{Symbol,1}}},Type{BinaryBuilder.UserNSRunner},String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.autobuild)),NamedTuple{(:verbose, :debug, :meta_json_stream),Tuple{Bool,Bool,IOStream}},typeof(autobuild),String,String,VersionNumber,Array{DirectorySource,1},String,Array{Linux,1},Array{Product,1},Array{Dependency,1}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.autobuild)),NamedTuple{(:verbose, :debug, :meta_json_stream, :compilers),Tuple{Bool,Bool,Nothing,Array{Symbol,1}}},typeof(autobuild),String,String,VersionNumber,Array{BinaryBuilder.AbstractSource,1},String,Array{Linux,1},Array{Product,1},Array{Dependency,1}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.build_tarballs)),NamedTuple{(:compilers,),Tuple{Array{Symbol,1}}},typeof(build_tarballs),Array{String,1},String,VersionNumber,Array{BinaryBuilder.AbstractSource,1},String,Array{Linux,1},Array{Product,1},Array{Dependency,1}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.check_cxxstring_abi)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(BinaryBuilder.check_cxxstring_abi),ObjectFile.ELF.ELFHandle{IOStream},Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.check_dynamic_linkage)),NamedTuple{(:platform, :silent, :verbose, :autofix),Tuple{Linux,Bool,Bool,Bool}},typeof(BinaryBuilder.check_dynamic_linkage),ObjectFile.ELF.ELFHandle{IOStream},Prefix,Array{String,1}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.check_isa)),NamedTuple{(:verbose, :silent),Tuple{Bool,Bool}},typeof(BinaryBuilder.check_isa),ObjectFile.ELF.ELFHandle{IOStream},Linux,Prefix})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.check_libgfortran_version)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(BinaryBuilder.check_libgfortran_version),ObjectFile.ELF.ELFHandle{IOStream},Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.check_license)),NamedTuple{(:verbose, :silent),Tuple{Bool,Bool}},typeof(BinaryBuilder.check_license),Prefix,String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.check_os_abi)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(BinaryBuilder.check_os_abi),ObjectFile.ELF.ELFHandle{IOStream},Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.choose_shards)),NamedTuple{(:compilers,),Tuple{Array{Symbol,1}}},typeof(BinaryBuilder.choose_shards),Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.ensure_soname)),NamedTuple{(:verbose, :autofix),Tuple{Bool,Bool}},typeof(BinaryBuilder.ensure_soname),Prefix,String,Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.generate_compiler_wrappers!)),NamedTuple{(:bin_path, :compilers),Tuple{String,Array{Symbol,1}}},typeof(BinaryBuilder.generate_compiler_wrappers!),Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.generate_compiler_wrappers!)),NamedTuple{(:bin_path,),Tuple{String}},typeof(BinaryBuilder.generate_compiler_wrappers!),Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.get_compilers_versions)),NamedTuple{(:compilers,),Tuple{Array{Symbol,1}}},typeof(BinaryBuilder.get_compilers_versions)})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.satisfied)),NamedTuple{(:verbose, :platform),Tuple{Bool,Linux}},typeof(satisfied),ExecutableProduct,Prefix})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.symlink_soname_lib)),NamedTuple{(:verbose, :autofix),Tuple{Bool,Bool}},typeof(BinaryBuilder.symlink_soname_lib),String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.translate_symlinks)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(BinaryBuilder.translate_symlinks),String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.update_linkage)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(BinaryBuilder.update_linkage),Prefix,Linux,String,SubString{String},String})
    precompile(Tuple{Type{Array{BinaryBuilder.AbstractSource,1}},UndefInitializer,Int64})
    precompile(Tuple{Type{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Axes,F,Args} where Args<:Tuple where F where Axes},typeof(BinaryBuilder.coerce_dependency),Tuple{Array{Dependency,1}}})
    precompile(Tuple{Type{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Axes,F,Args} where Args<:Tuple where F where Axes},typeof(BinaryBuilder.coerce_source),Tuple{Array{DirectorySource,1}}})
    precompile(Tuple{Type{Dependency},String})
    precompile(Tuple{Type{DirectorySource},String})
    precompile(Tuple{Type{ExecutableProduct},String,Symbol})
    precompile(Tuple{Type{FileSource},String,String})
    precompile(Tuple{Type{OutputCollector},Cmd,Base.Process,BinaryBuilder.LineStream,BinaryBuilder.LineStream,Base.GenericCondition{Base.AlwaysLockedST},Base.DevNull,Bool,Bool})
    precompile(Tuple{Type{OutputCollector},Cmd,Base.Process,BinaryBuilder.LineStream,BinaryBuilder.LineStream,Base.GenericCondition{Base.AlwaysLockedST},Base.TTY,Bool,Bool})
    precompile(Tuple{typeof(Base.Broadcast.broadcasted),Function,Array{BinaryBuilder.AbstractSource,1}})
    precompile(Tuple{typeof(Base.Broadcast.broadcasted),Function,Array{Dependency,1}})
    precompile(Tuple{typeof(Base.Broadcast.broadcasted),Function,Array{DirectorySource,1}})
    precompile(Tuple{typeof(Base.Broadcast.copyto_nonleaf!),Array{FileSource,1},Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Tuple{Base.OneTo{Int64}},typeof(BinaryBuilder.coerce_source),Tuple{Base.Broadcast.Extruded{Array{BinaryBuilder.AbstractSource,1},Tuple{Bool},Tuple{Int64}}}},Base.OneTo{Int64},Int64,Int64})
    precompile(Tuple{typeof(Base.Broadcast.instantiate),Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Nothing,typeof(BinaryBuilder.coerce_dependency),Tuple{Array{Dependency,1}}}})
    precompile(Tuple{typeof(Base.Broadcast.instantiate),Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Nothing,typeof(BinaryBuilder.coerce_source),Tuple{Array{DirectorySource,1}}}})
    precompile(Tuple{typeof(Base.Broadcast.restart_copyto_nonleaf!),Array{BinaryBuilder.AbstractSource,1},Array{FileSource,1},Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Tuple{Base.OneTo{Int64}},typeof(BinaryBuilder.coerce_source),Tuple{Base.Broadcast.Extruded{Array{BinaryBuilder.AbstractSource,1},Tuple{Bool},Tuple{Int64}}}},DirectorySource,Int64,Base.OneTo{Int64},Int64,Int64})
    precompile(Tuple{typeof(Base._compute_eltype),Type{Tuple{Pair{String,String},Pair{String,String},Pair{String,Array{DirectorySource,1}},Pair{String,String},Pair{String,Array{String,1}},Pair{String,Array{Product,1}},Pair{String,Array{Dependency,1}},Pair{String,Bool}}}})
    precompile(Tuple{typeof(Base.allocatedinline),Type{BinaryBuilder.CompilerShard}})
    precompile(Tuple{typeof(Base.grow_to!),Dict{String,Any},Tuple{Pair{String,String},Pair{String,String},Pair{String,Array{DirectorySource,1}},Pair{String,String},Pair{String,Array{String,1}},Pair{String,Array{Product,1}},Pair{String,Array{Dependency,1}},Pair{String,Bool}},Int64})
    precompile(Tuple{typeof(Base.grow_to!),Dict{String,String},Tuple{Pair{String,String},Pair{String,String},Pair{String,Array{DirectorySource,1}},Pair{String,String},Pair{String,Array{String,1}},Pair{String,Array{Product,1}},Pair{String,Array{Dependency,1}},Pair{String,Bool}},Int64})
    precompile(Tuple{typeof(Base.merge_types),NTuple{8,Symbol},Type{NamedTuple{(:cwd, :platform, :verbose, :workspaces, :compiler_wrapper_dir, :src_name, :shards),Tuple{String,Linux,Bool,Array{Pair{String,String},1},String,String,Array{BinaryBuilder.CompilerShard,1}}}},Type{NamedTuple{(:compilers,),Tuple{Array{Symbol,1}}}}})
    precompile(Tuple{typeof(Base.promote_typeof),FileSource,DirectorySource})
    precompile(Tuple{typeof(Base.vect),FileSource,Vararg{Any,N} where N})
    precompile(Tuple{typeof(BinaryBuilder.cppfilt),Array{SubString{String},1},Linux})
    precompile(Tuple{typeof(BinaryBuilder.minimum_instruction_set),Dict{String,Int64},Bool})
    precompile(Tuple{typeof(BinaryBuilder.should_ignore_lib),SubString{String},ObjectFile.ELF.ELFHandle{IOStream}})
    precompile(Tuple{typeof(BinaryBuilder.storage_dir),String,Vararg{String,N} where N})
    precompile(Tuple{typeof(BinaryBuilder.with_logfile),Function,Prefix,String})
    precompile(Tuple{typeof(JSON.Writer.show_element),JSON.Writer.CompactContext{Base.GenericIOBuffer{Array{UInt8,1}}},JSON.Serializations.StandardSerialization,ExecutableProduct})
    precompile(Tuple{typeof(JSON.Writer.show_pair),JSON.Writer.CompactContext{Base.GenericIOBuffer{Array{UInt8,1}}},JSON.Serializations.StandardSerialization,String,Array{Dependency,1}})
    precompile(Tuple{typeof(JSON.Writer.show_pair),JSON.Writer.CompactContext{Base.GenericIOBuffer{Array{UInt8,1}}},JSON.Serializations.StandardSerialization,String,Array{DirectorySource,1}})
    precompile(Tuple{typeof(JSON.Writer.show_pair),JSON.Writer.CompactContext{Base.GenericIOBuffer{Array{UInt8,1}}},JSON.Serializations.StandardSerialization,String,Array{Product,1}})
    precompile(Tuple{typeof(build_tarballs),Any,Any,Any,Any,Any,Any,Any,Any})
    precompile(Tuple{typeof(copy),Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Tuple{Base.OneTo{Int64}},typeof(BinaryBuilder.coerce_dependency),Tuple{Array{Dependency,1}}}})
    precompile(Tuple{typeof(copy),Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Tuple{Base.OneTo{Int64}},typeof(BinaryBuilder.coerce_source),Tuple{Array{DirectorySource,1}}}})
    precompile(Tuple{typeof(copyto!),Array{BinaryBuilder.AbstractSource,1},Tuple{FileSource,DirectorySource}})
    precompile(Tuple{typeof(findfirst),Function,Array{BinaryBuilder.CompilerShard,1}})
    precompile(Tuple{typeof(getindex),Type{Dependency},Dependency})
    precompile(Tuple{typeof(getindex),Type{Dependency}})
    precompile(Tuple{typeof(getindex),Type{DirectorySource}})
    precompile(Tuple{typeof(getindex),Type{Product},ExecutableProduct,ExecutableProduct,ExecutableProduct,ExecutableProduct,Vararg{ExecutableProduct,N} where N})
    precompile(Tuple{typeof(merge),NamedTuple{(:cwd, :platform, :verbose, :workspaces, :compiler_wrapper_dir, :src_name, :shards),Tuple{String,Linux,Bool,Array{Pair{String,String},1},String,String,Array{BinaryBuilder.CompilerShard,1}}},NamedTuple{(:compilers,),Tuple{Array{Symbol,1}}}})
    precompile(Tuple{typeof(repr),ExecutableProduct})
    precompile(Tuple{typeof(repr),LibraryProduct})
    precompile(Tuple{typeof(setindex!),Array{FileSource,1},FileSource,Int64})
    precompile(Tuple{typeof(setindex!),Dict{Any,Any},Dict{String,String},ExecutableProduct})
    precompile(Tuple{typeof(setindex!),Dict{String,Any},Array{Dependency,1},String})
    precompile(Tuple{typeof(setindex!),Dict{String,Any},Array{DirectorySource,1},String})
    precompile(Tuple{typeof(setindex!),Dict{String,Any},Array{Product,1},String})
    precompile(Tuple{typeof(similar),Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Tuple{Base.OneTo{Int64}},typeof(BinaryBuilder.coerce_source),Tuple{Base.Broadcast.Extruded{Array{BinaryBuilder.AbstractSource,1},Tuple{Bool},Tuple{Int64}}}},Type{FileSource}})
end
