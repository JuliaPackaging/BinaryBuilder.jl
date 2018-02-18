using Documenter, BinaryBuilder

makedocs(
    modules = [BinaryBuilder],
    format = :html,
    sitename = "BinaryBuilder.jl",
    pages = [
        "Home" => "index.md",
        "Environment Variables" => "environment_variables.md",
        "FAQ" => "FAQ.md",
        "Tricksy Gotchas" => "tricksy_gotchas.md",
        "Reference" => "reference.md",
    ],
)

deploydocs(
    deps = nothing,
    make = nothing,
    target = "build",
    repo = "github.com/JuliaPackaging/BinaryBuilder.jl.git",
    julia = "0.6",
)
