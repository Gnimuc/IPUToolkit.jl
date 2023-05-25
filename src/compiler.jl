# based on GPUCompiler example https://github.com/JuliaGPU/GPUCompiler.jl/blob/master/examples/kernel.jl
module IPUCompiler

export @codelet, @ipuprogram, PoplarTensor, PoplarVector, PoplarMatrix, In, Out, InOut

include("output.jl")

using GPUCompiler
using ..Poplar

# list of overrides (only for Julia 1.6)
const overrides = Expr[]

struct IPUCompilerParams <: AbstractCompilerParams
    kernel_name::String
end

# local method table for device functions
@static if isdefined(Base.Experimental, Symbol("@overlay"))
Base.Experimental.@MethodTable(method_table)
else
const method_table = nothing
end
# the method table to use
GPUCompiler.method_table(::CompilerJob{<:Any,IPUCompilerParams}) = method_table

macro device_override(ex)
    ex = macroexpand(__module__, ex)
    if Meta.isexpr(ex, :call)
        ex = eval(ex)
        error()
    end
    code = quote
        $GPUCompiler.@override($method_table, $ex)
    end
    if isdefined(Base.Experimental, Symbol("@overlay"))
        return esc(code)
    else
        push!(overrides, code)
        return
    end
end

macro device_function(ex)
    ex = macroexpand(__module__, ex)
    def = splitdef(ex)

    # generate a function that errors
    def[:body] = quote
        error("This function is not intended for use on the CPU")
    end

    esc(quote
        $(combinedef(def))
        @device_override $ex
    end)
end

include("runtime.jl")
include("tensors.jl")

GPUCompiler.runtime_module(::CompilerJob{<:Any,IPUCompilerParams}) = IPURuntime
# `GPUCompiler.isintrinsic` specifies functions which are to be considered intrinsics for
# the current job, and so don't have to be validated by the compilation pipeline.  We set
# `getVec$(kernel_name)` to be considered intrinsic, as this is implemented in the
# accompanying C++ codelet, so outside of the LLVM IR generated by GPUCompiler.
GPUCompiler.isintrinsic(@nospecialize(job::CompilerJob{<:Any,IPUCompilerParams}), fn::String) =
    contains(fn, Regex("^get_vec_(ptr|size)_" * job.config.params.kernel_name * "\$")) ||
    fn ∈ ("printf", "puts", "tanf")

function _codelet(graph, usr_kern::Expr)
    if usr_kern.head ∉ (:function, :(=)) || usr_kern.args[1].head !== :call
        throw(ArgumentError("@codelet takes a named function definition in input"))
    end

    name = usr_kern.args[1].args[1]
    args = usr_kern.args[1].args[2:end]
    codelet_fun = gensym(name)
    func_ptr = "extern get_vec_ptr_" * String(name)
    func_size = "extern get_vec_size_" * String(name)
    i = Int32(-1)
    kernargs = [
        # TODO: I'd really like to avoid that `getfield`.
        esc(:(
            $(arg.args[2])( # PoplarTensor{T,N,S}
                $(Expr(:call, :ccall, func_ptr,  :llvmcall, Ptr{getfield(@__MODULE__, arg.args[2].args[2])}, :((Int32,)), i += one(i))), # base::Ptr{T}
                (Int($(Expr(:call, :ccall, func_size, :llvmcall, UInt32,                                     :((Int32,)), i,      ))),), # size::NTuple{N,Int}.  TODO: make it work with N>1.
                $(Expr(:call, :ccall, func_size, :llvmcall, UInt32,                                          :((Int32,)), i,          )) # length::UInt32
                            )
        ))
        for arg in args]
    kern_call = Expr(:call, :($(esc(name))), kernargs...)

    return quote
        $(esc(usr_kern))
        function $(codelet_fun)()
            $(kern_call)
            return $(esc(nothing))
        end
        build_codelet($(esc(graph)), $(codelet_fun), $(String(name)), $(esc(name)))
    end
end

macro codelet(graph, usr_kern::Expr)
    return _codelet(graph, usr_kern)
end

# We have experienced some miscompilations of LLVM IR when using optimisation levels `-O1`
# or higher with old `popc`, especially v1.3-2.0.  So, we default to `-O0` with older
# versions, and `-O3` for newer versions.
const POPC_FLAGS = Poplar.SDK_VERSION ≥ v"2.2.0" ? `-g -O3` : `-g -O0`

_print_s(::Type{In}) = "Input"
_print_s(::Type{Out}) = "Output"
_print_s(::Type{InOut}) = "InOut"
_print_t(::Type{Int32}) = "int"
_print_t(::Type{Float16}) = "half"
_print_t(::Type{Float32}) = "float"
_print_vec(io::IO, ::Type{PoplarVector{T, S}}, name::String) where {T,S} = println(io, "poplar::", _print_s(S), "<poplar::Vector<", _print_t(T), ">> ", name, ";")

