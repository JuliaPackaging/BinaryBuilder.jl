# WebAssembly products, which ObjectFile.jl cannot read: static archives of wasm objects.
# There is no stable dynamic-linking ABI for wasm (`dylink.0` is still a work in progress), so
# libraries are archives, and the checks are on their members.

const WASM_MAGIC = UInt8[0x00, 0x61, 0x73, 0x6d]

function wasm_leb(b::AbstractVector{UInt8}, i::Int)
    r, s = UInt64(0), 0
    while true
        x = b[i]; i += 1
        r |= UInt64(x & 0x7f) << s; s += 7
        x & 0x80 == 0 && return Int(r), i
    end
end

"""
    ar_members(path) -> Vector{Pair{String,Vector{UInt8}}}

The members of a System V/GNU `ar` archive, without its symbol and long-name tables.
"""
function ar_members(path::AbstractString)
    b = read(path)
    length(b) >= 8 && b[1:8] == codeunits("!<arch>\n") || error("$(path) is not an ar archive")
    out = Pair{String,Vector{UInt8}}[]
    longnames = UInt8[]
    i = 9
    while i + 59 <= length(b)
        name = rstrip(String(b[i:i+15]))
        size = parse(Int, rstrip(String(b[i+48:i+57])))
        data = b[i+60:i+59+size]
        i += 60 + size + isodd(size)
        if name == "//"
            longnames = data
        elseif name in ("/", "/SYM64/", "__.SYMDEF", "__.SYMDEF SORTED")
            continue
        else
            if startswith(name, "/") && length(name) > 1 && all(isdigit, name[2:end])
                off = parse(Int, name[2:end]) + 1
                stop = something(findnext(==(UInt8('\n')), longnames, off), length(longnames) + 1)
                name = String(longnames[off:stop-1])
            end
            push!(out, rstrip(name, '/') => data)
        end
    end
    return out
end

"The custom sections of a wasm module or object, by name."
function wasm_custom_sections(b::AbstractVector{UInt8})
    out = Dict{String,Vector{UInt8}}()
    i = 9
    while i <= length(b)
        id = b[i]
        n, i = wasm_leb(b, i + 1)
        if id == 0x00
            len, j = wasm_leb(b, i)
            out[String(b[j:j+len-1])] = b[j+len:i+n-1]
        end
        i += n
    end
    return out
end

"The features a wasm object was compiled with (`+name`), from its `target_features` section."
function wasm_target_features(b::AbstractVector{UInt8})
    sec = get(wasm_custom_sections(b), "target_features", UInt8[])
    isempty(sec) && return Set{String}()
    feats = Set{String}()
    n, i = wasm_leb(sec, 1)
    for _ in 1:n
        prefix = Char(sec[i])
        len, i = wasm_leb(sec, i + 1)
        prefix == '+' && push!(feats, String(sec[i:i+len-1]))
        i += len
    end
    return feats
end

"Whether a wasm object has constructors: an `init_funcs` subsection (6) in its `linking` section."
function wasm_has_constructors(b::AbstractVector{UInt8})
    sec = get(wasm_custom_sections(b), "linking", UInt8[])
    isempty(sec) && return false
    _, i = wasm_leb(sec, 1)    # version
    while i <= length(sec)
        kind = sec[i]
        len, i = wasm_leb(sec, i + 1)
        kind == 0x06 && return true
        i += len
    end
    return false
end

"""
    audit_wasm(prefix, platform; io, verbose, silent) -> Bool

Checks the products of a wasm build: every `.a` member is a wasm object of the platform's
memory model (`memory64` exactly when `wasm64`), and shared libraries are flagged, since
wasm has no stable dynamic-linking ABI. Constructors are reported, since their order
against a host module's initialization is up to the final link.
"""
function audit_wasm(prefix::Prefix, platform::AbstractPlatform; io=stderr, verbose::Bool=false, silent::Bool=false)
    all_ok = true
    want64 = arch(platform) == "wasm64"
    for f in collect_files(prefix, f -> endswith(f, ".a") || endswith(f, ".so") || endswith(f, ".wasm"))
        rel = relpath(f, prefix.path)
        if endswith(f, ".so")
            !silent && @warn "$(rel): a wasm shared library; dylink.0 is not a stable ABI, ship a static archive" _module=nothing _file=nothing _line=nothing
            continue
        end
        endswith(f, ".a") || continue
        for (name, data) in ar_members(f)
            if length(data) < 8 || data[1:4] != WASM_MAGIC
                !silent && @error "$(rel)($(name)) is not a wasm object" _module=nothing _file=nothing _line=nothing
                all_ok = false
                continue
            end
            is64 = "memory64" in wasm_target_features(data)
            if is64 != want64
                kind = is64 ? "wasm64" : "wasm32"
                !silent && @error "$(rel)($(name)) is a $(kind) object, for $(triplet(platform))" _module=nothing _file=nothing _line=nothing
                all_ok = false
            end
            if wasm_has_constructors(data) && !silent
                @warn "$(rel)($(name)) has constructors" _module=nothing _file=nothing _line=nothing
            end
        end
        verbose && @info("Audited wasm archive $(rel)")
    end
    return all_ok
end
