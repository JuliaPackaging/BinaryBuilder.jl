using Documenter, BinaryBuilder

makedocs(
    modules = [BinaryBuilder],
    format = :html,
    sitename = "BinaryBuilder.jl",
    pages = [
        "Home" => "index.md",
        "Building Packages" => "build_tips.md",
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
    deps = nothing,
    make = nothing,
    target = "build",
    repo = "github.com/JuliaPackaging/BinaryBuilder.jl.git",
    julia = "0.6",
)
