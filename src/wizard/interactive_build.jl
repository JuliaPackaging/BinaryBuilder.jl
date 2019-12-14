include("hints.jl")

"""
    step4(state::WizardState, ur::Runner, platform::Platform,
          build_path::AbstractString, prefix::Prefix)

The fourth step selects build products after the first build is done
"""
function step4(state::WizardState, ur::Runner, platform::Platform,
               build_path::AbstractString, prefix::Prefix)
    printstyled(state.outs, "\t\t\t# Step 4: Select build products\n\n", bold=true)

    # Collect all executable/library files, explicitly exclude everything that is
    # a symlink to the artifacts directory, as usual.
    destdir = joinpath(prefix, "destdir")
    files = filter(f -> startswith(f, destdir), collapse_symlinks(collect_files(destdir)))
    files = filter_object_files(files)

    # Check if we can load them as an object file
    files = filter(files) do f
        readmeta(f) do oh
            return is_for_platform(oh, platform)
        end
    end

    # Strip out the prefix from filenames
    state.files = map(file->replace(file, "$(destdir)/" => ""), files)
    state.file_kinds = map(files) do f
        readmeta(f) do oh
            if isexecutable(oh)
                return :executable
            elseif islibrary(oh)
                return :library
            else
                return :other
            end
        end
    end

    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)

    if length(files) == 0
        printstyled(state.outs, "ERROR: ", color=:red)
        println(state.outs, "The build has produced no binary artifacts.")
        println(state.outs, " "^7, "This is generally because an error occured during the build")
        println(state.outs, " "^7, "or because you forgot to `make install` or equivalent.")
        println(state.outs)

        choice = request(terminal, "How would you like to proceed? (CTRL-C to exit)",
            RadioMenu([
                "Return to build environment",
                "Retry with a clean build environment",
                "Edit the script"
            ]))
        println(state.outs)

        if choice == 1
            # Link dependencies into the prefix again
            artifact_paths = setup_dependencies(prefix, state.dependencies, platform)
            return step3_interactive(state, prefix, platform, ur, build_path, artifact_paths)
        elseif choice == 2
            state.step = :step3
            return
        elseif choice == 3
            state.history = edit_script(state, state.history)
            state.step = :step3_retry
            return
        end
    elseif length(files) == 1
        println(state.outs, "The build has produced only one build artifact:\n")
        println(state.outs, "\t$(state.files[1])")
        println(state.outs)
    else
        println(state.outs, "The build has produced several libraries and executables.")
        println(state.outs, "Please select which of these you want to consider `products`.")
        println(state.outs, "These are generally those artifacts you will load or use from julia.")
        while true
            selected = collect(request(
                terminal,
                "",
                MultiSelectMenu(state.files))
            )
            selected_file_kinds = map(x->state.file_kinds[x], selected)
            selected_files = map(x->state.files[x], selected)

            if !isempty(selected_files)
                state.file_kinds = selected_file_kinds
                state.files = selected_files
                break
            else
                println(state.outs, "You must make at least one selection.")
            end
        end
    end

    state.file_varnames = Symbol[]
    println(state.outs, "Please provide a unique variable name for each build artifact:")
    for f in state.files
        varname = nonempty_line_prompt(
            "variable name",
            string(f, ":");
            force_identifier=true,
            ins=state.ins,
            outs=state.outs,
        )
        push!(state.file_varnames, Symbol(varname))
    end

    push!(state.validated_platforms, platform)
    # Advance to next step
    state.step = :step5a

    println(state.outs)
end

"""
    step3_audit(state::WizardState, platform::Platform, prefix::Prefix)

Audit the `prefix`.
"""
function step3_audit(state::WizardState, platform::Platform, destdir::String)
    printstyled(state.outs, "\n\t\t\tAnalyzing...\n\n", bold=true)

    audit(Prefix(destdir); io=state.outs, platform=platform,
        verbose=true, autofix=true, require_license=false)

    println(state.outs)
end

