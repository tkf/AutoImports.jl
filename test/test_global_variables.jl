module TestGlobalVariables
using AutoImports: global_variables
using Test

simple_code = """
using Somewhere: E
G = 1

\"\"\"
docstring of f
\"\"\"
function f(x)
    x + ((z) -> Y + z)(x)
end

function g(x)
    x
end

M.h(x) = nothing
"""

@testset "$label" for (label, code) in [
    ("simple", simple_code),
    ("module", """
               module MyModule
               $simple_code
               end
               """),
]
    vars = global_variables(code)

    if occursin("MyModule", code)
        @test vars.left == Set([:MyModule, :G, :E, :f, :g])
    else
        @test vars.left == Set([:G, :E, :f, :g])
    end

    @test Set([:Y, :M]) <= vars.right

    @testset for x in [:h, :x, :z]
        @test x ∉ vars.right
        @test x ∉ vars.left
    end
end

end  # module
