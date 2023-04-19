# based on GPUCompiler example https://github.com/JuliaGPU/GPUCompiler.jl/blob/master/examples/kernel.jl
module IPUCompiler

include("output.jl")

using GPUCompiler
using Match
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

function _codelet(graph, usr_kern)
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
            $(arg.args[2])($(Expr(:call, :ccall, func_ptr,  :llvmcall, Ptr{getfield(@__MODULE__, arg.args[2].args[2])}, :((Int32,)), i += one(i))),
                           $(Expr(:call, :ccall, func_size, :llvmcall, UInt32,                                          :((Int32,)), i,         )))
        ))
        for arg in args]
    kern_call = Expr(:call, :($(esc(name))), kernargs...)

    return quote
        let
            $(esc(usr_kern))
            function $(codelet_fun)()
                $(kern_call)
                return $(esc(nothing))
            end
            build_codelet($(esc(graph)), $(codelet_fun), $(String(name)), $(esc(name)))
        end
    end
end

macro codelet(graph, usr_kern)
    return _codelet(graph, usr_kern)
end

# We have experienced some miscompilations of LLVM IR when using optimisation levels `-O1`
# or higher with old `popc`, especially v1.3-2.0.  So, we default to `-O0` with older
# versions, and `-O3` for newer versions.
const POPC_FLAGS = Poplar.SDK_VERSION ≥ v"2.2.0" ? `-g -O3` : `-g -O0`

function build_codelet(graph, kernel, name, origKernel)
    target = NativeCompilerTarget()
    source = methodinstance(typeof(kernel), Tuple{})
    params = IPUCompilerParams(name)
    config = CompilerConfig(target, params)
    job = CompilerJob(source, config)
    llvm_ir = JuliaContext() do ctx
        string(GPUCompiler.compile(:llvm, job; ctx)[1])
    end

    args = methods(origKernel).ms[end].sig.parameters[2:end]
    # There doesn't seem to be a nicer way to do this
    argnames = split(methods(origKernel).ms[end].slot_syms, "\0")[2:methods(origKernel).ms[end].nargs]

    kernel_name = match(Regex("(_Z[\\d_]+$(name)[\\d_]+)"), llvm_ir)[1]

    # Create codelet file in temporary directory, so taht we don't pollute the
    # file system with codelet files everywhere.
    output_path = joinpath(mktempdir(), name * ".gp")

    mktempdir() do dir
        open(joinpath(dir, "gen_codelet.cpp"), "w") do io
            for i in 1:length(args)
                @match args[i] begin
                    PoplarVec{Int32, In} => println(io, "poplar::Input<poplar::Vector<int>> $(argnames[i]);")
                    PoplarVec{Float16, In} => println(io, "poplar::Input<poplar::Vector<half>> $(argnames[i]);")
                    PoplarVec{Float32, In} => println(io, "poplar::Input<poplar::Vector<float>> $(argnames[i]);")

                    PoplarVec{Int32, Out} => println(io, "poplar::Output<poplar::Vector<int>> $(argnames[i]);")
                    PoplarVec{Float16, Out} => println(io, "poplar::Output<poplar::Vector<half>> $(argnames[i]);")
                    PoplarVec{Float32, Out} => println(io, "poplar::Output<poplar::Vector<float>> $(argnames[i]);")

                    PoplarVec{Int32, InOut} => println(io, "poplar::InOut<poplar::Vector<int>> $(argnames[i]);")
                    PoplarVec{Float16, InOut} => println(io, "poplar::InOut<poplar::Vector<half>> $(argnames[i]);")
                    PoplarVec{Float32, InOut} => println(io, "poplar::InOut<poplar::Vector<float>> $(argnames[i]);")
                end
            end
        end

        input_file = joinpath(dir, "$(name).ll")
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
