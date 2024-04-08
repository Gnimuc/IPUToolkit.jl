# based on GPUCompiler example https://github.com/JuliaGPU/GPUCompiler.jl/blob/master/examples/kernel.jl
module IPUCompiler

export @codelet, @ipuprogram, VertexVector, VertexScalar, In, Out, InOut, get_scount_l, get_tile_id, randn2!, add_vertex

include("output.jl")

using GPUCompiler
using ..Poplar

# list of overrides (only for Julia 1.6)
const overrides = Expr[]

# Colossus backend
struct Colossus <: AbstractCompilerTarget
end
GPUCompiler.llvm_triple(::Colossus) = "colossus-graphcore-unknown-elf"
GPUCompiler.runtime_slug(j::CompilerJob{Colossus}) = j.config.params.kernel_name

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
    return esc(:( Base.Experimental.@overlay($method_table, $ex) ))
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

# Functions needed by the runtime
"""
    get_scount_l()

Call the [`__builtin_ipu_get_scount_l()`](https://docs.graphcore.ai/projects/poplar-api/en/latest/ipu_intrinsics/ipu_builtins.html#_CPPv426__builtin_ipu_get_scount_lv) builtin:

> Get the value of the control/status register (CSR) `SCOUNT_L`, which is the lower 32 bits of the tile cycle counter value.
"""
function get_scount_l end
"""
    get_tile_id()

Call the [`__builtin_ipu_get_tile_id()`](https://docs.graphcore.ai/projects/poplar-api/en/latest/ipu_intrinsics/ipu_builtins.html#_CPPv425__builtin_ipu_get_tile_idv) builtin:

> Get the tile ID of the current tile.
"""
function get_tile_id end

"""
    randn2!(v::VertexVector) -> v

Fill the vector `v` with normally-distributed (mean 0, standard deviation 1) random numbers.
The vector *must* have even length.
This function takes advantage of [IPU builtins for random number generation](https://docs.graphcore.ai/projects/poplar-api/en/latest/ipu_intrinsics/ipu_builtins.html#random-number-generation), which return pairs of numbers at a time.
"""
function randn2! end

include("vertices.jl")
include("runtime.jl")

GPUCompiler.runtime_module(::CompilerJob{<:Any,IPUCompilerParams}) = IPURuntime
# `GPUCompiler.isintrinsic` specifies functions which are to be considered intrinsics for
# the current job, and so don't have to be validated by the compilation pipeline.  We set
# `getVec$(kernel_name)` to be considered intrinsic, as this is implemented in the
# accompanying C++ codelet, so outside of the LLVM IR generated by GPUCompiler.
GPUCompiler.isintrinsic(@nospecialize(job::CompilerJob{<:Any,IPUCompilerParams}), fn::String) =
    contains(fn, Regex("^get_vec_(ptr|size)_" * job.config.params.kernel_name * "\$")) ||
    fn ∈ ("printf", "puts", "tanf") || startswith(fn, "_llvm_colossus_")

include("codelet.jl")
include("tensors.jl")
include("program.jl")
include("timing.jl")

function add_vertex(graph::Poplar.GraphAllocated,
                    compute_set::Poplar.ComputeSetAllocated,
                    tiles::Union{Integer,AbstractVector{<:Integer}},
                    codelet::Function,
                    args::Union{Number,Poplar.TensorAllocated}...)
    meths = methods(codelet)
    num_tiles = length(tiles)
    # Get the names of the arguments of the codelet.
    arg_names = string.(Base.method_argnames(meths[begin])[2:end])
    # Arguments validation
    if length(meths) != 1
        throw(ArgumentError("Function $(codelet) does not have exactly one method.  Use a different function which has a method only."))
    end
    if length(arg_names) != length(args)
        throw(ArgumentError("Function $(codelet) takes $(length(arg_names)) arguments but you passed $(length(args)) arguments for this vertex."))
    end
    for (arg_n, arg) in enumerate(args)
        if length(arg) < num_tiles
            throw(ArgumentError("The argument #$(arg_n) to $(codelet) has $(length(arg)) elements, which is less than the number of tiles ($(num_tiles))"))
        end
    end

    for (idx, tile) in enumerate(tiles)
        # Create a vertex on each tile
        vertex = Poplar.GraphAddVertex(graph, compute_set, string(codelet))

        # Evenly spread the arrays over all tiles.
        for (arg_n, arg) in enumerate(args)
            arg_slice = if num_tiles > 1 && arg isa Poplar.TensorAllocated
                stride = cld(length(arg), num_tiles)
                slice = (stride * (idx - 1)):min(length(arg) - 1, (stride * idx - 1))
                arg[slice]
            else
                arg
            end
            if arg isa Poplar.TensorAllocated
                Poplar.GraphSetTileMapping(graph, arg_slice, tile)
            end
            Poplar.GraphConnect(graph, vertex[arg_names[arg_n]], arg_slice)
        end

        # Add the vertex on the tile
        Poplar.GraphSetTileMapping(graph, vertex, tile)

        # TODO: allow setting the perf estimate of the vertex.
        if Poplar.SDK_VERSION < v"2.0"
            Poplar.GraphSetCycleEstimate(graph, vertex, 1)
        else
            Poplar.GraphSetPerfEstimate(graph, vertex, 1)
        end
    end
    return nothing