"""
    interactive_build(state::WizardState, prefix::Prefix,
                      ur::Runner, build_path::AbstractString)

    Runs the interactive shell for building, then captures bash history to save
    reproducible steps for building this source. Shared between steps 3 and 5
"""
function interactive_build(state::WizardState, prefix::Prefix,
                           ur::Runner, build_path::AbstractString;
                           hist_modify = string)
   histfile = joinpath(prefix, "metadir", ".bash_history")
   runshell(ur, stdin=state.ins, stdout=state.outs, stderr=state.outs)
   # This is an extremely simplistic way to capture the history,
   # but ok for now. Obviously doesn't include any interactive
   # programs, etc.
   if isfile(histfile)
       state.history = hist_modify(state.history,
            # This is a bit of a hack for now to get around the fact
            # that we don't know cwd when we get back from bash, but
            # always start in the WORKSPACE. This makes sure the script
            # accurately reflects that.
            string(
               "cd \$WORKSPACE/srcdir\n",
                String(read(histfile)),
            ),
        )
       rm(histfile)
   end

   printstyled(state.outs, "\n\t\t\tBuild complete\n\n", bold=true)
   print(state.outs, "Your build script was:\n\n\t")
   println(state.outs, replace(state.history, "\n" => "\n\t"))

   if yn_prompt(state, "Would you like to edit this script now?", :n) == :y
       state.history = edit_script(state, state.history)

       println(state.outs)
       msg = strip("""
       We will now rebuild with your new script to make sure it still works.
       """)
       println(state.outs, msg)
       println(state.outs)

       return true
   else
       return false
   end
end

"""
    step3_interactive(state::WizardState, prefix::Prefix, platform::Platform,
                      ur::Runner, build_path::AbstractString)

The interactive portion of step3, moving on to either rebuild with an edited
script or proceed to step 4.
"""
function step3_interactive(state::WizardState, prefix::Prefix,
                           platform::Platform,
                           ur::Runner, build_path::AbstractString, artifact_paths::Vector{String})

    if interactive_build(state, prefix, ur, build_path)
        # Unsymlink all the deps from the dest_prefix before moving to the next step
        cleanup_dependencies(prefix, artifact_paths)
        state.step = :step3_retry
    else
        step3_audit(state, platform, joinpath(prefix, "destdir"))
        # Unsymlink all the deps from the dest_prefix before moving to the next step
        cleanup_dependencies(prefix, artifact_paths)
        return step4(state, ur, platform, build_path, prefix)
    end
end

"""
    step3_retry(state::WizardState)

Rebuilds the initial Linux x86_64 build after things like editing the script
file manually, etc...
"""
function step3_retry(state::WizardState)
    platform = pick_preferred_platform(state.platforms)

    msg = "\t\t\t# Attempting to build for $(triplet(platform))\n\n"
    printstyled(state.outs, msg, bold=true)

    build_path = tempname()
    mkpath(build_path)
    prefix = setup_workspace(build_path, state.source_files, state.source_hashes; verbose=false)
    artifact_paths = setup_dependencies(prefix, state.dependencies, platform)

    ur = preferred_runner()(
        prefix.path;
        cwd="/workspace/srcdir",
        platform=platform,
        src_name=state.name,
        compilers=state.compilers,
    )
    with_logfile(joinpath(build_path, "out.log")) do io
        run(ur, `/bin/bash -c $(state.history)`, io; verbose=true, tee_stream=state.outs)
    end
    step3_audit(state, platform, joinpath(prefix, "destdir"))
    # Unsymlink all the deps from the dest_prefix before moving to the next step
    cleanup_dependencies(prefix, artifact_paths)

    return step4(state, ur, platform, build_path, prefix)
end


