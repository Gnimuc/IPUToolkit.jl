module IPUCompilerTest

using Test
using IPUToolkit.IPUCompiler
using IPUToolkit.Poplar
using Enzyme

include("common.jl")

function test_compiler_program(device)
    target = @cxxtest Poplar.DeviceGetTarget(device)
    graph = @cxxtest Poplar.Graph(target)

    # Define a local function to make sure macro hygiene is right
    double(x) = x * 2
    @codelet graph function TimesTwo(inconst::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
        outvec .= double.(inconst)
    end

    @codelet graph function Sort(invec::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
        outvec .= invec
        sort!(outvec)
    end

    @codelet graph function Sin(invec::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
        for idx in eachindex(outvec)
            @inbounds outvec[idx] = sin(invec[idx])
        end
    end

    @codelet graph function Print(outvec::PoplarVector{Float32, Out})
        @ipuprint "Hello, world!"
        @ipuprint "Titire tu" " patule" " recubans sub tegmine " "fagi"
        @ipuprint "The Answer to the Ultimate Question of Life, the Universe, and Everything is " 42
        x = Int32(7)
        @ipushow x
    end

    input = Float32[5, 2, 10, 102, -10, 2, 256, 15, 32, 100]

    inconst = @cxxtest Poplar.GraphAddConstant(graph, input)
    outvec1 = @cxxtest Poplar.GraphAddVariable(graph, Poplar.FLOAT(), UInt64[10], "outvec1");
    outvec2 = @cxxtest Poplar.GraphAddVariable(graph, Poplar.FLOAT(), UInt64[10], "outvec2");
    outvec3 = @cxxtest Poplar.GraphAddVariable(graph, Poplar.FLOAT(), UInt64[10], "outvec3");
    outvec4 = @cxxtest Poplar.GraphAddVariable(graph, Poplar.FLOAT(), UInt64[10], "outvec4");

    Poplar.GraphSetTileMapping(graph, inconst, 0)
    Poplar.GraphSetTileMapping(graph, outvec1, 0)
    Poplar.GraphSetTileMapping(graph, outvec2, 0)
    Poplar.GraphSetTileMapping(graph, outvec3, 0)
    Poplar.GraphSetTileMapping(graph, outvec4, 0)

    prog = @cxxtest Poplar.ProgramSequence()

    computeSetMul = @cxxtest Poplar.GraphAddComputeSet(graph, "computeSetMul")
    TimesTwoVtx = @cxxtest Poplar.GraphAddVertex(graph, computeSetMul, "TimesTwo")
    Poplar.GraphConnect(graph, TimesTwoVtx["inconst"], inconst)
    Poplar.GraphConnect(graph, TimesTwoVtx["outvec"], outvec1)
    Poplar.GraphSetTileMapping(graph, TimesTwoVtx, 0)
    if Poplar.SDK_VERSION < v"2.0"
        Poplar.GraphSetCycleEstimate(graph, TimesTwoVtx, 1)
    else
        # Poplar.GraphSetPerfEstimate(graph, TimesTwoVtx, 1)
    end

    computeSetSort = @cxxtest Poplar.GraphAddComputeSet(graph, "computeSetSort")
    SortVtx = @cxxtest Poplar.GraphAddVertex(graph, computeSetSort, "Sort")
    Poplar.GraphConnect(graph, SortVtx["invec"], outvec1)
    Poplar.GraphConnect(graph, SortVtx["outvec"], outvec2)
    Poplar.GraphSetTileMapping(graph, SortVtx, 0)
    if Poplar.SDK_VERSION < v"2.0"
        Poplar.GraphSetCycleEstimate(graph, SortVtx, 1)
    else
        # Poplar.GraphSetPerfEstimate(graph, SortVtx, 1)
    end

    computeSetSin = @cxxtest Poplar.GraphAddComputeSet(graph, "computeSetSin")
    SinVtx = @cxxtest Poplar.GraphAddVertex(graph, computeSetSin, "Sin")
    Poplar.GraphConnect(graph, SinVtx["invec"], outvec2)
    Poplar.GraphConnect(graph, SinVtx["outvec"], outvec3)
    Poplar.GraphSetTileMapping(graph, SinVtx, 0)
    if Poplar.SDK_VERSION < v"2.0"
        Poplar.GraphSetCycleEstimate(graph, SinVtx, 1)
    else
        # Poplar.GraphSetPerfEstimate(graph, SinVtx, 1)
    end

    computeSetPrint = @cxxtest Poplar.GraphAddComputeSet(graph, "computeSetPrint")
    PrintVtx = @cxxtest Poplar.GraphAddVertex(graph, computeSetPrint, "Print")
    Poplar.GraphConnect(graph, PrintVtx["outvec"], outvec4)
    Poplar.GraphSetTileMapping(graph, PrintVtx, 0)
    if Poplar.SDK_VERSION < v"2.0"
        Poplar.GraphSetCycleEstimate(graph, PrintVtx, 1)
    else
        # Poplar.GraphSetPerfEstimate(graph, PrintVtx, 1)
    end

    Poplar.ProgramSequenceAdd(prog, Poplar.ProgramExecute(computeSetMul))
    Poplar.ProgramSequenceAdd(prog, Poplar.ProgramExecute(computeSetSort))
    # The `@device_override` business works well only on Julia v1.7+
    if VERSION ≥ v"1.7"
        Poplar.ProgramSequenceAdd(prog, Poplar.ProgramExecute(computeSetSin))
    end
    Poplar.ProgramSequenceAdd(prog, Poplar.ProgramExecute(computeSetPrint))

    # Init some variables which will be used to read back from the IPU
    # the results of some basic operations.
    output_timestwo = similar(input)
    Poplar.GraphCreateHostRead(graph, "timestwo-read", outvec1)
    output_sort = similar(input)
    Poplar.GraphCreateHostRead(graph, "sort-read", outvec2)
    if VERSION ≥ v"1.7"
        output_sin = similar(input)
        Poplar.GraphCreateHostRead(graph, "sin-read", outvec3)
    end

    flags = @cxxtest Poplar.OptionFlags()
    Poplar.OptionFlagsSet(flags, "debug.instrument", "true")

    engine = @cxxtest Poplar.Engine(graph, prog, flags)
    # Load and run the program, but capture the stderr, so that we can test that
    # it contains what we expect.
    pipe = Pipe()
    redirect_stderr(pipe) do
        Poplar.EngineLoadAndRun(engine, device)
    end
    output = IOBuffer()
    task = @async write(output, pipe)
    close(pipe)
    wait(task)
    lines = split(String(take!(output)), '\n')
    @test contains(lines[1], r"Hello, world!$")
    @test contains(lines[2], r"Titire tu patule recubans sub tegmine fagi$")
    @test contains(lines[3], r"The Answer to the Ultimate Question of Life, the Universe, and Everything is 42$")
    @test contains(lines[4], r"x = 7$")
    @test lines[end] == ""

    # Read back some tensors and check the expected values.
    Poplar.EngineReadTensor(engine, "timestwo-read", output_timestwo)
    @test output_timestwo == 2 .* input
    Poplar.EngineReadTensor(engine, "sort-read", output_sort)
    @test output_sort == sort(output_timestwo)
    if VERSION ≥ v"1.7"
        Poplar.EngineReadTensor(engine, "sin-read", output_sin)
        @test output_sin == sin.(output_sort)
    end

    Poplar.DeviceDetach(device)
end

function test_ipuprogram(device)
    N = 10
    input = randn(Float32, N)
    outvec1 = PoplarVector{Float32, Out}(undef, N)
    outvec2 = PoplarVector{Float32, Out}(undef, N)
    outvec3 = PoplarVector{Float32, Out}(undef, N)
    outvec4 = PoplarVector{Float32, Out}(undef, N)
    outvec5 = PoplarVector{Float32, Out}(undef, N)
    f(x) = cos(x)
    f′(x) = first(first(autodiff_deferred(Reverse, f, Active(x))))
    g(x) = tan(x)
    g′(x) = first(first(autodiff_deferred(Reverse, g, Active(x))))

    @ipuprogram device begin
        function TimesTwo(inconst::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
            outvec .= 2 .* inconst
        end
        function Sort(invec::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
            outvec .= invec
            sort!(outvec; rev=true)
        end
        function Exp(invec::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
            for idx in eachindex(outvec)
                @inbounds outvec[idx] = exp(invec[idx])
            end
        end
        function DiffCos(invec::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
            outvec .= f′.(invec)
        end
        function DiffTan(invec::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
            for idx in eachindex(outvec)
                @inbounds outvec[idx] = g′(invec[idx])
            end
        end
        TimesTwo(input, outvec1)
        Sort(outvec1, outvec2)
        Exp(outvec2, outvec3)
        DiffCos(outvec3, outvec4)
        DiffTan(outvec4, outvec5)
        jl_outvec1 = outvec1
        jl_outvec2 = outvec2
        jl_outvec3 = outvec3
        jl_outvec4 = outvec4
        jl_outvec5 = outvec5
    end
    Poplar.DeviceDetach(device)
    @test jl_outvec1 ≈ 2 .* input
    @test jl_outvec2 ≈ sort(jl_outvec1; rev=true)
    @test jl_outvec3 ≈ exp.(jl_outvec2)
    @test jl_outvec4 ≈ @. -sin(jl_outvec3)
    @test jl_outvec5 ≈ @. sec(jl_outvec4) ^ 2
end

@testset "IPUCompiler" begin
    @testset "Test program: $(f)" for f in (test_compiler_program, test_ipuprogram)
        if Poplar.SDK_VERSION ≥ v"2.2.0" || Base.JLOptions().check_bounds != 1 # --check-bounds != yes
            # Get a device
            device = @cxxtest @test_logs((:info, r"^Trying to attach to device"),
                                         (:info, r"^Successfully attached to device"),
                                         (:info, r"^Attached to devices with IDs"),
                                         match_mode=:any,
                                         Poplar.get_ipu_device())
            # Run a test program
            f(device)
        else
            # With --check-bounds=yes GPUCompiler generates a function mentioning an undefined
            # symbol `gpu_malloc`.  Mark the test as broken until we sort this out.  However
            # this function is optimised away when compiling with `-O1` or higher, and for
            # Poplar.SDK_VERSION ≥ v"2.2.0" we use `-O3`.
            @warn """
                  Skipping IPUCompiler tests because bound checks are forced.  To run this testset use
                      using Pkg
                      Pkg.test("IPUToolkit"; julia_args=`--check-bounds=auto`)
                  """
            @test_broken false
        end
    end

    @testset "PoplarVector" begin
        vec = PoplarVector{Float32, Out}(undef, 10)
        @test vec.base == C_NULL
        @test vec.size == (10,)
        @test contains(repr(vec), r"PoplarVector{Float32,.*Out}")
    end

    @testset "Printing to IPU" begin
        # Printing is already tested in the program above, here we only check
        # that disabling printing makes the `@ipu*` macros no-op.
        IPUCompiler.DISABLE_PRINT[] = true
        @test @macroexpand(@ipuprintf "Hello, world!") == :()
        @test @macroexpand(@ipuprint "Hello, world!") == :()
        @test @macroexpand(@ipushow x) == :()
        # Restore `DISABLE_PRINT`
        IPUCompiler.DISABLE_PRINT[] = false
    end
end

end # module IPUCompilerTest
