module GroundEffects

using .Meta: isexpr

@nospecialize

"""
    lower(ex::Expr) :: Expr

Desugar subexpressions of `ex` as long as they are representable by Julia's
surface syntax.  The lowered output can be used as an output of macro.
"""
lower(ex::Expr) = lower(defaulthandlers(), ex)
lower(handlers::AbstractVector, ex::Expr) = Dispatcher(handlers)(ex)

defaulthandlers() = Any[
    handle_macrocall,
    handle_vect,
    handle_vcat,
    handle_hcat,
    handle_ref,
    handle_assignment,
    handle_inplace_materialize,
    handle_dotcall,
    handle_dotupdate,
    handle_getproperty,
    handle_do,
    handle_recursion,
]

struct Defer end
const defer = Defer()

struct Dispatcher
    handlers::Vector{Any}
end

function (lower::Dispatcher)(ex)
    for h in lower.handlers
        y = h(lower, ex)
        y === defer || return y
    end
    return ex
end

handle_recursion(lower, ::Any) = defer
handle_recursion(lower, ex::Expr) = Expr(ex.head, map(lower, ex.args)...)

handle_macrocall(_, ex) = isexpr(ex, :macrocall) ? ex : defer

function handle_vect(lower, ex)
    isexpr(ex, :vect) || return defer
    return Expr(:call, Base.vect, map(lower, ex.args)...)
end

function handle_vcat(lower, ex)
    isexpr(ex, :vcat) || return defer
    if all(isexpr.(ex.args, :row))
        rows = Tuple(length(a.args) for a in ex.args)
        return :($(Base.hvcat)($rows, $((
            lower(r) for a in ex.args for r in a.args
        )...)))
    else
        return :($(Base.vcat)($(map(lower, ex.args)...)))
    end
end

handle_hcat(lower, ex) =
    isexpr(ex, :hcat) ? :($(Base.hcat)($(map(lower, ex.args)...))) : defer

#=
function handle_typed_vcat(lower, ex)
end

function handle_typed_hcat(lower, ex)
end
=#

function handle_ref(lower, ex)
    isexpr(ex, :ref) || return defer
    statements, collection, indices = _handle_ref(lower, ex)
    push!(statements, Expr(:call, Base.getindex, collection, indices...))
    if length(statements) == 1
        return statements[1]
    else
        return Expr(:block, statements...)
    end
end

function _handle_ref(lower, ex)
    statements = []
    if length(ex.args) == 1
        collection = ex.args[1]
        indices = []
    else
        if ex.args[1] isa Symbol
            collection = ex.args[1]
        else
            @gensym collection
            push!(statements, :($collection = $(ex.args[1])))
        end
        indices = lower_indices(lower, collection, ex.args[2:end])
    end
    return statements, collection, indices
end

function handle_assignment(lower, ex)
    isexpr(ex, :(=)) || return defer
    lhs = Any[ex.args[1]]
    rhs = ex.args[2]
    while isexpr(rhs, :(=))
        push!(lhs, rhs.args[1])
        rhs = rhs.args[2]
    end
    @gensym rhsvalue
    args = mapfoldl(append!, lhs, init=Any[:($rhsvalue = $(lower(rhs)))]) do l
        _handle_assignment(lower, l, rhsvalue)
    end
    return Expr(:block, args..., rhsvalue)
end

function _handle_assignment(lower, lhs, rhs)
    if isexpr(lhs, :ref)
        statements, collection, indices = _handle_ref(lower, lhs)
        push!(statements, Expr(:call, Base.setindex!, collection, rhs, indices...))
        return statements
    elseif isexpr(lhs, :.)
        @assert length(lhs.args) == 2
        return [Expr(
            :call,
            Base.setproperty!,
            lower(lhs.args[1]),
            lhs.args[2],
            rhs,
        )]
    end
    return [:($lhs = $rhs)]
end

lower_indices(lower, collection, indices) =
    map(index -> lower_index(lower, collection, index), indices)

function lower_index(lower, collection, index)
    ex = handle_dotcall(index) do ex
        lower_index(lower, collection, ex)
    end
    ex === defer || return ex

    if isexpr(index, :call)
        return Expr(:call, lower_indices(lower, collection, index.args)...)
    elseif index === :end
        return :($(Base.lastindex)($collection))
    end
    return lower(index)
end

function handle_inplace_materialize(lower, ex)
    isexpr(ex, :.=) || return defer
    @assert length(ex.args) == 2
    a1, a2 = map(lower, ex.args)
    return :($(Base.materialize!)($a1, $(Base.broadcasted)(identity, $a2)))
end

function isdotopcall(ex)
    ex isa Expr && !isempty(ex.args) || return false
    op = ex.args[1]
    return op isa Symbol && Base.isoperator(op) && startswith(string(op), ".")
end

isdotcall(ex) =
    isexpr(ex, :.) && length(ex.args) == 2 && isexpr(ex.args[2], :tuple)

function handle_dotcall(lower, ex)
    isdotcall(ex) || isdotopcall(ex) || return defer
    return Expr(:call, Base.materialize, handle_lazy_dotcall(lower, ex))
end

function handle_lazy_dotcall(lower, ex)
    if isdotcall(ex)
        args = [
            lower(ex.args[1])
            map(x -> handle_lazy_dotcall(lower, x), ex.args[2].args)
        ]
    elseif isdotopcall(ex)
        args = [
            Symbol(String(ex.args[1])[2:end])
            map(x -> handle_lazy_dotcall(lower, x), ex.args[2:end])
        ]
    else
        return lower(ex)
    end
    return Expr(:call, Base.broadcasted, args...)
end

function handle_dotupdate(lower, ex)
    ex isa Expr || return defer
    m = match(r"^(\.)?(([^.]+)=)$", string(ex.head))
    m === nothing && return defer
    # e.g., `ex.head == :.+=`
    op = Symbol(m.captures[3])  # e.g., `:+`
    @assert length(ex.args) == 2
    a1, a2 = map(lower, ex.args)
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

#=
function handle_comparison(lower, ex)
end
=#

function handle_getproperty(lower, ex)
    isexpr(ex, :.) || return defer
    return Expr(:call, Base.getproperty, lower(ex.args[1]), ex.args[2])
end

function handle_do(lower, ex)
    isexpr(ex, :do) || return defer
    call, lambda = map(lower, ex.args)
    return Expr(call.head, call.args[1], lambda, call.args[2:end]...)
end

end # module
