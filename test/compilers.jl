using BinaryBuilder, Test

@testset "Compiler dictionary creation" begin
    platforms = supported_platforms()

    pd = preferred_platform_compiler(platforms)

    # Make sure everything is nothing
    @test length(platforms) == length(pd)
    @test all(isnothing.(values(pd)))

    # Try the expanded platform list
    platforms = supported_platforms()
    platforms = expand_gfortran_versions(platforms)
    pd = preferred_platform_compiler(platforms)
    @test length(platforms) == length(pd)
    @test all(isnothing.(values(pd)))

    # Set everything to a version
    pd = preferred_platform_compiler(platforms, v"5")
    @test length(platforms) == length(pd)
    @test all(values(pd) .== v"5")

    # Assign some compiler values
    pd = preferred_platform_compiler(platforms, v"5")
    set_preferred_compiler_version!(pd, v"10", p ->Sys.islinux(p))
    set_preferred_compiler_version!(pd, v"6", p ->Sys.isfreebsd(p))
    set_preferred_compiler_version!(pd, v"12", [Platform("x86_64", "macos")])
    set_preferred_compiler_version!(pd, v"13", [Platform("aarch64", "macos")])

    @test pd[Platform("x86_64", "linux")] == v"10"
    @test pd[Platform("x86_64", "freebsd")] == v"6"
    @test pd[Platform("x86_64", "macos")] == v"12"
    @test pd[Platform("aarch64", "macos")] == v"13"
end
