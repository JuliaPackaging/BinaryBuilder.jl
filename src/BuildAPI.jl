export build!, extract!, package!

# This bash code sets up our shell sessions with the appropriate traps
# to do things like save environment variables and whatnot between
# sandbox invocations, so that we can "enter" a build as if we had
# never left.
const bash_trap_prologue = raw"""
# Stop if we hit any errors.
set -e

# If we're running as `bash`, then use the `DEBUG` and `ERR` traps
if [ $(basename $0) = "bash" ]; then
    trap "RET=\$?; \
            trap - DEBUG INT TERM ERR EXIT; \
            set +e +x; \
            auto_install_license; \
            save_env; \
            exit \$RET" \
        EXIT

    trap "RET=\$?; \
            trap - DEBUG INT TERM ERR EXIT; \
            set +e +x; \
            echo Previous command \$! exited with \$RET >&2; \
            save_env; \
            exit \$RET" \
        INT TERM ERR

    # Start saving everything into our history
    trap save_history DEBUG
else
    # If we're running in `sh` or something like that, we need a
    # slightly slimmer set of traps. :(
    trap "RET=\$?; \
            echo Previous command exited with \$RET >&2; \
            set +e +x; \
            save_env; \
            exit \$RET" \
        EXIT INT TERM
fi
"""

function build!(meta::BuildMeta,
                src_name::String,
                src_version::VersionNumber,
                sources::Vector{<:AbstractSource},
                script::String,
                platform::AbstractPlatform,
                dependencies::Vector{<:AbstractDependency};
                kwargs...)
    # First, construct a `BuildConfig` representing this build
    config = BuildConfig(
        src_name,
        src_version,
        sources,
        script,
        platform,
        dependencies;
        kwargs...
    )
    return build!(meta, config)
end


"""
    get_compilers_versions(compilers)

Return the script string that is used to print the versions of the given `compilers`.
"""
function get_compiler_versions(config::BuildConfig, ur; verbose::Bool = false)
    compiler_versions_script =
        """
        set -x
        """
    if :c in config.compilers
        compiler_versions_script *=
            """
            cc --version
            c++ --version
            gcc --version
            g++ --version
            clang --version
            clang++ --version
            objc --version
            f77 --version
            gfortran --version
            ld -v
            """
    end
    if :go in config.compilers
        compiler_versions_script *=
            """
            go version
            """
    end
    if :rust in config.compilers
        compiler_versions_script *=
            """
            rustc --version
            rustup --version
            cargo --version
            """
    end

    compiler_version_io = IOBuffer()
    run(ur,
        `/bin/bash -l -c $(compiler_versions_script)`,
        compiler_version_io;
        verbose,
        tee_stream = devnull,
    )
    return take!(compiler_version_io)
end

