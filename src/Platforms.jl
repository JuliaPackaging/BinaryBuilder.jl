export AnyPlatform

# A platform that matches all platforms.  This is useful for building some
# platform-independent packages, like those containing only header files.
struct AnyPlatform <: Platform end
abi_agnostic(p::AnyPlatform) = p
Pkg.BinaryPlatforms.platform_name(::AnyPlatform) = "AnyPlatform"
Pkg.BinaryPlatforms.triplet(::AnyPlatform) = "any"
Base.show(io::IO, ::AnyPlatform) = print(io, "AnyPlatform()")
