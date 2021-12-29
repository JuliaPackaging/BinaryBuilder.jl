using JSON

## We start with definitions of instruction mnemonics, broken down by category:
const instruction_categories = JSON.parsefile(joinpath(@__DIR__, "instructions.json");
                                              dicttype=Dict{String,Vector{String}})

# Turn instructions "inside out", so e.g. we have "vzeroall" => "avx"
mnemonics_by_category = Dict(
    inst => cat for (cat, insts) in instruction_categories for inst in insts
)


"""
    instruction_mnemonics(path::AbstractString, platform::AbstractPlatform)

Dump a binary object with `objdump`, returning a list of instruction mnemonics
for further analysis with `analyze_instruction_set()`.

Note that this function only really makes sense for x86/x64 binaries.  Don't
run this on armv7l, aarch64, ppc64le etc... binaries and expect it to work.

This function returns the list of mnemonics as well as the counts of each,
binned by the mapping defined within `instruction_categories`.
"""
function instruction_mnemonics(path::AbstractString, platform::AbstractPlatform)
    # The outputs we are calculating
    counts = Dict{SubString{String}, Int}(k => 0 for k in keys(instruction_categories))
    mnemonics = Set{SubString{String}}()

    ur = preferred_runner()(
        abspath(dirname(path));
        cwd="/workspace/",
        platform=platform,
        verbose=false,
    )
    output = IOBuffer()

    # Run objdump to disassemble the input binary
    if Sys.isbsd(platform)
        objdump_cmd = "llvm-objdump -d $(basename(path))"
    else
        objdump_cmd = "\${target}-objdump -d $(basename(path))"
    end
    run_interactive(ur, `/bin/bash -c "$(objdump_cmd)"`; stdout=output, stderr=devnull)
    seekstart(output)

    @time for line in eachline(output)
        isempty(line) && continue

        # First, ensure that this line of output is 3 fields long at least
        @static if VERSION >= v"1.7.0-DEV.35"
            count('\t', line) != 2 && continue
        else
            count(==('\t'), line) != 2 && continue
        end
        # Grab the mnemonic for this line as the first word of the 3rd field
        idx = findlast('\t', line)
        s = SubString(line, idx+1)
        space = findfirst(' ', s)
        space === nothing && (space = lastindex(s))
        m = SubString(s, 1, space-1)

        push!(mnemonics, m)

        # For each mnemonic, find it in mnemonics_by_category, if we can, and
        # increment the appropriate `counts` member:
        if haskey(mnemonics_by_category, m)
            counts[mnemonics_by_category[m]] += 1
        else
            counts["unknown"] += 1
        end
    end

    # Return both the list of mnemonics as well as the binned counts
    return mnemonics, counts
end

function generic_march(p::AbstractPlatform)
    return first(first(Base.BinaryPlatforms.arch_march_isa_mapping[arch(p)]))
end

"""
    minimum_march(counts::Dict, p::AbstractPlatform)

This function returns the minimum instruction set required, depending on
whether the object file being pointed to is a 32-bit or 64-bit one:

* For 32-bit object files, this returns one of ["i686", "prescott"]

* For 64-bit object files, this returns one of ["x86_64", "avx", "avx2", "avx512"]
"""
function minimum_march(counts::Dict, p::AbstractPlatform)
    if arch(p) == "x86_64"
        avx512_instruction_categories = (
            "pku", "rdseed", "adcx", "clflush", "xsavec",
            "xsaves", "clwb", "avx512evex", "avex512vex",
        )
        avx2_instruction_categories = (
            "movbe", "avx2", "rdwrfsgs", "fma", "bmi1", "bmi2", "f16c",
        )
        # note that the extensions mmx, sse, and sse2 are part of the generic x86-64 architecture
        avx_instruction_categories = (
            "sse3", "ssse3", "sse4", "avx", "aes", "pclmulqdq",
        )
        if any(get.(Ref(counts), avx512_instruction_categories, 0) .> 0)
            return "avx512"
        elseif any(get.(Ref(counts), avx2_instruction_categories, 0) .> 0)
            return "avx2"
        elseif any(get.(Ref(counts), avx_instruction_categories, 0) .> 0)
            return "avx"
        end
    elseif arch(p) == "i686"
        if counts["sse3"] > 0
            return "prescott"
        end
    elseif arch(p) == "aarch64"
        # TODO: Detect instructions for aarch64 extensions
    elseif arch(p) == "armv6l"
        # We're just always going to assume we're running the single armv6l that Julia runs on.
    elseif arch(p) == "armv7l"
        # TODO: Detect NEON and vfpv4 instructions
    elseif arch(p) == "powerpc64le"
        # TODO Detect POWER9/10 instructions
    end
    return generic_march(p)
end


"""
    analyze_instruction_set(oh::ObjectHandle, platform::AbstractPlatform; verbose::Bool = false)

Analyze the instructions within the binary located at the given path for which
minimum instruction set it requires, taking note of groups of instruction sets
used such as `avx`, `sse4.2`, `i486`, etc....

Some binary files (such as libopenblas) contain multiple versions of functions,
internally determining which version to call by using the `cpuid` instruction
to determine processor support.  In an effort to detect this, we make note of
any usage of the `cpuid` instruction, disabling our minimum instruction set
calculations if such an instruction is found, and notifying the user of this
if `verbose` is set to `true`.

Note that this function only really makes sense for x86/x64 binaries.  Don't
run this on armv7l, aarch64, ppc64le etc... binaries and expect it to work.
"""
function analyze_instruction_set(oh::ObjectHandle, platform::AbstractPlatform; verbose::Bool = false)
    # Get list of mnemonics
    mnemonics, counts = instruction_mnemonics(path(oh), platform)

    # Analyze for minimum instruction set
    min_march = minimum_march(counts, platform)

    # If the binary uses `cpuid`, we can't know what it's doing, so just
    # return the most conservative ISA and warn the user if `verbose` is set.
    if counts["cpuid"] > 0
        if verbose && generic_march(platform) != min_march
            msg = replace("""
            $(basename(path(oh))) contains a `cpuid` instruction; refusing to
            analyze for minimum instruction set, as it may dynamically select
            the proper instruction set internally.  Would have chosen
            $(min_march), instead choosing $(generic_march(platform)).
            """, '\n' => ' ')
            @warn(strip(msg))
        end
        return generic_march(platform)
    end

    # Otherwise, return `min_march` and let 'em know!
    return min_march
end
