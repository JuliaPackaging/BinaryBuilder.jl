export AnyPlatform

"""
    AnyPlatform()

A special platform to be used to build platform-independent tarballs, like those
containing only header files.  [`FileProduct`](@ref) is the only product type
allowed with this platform.
"""
struct AnyPlatform <: Platform end
abi_agnostic(p::AnyPlatform) = p
Pkg.BinaryPlatforms.platform_name(::AnyPlatform) = "AnyPlatform"
Pkg.BinaryPlatforms.triplet(::AnyPlatform) = "any"
# Fallback on x86_64-linux-musl, but this shouldn't really matter in practice.
Pkg.BinaryPlatforms.arch(::AnyPlatform) = arch(Linux(:x86_64, libc=:musl))
Base.show(io::IO, ::AnyPlatform) = print(io, "AnyPlatform()")
