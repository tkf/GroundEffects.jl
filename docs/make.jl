using Documenter, GroundEffects

makedocs(;
    modules=[GroundEffects],
    format=Documenter.HTML(),
    pages=[
        "Home" => "index.md",
    ],
    repo="https://github.com/tkf/GroundEffects.jl/blob/{commit}{path}#L{line}",
    sitename="GroundEffects.jl",
    authors="Takafumi Arakaki <aka.tkf@gmail.com>",
    assets=String[],
)

deploydocs(;
    repo="github.com/tkf/GroundEffects.jl",
)
