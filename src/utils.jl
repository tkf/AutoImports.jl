function jlfiles(dir::AbstractString)
    paths = String[]
    for n in readdir(dir)
        p = joinpath(dir, n)
        if isdir(p)
            append!(paths, jlfiles(p))
        elseif endswith(p, ".jl")
            push!(paths, p)
        end
    end
    return paths
end

function find_pkgdir(start::AbstractString = ".")
    dir = abspath(start)
    while true
        isfile(joinpath(dir, "Project.toml")) && return dir

        next = dirname(dir)
        next === dir && error("$start is not inside a Julia project.")
        dir = next
    end
end

zipoffsets(args, offset) =
    zip(args, insert!(cumsum([x.fullspan for x in args[1:end-1]]), 1, 0) .+ offset)
