using IPUToolkit.IPUCompiler, IPUToolkit.Poplar
using Enzyme

# Define the arrays that will be used during the program.  `input` is a host array that will
# be automatically copied to an IPU array, the other `PoplarVector`s are placeholders for
# IPU arrays that will be populated during the execution of the program.
input = Float32[5, 2, 10, 102, -10, 2, 256, 15, 32, 100]
const N = length(input)
outvec1 = PoplarVector{Float32, Out}(undef, N)
outvec2 = PoplarVector{Float32, Out}(undef, N)
outvec3 = PoplarVector{Float32, Out}(undef, N)
outvec4 = PoplarVector{Float32, Out}(undef, N)
outvec5 = PoplarVector{Float32, Out}(undef, N)
outvec6 = PoplarVector{Float32, Out}(undef, N)

# Get the device.
device = Poplar.get_ipu_device()

sin′(x) = first(first(autodiff_deferred(Reverse, sin, Active(x))))
rosenbrock(x, y) = (1 - x) ^ 2 + 100 * (y - x ^ 2) ^ 2
rosenbrock′(x, y) = first(first(autodiff_deferred(Reverse, rosenbrock, Active(x), y)))
rosenbrock′_numer(x, y) = 400 * x ^ 3 - 400 * x * y + 2 * x - 2

# Inside `@ipuprogram` you can do only the following things:
#
# * define functions, which will be used as codelets in the IPU program
# * call these functions, which will automatically build the graph of the calls for you
# * print tensors on the IPU with the "special" function `print_tensor`
# * copy IPU tensors to the host
@ipuprogram device begin
    # Define the functions/codelets.  All arguments must be `PoplarVector`s.
    function Printing(input::PoplarVector{Float32, In})
        @ipuprint "Hello, world!"
        @ipuprint "The Answer to the Ultimate Question of Life, the Universe, and Everything is " 42
        x = Int32(7)
        @ipushow x
        @ipushow input[2]
    end
    function TimesTwo(inconst::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
        outvec .= 2 .* inconst
    end
    function Sort(invec::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
        outvec .= invec
        sort!(outvec)
    end
    function Cos(invec::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
        for idx in eachindex(outvec)
            @inbounds outvec[idx] = cos(invec[idx])
        end
    end
    function DiffSin(invec::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
        outvec .= sin′.(invec)
    end
    function DiffRosen(in1::PoplarVector{Float32, In}, in2::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
        outvec .= rosenbrock′.(in1, in2)
    end
    function DiffRosenNumer(in1::PoplarVector{Float32, In}, in2::PoplarVector{Float32, In}, outvec::PoplarVector{Float32, Out})
        outvec .= rosenbrock′_numer.(in1, in2)
    end

    # Run the functions.  Arguments must be the arrays defined above, either host arrays
    # (which will be copied to the IPU automatically) or `PoplarVector`s.
    Printing(input)
    TimesTwo(input, outvec1)
    Sort(outvec1, outvec2)
    Cos(outvec2, outvec3)
    DiffSin(outvec2, outvec4)
    DiffRosen(outvec3, outvec1, outvec5)
    DiffRosenNumer(outvec3, outvec1, outvec6)

    # `print_tensor` is a special function which prints tensors to the host
    # using `Poplar.ProgramPrintTensor` under the hood.  Syntax is
    #     print_tensor(<LABEL>, <tensor variable>)
    print_tensor("Input",     input)
    print_tensor("TimesTwo",  outvec1)
    print_tensor("Sorted",    outvec2)
    print_tensor("Sin    ",   outvec3)
    print_tensor("DiffCos",   outvec4)
    print_tensor("DiffRosen     ", outvec5)
    print_tensor("DiffRosenNumer", outvec6)

    # Copy IPU tensors to the host.  The right-hand side must be one of the tensors defined
    # above, the left-hand side is the name of a host array which will be created
    # automatically for you, so you will be able to reference them after the `@ipuprogram`.
    jl_outvec1 = outvec1
    jl_outvec2 = outvec2
    jl_outvec3 = outvec3
    jl_outvec4 = outvec4
    jl_outvec5 = outvec5
    jl_outvec6 = outvec6
end

# Detach the device when we're done.
Poplar.DeviceDetach(device)
