include("hints.jl")

"""
    step4(state::WizardState, ur::Runner, platform::Platform,
          build_path::AbstractString, prefix::Prefix)

The fourth step selects build products after the first build is done
"""
function step4(state::WizardState, ur::Runner, platform::Platform,
               build_path::AbstractString, prefix::Prefix)
    print_with_color(:bold, state.outs, "\t\t\t# Step 4: Select build products\n\n")

    # Collect all executable/library files
    files = collapse_symlinks(collect_files(prefix; exculuded_files=state.dependency_files))

    # Check if we can load them as an object file
    files = filter(files) do f
        try
            h = readmeta(f)
            is_for_platform(h, platform) || return false
            return true
        catch
            return false
        end
    end

    # Strip out the prefix from filenames
    state.files = map(file->replace(file, prefix.path, ""), files)
    state.file_kinds = map(files) do f
        h = readmeta(f)
        isexecutable(h) ? :executable :
        islibrary(h) ? :library : :other
    end

    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)

    if length(files) == 0
        print_with_color(:red, state.outs, "ERROR: ")
        println(state.outs, "The build has produced no binary artifacts.")
        println(state.outs, " "^7, "This is generally because an error occured during the build")
        println(state.outs, " "^7, "or because you forgot to `make install` or equivalent.")
        println(state.outs)

        choice = request(terminal, "How would you like to proceed?",
            RadioMenu([
                "Return to build enviornment",
                "Retry with a clean build enviornment",
                "Edit the script"
            ]))
        println(state.outs)

        if choice == 1
            return step3_interactive(state, prefix, platform, ur, build_path)
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
    else
        println(state.outs, "The build has produced several libraries and executables.")
        println(state.outs, "Please select which of these you want to consider `products`.")
        println(state.outs, "These are generally those artifacts you will load or use from julia.")
        selected = collect(request(
            terminal,
            "",
            MultiSelectMenu(state.files)))
        state.file_kinds = map(x->state.file_kinds[x], selected)
        state.files = map(x->state.files[x], selected)
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
function step3_audit(state::WizardState, platform::Platform, prefix::Prefix)
    print_with_color(:bold, state.outs, "\n\t\t\tAnalyzing...\n\n")

    audit(prefix; io=state.outs,
        platform=platform, verbose=true, autofix=true)

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
   histfile = joinpath(build_path, ".bash_history")
   runshell(ur, state.ins, state.outs, state.outs)
   # This is an extremely simplistic way to capture the history,
   # but ok for now. Obviously doesn't include any interactive
   # programs, etc.
   if isfile(histfile)
       state.history = hist_modify(state.history,
           # This is a bit of a hack for now to get around the fact
           # that we don't know cwd when we get back from bash, but
           # always start in the WORKSPACE. This makes sure the script
           # accurately reflects that.
           string("cd \$WORKSPACE/srcdir\n",
           readstring(histfile)))
       rm(histfile)
   end

   print_with_color(:bold, state.outs, "\n\t\t\tBuild complete\n\n")
   print(state.outs, "Your build script was:\n\n\t")
   print(state.outs, replace(state.history, "\n", "\n\t"))
   println(state.outs)

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
                           ur::Runner, build_path::AbstractString)

    if interactive_build(state, prefix, ur, build_path)
        state.step = :step3_retry
    else
        step3_audit(state, platform, prefix)

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

    msg = "\t\t\t# Attempting to build for $platform\n\n"
    print_with_color(:bold, state.ins, msg)

    build_path = tempname()
    mkpath(build_path)
    local ok = true
    cd(build_path) do
        prefix, ur = setup_workspace(
            build_path,
            state.source_files,
            state.source_hashes,
            state.dependencies,
            platform;
            verbose=true,
            tee_stream=state.outs
        )

        # Record which files were added by dependencies, so we don't offer
        # these to the user as products.
        state.dependency_files = Set{String}(collect_files(prefix))

        run(ur,
            `/bin/bash -c $(state.history)`,
            joinpath(build_path,"out.log");
            verbose=true,
            tee_stream=state.outs
        )

        step3_audit(state, platform, prefix)

        return step4(state, ur, platform, build_path, prefix)
    end
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

    print_with_color(:bold, state.outs, "\t\t\t# Step 3: Build for $(platform)\n\n")

    msg = strip("""
    You will now be dropped into the cross-compilation environment.
    Please compile the library. Your initial compilation target is $(platform).
    The \$prefix environment variable contains the target directory.
    Once you are done, exit by typing `exit` or `^D`
    """)
    println(state.outs, msg)
    println(state.outs)

    build_path = tempname()
    mkpath(build_path)
    state.history = ""
    cd(build_path) do
        histfile = joinpath(build_path, ".bash_history")
        prefix, ur = setup_workspace(
            build_path,
            state.source_files,
            state.source_hashes,
            state.dependencies,
            platform,
            Dict("HISTFILE"=>"/workspace/.bash_history");
            verbose=true,
            tee_stream=state.outs
        )
        provide_hints(state, joinpath(prefix.path, "..", "srcdir"))

        # Record which files were added by dependencies, so we don't offer
        # these to the user as products.
        state.dependency_files = Set{String}(collect_files(prefix))

        return step3_interactive(state, prefix, platform, ur, build_path)
    end
