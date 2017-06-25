# Results are but an idea
abstract BuildResult

# A Library Dependency is a special kind of Dependency that not only needs to
# exist, but needs to have a special set of audit rules applied to it to show
# that the library can be loaded, that it does not have dependencies that live
# outside of its prefix/the base Julia distribution, etc...
immutable LibraryResult <: BuildResult
    path::String

    function LibraryResult(path::AbstractString)
        # For LibraryResults, abstract away adding on dlext
        if !endswith(path, Libdl.dlext)
            path = "$(path).$(Libdl.dlext)"
        end
        return new(path)
    end
end

function satisfied(lr::LibraryResult; verbose::Bool = false)
    if !isfile(lr.path)
        if verbose
            info("$(lr.path) does not exist, reporting unsatisfied")
        end
        return false
    end

    lr_handle = Libdl.dlopen_e(lr.path)
    if lr_handle == C_NULL
        if verbose
            info("$(lr.path) cannot be dlopen'ed, reporting unsatisfied")
        end
        return false
    end
    Libdl.dlclose(lr_handle)

    return true
end



immutable FileResult <: BuildResult
    path::AbstractString
end

function satisfied(fr::FileResult; verbose::Bool = false)
    if !isfile(fr.path)
        if verbose
            info("FileResult $(fr.path) does not exist, reporting unsatisfied")
        end
        return false
    end
    return true
end