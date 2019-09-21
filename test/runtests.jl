using GroundEffects
using Test

statements(block) = filter(ex -> ex isa Expr, block.args)

expressions_to_be_lowered = quote
    [1; 2]
    [1 2; 3 4]
    [1 2]
    ones(2) .+ 2
    identity.(ones(2) .+ 2)
    [1, 2] .== [1, 3]
    [1, 2] .!= [1, 3]
    begin
        x = zeros(3)
        x .= 1
    end
    begin
        x = [1, 2, 3]
        x .+= 2
    end
end |> statements

@testset for ex in expressions_to_be_lowered
    lex = GroundEffects.lower(ex)
    @test ex != lex
    actual = @eval $lex
    desired = @eval $ex
    @test actual == desired
end
