using JSON, BinaryBuilder, Test

import BinaryBuilder.BinaryBuilderBase: sourcify

@testset "Meta JSON" begin
    meta_json_buff = IOBuffer()

    # Run autobuild() a few times to generate a moderately complex `meta.json`:
    dict = get_meta_json(
        "libfoo",
        v"1.0.0",
        [FileSource("https://julialang.org", "123123"), DirectorySource("./bundled")],
        "exit 1",
        [Platform("x86_64", "linux")],
        Product[LibraryProduct("libfoo", :libfoo), FrameworkProduct("fooFramework", :libfooFramework)],
        [Dependency("Zlib_jll")];
    )
    println(meta_json_buff, JSON.json(dict))

    dict = get_meta_json(
        "libfoo",
        v"1.0.0",
        [GitSource("https://github.com/JuliaLang/julia.git", "5d4eaca0c9fa3d555c79dbacdccb9169fdf64b65")],
        "exit 0",
        [Platform("x86_64", "linux"), Platform("x86_64", "windows")],
        Product[ExecutableProduct("julia", :julia), LibraryProduct("libfoo2", :libfoo2; dlopen_flags=[:RTLD_GLOBAL])],
        Dependency[];
    )
    println(meta_json_buff, JSON.json(dict))

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
    @test length(meta["platforms"]) == 2
    @test Platform("x86_64", "linux"; libc="glibc") ∈ meta["platforms"]
    @test Platform("x86_64", "windows") ∈ meta["platforms"]
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

    @test length(meta["products"]) == 4
    @test all(in.((LibraryProduct("libfoo", :libfoo), ExecutableProduct("julia", :julia), LibraryProduct("libfoo2", :libfoo2; dlopen_flags=[:RTLD_GLOBAL]), FrameworkProduct("fooFramework", :libfooFramework)), Ref(meta["products"])))
    @test length(meta["script"]) == 2
    @test all(in.(("exit 0", "exit 1"), Ref(meta["script"])))

    @testset "AnyPlatform" begin
        meta_json_buff = IOBuffer()
        dict = get_meta_json(
            "any_file",
            v"1.0.0",
            FileSource[],
            "exit 1",
            [AnyPlatform()],
            Product[FileProduct("file", :file)],
            BuildDependency[];
        )
        println(meta_json_buff, JSON.json(dict))

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
