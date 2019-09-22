using GroundEffects
using Test

statements(block) = filter(ex -> ex isa Expr, block.args)

expressions_to_be_lowered = quote
    [1, 2, 3, 4]
    [1; 2]
    [1 2; 3 4]
    [1 2]
    ones(2) .+ 2
    identity.(ones(2) .+ 2)
    [1, 2] .== [1, 3]
    [1, 2] .!= [1, 3]
    [1, 2][1]
    [1, 2][end]
    [1, 2][end ÷ 2]
    begin
        x = [1, 2, 3]
        ans = begin
            x[1] = 10
        end
        (ans, x)
    end
    begin
        x = [1, 2, 3]
        ans = begin
            x[end] = 30
        end
        (ans, x)
    end
    begin
        x = [1, 2, 3]
        ans = begin
            x[end÷2] = 10
        end
        (ans, x)
    end
    begin
        x = zeros(3)
        x .= 1
    end
    begin
        x = [1, 2, 3]
        x .+= 2
    end
    im.re
    identity() do; end()
    identity(identity)() do; end()
end |> statements

@testset for ex in expressions_to_be_lowered
    lex = GroundEffects.lower(ex)
    @test ex != lex
    actual = @eval $lex
    desired = @eval $ex
    @test actual == desired
end

mutable = Text("old")
@testset "setproperty!" begin
    ex = :(mutable.content = "new")
    lex = GroundEffects.lower(ex)
    @test ex != lex
    result = @eval $lex
    @test result == "new"
    @test mutable.content == "new"
end
