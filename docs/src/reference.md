# API reference

## Types
```@autodocs
Modules = [BinaryBuilderBase, BinaryBuilder, BinaryBuilder.Auditor, BinaryBuilder.Wizard]
Order = [:type]
```

## Functions
```@autodocs
Modules = [BinaryBuilderBase, BinaryBuilder, BinaryBuilder.Auditor, BinaryBuilder.Wizard]
Order = [:function]
# We'll include build_tarballs explicitly below, so let's exclude it here:
Filter = x -> !(isa(x, Function) && x === build_tarballs)
```

## Command Line
```@docs
build_tarballs
```

The [`build_tarballs`](@ref) function also parses command line arguments. The syntax is
described in the `--help` output:

````@eval
using BinaryBuilder, Markdown
Markdown.parse("""
```
$(BinaryBuilder.BUILD_HELP)
```
""")
````
