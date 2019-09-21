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

abstract type AbstractHandler end

defaulthandlers() = AbstractHandler[
    Handler{:macrocall}(),
    Handler{:vcat}(),
    Handler{:hcat}(),
    Handler{:.=}(),
    DotCallHandler(),
    DotUpdateHandler(),
    RecursionHandler(),
]

struct Dispatcher
    handlers::Vector{Any}
end

function (lower::Dispatcher)(ex)
    for h in lower.handlers
        if accept(h, ex)
            return handle(h, lower, ex)
        end
    end
    return ex
end

struct Handler{head} <: AbstractHandler end

accept(::Any, ::Any) = false
accept(::Handler{head}, ex::Expr) where head = ex.head == head

handle(::Handler{:macrocall}, _, ex) = ex

function handle(::Handler{:vcat}, lower, ex)
    if all(isexpr.(ex.args, :row))
        rows = Tuple(length(a.args) for a in ex.args)
        return :($(Base.hvcat)($rows, $((
            lower(r) for a in ex.args for r in a.args
        )...)))
    else
        return :($(Base.vcat)($(map(lower, ex.args)...)))
    end
end

handle(::Handler{:hcat}, lower, ex) =
    :($(Base.hcat)($(map(lower, ex.args)...)))

function handle(::Handler{:.=}, lower, ex)
    @assert length(ex.args) == 2
    a1, a2 = map(lower, ex.args)
    return :($(Base.materialize!)($a1, $(Base.broadcasted)(identity, $a2)))
end

struct DotCallHandler <: AbstractHandler end

function isdotopcall(ex)
    ex isa Expr || return false
    op = ex.args[1]
    return op isa Symbol && Base.isoperator(op) && startswith(string(op), ".")
end

isdotcall(ex) =
    isexpr(ex, :.) && length(ex.args) == 2 && isexpr(ex.args[2], :tuple)

accept(::DotCallHandler, ex::Expr) = isdotopcall(ex) || isdotcall(ex)

handle(::DotCallHandler, lower, ex) =
    Expr(:call, Base.materialize, handle_lazy_dotcall(lower, ex))

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

struct DotUpdateHandler <: AbstractHandler end

_dotupdatematch(ex) = match(r"^(\.)?(([^.]+)=)$", string(ex.head))

accept(::DotUpdateHandler, ex::Expr) = _dotupdatematch(ex) !== nothing

function handle(::DotUpdateHandler, lower, ex)
    m = _dotupdatematch(ex)
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

struct RecursionHandler <: AbstractHandler end

accept(::RecursionHandler, ::Expr) = true
handle(::RecursionHandler, lower, ex) = Expr(ex.head, map(lower, ex.args)...)

end # module
