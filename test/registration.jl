using BinaryBuilder, Test, Pkg, SHA, TOML, Tar, Logging
using BinaryBuilder.BinaryBuilderBase

@testset "Batch JLL reconstruction" begin
    mktempdir() do dir
        store, sidecars, code = [mkpath(joinpath(dir, x)) for x in ("store", "meta", "code")]
        platforms = [Platform("x86_64", "linux"; cuda="$(i).0") for i in 1:4]
        objs, filenames = Dict[], String[]
        hashes = Dict{String,String}()
        for (i, platform) in enumerate(platforms)
            source = mkpath(joinpath(dir, "source$(i)", "share"))
            write(joinpath(source, "value$(i)"), "payload $(i)")
            tree = Base.SHA1(Pkg.GitTools.tree_hash(dirname(source)))
            tar = joinpath(dir, "source$(i).tar")
            Tar.create(dirname(source), tar)
            filename = "Batch.v1.0.0.$(triplet(platform)).tar.gz"
            archive = joinpath(store, filename)
            run(pipeline(`$(BinaryBuilderBase.Gzip_jll.gzip()) -c $tar`; stdout=archive))
            hash = open(io -> bytes2hex(sha256(io)), archive)
            product = FileProduct("share/value$(i)", Symbol("value$(i)"))
            info = Dict{Product,Any}(product => Dict("path" => "share/value$(i)"))
            BinaryBuilder.write_build_meta(joinpath(sidecars, filename), hash, tree, info)
            push!(filenames, filename)
            hashes[filename] = hash
            push!(objs, Dict("name" => "Batch", "version" => v"1.0.0", "sources" => [],
                             "platforms" => [platform], "products" => [product],
                             "dependencies" => [Dependency(Pkg.PackageSpec(name="Dep$(i)_jll", uuid=Base.UUID(UInt128(i))))],
                             "julia_compat" => "1.10",
                             "lazy_artifacts" => true, "init_block" => "# init $(i)"))
        end
        old_prefix = "https://example.org/Batch-v1.0.0+0"
        new_prefix = "https://example.org/Batch-v1.0.0+1"
        version = v"1.0.0+1"

        # Compare all generated files with the established sequential implementation.
        baseline = mkpath(joinpath(dir, "baseline"))
        for (i, obj) in enumerate(objs)
            BinaryBuilder.rebuild_jll_package("Batch", version, obj["sources"], obj["platforms"],
                obj["products"], obj["dependencies"], store, old_prefix;
                code_dir=baseline, build_meta_dir=sidecars, from_scratch=(i == 1),
                julia_compat="1.10", lazy_artifacts=true, init_block=obj["init_block"])
        end
        tree_files(path) = Dict(relpath(joinpath(root, f), path) => read(joinpath(root, f))
                               for (root, _, files) in walkdir(path) for f in files)
        uploaded = BinaryBuilder.rebuild_jll_package(objs; download_dir=store,
            build_meta_dir=sidecars, code_dir=code, build_version=version, upload_prefix=old_prefix)
        @test uploaded == filenames
        @test tree_files(code) == tree_files(baseline)
        for (i, platform) in enumerate(platforms)
            wrapper = read(joinpath(code, "src", "wrappers", "$(triplet(platform)).jl"), String)
            @test occursin("# init $(i)", wrapper)
            @test occursin("export value$(i)", wrapper)
            @test occursin("using Dep$(i)_jll", wrapper)
        end

        # Cold downloads from separate metadata objects share a single concurrency cap.
        cold = mkpath(joinpath(dir, "cold"))
        active, peak = Ref(0), Ref(0)
        guard = ReentrantLock()
        function fetch_tarball(filename, destination)
            lock(guard) do
                active[] += 1
                peak[] = max(peak[], active[])
            end
            try
                sleep(0.05)
                cp(joinpath(store, filename), destination)
            finally
                lock(guard) do
                    active[] -= 1
                end
            end
        end
        withenv("BINARYBUILDER_REBUILD_CONCURRENCY" => "2") do
            result = BinaryBuilder.rebuild_jll_package(objs; download_dir=cold,
                build_meta_dir=sidecars, code_dir=code, build_version=version,
                upload_prefix=old_prefix, artifact_hashes=hashes, fetch_tarball,
                reuse_artifacts=false)
            @test result == filenames
        end
        @test peak[] == 2
        @test active[] == 0
        @test tree_files(code) == tree_files(baseline)

        # Two reusable assets, one recompressed archive, and one changed tree.
        previous = TOML.parsefile(joinpath(code, "Artifacts.toml"))
        entries = Dict(entry["cuda"] => entry for entry in previous["Batch"])
        mirror = Dict("url" => "https://mirror.example.org/asset.tar.gz", "sha256" => hashes[filenames[1]])
        push!(entries["1.0"]["download"], mirror)
        entries["3.0"]["download"][1]["sha256"] = repeat("0", 64)
        entries["4.0"]["git-tree-sha1"] = repeat("0", 40)
        open(joinpath(code, "Artifacts.toml"), "w") do io
            TOML.print(io, previous)
        end
        incremental = mkpath(joinpath(dir, "incremental"))
        result = BinaryBuilder.rebuild_jll_package(objs; download_dir=incremental,
            build_meta_dir=sidecars, code_dir=code, build_version=version,
            upload_prefix=new_prefix, artifact_hashes=hashes, fetch_tarball)
        @test result == filenames[3:4]
        @test sort(readdir(incremental)) == sort(filenames[3:4])
        entries = Dict(entry["cuda"] => entry for entry in TOML.parsefile(joinpath(code, "Artifacts.toml"))["Batch"])
        @test entries["1.0"]["download"] == previous["Batch"][findfirst(e -> e["cuda"] == "1.0", previous["Batch"])]["download"]
        @test entries["2.0"]["download"][1]["url"] == "$(old_prefix)/$(filenames[2])"
        @test entries["3.0"]["download"][1]["url"] == "$(new_prefix)/$(filenames[3])"
        @test entries["4.0"]["download"][1]["url"] == "$(new_prefix)/$(filenames[4])"
        @test all(e["lazy"] for e in values(entries))

        # A missing sidecar falls back to download and inspection, even for an old asset.
        rm(BinaryBuilder.build_meta_path(joinpath(sidecars, filenames[1])))
        fallback_dir = mkpath(joinpath(dir, "fallback"))
        result = BinaryBuilder.rebuild_jll_package(objs; download_dir=fallback_dir,
            build_meta_dir=sidecars, code_dir=code, build_version=version,
            upload_prefix=new_prefix, artifact_hashes=hashes, fetch_tarball)
        @test isempty(result) # inspection still discovers that the old asset is reusable
        @test readdir(fallback_dir) == filenames[1:1]

        # An unsupported sidecar version cannot authorize reuse either.
        sidecar2 = BinaryBuilder.build_meta_path(joinpath(sidecars, filenames[2]))
        metadata = BinaryBuilder.JSON.parsefile(sidecar2)
        metadata["version"] += 1
        write(sidecar2, BinaryBuilder.JSON.json(metadata))
        invalid_dir = mkpath(joinpath(dir, "invalid-meta"))
        @test_logs (:warn, r"is version") BinaryBuilder.rebuild_jll_package(objs;
            download_dir=invalid_dir, build_meta_dir=sidecars, code_dir=code,
            build_version=version, upload_prefix=new_prefix, artifact_hashes=hashes, fetch_tarball)
        @test sort(readdir(invalid_dir)) == sort(filenames[1:2])
        metadata["version"] -= 1
        write(sidecar2, BinaryBuilder.JSON.json(metadata))

        # The artifact-store checksum must match downloaded bytes. A failure must not
        # clear old wrappers or artifact bindings, and must release concurrency permits.
        saved = tree_files(code)
        broken = mkpath(joinpath(dir, "broken"))
        @test_throws CompositeException BinaryBuilder.rebuild_jll_package(objs;
            download_dir=broken, build_meta_dir=sidecars, code_dir=code,
            build_version=version, upload_prefix=new_prefix, artifact_hashes=hashes,
            fetch_tarball=(filename, destination) -> write(destination, "corrupted"),
            reuse_artifacts=false)
        @test tree_files(code) == saved

        # Sidecars alone cannot authorize reuse of a missing tarball.
        @test_throws ErrorException BinaryBuilder.rebuild_jll_package(objs;
            download_dir=mkpath(joinpath(dir, "untrusted")), build_meta_dir=sidecars,
            code_dir=code, build_version=version, upload_prefix=new_prefix)
        @test tree_files(code) == saved
        mixed = [objs[1], merge(objs[1], Dict("platforms" => [AnyPlatform()]))]
        @test_throws ArgumentError BinaryBuilder.rebuild_jll_package(mixed;
            download_dir=store, code_dir=code, build_version=version, upload_prefix=new_prefix)
        @test tree_files(code) == saved
        @test_throws ArgumentError BinaryBuilder.rebuild_jll_package([objs; objs[1:1]];
            download_dir=store, code_dir=code, build_version=version, upload_prefix=new_prefix)
        @test_throws ArgumentError BinaryBuilder.rebuild_jll_package(objs;
            download_dir=store, code_dir=code, build_version=version, upload_prefix=new_prefix,
            artifact_hashes=Dict("../$(filenames[1])" => hashes[filenames[1]]))
        # A legacy macOS filename can match both forms of the same platform; reject
        # the batch before two download callbacks can write the same destination.
        aliases = [merge(objs[1], Dict("platforms" => [p])) for p in
                   (Platform("aarch64", "macos"), parse(Platform, "aarch64-apple-darwin14"))]
        @test_throws ArgumentError BinaryBuilder.rebuild_jll_package(aliases;
            download_dir=store, code_dir=code, build_version=version, upload_prefix=new_prefix,
            artifact_hashes=Dict("Batch.v1.0.0.aarch64-apple-darwin14.tar.gz" => hashes[filenames[1]]),
            fetch_tarball=(args...) -> error("Must fail before downloading"))
    end
