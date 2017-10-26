"""
    target_envs(target::String)
Given a `target` (this term is used interchangeably with `triplet`), generate a
`Dict` mapping representing all the environment variables to be set within the
build environment to force compiles toward the defined target architecture.
Examples of things set are `PATH`, `CC`, `RANLIB`, as well as nonstandard
things like `target`.
"""
function target_envs(target::AbstractString)
    target_tool = tool -> "/opt/$(target)/bin/$(target)-$(tool)"
    mapping = Dict(
        "PATH" => "/opt/$(target)/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
        "AR" => target_tool("ar"),
        "CC" => target_tool("gcc"),
        "CXX" => target_tool("g++"),
        "FC" => target_tool("gfortran"),
        "LD" => target_tool("ld"),
        "NM" => target_tool("nm"),
        "AS" => target_tool("as"),
        "RANLIB" => target_tool("ranlib"),
        "STRIP" => target_tool("strip"),
        "INSTALL_NAME_TOOL" => target_tool("install_name_tool"),
        "LIBTOOL" => target_tool("libtool"),
        "LIPO" => target_tool("lipo"),
        "OTOOL" => target_tool("otool"),
        "target" => target,

        # Autotools really appreciates being able to build stuff for the
        # host system, so we set this to ease its woes
        "CC_FOR_BUILD" => "/opt/x86_64-linux-gnu/bin/gcc",
    )

    return mapping
end
