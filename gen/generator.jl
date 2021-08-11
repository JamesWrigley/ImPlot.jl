using Clang.Generators
using ExprTools, MacroTools, JSON3
# using ImPlot.LibCImPlot.CImPlot_jll
using CImGui.CImGui_jll

cd(@__DIR__)

const CIMGUI_INCLUDE_DIR = joinpath(CImGui_jll.artifact_dir, "include")
const CIMPLOT_INCLUDE_DIR = @__DIR__
const CIMPLOT_H = normpath(@__DIR__, "cimplot_patched.h")

options = load_options(joinpath(@__DIR__, "generator.toml"))

args = get_default_args()
pushfirst!(args, "-DCIMGUI_DEFINE_ENUMS_AND_STRUCTS")
pushfirst!(args, "-isystem$CIMGUI_INCLUDE_DIR")
push!(args, "-I$CIMPLOT_INCLUDE_DIR")

# add definitions
@add_def ImVec2 
@add_def ImVec4
@add_def ImGuiMouseButton
@add_def ImGuiKeyModFlags
@add_def ImS8 
@add_def ImU8
@add_def ImS16 
@add_def ImU16 
@add_def ImS32 
@add_def ImU32
@add_def ImS64 
@add_def ImU64 
@add_def ImTextureID 
@add_def ImGuiCond 
@add_def ImGuiDragDropFlags 
@add_def ImDrawList 
@add_def ImGuiContext

imdatatypes = [:Cfloat, :Cdouble, :ImS8, :ImU8, :ImS16, :ImU16, :ImS32, :ImU32, :ImS64, :ImU64]
jldatatypes = [:Float32, :Float64, :Int8, :UInt8, :Int16, :UInt16, :Int32, :UInt32, :Int64, :UInt64] 

imtojl_lookup = Dict(zip(imdatatypes, jldatatypes))
jltoim_lookup = Dict(zip(jldatatypes, imdatatypes))

plot_types = ["Line", "Scatter", "Stairs", "Shaded", "BarsH", "Bars", "ErrorBarsH",
              "ErrorBars", "Stems", "VLines", "HLines", "PieChart", "Heatmap", "Histogram",
              "Histogram2D", "Digital"]

ctx = create_context(CIMPLOT_H, args, options)
build!(ctx, BUILDSTAGE_NO_PRINTING)

json_string = read("assets/definitions.json", String);
metadata = JSON3.read(json_string);

function split_ccall(body)
    local funsymbol, rettype, argtypes, argnames
    for ex in body.args
        @capture(ex, ccall((funsymbol_, libcimplot), rettype_, (argtypes__,), argnames__)) && break
    end
    return (funsymbol, rettype, argtypes, argnames)
end

function parse_default(T::DataType, str)
    str == "((void*)0" && return :C_NULL
    T <: Integer && return (startswith(str, "sizeof") ? :(sizeof($T)) : Meta.parse(str))
    T <: AbstractFloat && return Meta.parse(str) 
    T <: Cstring && return str
    T <: Bool && return Meta.parse(str)
    T <: Symbol && return Symbol(str)
    return nothing
end

function make_plotmethod(def, metadata)

    def[:name] = Symbol(metadata.funcname)
    (funsymbol, rettype, argtypes, argnames) = split_ccall(def[:body]) 
    fun_args = def[:args]

    for (i, argtype) in enumerate(argtypes)
        sym = argnames[i]
        if @capture(argtype, Ptr{ptrtype_}) && ptrtype ∈ imdatatypes
            def[:args][i] = :($sym::Union{Ptr{$ptrtype},Ref{$ptrtype},AbstractArray{$ptrtype}})
        elseif argtype ∈ (:Cint, :Clong, :Cshort, :Cushort, :Culong, :Cuchar, :Cchar)

            if length(metadata.defaults) > 0 && hasproperty(metadata.defaults, sym)
                val = parse_default(eval(argtype), getproperty(metadata.defaults,sym))
                def[:args][i] = :($( Expr(:kw, :($sym::Integer), val)) )

            else
                def[:args][i] = :($sym::Integer) 
            end

        elseif argtype ∈ (:Cfloat, :Cdouble)
            if length(metadata.defaults) > 0 && hasproperty(metadata.defaults, sym)
                val = parse_default(eval(argtype), getproperty(metadata.defaults,sym))
                def[:args][i] = :($( Expr(:kw, :($sym::Real), val)) )
            else
                def[:args][i] = :($sym::Real)
            end
        elseif argtype == :Cstring
            # Don't annotate string arguments--we want to be able to pass C_NULL
            if length(metadata.defaults) > 0 && hasproperty(metadata.defaults, sym)
                val = parse_default(eval(argtype), getproperty(metadata.defaults, sym))
                def[:args][i] = :($(Expr(:kw, sym, val)))
            end
        end
    end
    
    def[:body] = Expr(:block, 
                      :(ccall(($funsymbol, libcimplot), $rettype, ($(argtypes...),), $(argnames...))))
end             

function make_finalizer!(def, metadata)
    def[:name] = :(Base.finalizer)
    (funsymbol, rettype, argtypes, argnames) = split_ccall(def[:body]) 
    argtype = only(argtypes)
    argname = only(argnames)

    @capture(argtype, Ptr{ptrtype_})
    def[:args] = [:($argname::$ptrtype)]
    new_ccall = :(ccall(($funsymbol, libcimplot), $rettype, ($argtype,), $argname))
    def[:body] = Expr(:block, :(ptr = pointer_from_objref($argname)),
                      :(GC.@preserve $argname $new_ccall))
