using Documenter, BinaryBuilder

makedocs(
    format = :html,
    sitename = "BinaryBuilder.jl",
    pages = [
        "Home" => "index.md",
        "Environment Variables" => "environment_variables.md",
        "FAQ" => "FAQ.md",
        "Tricksy Gotchas" => "tricksy_gotchas.md",
    ],
)

deploydocs(
    repo = "github.com/JuliaPackaging/BinaryBuilder.jl.git",
)