"""
    Pick the first platform for use to run on. We prefer Linux x86_64 because
    that's generally the host platform, so it's usually easiest. After that we
    go by the following preferences:
        - OS (in order): Linux, Windows, OSX
        - Architecture: x86_64, i686, aarch64, powerpc64le, armv7l
        - The first remaining after this selection
"""
function pick_preferred_platform(platforms)
    if Linux(:x86_64) in platforms
        return Linux(:x86_64)
    end
    for os in (Linux, Windows, MacOS)
        plats = filter(p->p isa os, platforms)
        if !isempty(plats)
            platforms = plats
        end
    end
    for a in (:x86_64, :i686, :aarch64, :powerpc64le, :armv7l)
        plats = filter(p->arch(p) == a, platforms)
        if !isempty(plats)
            platforms = plats
        end
    end
    first(platforms)
end

"""
    step34(state::WizardState)

Starts initial build for Linux x86_64, which is our initial test target
platform.  Sources that build properly for this platform continue on to attempt
builds for more complex platforms.
"""
function step34(state::WizardState)
    platform = pick_preferred_platform(state.platforms)
    push!(state.visited_platforms, platform)

    printstyled(state.outs, "\t\t\t# Step 3: Build for $(platform)\n\n", bold=true)

    println(state.outs, "You will now be dropped into the cross-compilation environment.")
    print(state.outs, "Please compile the package. Your initial compilation target is ")
    printstyled(state.outs, triplet(platform), bold=true)
    println(state.outs)

    print(state.outs, "The ")
    printstyled(state.outs, "\$prefix ", bold=true)
    println(state.outs, "environment variable contains the target directory.")
    print(state.outs, "Once you are done, exit by typing ")
    printstyled(state.outs, "`exit`", bold=true)
    print(state.outs, " or ")
    printstyled(state.outs, "`^D`", bold=true)
    println(state.outs)
    println(state.outs)

    build_path = tempname()
    mkpath(build_path)
    state.history = ""
    prefix = setup_workspace(
        build_path,
        state.source_files,
        state.source_hashes;
        verbose=false,
    )
    artifact_paths = setup_dependencies(prefix, state.dependencies, platform)

    provide_hints(state, joinpath(prefix.path, "srcdir"))

    ur = preferred_runner()(
        prefix.path;
        cwd="/workspace/srcdir",
        workspaces = [
            joinpath(prefix, "metadir") => "/meta",
        ],
        platform=platform,
        src_name=state.name,
        compilers=state.compilers,
    )
    return step3_interactive(state, prefix, platform, ur, build_path, artifact_paths)
end