end

function step5_internal(state::WizardState, platform::Platform, message)
    print(state.outs, "Your next build target will be ")
    print_with_color(:bold, state.outs, platform)
    println(state.outs, message)
    println(state.outs)
    println(state.outs, "Press any key to continue...")
    read(state.ins, Char)
    println(state.outs)

    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)

    print_with_color(:bold, state.ins, "\t\t\t# Attempting to build for $platform\n\n")

    build_path = tempname()
    mkpath(build_path)
    local ok = false
    while !ok
        cd(build_path) do
            prefix, ur = setup_workspace(
                build_path,
                state.source_files,
                state.source_hashes,
                state.dependencies,
                platform,
                Dict("HISTFILE"=>"/workspace/.bash_history");
                verbose=true,
                tee_stream=state.outs
            )

            run(ur,
                `/bin/bash -c $(state.history)`,
                joinpath(build_path,"out.log");
                verbose=true,
                tee_stream=state.outs
            )

            while true
                msg = "\n\t\t\tBuild complete. Analyzing...\n\n"
                print_with_color(:bold, state.outs, msg)

                audit(prefix; io=state.outs,
                    platform=platform, verbose=true, autofix=true)

                ok = isempty(match_files(state, prefix, platform, state.files))
                if !ok
                    println(state.outs)
                    print_with_color(:red, state.outs, "ERROR: ")
                    msg = "Some build products could not be found (see above)."
                    println(state.outs, msg)
                    println(state.outs)

                    # N.B.: This is (slightly modified) a Star Trek reference (TNG Season 1, Episode 25,
                    # 25:00).
                    choice = request(terminal,
                        "Please specify how you would like to proceed.",
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
                        rm(build_path; force = true, recursive = true)
                        mkpath(build_path)
                        prefix, ur = setup_workspace(
                            build_path,
                            state.source_files,
                            state.source_hashes,
                            state.dependencies,
                            platform,
                            Dict("HISTFILE"=>"/workspace/.bash_history");
                            verbose=true,
                            tee_stream=state.outs
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
                    println(state.outs, "")
                    msg = "You have successfully built for $platform. Congratulations!"
                    println(state.outs, msg)
                    break
                end
            end

            println(state.outs)
        end
    end
    return ok
end

function step5a(state::WizardState)
    print_with_color(:bold, state.outs, "\t\t\t# Step 5: Generalize the build script\n\n")

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

    msg = strip("""
    We will now attempt to use the same script to build for other operating systems.
    This will likely fail, but the failure mode will help us understand why.
    """)
    println(state.outs, msg)

    msg = ".\n This will help iron out any issues\nwith the cross compiler"
    if step5_internal(state, platform, msg)
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

    if step5_internal(state, platform,
    ".\n This should uncover issues related to architecture differences.")
        state.step = :step5c
        push!(state.visited_platforms, platform)
    end
end

function step5c(state::WizardState)
    msg = strip("""
    We will now attempt to build all remaining platform.
    Note that these builds are not verbose.
    If you have edited the script since we attempted to build for any given
    platform, we will verify that the new script still works now.
    This will probably take a while.

    Press any key to continue...
    """)
    println(state.outs, msg)
    read(state.ins, Char)
    println(state.outs)

    pred = x -> !(x in state.validated_platforms)
    for platform in filter(pred, state.platforms)
        print(state.outs, "Building $platform ")
        build_path = tempname()
        mkpath(build_path)
        local ok = true
        cd(build_path) do
            prefix, ur = setup_workspace(
                build_path,
                state.source_files,
                state.source_hashes,
                state.dependencies,
                platform;
                verbose=false,
                tee_stream=state.outs
            )

            run(ur,
                `/bin/bash -c $(state.history)`,
                joinpath(build_path,"out.log");
                verbose=false,
                tee_stream=state.outs
            )

            audit(prefix;
                io=state.outs,
                platform=platform,
                verbose=false,
                silent=true,
                autofix=true
            )

            ok = isempty(match_files(
                state,
                prefix,
                platform,
                state.files;
                silent = true
            ))
        end
        print(state.outs, "[")
        if ok
            print_with_color(:green, state.outs, "✓")
            push!(state.validated_platforms, platform)
        else
            print_with_color(:red, state.outs, "✗")
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
        end
        return
    end

    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)

    msg = "\t\t\t# Step 6: Revisit failed platforms\n\n"
    print_with_color(:bold, state.outs, msg)

    println(state.outs, "Several platforms failed to build:")
    for plat in state.failed_platforms
        println(state.outs, " - ", plat)
    end

    println(state.outs)

    choice = request(terminal,
        "What would you like to do?",
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
        if step5_internal(state, plats[choice], ". ")
            delete!(state.failed_platforms, plats[choice])
        end
        # Will wrap back around to step 6
    elseif choice == 3
        change_script!(state, edit_script(state, state.history))
        empty!(state.failed_platforms)
        # Will wrap back around to step 6 (which'll go back to 5c)
    end
end
