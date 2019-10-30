using Documenter, AutoImports

makedocs(;
    modules=[AutoImports],
    format=Documenter.HTML(),
    pages=[
        "Home" => "index.md",
    ],
    repo="https://github.com/tkf/AutoImports.jl/blob/{commit}{path}#L{line}",
    sitename="AutoImports.jl",
    authors="Takafumi Arakaki <aka.tkf@gmail.com>",
    assets=String[],
)

deploydocs(;
    repo="github.com/tkf/AutoImports.jl",
)