function step5_internal(state::WizardState, platform::Platform)
    print(state.outs, "Your next build target will be ")
    printstyled(state.outs, triplet(platform), bold=true)
    println(state.outs)
    print(state.outs, "Press any key to continue...")
    read(state.ins, Char)
    println(state.outs)

    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)

    printstyled(state.outs, "\t\t\t# Attempting to build for $(triplet(platform))\n\n", bold=true)

    build_path = tempname()
    mkpath(build_path)
    local ok = false
    # The code path in this function is rather complex (and unpredictable)
    # due to the fact that the user makes the choices. Therefore we keep
    # track of all the linked artifacts in a dictionary, and make sure to
    # unlink them before setting up a new build prefix
    prefix_artifacts = Dict{Prefix,Vector{String}}()
    while !ok
        cd(build_path) do
            prefix = setup_workspace(build_path, state.source_files, state.source_hashes; verbose=true)
            # Clean up artifacts in case there are some
            cleanup_dependencies(prefix, get(prefix_artifacts, prefix, String[]))
            artifact_paths = setup_dependencies(prefix, state.dependencies, platform)
            # Record newly added artifacts for this prefix
            prefix_artifacts[prefix] = artifact_paths
            ur = preferred_runner()(
                prefix.path;
                cwd="/workspace/srcdir",
                platform=platform,
                src_name=state.name,
                compilers=state.compilers,
            )
            with_logfile(joinpath(build_path, "out.log")) do io
                run(ur, `/bin/bash -c $(state.history)`, io; verbose=true, tee_stream=state.outs)
            end

            while true
                msg = "\n\t\t\tBuild complete. Analyzing...\n\n"
                printstyled(state.outs, msg, bold=true)

                audit(Prefix(joinpath(prefix, "destdir")); io=state.outs,
                    platform=platform, verbose=true, autofix=true, require_license=false)

                ok = isempty(match_files(state, prefix, platform, state.files))
                if !ok
                    println(state.outs)
                    printstyled(state.outs, "ERROR: ", color=:red)
                    msg = "Some build products could not be found (see above)."
                    println(state.outs, msg)
                    println(state.outs)

                    choice = request(terminal,
                        "How would you like to proceed? (CTRL-C to exit)",
                        RadioMenu([
                            "Drop into build environment",
                            "Open a clean session for this platform",
                            "Disable this platform",
                            "Edit build script",
                        ])
                    )

                    if choice == 1
                        if interactive_build(state, prefix, ur, build_path;
                                          hist_modify = function(olds, s)
                            """
                            $olds
                            if [ \$target = "$(triplet(platform))" ]; then
                            $s
                            fi
                            """
                            end)
                            # We'll go around again after this
                            break
                        else
                            # Go back to analysis of the newly environment
                            continue
                        end
                    elseif choice == 2
                        rm(build_path; force=true, recursive=true)
                        mkpath(build_path)
                        prefix = setup_workspace(
                            build_path,
                            state.source_files,
                            state.source_hashes;
                            verbose=true,
                        )
                        # Clean up artifacts in case there are some
                        cleanup_dependencies(prefix, get(prefix_artifacts, prefix, String[]))
                        artifact_paths = setup_dependencies(prefix, state.dependencies, platform)
                        # Record newly added artifacts for this prefix
                        prefix_artifacts[prefix] = artifact_paths

                        ur = preferred_runner()(
                            prefix.path;
                            cwd="/workspace/srcdir",
                            platform=platform,
                            src_name=state.name,
                            compilers=state.compilers,
                        )

                        if interactive_build(state, prefix, ur, build_path;
                                          hist_modify = function(olds, s)
                            """
                            if [ \$target != "$(triplet(platform))" ]; then
                            $olds
                            else
                            $s
                            fi
                            """
                            end)
                            # We'll go around again after this
                            break
                        else
                            # Go back to analysis of the newly environment
                            continue
                        end
                    elseif choice == 3
                        filter!(p->p != platform, state.platforms)
                        ok = true
                        break
                    elseif choice == 4
                        change_script!(state, edit_script(state, state.history))
                        break
                        # Well go around again after this
                    end
                else
                    ok = true
                    push!(state.validated_platforms, platform)
                    println(state.outs)
                    print(state.outs, "You have successfully built for ")
                    printstyled(state.outs, triplet(platform), bold=true)
                    println(state.outs, ". Congratulations!")
                    break
                end
            end

            println(state.outs)
        end
    end
    # Unsymlink all the deps from the prefixes before moving to the next step
    for (prefix, paths) in prefix_artifacts
        cleanup_dependencies(prefix, paths)
    end
    return ok
end

function step5a(state::WizardState)
    printstyled(state.outs, "\t\t\t# Step 5: Generalize the build script\n\n", bold=true)

    # We will try to pick a platform for a different operating system
    possible_platforms = filter(state.platforms) do plat
        !(any(state.visited_platforms) do p
            plat isa typeof(p)
        end)
    end
    if isempty(possible_platforms)
        state.step = :step5b
        return
    end
    platform = pick_preferred_platform(possible_platforms)

    println(state.outs, "We will now attempt to use the same script to build for other operating systems.")
    println(state.outs, "This will help iron out any issues with the cross compiler.")
    if step5_internal(state, platform)
        push!(state.visited_platforms, platform)
        state.step = :step5b
    end
end