end

function add_vertex(graph::Poplar.GraphAllocated,
                    program::Poplar.ProgramSequenceAllocated,
                    tiles::Union{Integer,AbstractVector{<:Integer}},
                    codelet::Function,
                    args::Union{Number,Poplar.TensorAllocated}...)
    compute_set = Poplar.GraphAddComputeSet(graph, string(codelet))
    add_vertex(graph, compute_set, tiles, codelet, args...)
    Poplar.ProgramSequenceAdd(program, Poplar.ProgramExecute(compute_set))
    return nothing
end

add_vertex(graph::Poplar.GraphAllocated, compute_set::Poplar.ComputeSetAllocated,
           codelet::Function, args::Union{Number,Poplar.TensorAllocated}...) =
               add_vertex(graph, compute_set, 0, codelet, args...)
add_vertex(graph::Poplar.GraphAllocated, program::Poplar.ProgramSequenceAllocated,
           codelet::Function, args::Union{Number,Poplar.TensorAllocated}...) =
               add_vertex(graph, program, 0, codelet, args...)

"""
    add_vertex(graph::Poplar.GraphAllocated,
               compute_set_or_program::Union{Poplar.ComputeSetAllocated, Poplar.ProgramSequenceAllocated},
               [tiles::Union{Integer,AbstractVector{<:Integer}},]
               codelet::Function,
               args::Union{Number,Poplar.TensorAllocated}...) -> Nothing

Add the codelet function `codelet` created with [`@codelet`](@ref) to `graph`, using the tensors `args` as arguments.
The function `codelet` must have exactly one method, no more, no less.
The second argument can be either the program or the compute set to which to add the new vertex/vertices.
If a program is passed, a new compute set will be automatically created.

`add_vertex` also evenly maps all tensors and vertices across all `tiles`, which can be either a single tile ID or an `AbstractVector` of IDs and defaults to single tile 0 if this argument is omitted.
Note that all argument tensors `args` must be longer than or equal to the number of `tiles`.
If you want to have better control over tile mapping, use `Poplar.GraphAddVertex` instead.
"""
add_vertex

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
    v"3.1.0" => v"15.0.0",
    v"3.2.0" => v"15.0.0",
    v"3.3.0" => v"16.0.0",
)

function __init__()
    @static if get(POPLAR_SDK_LLVM_MAPPING, Base.thisminor(Poplar.SDK_VERSION), v"0") != Base.thismajor(Base.libllvm_version)
        sdk_llvm_version = get(POPLAR_SDK_LLVM_MAPPING, Base.thisminor(Poplar.SDK_VERSION), "UNKNOWN")
        if sdk_llvm_version == "UNKNOWN" && !isnothing(Sys.which("popc"))
            sdk_llvm_version = match(r"clang version ([\d.]+)", readchomp(`popc --version`))[1]
        end
        @warn """
              You are using Poplar SDK v$(Poplar.SDK_VERSION) which is coupled to LLVM v$(sdk_llvm_version), but your Julia uses LLVM v$(Base.libllvm_version).
              IPUCompiler code generation may not work correctly.
              """
    end
end

end # module IPUCompiler