function build_codelet(graph, kernel, name, origKernel)
    target = NativeCompilerTarget()
    source = methodinstance(typeof(kernel), Tuple{})
    params = IPUCompilerParams(name)
    config = CompilerConfig(target, params)
    job = CompilerJob(source, config)
    llvm_ir = JuliaContext() do ctx
        string(GPUCompiler.compile(:llvm, job; ctx)[1])
    end

    method = methods(origKernel)[end]
    args = method.sig.parameters[2:end]
    argnames = string.(Base.method_argnames(method)[2:end])

    kernel_name = match(Regex("(_Z[\\d_]+$(name)[\\d_]+)"), llvm_ir)[1]

    # Create codelet file in temporary directory, so taht we don't pollute the
    # file system with codelet files everywhere.
    output_path = joinpath(mktempdir(), name * ".gp")

    mktempdir() do dir
        open(joinpath(dir, "gen_codelet.cpp"), "w") do io
            for i in 1:length(args)
                _print_vec(io, args[i], argnames[i])
            end
        end

        input_file = joinpath("$(name).ll")
        write(input_file, llvm_ir)

        run(```
            popc
            $(POPC_FLAGS)
            -X -Wno-override-module
            -X -Qunused-arguments
            -DGET_VEC_PTR_NAME=get_vec_ptr_$(name)
            -DGET_VEC_SIZE_NAME=get_vec_size_$(name)
            -DCLASS_NAME=$(name)
            -DFIRST_NAME=$(argnames[1])
            -DKERNEL_NAME=$(kernel_name)
            -I$(dir)
            $(input_file)
            $(joinpath(@__DIR__, "codelet_gen.cpp"))
            -o $(output_path)
            ```)
    end

    Poplar.GraphAddCodelets(graph, output_path)
    return nothing
end

function _get_name_args(expr::Expr)
    name = expr.args[1].args[1]
    args = [(arg.args[1], arg.args[2].args[2], arg.args[2].args[3]) for arg in expr.args[1].args[2:end]]
    return name, args
end

function _add_vertex!(initialised_tensors::Dict{Symbol, Symbol}, graph, prog, name_args::Dict, expr::Expr)
    # NOTE: this dictionary can't be `const` because the Poplar types like
    # `FLOAT()` have to be evaluated at runtime.
    jl_type_to_poplar_type = Dict(
        :Float32 => Poplar.FLOAT(),
    )

    name = expr.args[1]
    f_args = name_args[name]
    compute_set = string(name, "_compute_set")
    compute_set_sym = gensym(compute_set)
    vertex = gensym(Symbol(name, "_vertex"))
    out = quote
        $(esc(compute_set_sym)) = $(esc(Poplar.GraphAddComputeSet))($(esc(graph)), $(compute_set))
        $(esc(vertex)) = $(esc(Poplar.GraphAddVertex))($(esc(graph)), $(esc(compute_set_sym)), $(string(name)))
        $(esc(Poplar.GraphSetTileMapping))($(esc(graph)), $(esc(vertex)), 0) # <-- TOOD: let change the tile mapping
        # $(esc(Poplar.GraphSetPerfEstimate))($(esc(graph)), $(esc(vertex)), 1)
    end
    if length(expr.args) > 1
        for (idx, arg) in enumerate(expr.args[2:end])
            arg_info = f_args[idx]
            vec = gensym(arg_info[1])
            if arg ∉ keys(initialised_tensors)
                append!(out.args,
                        (quote
                             if $(esc(arg)) isa PoplarTensor
                                 $(esc(vec)) = $(esc(Poplar.GraphAddVariable))($(esc(graph)), $(esc(jl_type_to_poplar_type[arg_info[2]])), collect(UInt64.($(esc(arg)).size)), $(string(arg)))
                             elseif $(esc(arg)) isa Array
                                 $(esc(vec)) = $(esc(Poplar.GraphAddConstant))($(esc(graph)), $(esc(jl_type_to_poplar_type[arg_info[2]])), collect(UInt64.(size($(esc(arg))))), $(esc(arg)))
                             else
                                 error("`$(string(arg))` is a `$(typeof(esc(arg)))`, it must be either an `Array` or a `PoplarTensor`")
                             end
                             $(esc(Poplar.GraphSetTileMapping))($(esc(graph)), $(esc(vec)), 0) # <-- TODO: let change the tile mapping
                         end).args)
                initialised_tensors[arg] = vec
            end
            append!(out.args,
                    (quote
                         $(esc(Poplar.GraphConnect))($(esc(graph)), $(esc(vertex))[$(string(arg_info[1]))], $(esc(initialised_tensors[arg])))
                     end).args)
        end
    end
    append!(out.args,
            (quote
                 $(esc(Poplar.ProgramSequenceAdd))($(esc(prog)), $(esc(Poplar.ProgramExecute))($(esc(compute_set_sym))))
             end).args)
    return out
