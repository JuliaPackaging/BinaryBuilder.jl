using Documenter, BinaryBuilder

makedocs(
    modules = [BinaryBuilder],
    sitename = "BinaryBuilder.jl",
    pages = [
        "Home" => "index.md",
        "Building Packages" => "build_tips.md",
        "JLL packages" => "jll.md",
        "FAQ" => "FAQ.md",
        "Internals" => [
            "RootFS" => "rootfs.md",
            "Environment Variables" => "environment_variables.md",
            "Tricksy Gotchas" => "tricksy_gotchas.md",
            "Reference" => "reference.md",
        ],
    ],
)

deploydocs(
    repo = "github.com/JuliaPackaging/BinaryBuilder.jl.git",
)
