using JSON, BinaryBuilder, Test

import BinaryBuilder: sourcify

@testset "Meta JSON" begin
    mktempdir() do tmpdir
        meta_json_buff = IOBuffer() 
        # Run autobuild() a few times to generate a moderately complex `meta.json`:
        build_output_meta = autobuild(
            tmpdir,
            "libfoo",
            v"1.0.0",
            [FileSource("https://julialang.org", "123123"), DirectorySource("./bundled")],
            "exit 1",
            [Linux(:x86_64)],
            Product[LibraryProduct("libfoo", :libfoo)],
            [Dependency("Zlib_jll")];
            meta_json_stream=meta_json_buff,
        )
        @test build_output_meta == Dict()

        build_output_meta = autobuild(
            tmpdir,
            "libfoo",
            v"1.0.0",
            [GitSource("https://github.com/JuliaLang/julia.git", "5d4eaca0c9fa3d555c79dbacdccb9169fdf64b65")],
            "exit 0",
            [Linux(:x86_64), Windows(:x86_64)],
            Product[ExecutableProduct("julia", :julia)],
            Dependency[];
            meta_json_stream=meta_json_buff,
        )
        @test build_output_meta == Dict()

        # Now, deserialize the info:
        seek(meta_json_buff, 0)

        # Strip out ending newlines as that makes our while loop below sad
        meta_json_buff = IOBuffer(strip(String(take!(meta_json_buff))))
        objs = []
        while !eof(meta_json_buff)
            push!(objs, JSON.parse(meta_json_buff))
        end

        # Ensure that we get two JSON objects
        @test length(objs) == 2

        # Merge them, then test that the merged object contains everything we expect
        meta = BinaryBuilder.cleanup_merged_object!(BinaryBuilder.merge_json_objects(objs))

        @test all(haskey.(Ref(meta), ("name", "version", "script", "platforms", "products", "dependencies")))
        @test meta["name"] == "libfoo"
        @test meta["version"] == v"1.0.0"
        @test length(meta["sources"]) == 3
        @test all(in.(
              (
                  Dict("url" => "https://julialang.org",
                       "hash" => "123123",
                       "unpack_target" => "",
                       "type" => "file"),
                  Dict("url" => "https://github.com/JuliaLang/julia.git",
                       "hash" => "5d4eaca0c9fa3d555c79dbacdccb9169fdf64b65",
                       "unpack_target" => "",
                       "type" => "git"),
                  Dict("path" => "./bundled",
                       "unpack_target" => "",
                       "type" => "directory"),
              ), Ref(meta["sources"])))
        @test sourcify(Dict("type" => "directory", "path" => "foo")) == DirectorySource("foo")
        @test sourcify(Dict("type" => "git", "url" => "https://github.com/JuliaLang/julia.git", "hash" => "12345")) == GitSource("https://github.com/JuliaLang/julia.git", "12345")
        @test sourcify(Dict("type" => "file", "url" => "https://julialang.org", "hash" => "98765")) == FileSource("https://julialang.org", "98765")
        @test_throws ErrorException sourcify(Dict("type" => "qux"))
        @test length(meta["products"]) == 2
        @test all(in.((LibraryProduct("libfoo", :libfoo), ExecutableProduct("julia", :julia)), Ref(meta["products"])))
        @test length(meta["script"]) == 2
        @test all(in.(("exit 0", "exit 1"), Ref(meta["script"])))
    end
end