end

function _print_tensor(prog::Symbol, initialised_tensors::Dict{Symbol, Symbol}, expr::Expr)
    (length(expr.args) == 3 && expr.args[2] isa String && expr.args[3] isa Symbol) || error("""
        The `print_tensor` function must have as first argument a `String` and second argument the tensor name:
            print_tensor("Description", tensor_name)
        """)
    return quote
        $(esc(Poplar.ProgramSequenceAdd))($(esc(prog)), $(esc(Poplar.ProgramPrintTensor))($(expr.args[2]), $(esc(initialised_tensors[expr.args[3]]))))
    end
end

function _read_tensor(engine::Symbol, graph::Symbol, initialised_tensors::Dict{Symbol,Symbol}, expr::Expr)
    (length(expr.args) == 2 && expr.args[1] isa Symbol && expr.args[2] isa Symbol) || error("""
        Assignment can only be done between two variable names:
            jl_var = ipu_tensor
        where `jl_var` is a newly created Julia variable on the host, and `ipu_tensor` is the name of a tensor on the IPU.
        """)
    jl_var = expr.args[1]
    ipu_tensor = expr.args[2]
    read_name = string(ipu_tensor, "_read")
    return (:($(esc(Poplar.GraphCreateHostRead))($(esc(graph)), $(read_name), $(esc(initialised_tensors[ipu_tensor])))),
            quote
                $(esc(jl_var)) = $(esc(_similar))($(esc(ipu_tensor)))
                $(esc(Poplar.EngineReadTensor))($(esc(engine)), $(read_name), $(esc(jl_var)))
            end)
end

macro ipuprogram(device, program::Expr)
    program.head === :block || error("The second argument to the `@ipuprogram` macro must be a begin-end block")
    graph = gensym("graph")
    prog = gensym("prog")
    engine = gensym("engine")
    out = quote
        $(esc(graph)) = $(esc(Poplar.Graph))($(esc(Poplar.DeviceGetTarget))($(esc(device))))
        $(esc(prog)) = $(esc(Poplar.ProgramSequence))()
    end
    postamble = quote end
    name_args = Dict{Symbol,Any}()
    initialised_tensors = Dict{Symbol,Symbol}()
    for expr in program.args
        expr isa LineNumberNode && continue
        if expr.head ∈ (:function, :(=)) && (expr.args[1] isa Expr && expr.args[1].head === :call)
            append!(out.args, _codelet(graph, expr).args)
            na = _get_name_args(expr)
            name_args[na[1]] = na[2]
        elseif expr.head === :call
            if expr.args[1] === :print_tensor
                append!(out.args, _print_tensor(prog, initialised_tensors, expr).args)
            else
                append!(out.args, _add_vertex!(initialised_tensors, graph, prog, name_args, expr).args)
            end
        elseif expr.head == :(=)
            o, p = _read_tensor(engine, graph, initialised_tensors, expr)
            push!(out.args, o)
            append!(postamble.args, p.args)
        end
    end
    flags = gensym("flags")
    append!(out.args,
            (quote
                 $(esc(flags)) = Poplar.OptionFlags()
                 $(esc(Poplar.OptionFlagsSet))($(esc(flags)), "debug.instrument", "true")
                 $(esc(engine)) = $(esc(Poplar.Engine))($(esc(graph)), $(esc(prog)), $(esc(flags)))
                 $(esc(Poplar.EngineLoadAndRun))($(esc(engine)), $(esc(device)))
             end).args)
    append!(out.args, postamble.args)
    return out
end

# Mapping of the LLVM version used by each version of the Poplar SDK.  To find it, use `popc
# --version`.
const POPLAR_SDK_LLVM_MAPPING = Dict(
    v"1.3.0" => v"11.0.0",
    v"1.4.0" => v"11.0.0",
    v"2.0.0" => v"11.0.0",
    v"2.1.0" => v"13.0.0",
    v"2.2.0" => v"13.0.0",
    v"2.3.0" => v"14.0.0",
    v"2.4.0" => v"14.0.0",
    v"2.5.0" => v"14.0.0",
    v"2.6.0" => v"15.0.0",
    v"3.0.0" => v"15.0.0",
)

function __init__()
    sdk_llvm_version = POPLAR_SDK_LLVM_MAPPING[Base.thisminor(Poplar.SDK_VERSION)]
    if sdk_llvm_version != Base.thismajor(Base.libllvm_version)
        @warn """
              You are using Poplar SDK v$(Poplar.SDK_VERSION) which is coupled to LLVM v$(sdk_llvm_version), but your Julia uses LLVM v$(Base.libllvm_version).
              IPUCompiler code generation may not work correctly.
              """
    end
end

end # module IPUCompiler