end

function make_constructor!(def, metadata)
    def[:name] = Symbol(metadata.stname)
    (funsymbol, rettype, argtypes, argnames) = split_ccall(def[:body])
    new_ccall = :(ptr = ccall(($funsymbol, libcimplot), $rettype, ($(argtypes...),), $(argnames...)))
    def[:body] = Expr(:block, new_ccall, :(unsafe_load(ptr)))
end

function make_objmethod!(def, metadata)
    def[:name] = Symbol(metadata.funcname)
end

function make_nonudt(def, metadata)
    def[:name] = Symbol(metadata.funcname)
    (funsymbol, rettype, argtypes, argnames) = split_ccall(def[:body])
    out_arg_type = first(argtypes)
    sym = popfirst!(def[:args]) 
    @capture(first(argtypes), Ptr{ptr_type_})
    def[:body] = Expr(:block,
                      :($sym = Ref($ptr_type)),
                      :(ccall(($funsymbol, libcimplot), $rettype, ($(argtypes...),), $(argnames...))),
                      :($sym[]))

    if length(propertynames(metadata.defaults)) > 0
        for (i, argtype) in enumerate(argtypes)
            sym = argnames[i]
            if hasproperty(metadata.defaults, sym)
                if argtype ∈ imdatatypes
                    val = parse_default(eval(imtojl_lookup[argtype]), getproperty(metadta.defaults, sym))
                    #HERE
            end
        end
    end  
end

function make_generic(def, metadata)
    def[:name] = Symbol(metadata.funcname)
    (funsymbol, rettype, argtypes, argnames) = split_ccall(def[:body])
    def[:body] = Expr(:block,
                      :(ccall(($funsymbol, libcimplot), $rettype, ($(argtypes...),), $(argnames...))))
    if length(propertynames(metadata.defaults)) > 0
        # parse default values
    end
end

function revise_function(ex::Expr, all_metadata, options) 
    def = ExprTools.splitdef(ex)
    
    # Skip Expr function names (e.g. :(Base.getproperty))
    def[:name] isa Symbol || return ex
    fun_name = String(def[:name])

    # Skip functions not in the JSON metadata
    any(startswith.(fun_name,String.(propertynames(all_metadata)))) || return ex
    
    local metadata
    # Find and extract metadata for specific cimplot function
    for objfield in all_metadata
        objvec = objfield.second
        idx = findfirst(x -> isequal(x.ov_cimguiname, fun_name), objvec)
        if !isnothing(idx)
            metadata = objvec[idx]
            break
        end
    end

    @isdefined(metadata) || throw("Could not find cimgui function in JSON metadata")
   
    # Check if it's for a type
    if metadata.stname !== ""
        # Skip constructors/destructors 
        if metadata.stname ∉ options["general"]["auto_mutability_blacklist"]
            if hasproperty(metadata, :destructor)
                make_finalizer!(def, metadata)
                return ExprTools.combinedef(def)
            elseif hasproperty(metadata, :constructor)
                # write contructor...
                make_constructor!(def, metadata)
                return ExprTools.combinedef(def)
            end
            # Fall through to object method
            make_objmethod!(def,metadata)
            return ExprTools.combinedef(def)
        end
    elseif startswith(metadata.funcname, "Plot")
        # Since Plot functions are templated, dispatch on pointer (data input) arguments
        make_plotmethod(def, metadata)
        return ExprTools.combinedef(def)
    elseif hasproperty(metadata, :nonUDT)

        # Pop the pOut argument and insert a Ref creation and unload...
        make_nonudt(def, metadata)
        return ExprTools.combinedef(def)

    else
        make_generic(def, metadata)
        out = ExprTools.combinedef(def)
        return out
    end
    @warn "function $(def[:name]) not parsed"
        return ex
end

function rewrite!(dag::ExprDAG, metadata, options)
    for node in get_nodes(dag)
        expressions = get_exprs(node)
        for (i, expr) in enumerate(expressions)
            if Meta.isexpr(expr, :function)
                    expressions[i] = revise_function(expr, metadata, options)
            end
        end
    end
end

ctx = create_context(CIMPLOT_H, args, options)
build!(ctx, BUILDSTAGE_NO_PRINTING)

rewrite!(ctx.dag, metadata, options)




build!(ctx, BUILDSTAGE_PRINTING_ONLY)


    #=
    # Strip off the prefix to match C++ (since we have a namespace)
    fun_name = fun_name[8:end] # remove first 7 characters == 'ImPlot_'

    # Plot functions are templated and have a regular structure
    if startswith(fun_name, "Plot")
        body = def[:body]
        fun_args= def[:args]
        new_body = MacroTools.postwalk(x -> carg_modify(x, fun_args), body)
        new_name = ""
        for ptype in plot_types
            fullname = "Plot" * ptype
            if startswith(fun_name, fullname)
                if length(fullname) > length(new_name)
                    new_name = fullname
                end
            end
        end
        def[:name] = Symbol(new_name)
        def[:args] = fun_args
        def[:body] = new_body
    end
    return ExprTools.combinedef(def)
    =#

