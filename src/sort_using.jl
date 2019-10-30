function contiguous_groups(f, xs)
    ys = []
    ingroup = false
    for x in xs
        ingroup, was_ingroup = f(x), ingroup
        if ingroup
            if !was_ingroup
                push!(ys, [])
            end
            push!(ys[end], x)
        end
    end
    return ys
end

function using_groups(f::SourceCode, cst::CSTParser.EXPR, offset)
    # Contiguous groups of `CSTParser.EXPR`s that are either `using`
    # or `import`:
    groups = contiguous_groups(zipoffsets(cst.args, offset)) do (x, o)
        x.typ in (CSTParser.Using, CSTParser.Import)
    end
    @assert all(diff(last.(Iterators.flatten(groups))) .> 1)

    # Further split the group by looking at the CSTs and checking they
    # contain trailing newlines:
    return Base.Generator(groups) do xs
        ys = [[xs[1]]]
        for x in xs[2:end]
            ex, offset = ys[end][end]
            if !(ex.span == ex.fullspan || f.content[offset+ex.span:offset+ex.fullspan-1] == "\n")
                push!(ys, [])
            end
            push!(ys[end], x)
        end
        return ys
    end |> Iterators.flatten
end

sort_using!(f::SourceCode) = sort_using!(f, f.cst, 1)
function sort_using!(f::SourceCode, cst::CSTParser.EXPR, offset)
    if cst.args === nothing
        return
    elseif !any(x -> x.typ in (CSTParser.Using, CSTParser.Import), cst.args)
        for x in cst.args
            sort_using!(f, x, offset)
            offset += x.fullspan
        end
        return
    end

    for group in using_groups(f, cst, offset)
        goffset = group[1][2]
        gspan = sum(x.fullspan for (x, _) in group)
        ending = let x = group[end][1], offset = group[end][2]
            f.content[offset+x.span+1:offset+x.fullspan-1]
        end
        usings = sort(
            group,
            by = ((x, _),) -> (
                # `import`s, and then `using`s:
                findfirst((CSTParser.Import, CSTParser.Using) .== x.typ)::Integer,
                # Sort by name:
                x.args[2].val,
            ),
        )
        content = sprint() do io
            for (x, offset) in usings
                vars = importednames(x)
                if vars !== nothing &&
                   findfirst(a -> a.kind == CSTParser.Tokens.COLON, x.args) === 3
                    # TODO: `using A.B: D, C` not handled due to `=== 3`
                    vars = sort(vars)
                    if x.typ == CSTParser.Using
                        println(io, newusing(x.args[2].val, vars))
                    else
                        println(io, newimport(x.args[2].val, vars))
                    end
                else
                    println(io, f.content[offset:offset+x.span-1])
                end
            end
            print(io, ending)
        end
        push!(f.edits, Edit(goffset, gspan, content))
    end
end

sort_export!(f::SourceCode) = sort_export!(f, f.cst, 1)
function sort_export!(f::SourceCode, cst::CSTParser.EXPR, offset)
    if cst.args === nothing
        return
    elseif !any(x -> x.typ === CSTParser.Export, cst.args)
        for x in cst.args
            sort_export!(f, x, offset)
            offset += x.fullspan
        end
        return
    end

    for (ex, offset) in zipoffsets(cst.args, offset)
        ex.typ === CSTParser.Export || continue
        ex.args[1].typ == CSTParser.KEYWORD || continue
        strs = comma_separated_names(ex.args[2:end])
        strs === nothing && continue
        content = format_text(string("export ", join(sort(strs), ", ")))
        push!(f.edits, Edit(offset, ex.span, content))
    end
end

function sort_names!(f::SourceCode)
    sort_using!(f)
    sort_export!(f)
    sort!(f.edits, by=x->x.offset)
    return f
end

function sorted_files!(input_files)
    output_files = SourceCode[]
    for f in input_files
        f = sort_names!(f)
        isempty(f.edits) || push!(output_files, f)
    end
    return output_files
end