function build!(meta::BuildMeta,
                config::BuildConfig)
    meta.builds[config] = nothing

    # If a dry run is requested, we skip our build, but create a "skipped"
    # `BuildResult` object, which can be used in future `extract!()` steps.
    if :build in meta.dry_run
        meta.builds[config] = BuildResult_skipped(config)
        return config
    end

    # If we're actually building, then the first thing we do is set up the build environment on-disk
    build_path = joinpath(meta.build_dir, triplet(config.concrete_target))
    prefix = setup_workspace(
        build_path,
        config.sources,
        config.concrete_target;
        verbose=meta.verbose,
    )

    # Download and unpack dependencies into our prefix, first for our host tools,
    # and then for our target-specific dependencies.  This results in artifact
    # paths that have been symlinked into our build prefix, which we will un-link
    # in the future before finalizing the built artifact for _this_ build.
    host_artifact_paths = setup_dependencies(
        prefix,
        Pkg.Types.PackageSpec[getpkg(d) for d in config.dependencies if is_host_dependency(d)],
        default_host_platform;
        verbose=meta.verbose
    )
    target_artifact_paths = setup_dependencies(
        prefix,
        Pkg.Types.PackageSpec[getpkg(d) for d in config.dependencies if is_target_dependency(d)],
        config.concrete_target;
        verbose=meta.verbose
    )

    # Create a runner to work inside this workspace with the nonce built-in
    # TODO: convert this to use Sandbox.jl
    ur = preferred_runner()(
        prefix.path;
        cwd = "/workspace/srcdir",
        platform = config.concrete_target,
        verbose = meta.verbose,
        workspaces = [
            joinpath(prefix, "metadir") => "/meta",
        ],
        compiler_wrapper_path = joinpath(prefix, "compiler_wrappers"),
        src_name = config.src_name,
        shards = config.shards,
        allow_unsafe_flags = config.allow_unsafe_flags,
        lock_microarchitecture = config.lock_microarchitecture,
    )

    # This is where our target-specific code should end up
    dest_prefix = Prefix(BinaryBuilderBase.destdir(prefix.path, config.concrete_target))

    # This holds our logs, keyed by log source identifier
    logs = Dict{String,String}()
    
    # We're going to log our compiler versions, and we'll only store it into our `logs`.
    logs["compiler_versions"] = get_compiler_versions(config, ur; verbose=meta.verbose)

    # Set up some bash traps for proper cleanup and integration with our rootfs bash utilities
    trapper_wrapper = """
    $(bash_trap_prologue)

    $(config.script)
    """

    # Run the build script
    build_io = IOBuffer()
    build_successful = run(ur, `/bin/bash -l -c $(trapper_wrapper)`, build_io; verbose=meta.verbose)
    logs["build_output"] = take!(build_io)

    if !build_successful
        if meta.debug == "error"
            @warn("Build failed, launching debug shell")
            run_interactive(ur, `/bin/bash -l -i`)
        end
        msg = "Build for $(config.src_name) on $(triplet(config.platform)) did not complete successfully\n"
        error(msg)
    end

    ## Cleanup dependencies, we'll re-symlink them for auditing after extraction
    cleanup_dependencies(prefix, host_artifact_paths, default_host_platform)
    cleanup_dependencies(prefix, target_artifact_paths, concrete_platform)

    ## TODO: Add a "post-cleanup" phase to auditor and do this there
    # Yet another audit pass that needs to run after cleaning up dependencies
    Auditor.warn_deadlinks(dest_prefix.path)

    if :remove_empty_dirs ∉ config.audit_action_blocklist
        for (root, dirs, files) = walkdir(dest_prefix.path; topdown=false)
            # We do readdir() here because `walkdir()` does not do a true in-order traversal
            if isempty(readdir(root))
                rm(root)
            end
        end
    end

    # Construct BuildResult object that contains all the relevant metadata for this build.
    meta.builds[config] = BuildResult(
        config,
        build_successful ? :complete : :failed,
        dest_prefix,
        logs,
    )
    return config
end

function extract!(meta::BuildMeta,
                  build::BuildResult,
                  script::AbstractString,
                  products::Vector{Product},
                  audit_action_blocklist::Vector{Symbol} = Symbol[])
    return extract!(meta,
        ExtractConfig(build, script, products, audit_action_blocklist),
    )
end

function extract!(meta::BuildMeta,
                  config::ExtractConfig)
    # If a dry run is requested, we skip our extraction, but create a "skipped"
    # `ExtractResult` object, which can be used in future `package!()` steps.
    if :extract in meta.dry_run
        # Create `:skipped` ExtractResult
        meta.extractions[config] = ExtractResult_skipped(config)
        return meta.extractions[config]
    end

    trapper_wrapper = """
    $(bash_trap_prologue)

    $(config.script)
    """

    # This holds our logs, keyed by log source identifier
    logs = Dict{String,String}()

    # Create artifact to extract into, for packaging purposes
    create_artifact() do artifact_prefix
        # Create a runner to do the extraction.  We never mount any compilers,
        # users should do all compilation in the build step.
        ur = preferred_runner()(
            config.build.prefix;
            cwd = "/workspace/srcdir",
            # We'll still report ourselves as the proper platform, in case the extraction script
            # wants to know things like if it's extracting for darwin, etc...
            platform = config.concrete_target,
            verbose = meta.verbose,
            workspaces = [
                joinpath(config.build.prefix, "metadir") => "/meta",
                # I'm not super fond of this, since it kind of ties this outer function call in
                # with the internal details of where things are, as set up by `setup_workspace()`.
                # Once we move to using `Sandbox.jl` and `SandboxConfig` this will become much simpler.
                artifact_prefix => "/workspace/destdir",
            ],
            src_name = config.build.config.src_name,

            # No shards for you!
            shards = CompilerShard[],
        )

        extraction_io = IOBuffer()
        extraction_successful = run(ur, `/bin/bash -l -c $(trapper_wrapper)`, extraction_io; verbose=meta.verbose)
        logs["extraction-$(triplet(platform))"] = take!(extraction_io)

        if !extraction_successful
            if meta.debug == "error"
                @warn("Extraction failed, launching debug shell")
                run_interactive(ur, `/bin/bash -l -i`)
            end
            msg = "Extraction for $(jll_name) on $(triplet(config.platform)) did not complete successfully\n"
            error(msg)
        end

        # Run an audit of the prefix to ensure it is properly relocatable
        if :all ∉ config.audit_action_blocklist
            # Set up target-only dependencies with a symlink nest for auditing
            target_artifact_paths = setup_dependencies(
                config.build.prefix,
                Pkg.Types.PackageSpec[getpkg(d) for d in config.build.dependencies if is_target_dependency(d)],
                config.concrete_target;
                verbose=meta.verbose
            )

            ## TODO: change audit to actually fail builds, after we have a more
            ## flexible audit pass selection mechanism
            audit(config, config.build.prefix, logs; verbose=meta.verbose)

            cleanup_dependencies(config.build.prefix, target_artifact_paths, config.concrete_target)

            # if !audit_result && !ignore_audit_errors
            #     msg = replace("""
            #     Audit failed for $(dest_prefix.path).
            #     Address the errors above to ensure relocatability.
            #     To override this check, set `ignore_audit_errors = true`.
            #     """, '\n' => ' ')
            #     error(strip(msg))
            # end
        end
    end
    
    meta.extractions[config] = ExtractResult(config, :successful, artifact, logs)
    return config
