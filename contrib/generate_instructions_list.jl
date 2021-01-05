using LightXML, JSON

###
# Formatter taken from the README of JSON.jl
import JSON.Writer
import JSON.Writer.JSONContext
mutable struct PYONContext <: JSONContext
    underlying::JSONContext
end

for delegate in [:indent,
                 :delimit,
                 :separate,
                 :begin_array,
                 :end_array,
                 :begin_object,
                 :end_object]
    @eval JSON.Writer.$delegate(io::PYONContext) = JSON.Writer.$delegate(io.underlying)
end
Base.write(io::PYONContext, byte::UInt8) = write(io.underlying, byte)

JSON.Writer.show_null(io::PYONContext) = print(io, "None")
pyonprint(io::IO, obj) = let io = PYONContext(JSON.Writer.PrettyContext(io, 4))
    JSON.print(io, obj)
    return
end
###

function generate_dict()
    file = joinpath(@__DIR__, "instructions.xml")
    # Download the list of instructions from https://uops.info/xml.html
    if !isfile(file)
        download("https://uops.info/instructions.xml", file)
    end
    xml = parse_file(file)
    # Get the list of all extensions
    extensions = get_elements_by_tagname(root(xml), "extension")

    # Accumulator for all instructions.  The strategy is the following: we loop
    # over the extensions from the lower ones to the higher ones, if an
    # instruction is already found in a lower extension, then it is not added to
    # the higher one.
    all_instructions = String[]
    dict = Dict{String,Vector{String}}("unknown" => String[], "cpuid" => ["cpuid"])
    for name in (
        "mmx", "sse", "sse2", "sse3", "ssse3", "sse4", "avx", "aes", "pclmulqdq" , # sandybridge (aka AVX)
        "movbe", "avx2", "rdwrfsgs", "fma", "bmi1", "bmi2", "f16c", # haswell (aka AVX2)
        "pku", "rdseed", "adcx", "clflush", "xsavec", "xsaves", "clwb", "avx512evex", "avx512vex", # skylake-avx512 (aka AVX512)
    )
        instructions = String[]
        for idx in findall(x -> name == lowercase(attribute(x, "name")), extensions)
            for instruction in get_elements_by_tagname(extensions[idx], "instruction")
                instruction = lowercase(replace(attribute(instruction, "asm"), r"{[a-z]+} " => ""))
                if instruction ∉ all_instructions
                    unique!(sort!(push!(all_instructions, instruction)))
                    unique!(sort!(push!(instructions, instruction)))
                end
            end
        end
        dict[name] = instructions
    end
    free(xml)
    # We're basically converting an XML to a JSON, funny isn't it?
    open(joinpath(@__DIR__, "..", "src", "auditor", "instructions.json"), "w") do io
        pyonprint(io, dict)
        # Be nice and add a newline at the end of the file
        println(io)
    end
    return dict
end
