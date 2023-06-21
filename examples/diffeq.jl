using IPUToolkit.IPUCompiler
using IPUToolkit.Poplar
using DiffEqGPU
using StaticArrays
using OrdinaryDiffEq
using Plots

function lorenz(u, p, t)
    σ = p[1]
    ρ = p[2]
    β = p[3]
    du1 = σ * (u[2] - u[1])
    du2 = u[1] * (ρ - u[3]) - u[2]
    du3 = u[1] * u[2] - β * u[3]
    return SVector{3}(du1, du2, du3)
end

ENV["POPLAR_RUNTIME_OPTIONS"] = """{"target.hostSyncTimeout":"60"}"""

IPUCompiler.PROGRESS_SPINNER[] = false

device = Poplar.get_ipu_device()
target = Poplar.DeviceGetTarget(device)
graph = Poplar.Graph(target)

num_tiles = Int(Poplar.TargetGetNumTiles(target))
tiles = 0:(num_tiles - 1)

# Create a range of different input parameters
p = let
    σ = repeat(range(0f0; step=0.2f0, length=64); inner=23)
    ρ = repeat(range(10f0; step=1f0, length=23); outer=64)
    β = repeat([8f0 / 3f0], num_tiles)
    zip(σ, ρ, β) |> Iterators.flatten |> collect
end
# Output arrays
n = 10000
u1 = Vector{Float32}(undef, n * num_tiles)
u2 = Vector{Float32}(undef, n * num_tiles)

# Define kernel
@codelet graph function solve_lorenz(u1::VertexVector{Float32, Out},
                                     u2::VertexVector{Float32, Out},
                                     p::VertexVector{Float32, In})
    u0 = @SVector [1f0; 0f0; 0f0]
    svp = @inbounds SVector{3, Float32}(p)
    integ = DiffEqGPU.init(GPUTsit5(), lorenz, false, u0, 0f0, 0.005f0, svp, nothing, CallbackSet(nothing), true, false)
    for idx in eachindex(u1, u2)
        DiffEqGPU.step!(integ, integ.t + integ.dt, integ.u)
        u1[idx] = integ.u[1]
        u2[idx] = integ.u[2]
    end
    return nothing
end

# Input and output tensors on the IPU
p_ipu =  Poplar.GraphAddConstant(graph, p)
u1_ipu = Poplar.GraphAddVariable(graph, Poplar.FLOAT(), UInt64[n * num_tiles], "u1")
u2_ipu = Poplar.GraphAddVariable(graph, Poplar.FLOAT(), UInt64[n * num_tiles], "u2")

prog = Poplar.ProgramSequence()

# Run the codelet defined above on all tiles, with tensors evenly spread across all cores.
add_vertex(graph, prog, tiles, solve_lorenz, u1_ipu, u2_ipu, p_ipu)

# Prepare tensors read
Poplar.GraphCreateHostRead(graph, "u1-read", u1_ipu)
Poplar.GraphCreateHostRead(graph, "u2-read", u2_ipu)

# Run the program
engine = Poplar.Engine(graph, prog)
Poplar.EngineLoadAndRun(engine, device)

# Read the output tensors back to the CPU
Poplar.EngineReadTensor(engine, "u1-read", u1)
Poplar.EngineReadTensor(engine, "u2-read", u2)

Poplar.DeviceDetach(device)
