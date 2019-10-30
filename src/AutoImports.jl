module AutoImports

import JuliaVariables
using Base.Meta: isexpr
using CSTParser: CSTParser, Tokens
using JuliaVariables.MLStyle
using JuliaFormatter: format_text
using Pkg: TOML

include("utils.jl")
include("global_variables.jl")
include("add_using.jl")
include("sort_using.jl")
include("api.jl")

end # module
