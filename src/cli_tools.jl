function check_flag!(ARGS, flag)
    flag_present = flag in ARGS
    filter!(x -> x != flag, ARGS)
    return flag_present
end

function extract_flag!(ARGS, flag, val = nothing)
    for f in ARGS
        if f == flag || startswith(f, string(flag, "="))
            # Check if it's just `--flag` or if it's `--flag=foo`
            if f != flag
                val = split(f, '=')[2]
            end

            # Drop this value from our ARGS
            filter!(x -> x != f, ARGS)
            return (true, val)
        end
    end
    return (false, val)
end
