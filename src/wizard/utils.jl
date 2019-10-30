
function nonempty_line_prompt(name, msg; ins=stdin, outs=stdout, force_identifier=false)
    val = ""
    while true
        print(outs, msg, "\n> ")
        val = strip(readline(ins))
        println(outs)
        if !isempty(val) && (!force_identifier || Base.isidentifier(val))
            break
        end
        printstyled(outs, "$(name) may not be empty!\n", color=:red)
    end
    return val
end

"""
    normalize_name(file::AbstractString)

Given a filename, normalize it, stripping out extensions.  E.g. the file path
`"foo/libfoo.tar.gz"` would get mapped to `"libfoo"`.
"""
function normalize_name(file::AbstractString)
    file = basename(file)
    idx = findfirst(isequal('.'), file)
    if idx !== nothing
        file = file[1:prevind(file, idx)]
    end
    # Strip -123, which is a common thing for libraries on windows
    idx = findlast(isequal('-'), file)
    if idx !== nothing && all(isnumeric, file[nextind(file, idx):end])
        file = file[1:prevind(file, idx)]
    end
    return file
end

"""
    filter_object_files(files)

Given a list of files, filter out any that cannot be opened by `readmeta()`
from `ObjectFile`.
"""
function filter_object_files(files)
    return filter(files) do f
        try
            readmeta(f) do oh
                return true
            end
        catch e
            # If it was just a MagicMismatch, then return false for this file
            if isa(e, ObjectFile.MagicMismatch)
                return false
            end

            # If it was an EOFError (e.g. this was an empty file) then return false
            if isa(e, EOFError)
                return false
            end

            # If something else wrong then rethrow that error and pass it up
            rethrow(e)
        end
    end
end

"""
    match_files(state::WizardState, prefix::Prefix,
                platform::Platform, files::Vector; silent::Bool = false)

Inspects all binary files within a prefix, matching them with a given list of
`files`, complaining if there are any files that are not properly matched and
returning the set of normalized names that were not matched, or an empty set if
all names were properly matched.
"""
function match_files(state::WizardState, prefix::Prefix,
                     platform::Platform, files::Vector; silent::Bool = false)
    # Collect all executable/library files
    prefix_files = collapse_symlinks(collect_files(prefix))
    prefix_files = filter_object_files(prefix_files)
    # Check if we can load them as an object file
    prefix_files = filter(prefix_files) do f
        readmeta(f) do oh
            if !is_for_platform(oh, platform)
                if !silent
                    @warn("Skipping binary `$f` with incorrect platform")
                end
                return false
            end
            return true
        end
    end

    norm_prefix_files = Set(map(normalize_name, prefix_files))
    norm_files = Set(map(normalize_name, files))
    d = setdiff(norm_files, norm_prefix_files)
    if !isempty(d)
        if !silent
            @warn("Could not find correspondences for $(join(d, ' '))")
        end
    end
    return d
end

"""
    edit_script(state::WizardState, script::AbstractString)

For consistency (and security), use the sandbox for editing a script, launching
`vi` within an interactive session to edit a buildscript.
"""
function edit_script(state::WizardState, script::AbstractString)
    # Create a temporary directory to hold the script inside of
    temp_prefix() do prefix
        # Write the script out to a file
        path = joinpath(prefix, "script")
        open(path, "w") do f
            write(f, script)
        end

        # Launch a sandboxed vim editor
        ur = preferred_runner()(
            prefix.path,
            cwd = "/workspace/",
            platform = Linux(:x86_64),
        )
        run_interactive(ur,
            `/usr/bin/vim /workspace/script`;
            stdin=state.ins,
            stdout=state.outs,
            stderr=state.outs,
        )

        # Once the user is finished, read the script back in
        script = String(read(path))
    end
    return script
end

"""
    yn_prompt(state::WizardState, question::AbstractString, default = :y)

Perform a `[Y/n]` or `[y/N]` question loop, using `default` to choose between
the prompt styles, and looping until a proper response (e.g. `"y"`, `"yes"`,
`"n"` or `"no"`) is received.
"""
function yn_prompt(state::WizardState, question::AbstractString, default = :y)
    @assert default in (:y, :n)
    ynstr = default == :y ? "[Y/n]" : "[y/N]"
    while true
        print(state.outs, question, " ", ynstr, ": ")
        answer = lowercase(strip(readline(state.ins)))
        if isempty(answer)
            return default
        elseif answer == "y" || answer == "yes"
            return :y
        elseif answer == "n" || answer == "no"
            return :n
        else
            println(state.outs, "Unrecognized answer. Answer `y` or `n`.")
        end
    end
end

"""
    Change the script. This will invalidate all platforms to make sure we later
    verify that they still build with the new script.
"""
function change_script!(state, script)
    state.history = strip(script)
    empty!(state.validated_platforms)
end

function print_wizard_logo(outs)
    logo = raw"""

        o      `.
       o*o      \'-_               00000000: 01111111  $.
         \\      \;"".     ,;.--*  00000001: 01000101  $E
          \\     ,\''--.--'/       00000003: 01001100  $L
          :=\--<' `""  _   |       00000003: 01000110  $F
          ||\\     `" / ''--       00000004: 00000010  .
          `/_\\,-|    |            00000005: 00000001  .
              \\/     L
               \\ ,'   \             
             _/ L'   `  \          Join us in the #binarybuilder channel on the
            /  /    /   /          community slack: https://julialang.slack.com
           /  /    |    \            
          "_''--_-''---__=;        https://github.com/JuliaPackaging/BinaryBuilder.jl
    """

    blue    = "\033[34m"
    red     = "\033[31m"
    green   = "\033[32m"
    magenta = "\033[35m"
    normal  = "\033[0m\033[0m"

    # These color codes are annoying to embed, just run replacements here
    logo = replace(logo, " o " => " $(green)o$(normal) ")
    logo = replace(logo, "o*o" => "$(red)o$(blue)*$(magenta)o$(normal)")
    logo = replace(logo, ".--*" => "$(red).$(green)-$(magenta)-$(blue)*$(normal)")

    logo = replace(logo, "\$." => "$(blue).$(normal)")
    logo = replace(logo, "\$E" => "$(red)E$(normal)")
    logo = replace(logo, "\$L" => "$(green)L$(normal)")
    logo = replace(logo, "\$F" => "$(magenta)F$(normal)")
    logo = replace(logo, "#binarybuilder" => "$(green)#binarybuilder$(normal)")
    logo = replace(logo, "https://julialang.slack.com" => "$(green)https://julialang.slack.com$(normal)")

    println(outs, logo)

    println(outs,
        "Welcome to the BinaryBuilder wizard.  ",
        "We'll get you set up in no time."
    )
    println(outs)
end


with_logfile(f::Function, prefix::Prefix, name::String) = with_logfile(f, joinpath(logdir(prefix), name))
function with_logfile(f::Function, logfile::String)
    mkpath(dirname(logfile))    

    # If it's already a file, remove it, as it is probably an incorrect symlink
    if isfile(logfile)
        rm(logfile; force=true)
    end
    open(logfile, "w") do io
        f(io)
    end
end