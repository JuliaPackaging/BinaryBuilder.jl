## This is until we have a good replacement for `info(io, msg)` on 0.7+
function info(io::IO, args...)
    if io != stdout
        printstyled(io, "Info: "; color=Base.info_color())
        printstyled(io, args...; color=Base.info_color())
        println(io)
    else
        @info(args)
    end
end
function warn(io::IO, args...)
    if io != stdout
        printstyled(io, "Warning: "; color=Base.warn_color())
        printstyled(io, args...; color=Base.warn_color())
        println(io)
    else
        @warn(args)
    end
end

function extract_kwargs(kwargs, keys)
    return (k => v for (k, v) in kwargs if k in keys)
end
