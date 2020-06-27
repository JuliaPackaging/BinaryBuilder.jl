using JSON

## We start with definitions of instruction mnemonics, broken down by category:
const instruction_categories = JSON.parsefile(joinpath(@__DIR__, "instructions.json");
                                              dicttype=Dict{String,Vector{String}})

# Turn instructions "inside out", so e.g. we have "vzeroall" => "avx"
mnemonics_by_category = Dict(
    inst => cat for (cat, insts) in instruction_categories for inst in insts
)


"""
    instruction_mnemonics(path::AbstractString, platform::Platform)

Dump a binary object with `objdump`, returning a list of instruction mnemonics
for further analysis with `analyze_instruction_set()`.

Note that this function only really makes sense for x86/x64 binaries.  Don't
run this on armv7l, aarch64, ppc64le etc... binaries and expect it to work.

This function returns the list of mnemonics as well as the counts of each,
binned by the mapping defined within `instruction_categories`.
"""
function instruction_mnemonics(path::AbstractString, platform::Platform)
    # The outputs we are calculating
    counts = Dict(k => 0 for k in keys(instruction_categories))
    mnemonics = String[]

    ur = preferred_runner()(
        abspath(dirname(path));
        cwd="/workspace/",
        platform=platform,
        verbose=false,
    )
    output = IOBuffer()

    # Run objdump to disassemble the input binary
    if platform isa MacOS || platform isa FreeBSD
        objdump_cmd = "llvm-objdump -d $(basename(path))"
    else
        objdump_cmd = "\${target}-objdump -d $(basename(path))"
    end
    run_interactive(ur, `/bin/bash -c "$(objdump_cmd)"`; stdout=output, stderr=devnull)
    seekstart(output)

    for line in eachline(output)
        # First, ensure that this line of output is 3 fields long at least
        fields = filter(x -> !isempty(strip(x)), split(line, '\t'))
        if length(fields) < 3
            continue
        end

        # Grab the mnemonic for this line as the first word of the 3rd field
        m = split(fields[3])[1]
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

"""
    minimum_instruction_set(counts::Dict, is_64bit::Bool)

This function returns the minimum instruction set required, depending on
whether the object file being pointed to is a 32-bit or 64-bit one:

* For 32-bit object files, this returns one of [:pentium4, :prescott]

* For 64-bit object files, this returns one of [:x86_64, :sandybridge, :haswell, :skylake_avx512]
"""
function minimum_instruction_set(counts::Dict, is_64bit::Bool)
    if is_64bit
        avx512_instruction_categories = ("pku", "rdseed", "adcx", "clflush", "xsavec", "xsaves", "clwb", "avx512evex", "avex512vex")
        avx2_instruction_categories = ("movbe", "avx2", "rdwrfsgs", "fma", "bmi1", "bmi2", "f16c")
        # note that the extensions mmx, sse, and sse2 are part of the generic x86-64 architecture
        avx_instruction_categories = ("sse3", "ssse3", "sse4", "avx", "aes", "pclmulqdq")
        if any(get.(Ref(counts), avx512_instruction_categories, 0) .> 0)
            return :skylake_avx512
        elseif any(get.(Ref(counts), avx2_instruction_categories, 0) .> 0)
            return :haswell
        elseif any(get.(Ref(counts), avx_instruction_categories, 0) .> 0)
            return :sandybridge
        end
        return :x86_64
    else
        if counts["sse3"] > 0
            return :prescott
        end
        return :pentium4
    end
end


"""
    analyze_instruction_set(oh::ObjectHandle, platform::Platform; verbose::Bool = false)

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
function analyze_instruction_set(oh::ObjectHandle, platform::Platform; verbose::Bool = false)
    # Get list of mnemonics
    mnemonics, counts = instruction_mnemonics(path(oh), platform)

    # Analyze for minimum instruction set
    min_isa = minimum_instruction_set(counts, is64bit(oh))

    # If the binary uses `cpuid`, we can't know what it's doing, so just
    # return the most conservative ISA and warn the user if `verbose` is set.
    if counts["cpuid"] > 0
        new_min_isa = is64bit(oh) ? :x86_64 : :pentium4
        if verbose && new_min_isa != min_isa
            msg = replace("""
            $(basename(path(oh))) contains a `cpuid` instruction; refusing to
            analyze for minimum instruction set, as it may dynamically select
            the proper instruction set internally.  Would have chosen
            $(min_isa), instead choosing $(new_min_isa).
            """, '\n' => ' ')
            @warn(strip(msg))
        end
        return new_min_isa
    end

    # Otherwise, return `min_isa` and let 'em know!
    return min_isa
end

