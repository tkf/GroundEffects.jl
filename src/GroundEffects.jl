module GroundEffects

using .Meta: isexpr

"""
    lower(ex::Expr) :: Expr

Desugar subexpressions of `ex` as long as they are representable by Julia's
surface syntax.  The lowered output can be used as an output of macro.
"""
lower(ex::Expr) = _lower(ex)

_lower(x) = x

function _lower(ex::Expr)
    if ex.head === :macrocall
        return ex
    elseif ex.head === :vcat
        if all(isexpr.(ex.args, :row))
            rows = Tuple(length(a.args) for a in ex.args)
            return :($(Base.hvcat)($rows, $((
                _lower(r) for a in ex.args for r in a.args
            )...)))
        else
            return :($(Base.vcat)($(map(_lower, ex.args)...)))
        end
    elseif ex.head === :hcat
        return :($(Base.hcat)($(map(_lower, ex.args)...)))
    elseif ex.head === :.=
        @assert length(ex.args) == 2
        a1, a2 = map(_lower, ex.args)
        return :($(Base.materialize!)($a1, $(Base.broadcasted)(identity, $a2)))
    elseif (m = match(r"^(\.)?(([^.]+)=)$", string(ex.head))) !== nothing
        # e.g., `ex.head == :.+=`
        op = Symbol(m.captures[3])  # e.g., `:+`
        @assert length(ex.args) == 2
        a1, a2 = map(_lower, ex.args)
        if m.captures[1] === nothing
            # e.g., `ex.head == :+=`
            if !(a1 isa Symbol)
                error("Assignment destination must be a symbol. Got:\n", a1)
            end
            return :($a1 = $op($a1, $a2))
        elseif a1 isa Symbol
            return :($(Base.materialize!)($a1, $(Base.broadcasted)($op, $a1, $a2)))
        else
            @gensym lhs
            return Expr(
                :block,
                :($lhs = $a1),
                :($(Base.materialize!)($lhs, $(Base.broadcasted)($op, $lhs, $a2))),
            )
        end
    end
    return Expr(ex.head, _lower.(ex.args)...)
end

end # module
