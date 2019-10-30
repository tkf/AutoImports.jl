struct Edit
    offset::Int
    span::Int
    content::String
end

struct SourceCode
    path::String
    content::String
    cst::CSTParser.EXPR
    edits::Vector{Edit}
end

SourceCode(path, content, cst) = SourceCode(path, content, cst, [])
function SourceCode(path, content)
    cst, ps = CSTParser.parse(CSTParser.ParseState(content), true)
    return SourceCode(path, content, cst)
end
SourceCode(path) = SourceCode(path, read(path, String))

newusing(pkgname, allvars) = format_text("using $pkgname: $(join(allvars, ", "))")
newimport(pkgname, allvars) = format_text("import $pkgname: $(join(allvars, ", "))")

isimportable(cst) = cst.typ !== CSTParser.PUNCTUATION

ascode(cst::CSTParser.EXPR) =
    if cst.typ === CSTParser.MacroName
        @assert cst.args[1].kind === Tokens.AT_SIGN
        x = cst.args[2]
        if x.typ == CSTParser.IDENTIFIER
            "@" * x.val
        elseif x.typ == CSTParser.OPERATOR
            string('@', Tokens.UNICODE_OPS_REVERSE[x.kind])
        end
    elseif cst.typ === CSTParser.IDENTIFIER
        cst.val
    elseif cst.typ === CSTParser.OPERATOR
        String(Tokens.UNICODE_OPS_REVERSE[x.kind])
    end

function comma_separated_names(args::Vector{CSTParser.EXPR})
    strs = map(ascode, filter(isimportable, args))
    all(x -> x isa AbstractString, strs) || return nothing
    return strs
end

function importednames(cst::CSTParser.EXPR)::Union{Nothing,Vector{String}}
    @assert cst.typ in (CSTParser.Using, CSTParser.Import)
    i = findfirst(x -> x.kind == Tokens.COLON, cst.args)
    if i === nothing
        if findfirst(x -> x.kind == Tokens.DOT, cst.args) === nothing
            return [cst.args[2].val]  # Handle: using A
        end
        x = cst.args[end]
        if x.typ == CSTParser.IDENTIFIER
            return [x.val]  # Handle: using A.B
        end
    else
        return comma_separated_names(cst.args[i+1:end])
    end
    return nothing
end

_add_using_vars!(f::SourceCode, tobeimported) = _add_using_vars!(f, f.cst, 1, tobeimported)
function _add_using_vars!(f::SourceCode, ex, offset, tobeimported)
    modified = false
    if ex.typ == CSTParser.Using
        for (pkg, vars) in collect(tobeimported)
            if ex.args[2].val == pkg.name
                allvars = sort!(append!(String.(vars), importednames(ex)))
                e = Edit(offset, ex.span, newusing(pkg.name, allvars))
                push!(f.edits, e)
                pop!(tobeimported, pkg)
                modified = true
                break
            end
        end
        # if !modified
        #     vars = importednames(ex)
        #     if vars !== nothing && !issorted(vars)
        #         e = Edit(offset, ex.span, newusing(ex.args[2].val, sort(vars)))
        #         push!(f.edits, e)
        #         modified = true
        #     end
        # end
    else
        for sub in something(ex.args, ())
            modified |= _add_using_vars!(f, sub, offset, tobeimported)
            offset += sub.fullspan
            # # Commented out to sort existing imports:
            # # isempty(tobeimported) && break
        end
    end
    return modified
end

function new_using_vars!(f::SourceCode, tobeimported)
    ex = f.cst::CSTParser.EXPR
    @assert ex.typ == CSTParser.FileH
    i0 = findfirst(ex.args) do x
        x.typ == CSTParser.Using
    end
    if i0 === nothing
        inew = 1
    else
        i1 = findfirst(ex.args[i0+1:end]) do x
            x.typ != CSTParser.Using
        end
        inew = i0 + something(i1, 1)
    end

    offset = 1 + sum(x.fullspan for x in ex.args[1:inew-1])
    lines = map((pkg, vars) -> newusing(pkg.name, sort(vars)), tobeimported)
    push!(f.edits, Edit(offset, 0, join(lines, "\n")))

    empty!(tobeimported)
    return
end

function add_using!(paths::AbstractVector{<:AbstractString}, tobeimported)
    files = SourceCode[]
    local f1
    for (i, p) in enumerate(paths)
        f = SourceCode(p)
        if _add_using_vars!(f, tobeimported)
            push!(files, f)
        end
        if i == 1
            f1 = f
        end
        isempty(tobeimported) && break
    end

    # Add new `using` statements
    if !isempty(tobeimported)
        new_using_vars!(f1, tobeimported)
        if files[1] !== f1
            pushfirst!(files, f1)
        end
    end

    return files
end

format_code(f::SourceCode) = sprint(format_code, f)
function format_code(io, f::SourceCode)
    @assert all(diff([e.offset for e in f.edits]) .> 1)
    cursor = 1
    for e in f.edits
        # @show e.offset e.content
        # print(f.content[cursor:e.offset-1])
        # println()
        # println("---")
        # print(f.content[e.offset:e.offset+e.span-1])
        # println()
        # println("===")
        # print(e.content)
        # println()
        # println("^^^")
        print(io, f.content[cursor:e.offset-1])
        print(io, e.content)
        cursor = e.offset + e.span
    end
    print(io, f.content[cursor:end])
end

function format_files_to_dict(files)
    formatted = Dict{String,String}()
    for f in files
        formatted[f.path] = format_code(f)
    end
    return formatted
end

function Base.print(io::IO, f::SourceCode)
    printstyled(io, "---a/", f.path, '\n'; color=:red)
    printstyled(io, "+++b/", f.path, '\n'; color=:green)
    offset = 1
    for e in f.edits
        eend = e.offset+e.span-1

        printstyled(io, "@@\n"; color=:cyan)
        aend = something(findnext('\n', f.content, eend), lastindex(f.content))
        atxt = f.content[e.offset:aend]
        for line in split(atxt, '\n')
            printstyled(io, '+', line, '\n'; color=:red)
        end

        btxt = string(e.content, f.content[eend+1:aend])
        for line in split(btxt, '\n')
            printstyled(io, '-', line, '\n'; color=:green)
        end

        offset += e.span
    end
end