end

@testset "Reuse platform-independent artifacts" begin
    mktempdir() do dir
        store, code, cold = [mkpath(joinpath(dir, x)) for x in ("store", "code", "cold")]
        filename = "Data.v1.0.0.any.tar.gz"
        archive = joinpath(store, filename)
        write(archive, "bytes need not be unpacked with valid build metadata")
        hash = open(io -> bytes2hex(sha256(io)), archive)
        tree = Base.SHA1(repeat("1", 40))
        BinaryBuilder.write_build_meta(archive, hash, tree, Dict{Product,Any}())
        obj = Dict("name" => "Data", "version" => v"1.0.0", "sources" => [],
                   "platforms" => [AnyPlatform()], "products" => Product[],
                   "dependencies" => Dependency[])
        prefix = "https://example.org/old"
        BinaryBuilder.rebuild_jll_package([obj]; download_dir=store, code_dir=code,
            build_version=v"1.0.0+0", upload_prefix=prefix)
        original = TOML.parsefile(joinpath(code, "Artifacts.toml"))
        @test original["Data"] isa Dict
        uploads = BinaryBuilder.rebuild_jll_package([obj]; download_dir=cold,
            build_meta_dir=store, code_dir=code, build_version=v"1.0.0+1",
            upload_prefix="https://example.org/new", artifact_hashes=Dict(filename => hash),
            fetch_tarball=(args...) -> error("Reused asset must not be fetched"))
        @test isempty(uploads)
        @test isempty(readdir(cold))
        @test TOML.parsefile(joinpath(code, "Artifacts.toml")) == original
        @test TOML.parsefile(joinpath(code, "Project.toml"))["version"] == "1.0.0+1"
    end
end
