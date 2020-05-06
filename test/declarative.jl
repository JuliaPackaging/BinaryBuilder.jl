using JSON, BinaryBuilder, Test

import BinaryBuilder: sourcify, dependencify, major, minor, patch, version

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
            Product[LibraryProduct("libfoo", :libfoo), FrameworkProduct("fooFramework", :libfooFramework)],
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
            Product[ExecutableProduct("julia", :julia), LibraryProduct("libfoo2", :libfoo2; dlopen_flags=[:RTLD_GLOBAL])],
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
        @test Set(meta["platforms"]) == Set([Linux(:x86_64, libc=:glibc), Windows(:x86_64)])
        @test length(meta["sources"]) == 3
        @test all(in.(
              (
                  FileSource("https://julialang.org", "123123"),
                  GitSource("https://github.com/JuliaLang/julia.git", "5d4eaca0c9fa3d555c79dbacdccb9169fdf64b65"),
                  DirectorySource("./bundled"),
              ), Ref(meta["sources"])))
        @test sourcify(Dict("type" => "directory", "path" => "foo")) == DirectorySource("foo")
        @test sourcify(Dict("type" => "git", "url" => "https://github.com/JuliaLang/julia.git", "hash" => "12345")) == GitSource("https://github.com/JuliaLang/julia.git", "12345")
        @test sourcify(Dict("type" => "file", "url" => "https://julialang.org", "hash" => "98765")) == FileSource("https://julialang.org", "98765")
        @test_throws ErrorException sourcify(Dict("type" => "qux"))
        # `PackageSpec(; name = "Foo") != PackageSpec(; name = "Foo")`, so we
        # need to manually compare the fields we care about
        d = dependencify(Dict("type" => "dependency", "name" => "Foo_jll", "uuid" => nothing,
                              "version-major" => 0, "version-minor" => 0, "version-patch" => 0))
        ref_d = Dependency(PackageSpec(; name = "Foo_jll"))
        @test d.pkg.name == ref_d.pkg.name
        @test d.pkg.uuid == ref_d.pkg.uuid
        v = version(d)
        ref_v = version(ref_d)
        @test (major(v), minor(v), patch(v)) == (major(ref_v), minor(ref_v), patch(ref_v))
        d = dependencify(Dict("type" => "builddependency", "name" => "Qux_jll", "uuid" => nothing,
                              "version-major" => 1, "version-minor" => 2, "version-patch" => 3))
        ref_d = Dependency(PackageSpec(; name = "Qux_jll", version = v"1.2.3"))
        @test d.pkg.name == ref_d.pkg.name
        @test d.pkg.uuid == ref_d.pkg.uuid
        v = version(d)
        ref_v = version(ref_d)
        @test (major(v), minor(v), patch(v)) == (major(ref_v), minor(ref_v), patch(ref_v))
        @test_throws ErrorException dependencify(Dict("type" => "bar"))
        @test length(meta["products"]) == 4
        @test all(in.((LibraryProduct("libfoo", :libfoo), ExecutableProduct("julia", :julia), LibraryProduct("libfoo2", :libfoo2; dlopen_flags=[:RTLD_GLOBAL]), FrameworkProduct("fooFramework", :libfooFramework)), Ref(meta["products"])))
        @test length(meta["script"]) == 2
        @test all(in.(("exit 0", "exit 1"), Ref(meta["script"])))
    end

    @testset "AnyPlatform" begin
        mktempdir() do tmpdir
            meta_json_buff = IOBuffer()
            build_output_meta = autobuild(
                tmpdir,
                "any_file",
                v"1.0.0",
                FileSource[],
                "exit 1",
                [AnyPlatform()],
                Product[FileProduct("file", :file)],
                BuildDependency[];
                meta_json_stream=meta_json_buff,
            )
            @test build_output_meta == Dict()
            # Deserialize the info:
            seekstart(meta_json_buff)
            # Strip out ending newlines as that makes our while loop below sad
            meta_json_buff = IOBuffer(strip(String(take!(meta_json_buff))))
            objs = []
            while !eof(meta_json_buff)
                push!(objs, JSON.parse(meta_json_buff))
            end
            # Ensure that we get one JSON object
            @test length(objs) == 1
            # Platform-independent build: the JSON file doesn't have a "platforms" key
            @test !haskey(objs[1], "platforms")
            # Merge them, then test that the merged object contains everything we expect
            meta = BinaryBuilder.cleanup_merged_object!(BinaryBuilder.merge_json_objects(objs))
            # The "platforms" key comes back in the cleaned up object
            @test meta["platforms"] == [AnyPlatform()]
        end
    end
end
