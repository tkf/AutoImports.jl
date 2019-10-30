function parse_ast(code::AbstractString)
    start = 1
    args = []
    while true
        ex, next = Meta.parse(code, start)
        next === start && break
        start = next
        push!(args, ex)
    end
    return Expr(:block, args...)
end

function match_macro(prefix, name, ex)
    x = Symbol(name)
    return ex in (x, :($prefix.$x))
end

preprocess_ast(x) = x
function preprocess_ast(ex::Expr)
    #! format: off
    if isexpr(ex, :macrocall) && (
        ex.args[1] == GlobalRef(Core, Symbol("@doc")) ||
        match_macro(:Base, "@inline", ex.args[1]) ||
        match_macro(:Base, "@propagate_inbounds", ex.args[1]) ||
        match_macro(:Base, "@pure", ex.args[1]) ||
        match_macro(:Base, "@nospecialize", ex.args[1]) ||
        match_macro(:Base, "@static", ex.args[1]) ||
        match_macro(:Test, "@testset", ex.args[1])
    )
        return preprocess_ast(ex.args[end])
    elseif isexpr(ex, :macrocall) && match_macro(:Test, "@test", ex.args[1])
        return preprocess_ast(ex.args[3])
    elseif (
        isexpr(ex, :macrocall) &&
        match_macro(:Base, "@deprecate", ex.args[1]) &&
        length(ex.args) >= 4
    )
        # Handle: @deprecate old new
        return :($(ex.args[3]) = $(ex.args[4]))
    end
    #! format: on
    return Expr(ex.head, preprocess_ast.(ex.args)...)
end

vsolve(ex::Expr) = JuliaVariables.solve(ex)
vsolve(code::AbstractString) = vsolve(preprocess_ast(parse_ast(code)))

resolvedvar(x::Symbol) = x
function resolvedvar(scopedvar::JuliaVariables.ScopedVar)
    scope = scopedvar.scope
    sym = scopedvar.sym
    return scope[sym]
end

assymbol(x) = resolvedvar(x)::Symbol

isglobalvar(_) = false
# isglobalvar(::JuliaVariables.GlobalVar) = true
isglobalvar(scopedvar::JuliaVariables.ScopedVar) =
    resolvedvar(scopedvar) isa JuliaVariables.GlobalVar

function maybe_push_lvar!(vars, x)
    if isglobalvar(x)
        push!(vars.left, assymbol(x))
    end
    return vars
end

function maybe_push_rvar!(vars, x)
    if isglobalvar(x)
        push!(vars.right, assymbol(x))
    end
    return vars
end

global_variables!(vars, _) = vars
function global_variables!(vars, x::JuliaVariables.ScopedFunc)
    if isexpr(x.func, :function) || isexpr(x.func, :(=))
        sig = x.func.args[1]
        if isexpr(sig, :where)
            sig = sig.args[1]
        end
        if isexpr(sig, :call)
            if isexpr(sig.args[1], :.)
                # Handle: M.f() = ...
                maybe_push_rvar!(vars, sig.args[1].args[1])
            else
                maybe_push_lvar!(vars, sig.args[1])
            end
        end
    end
    global_variables!(vars, x.func.args[2])
    return vars
end

# function global_variables!(vars, x::JuliaVariables.GlobalVar)
#     push!(vars.right, assymbol(x))
#     return vars
# end

global_variables!(vars, x::JuliaVariables.ScopedVar) =
    maybe_push_rvar!(vars, x)

function global_variables!(vars, ex::Expr)
    if isexpr(ex, :(=))
        lvar = ex.args[1]
        if isexpr(lvar, :curly)
            lvar = lvar.args[1]
        end
        maybe_push_lvar!(vars, lvar)
        return global_variables!(vars, ex.args[2])
    elseif (isexpr(ex, :import) || isexpr(ex, :using))
        if isexpr(ex.args[1], :(:))
            # Add `x`, `y`, ... from `using M: x, y, ...`:
            args = [isexpr(x, :(.)) ? x.args[1] : x for x in ex.args[1].args[2:end]]
        else
            # Add `M` from `using M`:
            args = Any[ex.args[1].args[1]]
        end
        globals = Iterators.filter(isglobalvar, args)
        # globals = collect(globals)
        # @show globals
        mapfoldl(assymbol, push!, globals, init = vars.left)
        return vars
    elseif isexpr(ex, :struct)
        if isexpr(ex.args[2], :(<:))
            typeex = ex.args[2].args[1]
            global_variables!(vars, ex.args[2].args[2])
        else
            typeex = ex.args[2]
        end
        if isexpr(typeex, :curly)
            maybe_push_lvar!(vars, typeex.args[1])
        else
            maybe_push_lvar!(vars, typeex)
        end
        # It seems JuliaVariables detects fields as global variables.
        # Workaround it by not recursing inside.
        return vars
    elseif isexpr(ex, :abstract)
        lvar = ex.args[1]
        if isexpr(lvar, :<:)
            global_variables!(vars, lvar.args[2])
            lvar = lvar.args[1]
        end
        if isexpr(lvar, :curly)
            lvar = lvar.args[1]
        end
        maybe_push_lvar!(vars, lvar)
        return vars
    elseif isexpr(ex, :macro)
        # Macro arguments are treated as globals
        # https://github.com/thautwarm/JuliaVariables.jl/issues/10
        # So, let's not recurse into the expression manually.
        if isexpr(ex.args[1], :call)
            lvar = ex.args[1].args[1]
            if isglobalvar(lvar)
                s = assymbol(lvar)
                if !startswith(string(s), "@")
                    s = Symbol('@', s)
                end
                push!(vars.left, s)
            end
        end
        return vars
    elseif isexpr(ex, :macrocall)
        if ex.args[1] isa Symbol
            push!(vars.right, ex.args[1])
        end
    elseif isexpr(ex, :module)
        maybe_push_lvar!(vars, ex.args[2])
        # TODO: support sub-module
        # return vars
    elseif isexpr(ex, :.)
        return vars
    end
    return foldl(global_variables!, ex.args, init = vars)