end

function package!(meta::BuildMeta,
                  extractions::Vector{ExtractResult};
                  name::Union{Nothing,AbstractString} = nothing)
    return package!(
        meta,
        PackageConfig(extractions; name),
    )
end

"""
    get_latest_package_version(name::String; constraint::Function)

Return the latest-registered version of this package, subject to a constraint
that is applied to each VersionNumber found in the registry before considering it.
"""
function get_latest_package_version(name::String; constraint::Function = v -> true)
    ctx = Pkg.Types.Context()

    # Force-update the registry, in case we pushed a new version recently
    update_registry(ctx, devnull)

    # Look in the registry to see if there are any paths of this 
    pkg_paths = Pkg.Operations.registered_paths(ctx, jll_uuid(name))
    if any(isfile(joinpath(p, "Package.toml")) for p in pkg_paths)
        # Find largest version number that matches ours in the registered paths
        versions = VersionNumber[]
        for pkg_path in pkg_paths
            append!(versions,
                # Load in all versions defined in each file.
                # On error, returns an empty list
                RegistryTools.Compress.load_versions(
                    joinpath(pkg_path, "Versions.toml")
                )
            )
        end
        
        # If the user has some kind of constraint (e.g. "Find me the latest
        # version that is of the form 1.X.X") apply it here.
        filter!(constraint, versions)

        # Return the highest one!
        return maximum(versions)
    end

    # We know nothing about this package.
    return nothing
end

function package!(meta::BuildMeta, config::PackageConfig)
    # Get the latest (registered) version of this package:
    published_version = get_latest_package_version(config.name)
    published_version = 

    # If a dry run is requested, we skip our packaging, but create a "skipped"
    # `PackageResult` object, which can be used in static analysis.
    if :package in meta.dry_run
        # Create `:skipped` ExtractResult
        meta.packages[config] = PackageResult_skipped(config, published_version)
        return config
    end

    # Generate JLL package
    

    meta.packages[config] = PackageResult(
        config,
        :successful,
        published_version,
    )
    return config
end

function build_tarballs(ARGS, src_name, src_version, sources, script,
                        platforms, products, dependencies;
                        julia_compat::String = DEFAULT_JULIA_VERSION_SPEC,
                        compilers::Vector{Symbol} = [:c],
                        audit_action_blocklist::Vector{Symbol} = Symbol[],
                        kwargs...)
    meta = BuildMeta(ARGS)
    for platform in platforms
        # Build this config
        build_config = build!(meta, src_name, src_version, sources, script, platform, dependencies; compilers)
        build_result = meta.builds[build_config]

        # If this build was successful (or skipped), extract it!
        if build_result.status ∈ (:successful, :skipped)
            extraction_config = extract!(meta, build_result, "cp -a * \${prefix}", products, audit_action_blocklist)
            extraction_result = meta.extractions[extraction_config]

            if extraction_result.status == :successful
            end
        end
    end
    package_results = package!(meta, build_results, "cp -a * \${prefix}", products)
    return meta
end
