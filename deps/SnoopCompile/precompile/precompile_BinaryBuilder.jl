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
    isdefined(Base, Symbol("#630#631")) && precompile(Tuple{getfield(Base, Symbol("#630#631"))})
    isdefined(Base.Broadcast, Symbol("#31#32")) && precompile(Tuple{getfield(Base.Broadcast, Symbol("#31#32")),ArchiveSource})
    isdefined(Base.Broadcast, Symbol("#31#32")) && precompile(Tuple{getfield(Base.Broadcast, Symbol("#31#32")),DirectorySource})
    isdefined(BinaryBuilder.Auditor, Symbol("#110#113")) && precompile(Tuple{getfield(BinaryBuilder.Auditor, Symbol("#110#113")),String})
    isdefined(BinaryBuilder.Auditor, Symbol("#32#45")) && precompile(Tuple{getfield(BinaryBuilder.Auditor, Symbol("#32#45")),String})
    isdefined(BinaryBuilder.Auditor, Symbol("#33#46")) && precompile(Tuple{getfield(BinaryBuilder.Auditor, Symbol("#33#46")),String})
    isdefined(BinaryBuilder.Auditor, Symbol("#33#46")) && precompile(Tuple{getfield(BinaryBuilder.Auditor, Symbol("#33#46")),SubString{String}})
    isdefined(BinaryBuilder.Auditor, Symbol("#92#98")) && precompile(Tuple{getfield(BinaryBuilder.Auditor, Symbol("#92#98")),String})
    isdefined(BinaryBuilder.Auditor, Symbol("#check_set#87")) && precompile(Tuple{getfield(BinaryBuilder.Auditor, Symbol("#check_set#87")),String,Array{String,1}})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#109#114")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#109#114")),String})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#110#115")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#110#115")),String})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#111#116")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#111#116")),String})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#171#172")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#171#172"))})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#GOOS#94")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#GOOS#94")),Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#base_gcc_flags#76")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#base_gcc_flags#76")),Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#cargo#101")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#cargo#101")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#cc#91")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#cc#91")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#clang#88")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#clang#88")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#clang_compile_flags#81")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#clang_compile_flags#81")),Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#clang_flags#80")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#clang_flags#80")),Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#clang_link_flags#82")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#clang_link_flags#82")),Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#clangxx#89")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#clangxx#89")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#cxx#92")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#cxx#92")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#cxxfilt#104")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#cxxfilt#104")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#fortran_flags#78")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#fortran_flags#78")),Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#gcc_flags#77")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#gcc_flags#77")),Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#gcc_link_flags#83")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#gcc_link_flags#83")),Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#gfortran#87")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#gfortran#87")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#go#96")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#go#96")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#meson#102")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#meson#102")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#objc#90")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#objc#90")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#patchelf#103")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#patchelf#103")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#rust_flags#98")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#rust_flags#98")),Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#rustc#99")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#rustc#99")),IOStream,Linux})
    isdefined(BinaryBuilder.BinaryBuilderBase, Symbol("#rustup#100")) && precompile(Tuple{getfield(BinaryBuilder.BinaryBuilderBase, Symbol("#rustup#100")),IOStream,Linux})
    isdefined(BinaryBuilder.OutputCollectors, Symbol("#1#3")) && precompile(Tuple{getfield(BinaryBuilder.OutputCollectors, Symbol("#1#3"))})
    isdefined(BinaryBuilder.OutputCollectors, Symbol("#14#15")) && precompile(Tuple{getfield(BinaryBuilder.OutputCollectors, Symbol("#14#15"))})
    isdefined(BinaryBuilder.OutputCollectors, Symbol("#2#4")) && precompile(Tuple{getfield(BinaryBuilder.OutputCollectors, Symbol("#2#4"))})
    let fbody = try __lookup_kwbody__(which(BinaryBuilder.Auditor.audit, (Prefix,String,))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Base.TTY,Linux,Bool,Bool,Bool,Bool,Bool,typeof(audit),Prefix,String,))
        end
    end
    let fbody = try __lookup_kwbody__(which(BinaryBuilder.Auditor.check_cxxstring_abi, (ObjectFile.ELF.ELFHandle{IOStream},Linux,))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Base.TTY,Bool,typeof(BinaryBuilder.Auditor.check_cxxstring_abi),ObjectFile.ELF.ELFHandle{IOStream},Linux,))
        end
    end
    let fbody = try __lookup_kwbody__(which(BinaryBuilder.BinaryBuilderBase.compress_dir, (String,))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Type{T} where T,Int64,String,Bool,typeof(BinaryBuilder.BinaryBuilderBase.compress_dir),String,))
        end
    end
    let fbody = try __lookup_kwbody__(which(BinaryBuilder.BinaryBuilderBase.resolve_jlls, (Array{Dependency,1},))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Pkg.Types.Context,Base.TTY,typeof(BinaryBuilder.BinaryBuilderBase.resolve_jlls),Array{Dependency,1},))
        end
    end
    let fbody = try __lookup_kwbody__(which(BinaryBuilder.build_tarballs, (Any,Any,Any,Any,Any,Any,Any,Any,))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Any,typeof(build_tarballs),Any,Any,Any,Any,Any,Any,Any,Any,))
        end
    end
    let fbody = try __lookup_kwbody__(which(run, (BinaryBuilder.BinaryBuilderBase.UserNSRunner,Cmd,IOStream,))) catch missing end
        if !ismissing(fbody)
            precompile(fbody, (Bool,Base.TTY,typeof(run),BinaryBuilder.BinaryBuilderBase.UserNSRunner,Cmd,IOStream,))
        end
    end
    precompile(Tuple{Core.kwftype(typeof(Base.Broadcast.broadcasted_kwsyntax)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(Base.Broadcast.broadcasted_kwsyntax),Function,Array{BinaryBuilder.BinaryBuilderBase.AbstractSource,1}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.check_cxxstring_abi)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(BinaryBuilder.Auditor.check_cxxstring_abi),ObjectFile.ELF.ELFHandle{IOStream},Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.check_dynamic_linkage)),NamedTuple{(:platform, :silent, :verbose, :autofix),Tuple{Linux,Bool,Bool,Bool}},typeof(BinaryBuilder.Auditor.check_dynamic_linkage),ObjectFile.ELF.ELFHandle{IOStream},Prefix,Array{String,1}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.check_isa)),NamedTuple{(:verbose, :silent),Tuple{Bool,Bool}},typeof(BinaryBuilder.Auditor.check_isa),ObjectFile.ELF.ELFHandle{IOStream},Linux,Prefix})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.check_libgfortran_version)),NamedTuple{(:verbose, :has_csl),Tuple{Bool,Bool}},typeof(BinaryBuilder.Auditor.check_libgfortran_version),ObjectFile.ELF.ELFHandle{IOStream},Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.check_libgomp)),NamedTuple{(:verbose, :has_csl),Tuple{Bool,Bool}},typeof(BinaryBuilder.Auditor.check_libgomp),ObjectFile.ELF.ELFHandle{IOStream},Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.check_license)),NamedTuple{(:verbose, :silent),Tuple{Bool,Bool}},typeof(BinaryBuilder.Auditor.check_license),Prefix,String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.check_os_abi)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(BinaryBuilder.Auditor.check_os_abi),ObjectFile.ELF.ELFHandle{IOStream},Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.ensure_soname)),NamedTuple{(:verbose, :autofix),Tuple{Bool,Bool}},typeof(BinaryBuilder.Auditor.ensure_soname),Prefix,String,Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.relink_to_rpath)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(BinaryBuilder.Auditor.relink_to_rpath),Prefix,Linux,String,SubString{String}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.symlink_soname_lib)),NamedTuple{(:verbose, :autofix),Tuple{Bool,Bool}},typeof(BinaryBuilder.Auditor.symlink_soname_lib),String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.translate_symlinks)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(BinaryBuilder.Auditor.translate_symlinks),String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.Auditor.update_linkage)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(BinaryBuilder.Auditor.update_linkage),Prefix,Linux,String,SubString{String},String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.BinaryBuilderBase.Type)),NamedTuple{(:cwd, :platform),Tuple{String,Linux}},Type{BinaryBuilder.BinaryBuilderBase.UserNSRunner},String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.BinaryBuilderBase.Type)),NamedTuple{(:cwd, :platform, :verbose),Tuple{String,Linux,Bool}},Type{BinaryBuilder.BinaryBuilderBase.UserNSRunner},String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.BinaryBuilderBase.Type)),NamedTuple{(:cwd, :platform, :verbose, :workspaces, :compiler_wrapper_dir, :src_name, :shards, :compilers),Tuple{String,Linux,Bool,Array{Pair{String,String},1},String,String,Array{BinaryBuilder.BinaryBuilderBase.CompilerShard,1},Array{Symbol,1}}},Type{BinaryBuilder.BinaryBuilderBase.UserNSRunner},String})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.BinaryBuilderBase.choose_shards)),NamedTuple{(:compilers,),Tuple{Array{Symbol,1}}},typeof(BinaryBuilder.BinaryBuilderBase.choose_shards),Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.BinaryBuilderBase.generate_compiler_wrappers!)),NamedTuple{(:bin_path, :compilers),Tuple{String,Array{Symbol,1}}},typeof(BinaryBuilder.BinaryBuilderBase.generate_compiler_wrappers!),Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.BinaryBuilderBase.generate_compiler_wrappers!)),NamedTuple{(:bin_path,),Tuple{String}},typeof(BinaryBuilder.BinaryBuilderBase.generate_compiler_wrappers!),Linux})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.BinaryBuilderBase.satisfied)),NamedTuple{(:verbose, :platform),Tuple{Bool,Linux}},typeof(satisfied),ExecutableProduct,Prefix})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.BinaryBuilderBase.setup_workspace)),NamedTuple{(:verbose,),Tuple{Bool}},typeof(BinaryBuilder.BinaryBuilderBase.setup_workspace),String,Array{BinaryBuilder.BinaryBuilderBase.SetupSource,1}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.autobuild)),NamedTuple{(:verbose, :debug, :meta_json_stream),Tuple{Bool,Bool,IOStream}},typeof(autobuild),String,String,VersionNumber,Array{DirectorySource,1},String,Array{Linux,1},Array{Product,1},Array{Dependency,1}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.autobuild)),NamedTuple{(:verbose, :debug, :meta_json_stream, :compilers),Tuple{Bool,Bool,Nothing,Array{Symbol,1}}},typeof(autobuild),String,String,VersionNumber,Array{BinaryBuilder.BinaryBuilderBase.AbstractSource,1},String,Array{Linux,1},Array{Product,1},Array{Dependency,1}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.build_tarballs)),NamedTuple{(:compilers,),Tuple{Array{Symbol,1}}},typeof(build_tarballs),Array{String,1},String,VersionNumber,Array{BinaryBuilder.BinaryBuilderBase.AbstractSource,1},String,Array{Linux,1},Array{Product,1},Array{Dependency,1}})
    precompile(Tuple{Core.kwftype(typeof(BinaryBuilder.get_compilers_versions)),NamedTuple{(:compilers,),Tuple{Array{Symbol,1}}},typeof(BinaryBuilder.get_compilers_versions)})
    precompile(Tuple{Type{ArchiveSource},String,String})
    precompile(Tuple{Type{Array{BinaryBuilder.BinaryBuilderBase.AbstractSource,1}},UndefInitializer,Int64})
    precompile(Tuple{Type{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Axes,F,Args} where Args<:Tuple where F where Axes},typeof(BinaryBuilder.BinaryBuilderBase.coerce_dependency),Tuple{Array{Dependency,1}}})
    precompile(Tuple{Type{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Axes,F,Args} where Args<:Tuple where F where Axes},typeof(BinaryBuilder.BinaryBuilderBase.coerce_source),Tuple{Array{DirectorySource,1}}})
    precompile(Tuple{Type{BinaryBuilder.OutputCollectors.OutputCollector},Cmd,Base.Process,BinaryBuilder.OutputCollectors.LineStream,BinaryBuilder.OutputCollectors.LineStream,Base.GenericCondition{Base.AlwaysLockedST},Base.DevNull,Bool,Bool})
    precompile(Tuple{Type{BinaryBuilder.OutputCollectors.OutputCollector},Cmd,Base.Process,BinaryBuilder.OutputCollectors.LineStream,BinaryBuilder.OutputCollectors.LineStream,Base.GenericCondition{Base.AlwaysLockedST},Base.TTY,Bool,Bool})
    precompile(Tuple{Type{Dependency},String})
    precompile(Tuple{Type{DirectorySource},String})
    precompile(Tuple{Type{ExecutableProduct},String,Symbol})
    precompile(Tuple{typeof(Base.Broadcast.broadcasted),Function,Array{BinaryBuilder.BinaryBuilderBase.AbstractSource,1}})
    precompile(Tuple{typeof(Base.Broadcast.broadcasted),Function,Array{Dependency,1}})
    precompile(Tuple{typeof(Base.Broadcast.broadcasted),Function,Array{DirectorySource,1}})
    precompile(Tuple{typeof(Base.Broadcast.broadcasted),Function,Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Nothing,typeof(BinaryBuilder.BinaryBuilderBase.getname),Tuple{Array{Dependency,1}}},String})
    precompile(Tuple{typeof(Base.Broadcast.combine_eltypes),Function,Tuple{Array{BinaryBuilder.BinaryBuilderBase.AbstractSource,1}}})
    precompile(Tuple{typeof(Base.Broadcast.copyto_nonleaf!),Array{ArchiveSource,1},Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Tuple{Base.OneTo{Int64}},typeof(BinaryBuilder.BinaryBuilderBase.coerce_source),Tuple{Base.Broadcast.Extruded{Array{BinaryBuilder.BinaryBuilderBase.AbstractSource,1},Tuple{Bool},Tuple{Int64}}}},Base.OneTo{Int64},Int64,Int64})
    precompile(Tuple{typeof(Base.Broadcast.instantiate),Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Nothing,typeof(BinaryBuilder.BinaryBuilderBase.coerce_dependency),Tuple{Array{Dependency,1}}}})
    precompile(Tuple{typeof(Base.Broadcast.instantiate),Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Nothing,typeof(BinaryBuilder.BinaryBuilderBase.coerce_source),Tuple{Array{DirectorySource,1}}}})
    precompile(Tuple{typeof(Base.Broadcast.restart_copyto_nonleaf!),Array{BinaryBuilder.BinaryBuilderBase.AbstractSource,1},Array{ArchiveSource,1},Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Tuple{Base.OneTo{Int64}},typeof(BinaryBuilder.BinaryBuilderBase.coerce_source),Tuple{Base.Broadcast.Extruded{Array{BinaryBuilder.BinaryBuilderBase.AbstractSource,1},Tuple{Bool},Tuple{Int64}}}},DirectorySource,Int64,Base.OneTo{Int64},Int64,Int64})
    precompile(Tuple{typeof(Base._compute_eltype),Type{Tuple{Pair{String,String},Pair{String,String},Pair{String,Array{DirectorySource,1}},Pair{String,String},Pair{String,Array{Product,1}},Pair{String,Array{Dependency,1}},Pair{String,Bool}}}})
    precompile(Tuple{typeof(Base.allocatedinline),Type{BinaryBuilder.BinaryBuilderBase.CompilerShard}})
    precompile(Tuple{typeof(Base.allocatedinline),Type{Dependency}})
    precompile(Tuple{typeof(Base.grow_to!),Dict{String,Any},Tuple{Pair{String,String},Pair{String,String},Pair{String,Array{DirectorySource,1}},Pair{String,String},Pair{String,Array{Product,1}},Pair{String,Array{Dependency,1}},Pair{String,Bool}},Int64})
    precompile(Tuple{typeof(Base.grow_to!),Dict{String,String},Tuple{Pair{String,String},Pair{String,String},Pair{String,Array{DirectorySource,1}},Pair{String,String},Pair{String,Array{Product,1}},Pair{String,Array{Dependency,1}},Pair{String,Bool}},Int64})
    precompile(Tuple{typeof(Base.merge_types),NTuple{8,Symbol},Type{NamedTuple{(:cwd, :platform, :verbose, :workspaces, :compiler_wrapper_dir, :src_name, :shards),Tuple{String,Linux,Bool,Array{Pair{String,String},1},String,String,Array{BinaryBuilder.BinaryBuilderBase.CompilerShard,1}}}},Type{NamedTuple{(:compilers,),Tuple{Array{Symbol,1}}}}})
    precompile(Tuple{typeof(Base.promote_typeof),ArchiveSource,DirectorySource})
    precompile(Tuple{typeof(Base.vect),ArchiveSource,Vararg{Any,N} where N})
    precompile(Tuple{typeof(BinaryBuilder.Auditor.cppfilt),Array{SubString{String},1},Linux})
    precompile(Tuple{typeof(BinaryBuilder.Auditor.is_default_lib),SubString{String},ObjectFile.ELF.ELFHandle{IOStream}})
    precompile(Tuple{typeof(BinaryBuilder.Auditor.is_troublesome_library_link),SubString{String},Linux})
    precompile(Tuple{typeof(BinaryBuilder.Auditor.minimum_instruction_set),Dict{String,Int64},Bool})
    precompile(Tuple{typeof(BinaryBuilder.Auditor.should_ignore_lib),SubString{String},ObjectFile.ELF.ELFHandle{IOStream}})
    precompile(Tuple{typeof(BinaryBuilder.BinaryBuilderBase.storage_dir),String,Vararg{String,N} where N})
    precompile(Tuple{typeof(BinaryBuilder.BinaryBuilderBase.with_logfile),Function,Prefix,String})
    precompile(Tuple{typeof(BinaryBuilder.check_flag!),Array{String,1},String})
    precompile(Tuple{typeof(BinaryBuilder.extract_flag!),Array{String,1},String,String})
    precompile(Tuple{typeof(BinaryBuilder.extract_flag!),Array{String,1},String})
    precompile(Tuple{typeof(JSON.Writer.show_element),JSON.Writer.CompactContext{Base.GenericIOBuffer{Array{UInt8,1}}},JSON.Serializations.StandardSerialization,ExecutableProduct})
    precompile(Tuple{typeof(JSON.Writer.show_pair),JSON.Writer.CompactContext{Base.GenericIOBuffer{Array{UInt8,1}}},JSON.Serializations.StandardSerialization,String,Array{Dependency,1}})
    precompile(Tuple{typeof(JSON.Writer.show_pair),JSON.Writer.CompactContext{Base.GenericIOBuffer{Array{UInt8,1}}},JSON.Serializations.StandardSerialization,String,Array{DirectorySource,1}})
    precompile(Tuple{typeof(JSON.Writer.show_pair),JSON.Writer.CompactContext{Base.GenericIOBuffer{Array{UInt8,1}}},JSON.Serializations.StandardSerialization,String,Array{Product,1}})
    precompile(Tuple{typeof(build_tarballs),Any,Any,Any,Any,Any,Any,Any,Any})
    precompile(Tuple{typeof(copy),Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Tuple{Base.OneTo{Int64}},typeof(BinaryBuilder.BinaryBuilderBase.coerce_dependency),Tuple{Array{Dependency,1}}}})
    precompile(Tuple{typeof(copy),Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Tuple{Base.OneTo{Int64}},typeof(BinaryBuilder.BinaryBuilderBase.coerce_source),Tuple{Array{DirectorySource,1}}}})
    precompile(Tuple{typeof(copyto!),Array{BinaryBuilder.BinaryBuilderBase.AbstractSource,1},Tuple{ArchiveSource,DirectorySource}})
    precompile(Tuple{typeof(getindex),Type{Dependency},Dependency})
    precompile(Tuple{typeof(getindex),Type{Dependency}})
    precompile(Tuple{typeof(getindex),Type{DirectorySource}})
    precompile(Tuple{typeof(getindex),Type{Product},ExecutableProduct,ExecutableProduct,ExecutableProduct,ExecutableProduct,Vararg{ExecutableProduct,N} where N})
    precompile(Tuple{typeof(isequal),ExecutableProduct,ExecutableProduct})
    precompile(Tuple{typeof(merge),NamedTuple{(:cwd, :platform, :verbose, :workspaces, :compiler_wrapper_dir, :src_name, :shards),Tuple{String,Linux,Bool,Array{Pair{String,String},1},String,String,Array{BinaryBuilder.BinaryBuilderBase.CompilerShard,1}}},NamedTuple{(:compilers,),Tuple{Array{Symbol,1}}}})
    precompile(Tuple{typeof(setindex!),Array{ArchiveSource,1},ArchiveSource,Int64})
    precompile(Tuple{typeof(setindex!),Array{BinaryBuilder.BinaryBuilderBase.SetupSource{ArchiveSource},1},BinaryBuilder.BinaryBuilderBase.SetupSource{ArchiveSource},Int64})
    precompile(Tuple{typeof(setindex!),Dict{Product,Any},Dict{String,String},ExecutableProduct})
    precompile(Tuple{typeof(setindex!),Dict{String,Any},Array{Dependency,1},String})
    precompile(Tuple{typeof(setindex!),Dict{String,Any},Array{DirectorySource,1},String})
    precompile(Tuple{typeof(setindex!),Dict{String,Any},Array{Product,1},String})
    precompile(Tuple{typeof(similar),Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1},Tuple{Base.OneTo{Int64}},typeof(BinaryBuilder.BinaryBuilderBase.coerce_source),Tuple{Base.Broadcast.Extruded{Array{BinaryBuilder.BinaryBuilderBase.AbstractSource,1},Tuple{Bool},Tuple{Int64}}}},Type{ArchiveSource}})
    precompile(Tuple{typeof(strip),IOStream,Linux})
end
