"""
    autoimports(pkgdir::AbstractString)
    autoimports(paths::AbstractString...)
    autoimports(paths::AbstractVector{<:AbstractString})

# Keyword Arguments
- `project::AbstractString`
- `dry_run::Bool = false`: Do not write to files (imples `verbose=true`).
- `verbose::Bool = false`: Print operations to be performed.
- `sort::Bool = true`: Sort `using`s and `import`s.
"""
autoimports(pkgdir::AbstractString = find_pkgdir(); kwargs...) = autoimports(
    isdir(pkgdir) ? sort!(jlfiles(joinpath(pkgdir, "src"))) : [pkgdir];
    project = isdir(pkgdir) ? joinpath(pkgdir, "Project.toml") : Base.active_project(),
    kwargs...,
)

module __EmptyModule end

unbound_vars_for(vars) = setdiff(
    vars.right,
    vars.left,
    names(Base),
    names(Core),
    names(__EmptyModule; all = true),
)

function _sortnames!(formatted, paths)

#! format: off
    files = sorted_files!(
        let code = get(formatted, p, nothing)
            code === nothing ? SourceCode(p) : SourceCode(p, code)
        end
        for p in paths
    )
#! format: on

    for (p, code) in format_files_to_dict(files)
        formatted[p] = code
    end
    # Note: not using the result of `format_files_to_dict(files)`
    # directly to avoid skipping edits existing in `formatted`.

    return formatted
end

function _write_formatted(formatted; dry_run, verbose)
    if verbose
        @info "Updating files..." files = sort!(collect(keys(formatted)))
    end

    dry_run && return

    # Write results to files
    for (p, code) in formatted
        write(p, code)
    end
end

function autoimports(
    paths::AbstractArray{<:AbstractString};
    project::AbstractString = Base.active_project(),
    dry_run::Bool = false,
    verbose::Bool = false,
    sort::Bool = true,
)
    verbose = verbose | dry_run

    if verbose
        @info "Analyzing and modifying $(length(paths)) files." project sort dry_run
    end
    if !occursin("AutoImports", ENV["JULIA_DEBUG"])
        ENV["JULIA_DEBUG"] = ENV["JULIA_DEBUG"] * ",AutoImports"
    end
    @debug "Debug logging enabled" ENV["JULIA_DEBUG"]

    # Find unbound variables
    vars = module_variables(paths)
    unbound_vars = unbound_vars_for(vars)
    @debug "Unbound variables found" unbound_vars = Text(join(unbound_vars, ", "))

    # List variables defined in deps
    depsvars = depsvars_from_tomlpath(project, imported_modules(paths))

    # Find packages that define `unbound_vars`
    tobeimported = Dict{Base.PkgId,Vector{Symbol}}()
    for v in unbound_vars
        for (pkg, dvars) in depsvars
            if v in dvars.left
                push!(get!(tobeimported, pkg, []), v)
                @goto ok
            end
        end
        @warn "Variable `$v` not found anywhere."
        @label ok
    end
    isempty(tobeimported) && return sortnames(paths; dry_run = dry_run, verbose = verbose)

    if verbose
        import_texts = sprint() do io
            for (pkg, vars) in sort!(
                collect(tobeimported),
                by = ((pkg, _),) -> pkg.name,
            )
                print(io, "using $(pkg.name): ")
                join(io, vars, ", ")
                println(io)
            end
        end
        @info """
        Required explicit imports:
        $import_texts"""
    end

    @debug "Adding explicit imports..." tobeimported
    files = add_using!(paths, tobeimported)

    formatted = format_files_to_dict(files)

    if sort
        _sortnames!(formatted, paths)
    end

    _write_formatted(formatted; dry_run = dry_run, verbose = verbose)
end

"""
    sortnames(path::AbstractString = ".")
    sortnames(paths::AbstractString...)
    sortnames(paths::AbstractVector{<:AbstractString})

# Keyword Arguments
- `dry_run::Bool = false`: Do not write to files (imples `verbose=true`).
- `verbose::Bool = false`: Print operations to be performed.
"""
sortnames(path::AbstractString = "."; kwargs...) =
    sortnames(isdir(path) ? sort!(jlfiles(path)) : [path]; kwargs...)

function sortnames(
    paths::AbstractArray{<:AbstractString};
    dry_run::Bool = false,
    verbose::Bool = false,
)
    verbose = verbose | dry_run
    formatted = _sortnames!(Dict{String,String}(), paths)
    _write_formatted(formatted; dry_run = dry_run, verbose = verbose)
end

@nospecialize
autoimports(paths::AbstractString...; kwargs...) = autoimports(collect(paths); kwargs...)
sortnames(paths::AbstractString...; kwargs...) = sortnames(collect(paths); kwargs...)
@specialize

sortnames_text(code::AbstractString) = sprint(sortnames_text, code)
function sortnames_text(io::IO, code::AbstractString)
    f = sort_names!(SourceCode("<string>", code))
    format_code(io, f)
end
