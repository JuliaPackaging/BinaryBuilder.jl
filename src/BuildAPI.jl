export build!, package!

function build!(meta::BuildMeta,
                src_name::String,
                src_version::VersionNumber,
                sources::Vector{<:AbstractSource},
                script::String,
                platform::AbstractPlatform,
                dependencies::Vector{<:Dependency};
                kwargs...)
    # First, construct a `BuildConfig` representing this build
    config = BuildConfig(
        src_name,
        src_version,
        sources,
        dependencies,
        script,
        platform;
        kwargs...
    )
    push!(meta.builds, config)

    # If a dry run is requested, we skip all our builds
    if meta.dry_run[:build]
        return
    end

    # If we're actually building, then the first thing we do is set up the build environment on-disk
    build_path = joinpath(dir, "build", triplet(config.concrete_target))
    mkpath(build_path)

    prefix = setup_workspace(
        build_path,
        config.sources,
        config.concrete_target;
        verbose=meta.verbose,
    )

    # Download and unpack dependences into our prefix, first for our host tools,
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
        compiler_wrapper_dir = joinpath(prefix, "compiler_wrappers"),
        src_name = config.src_name,
        shards = config.shards,
        allow_unsafe_flags = config.allow_unsafe_flags,
        lock_microarchitecture = config.lock_microarchitecture,
    )

    # This is where our target-specific code should end up
    dest_prefix = Prefix(BinaryBuilderBase.destdir(prefix.path, config.concrete_target))

    # 
    logs = Dict{String,String}()
    
    # ...because we want to log all their versions.  However, we don't
    # want this to be shown in the console, so we first run this without
    # teeing to stdout
    compiler_version_io = IOBuffer()
    run(ur, `/bin/bash -l -c $(get_compilers_versions(config.compilers))`, compiler_version_io;
        verbose = meta.verbose, tee_stream = devnull)
    logs["compiler_versions"] =  take!(compiler_version_io)


    # Set up some bash traps for proper cleanup and integration with our rootfs bash utilities
    trapper_wrapper = """
    # Stop if we hit any errors.
    set -e

    # If we're running as `bash`, then use the `DEBUG` and `ERR` traps
    if [ \$(basename \$0) = "bash" ]; then
        trap "RET=\\\$?; \\
              trap - DEBUG INT TERM ERR EXIT; \\
              set +e +x; \\
              auto_install_license; \\
              save_env; \\
              exit \\\$RET" \\
            EXIT

        trap "RET=\\\$?; \\
              trap - DEBUG INT TERM ERR EXIT; \\
              set +e +x; \\
              echo Previous command \\\$! exited with \\\$RET >&2; \\
              save_env; \\
              exit \\\$RET" \\
            INT TERM ERR

        # Start saving everything into our history
        trap save_history DEBUG
    else
        # If we're running in `sh` or something like that, we need a
        # slightly slimmer set of traps. :(
        trap "RET=\\\$?; \\
              echo Previous command exited with \\\$RET >&2; \\
              set +e +x; \\
              save_env; \\
              exit \\\$RET" \\
            EXIT INT TERM
    fi

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

    # Run an audit of the prefix to ensure it is properly relocatable
    if :all ∉ config.audit_action_blocklist
        audit(config, dest_prefix, logs; verbose=meta.verbose)
        ## TODO: change audit to actually fail builds, after we have a more
        ## flexible audit pass selection mechanism

        # if !audit_result && !ignore_audit_errors
        #     msg = replace("""
        #     Audit failed for $(dest_prefix.path).
        #     Address the errors above to ensure relocatability.
        #     To override this check, set `ignore_audit_errors = true`.
        #     """, '\n' => ' ')
        #     error(strip(msg))
        # end
    end

    ## At this point, we consider the destination prefix to be more or less complete
    ## So let's clean things out in expectation of packaging
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
    build_result = BuildResult(
        config,
        build_successful ? :complete : :failed,
        dest_prefix,
        logs,
    )

    return build_result
end

function package!(meta::BuildMeta,
                  builds::Vector{BuildResult},
                  jll_name::String,
                  script::String,
                  products::Vector{<:Product})
    # If a dry run is requested, we skip all our packagings
    if meta.dry_run[:package]
        return
    end


    ## Before returning the package result, check to amek sure that the generated JLL is actually loadable.
    # This is instead of the "satisfied/non-satisfied" check at build time, and ensures that the packaged
    # JLLs are (a) complete, (b) loadable on the native machine, and (c) valid, considering we will allow
    # some level of JLL customization (RTLD flags, init blocks, etc...)
    return package_results
end

function build_tarballs(ARGS, src_name, src_version, sources, script,
                        platforms, products, dependencies;
                        julia_compat::String = DEFAULT_JULIA_VERSION_SPEC,
                        compilers::Vector{Symbol} = [:c],
                        kwargs...)
    meta = BuildMeta(ARGS)
    build_results = BuildResult[]
    for platform in platforms
        push!(build_results, build!(meta, src_name, src_version, sources, script, platform, dependencies; compilers))
    end
    package_results = package!(meta, build_results, "cp -a * \${prefix}", products)
    return meta
end
