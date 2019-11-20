function extract_kwargs(kwargs, keys)
    return (k => v for (k, v) in kwargs if k in keys)
end
