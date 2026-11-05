using Test, BinaryBuilder, BinaryBuilderBase
using BinaryBuilder.Auditor: ar_members, wasm_target_features, wasm_has_constructors, audit_wasm

# WASM_ARCHIVES: a directory with wasm32/libpcre2-8.a and wasm64/libpcre2-8.a (e.g. from
# Yggdrasil's P/PCRE2_wasm); skipped without it.
@testset "WebAssembly audit" begin
    dir = get(ENV, "WASM_ARCHIVES", "")
    if isempty(dir) || !haskey(Base.BinaryPlatforms.arch_mapping, "wasm32")
        @test_skip "no wasm archives, or no wasm in Base.BinaryPlatforms"
    else
        a32 = joinpath(dir, "wasm32", "libpcre2-8.a")
        a64 = joinpath(dir, "wasm64", "libpcre2-8.a")
        m32, m64 = ar_members(a32), ar_members(a64)
        @test length(m32) == length(m64) > 20
        @test all(((_, d),) -> d[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d], m32)
        @test !any(((_, d),) -> "memory64" in wasm_target_features(d), m32)
        @test all(((_, d),) -> "memory64" in wasm_target_features(d), m64)
        @test !any(((_, d),) -> wasm_has_constructors(d), m64)

        p32 = Platform("wasm32", "wasi"; os_version = v"1")
        p64 = Platform("wasm64", "wasi")
        prefix(a) = (d = mktempdir(); mkpath(joinpath(d, "lib")); cp(a, joinpath(d, "lib", "libpcre2-8.a")); Prefix(d))
        @test audit_wasm(prefix(a32), p32; silent = true)
        @test audit_wasm(prefix(a64), p64; silent = true)
        # an archive of the other memory model is refused
        @test !audit_wasm(prefix(a32), p64; silent = true)
        @test !audit_wasm(prefix(a64), p32; silent = true)
        # and so is a member that isn't wasm
        d = mktempdir(); mkpath(joinpath(d, "lib"))
        write(joinpath(d, "lib", "libx.a"), "!<arch>\n" * rpad("x.o/", 16) * rpad("0", 12) * rpad("0", 6) * rpad("0", 6) * rpad("644", 8) * rpad("4", 10) * "`\n" * "\x7fELF")
        @test !audit_wasm(Prefix(d), p32; silent = true)
    end
end