function step5b(state::WizardState)

    # We will try to pick a platform for a different architeture
    possible_platforms = filter(state.platforms) do plat
        !(any(state.visited_platforms) do p
            arch(plat) == arch(p) ||
            # Treat the x86 variants equivalently
            (arch(p) in (:x86_64, :i686) &&
             arch(plat) in (:x86_64, :i686))
        end)
    end
    if isempty(possible_platforms)
        state.step = :step5c
        return
    end
    platform = pick_preferred_platform(possible_platforms)

    println(state.outs, "This should uncover issues related to architecture differences.")
    if step5_internal(state, platform)
        state.step = :step5c
        push!(state.visited_platforms, platform)
    end
end

function step5c(state::WizardState)
    msg = strip("""
    We will now attempt to build all remaining platforms.  Note that these
    builds are not verbose.  If you have edited the script since we attempted
    to build for any given platform, we will verify that the new script still
    works.  This will probably take a while.
    Press any key to continue...
    """)
    print(state.outs, msg)
    read(state.ins, Char)
    println(state.outs)

    pred = x -> !(x in state.validated_platforms)
    for platform in filter(pred, state.platforms)
        print(state.outs, "Building $(triplet(platform)): ")
        build_path = tempname()
        mkpath(build_path)
        local ok = true

        prefix = setup_workspace(
            build_path,
            state.source_files,
            state.source_hashes;
            verbose=false,
        )
        artifact_paths = setup_dependencies(prefix, state.dependencies, platform)
        ur = preferred_runner()(
            prefix.path;
            cwd="/workspace/srcdir",
            platform=platform,
            src_name=state.name,
            compilers=state.compilers,
        )
        with_logfile(joinpath(build_path, "out.log")) do io
            run(ur, `/bin/bash -c $(state.history)`, io; verbose=false, tee_stream=state.outs)
        end

        audit(Prefix(joinpath(prefix, "destdir"));
            io=state.outs,
            platform=platform,
            verbose=false,
            silent=true,
            autofix=true,
            require_license=false,
        )

        ok = isempty(match_files(
            state,
            prefix,
            platform,
            state.files;
            silent = true
        ))

        # Unsymlink all the deps from the prefix before moving to the next platform
        cleanup_dependencies(prefix, artifact_paths)

        print(state.outs, "[")
        if ok
            printstyled(state.outs, "✓", color=:green)
            push!(state.validated_platforms, platform)
        else
            printstyled(state.outs, "✗", color=:red)
            push!(state.failed_platforms, platform)
        end
        println(state.outs, "]")
    end

    println(state.outs)
end

function step6(state::WizardState)
    if isempty(state.failed_platforms)
        if any(p->!(p in state.validated_platforms), state.platforms)
            # Some platforms weren't validated, we probably edited the script.
            # Go back to 5c to recompute failed platforms
            state.step = :step5c
        else
            state.step = :step7
            printstyled(state.outs, "\t\t\tDone!\n\n", bold=true)
        end
        return
    end

    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)

    msg = "\t\t\t# Step 6: Revisit failed platforms\n\n"
    printstyled(state.outs, msg, bold=true)

    println(state.outs, "Several platforms failed to build:")
    for plat in state.failed_platforms
        println(state.outs, " - ", plat)
    end

    println(state.outs)

    choice = request(terminal,
        "How would you like to proceed? (CTRL-C to exit)",
        RadioMenu([
            "Disable these platforms",
            "Revisit manually",
            "Edit script and retry all",
        ])
    )

    println(state.outs)

    if choice == 1
        filter!(p->!(p in state.failed_platforms), state.platforms)
        state.step = :step7
    elseif choice == 2
        plats = collect(state.failed_platforms)
        if length(plats) > 1
            choice = request(terminal,
                "Which platform would you like to revisit?",
                RadioMenu(map(repr, plats)))
            println(state.outs)
        else
            choice = 1
        end
        if step5_internal(state, plats[choice])
            delete!(state.failed_platforms, plats[choice])
        end
        # Will wrap back around to step 6
    elseif choice == 3
        change_script!(state, edit_script(state, state.history))
        empty!(state.failed_platforms)
        # Will wrap back around to step 6 (which'll go back to 5c)
    end
end
