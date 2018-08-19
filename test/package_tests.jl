# Run the package tests if we ask for it
if lowercase(get(ENV, "BINARYBUILDER_PACKAGE_TESTS", "false") ) == "true"
    cd("package_tests") do
        include(joinpath(pwd(), "runtests.jl"))
    end
end