end

global_variables(ex::Expr) = global_variables!((left = Set([]), right = Set([])), ex)
global_variables(code::AbstractString) = global_variables(vsolve(code))

merge_global_variables!(::Nothing, y) = y
function merge_global_variables!(x, y)
    union!(x.left, y.left)
    union!(x.right, y.right)
    return x
end

# TODO: handle submodules
module_variables(dir::AbstractString) = module_variables(sort!(jlfiles(dir)))
function module_variables(paths::AbstractVector{<:AbstractString})
    return mapfoldl(merge_global_variables!, paths; init = nothing) do p
        # @debug "Analyzing $p"
        try
            global_variables(read(p, String))
        catch err
            @error(
                "global_variables(read($(repr(p)), String))",
                exception = (err, catch_backtrace()),
            )
            global_variables("")
        end
    end
end

function module_variables(pkg::Base.PkgId)
    path = Base.locate_package(pkg)
    return module_variables(dirname(path))
end

function depsvars_from_tomlpath(tomlpath, imported_modules = ())
    deps = get(TOML.parsefile(tomlpath), "deps", Dict{String,Any}())
    if !isempty(imported_modules)
        imported_modules = unique(String.(imported_modules))
        notfound = setdiff(imported_modules, keys(deps))
        if !isempty(notfound)
            @warn "Packages not found in `$tomlpath`:\n$(join(notfound, "\n"))"
        end
        deps = filter(deps) do (pkgname, _)
            pkgname in imported_modules
        end
    end
    return depsvars_from_deps(deps)
end

function depsvars_from_deps(deps)
    depsvars = []
    for (pkgname, pkguuid) in deps
        pkg = Base.PkgId(Base.UUID(pkguuid), pkgname)
        @debug "Analyzing $pkg..."
        push!(depsvars, (pkg, module_variables(pkg)))
    end
    sort!(depsvars, by = ((pkg, _),) -> pkg.name)
    # TODO: make it `export`-aware
    return depsvars
end

__imported_modules(_) = Symbol[]
function __imported_modules(ex::Expr)::Vector{Symbol}
    @match ex begin
        :(using $name:$(_...)) || :(import $name:$(_...)) => return [name]
        :(using $name) || :(import $name) => [name]

        # Handle: using A.B: C, D
        :(using $(names...):$(_...)) || :(import $(names...):$(_...)) => [names[1]]
        Expr(:using, Expr(:(:), x, _...)) || Expr(:import, Expr(:(:), x, _...)) => begin
            @match x begin
                Expr(:., name, _...) => [name]
                Expr(:., :., _...) => []  # using .A: B
                _ => error("Unexpected `using`/`import` argument `$x` in:\n", ex)
            end
        end

        # Handle: using A.B.C.D
        :(using $(names...)) || :(import $(names...)) => [names[1]]

        # Handle: using A, B.C, D
        Expr(:using, args...) || Expr(:import, args...) => begin
            map(args) do x
                @match x begin
                    Expr(:., name, _...) => name
                    _ => error("Unexpected `using`/`import` argument `$x` in:\n", ex)
                end
            end
        end

        # Recurse:
        _ => mapreduce(__imported_modules, vcat, ex.args; init = Symbol[])
    end
end

_imported_modules(code::AbstractString) = __imported_modules(parse_ast(code))

imported_modules(ex::Expr) = __imported_modules(ex)
imported_modules(path::AbstractString) = _imported_modules(read(path, String))
imported_modules(paths::AbstractVector{<:AbstractString}) =
    mapreduce(imported_modules, vcat, paths; init = Symbol[])
