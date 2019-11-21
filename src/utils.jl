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

function firstmatch(f, xs)
    for x in xs
        f(x) && return Some(x)
    end
    return nothing
end

ifnothing(f) = x -> ifnothing(f, x)
ifnothing(f, ::Nothing) = f()
ifnothing(_, x) = something(x)

_project_toml_path_from_dir(project) =
    firstmatch(
        isfile,
        (
         # Candidate locations of project TOML file:
         joinpath(project, "Project.toml"),
         joinpath(project, "JuliaProject.toml"),
        ),
    ) |> ifnothing() do
        error(
            "Directory `$project` does not have a `Project.toml` or",
            " `JuliaProject.toml` file.",
        )
    end

as_project_toml_path(project) =
    if isdir(project)
        _project_toml_path_from_dir(project)
    elseif basename(project) ∈ ("Manifest.toml", "JuliaManifest.toml")
        _project_toml_path_from_dir(dirname(project))
    else
        project
    end
