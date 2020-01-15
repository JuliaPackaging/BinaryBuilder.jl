function extract_kwargs(kwargs, keys)
    return (k => v for (k, v) in pairs(kwargs) if k in keys)
end
