# Neural ODEs on GPUs

Note that the differential equation solvers will run on the GPU if the initial
condition is a GPU array. Thus, for example, we can define a neural ODE by hand
that runs on the GPU (if no GPU is available, the calculation defaults back to the CPU):

```julia
using DifferentialEquations, Lux, Optim, DiffEqSensitivity
using DiffEqFlux: NeuralODE

using Random
rng = Random.default_rng()

model_gpu = Chain(Dense(2, 50, tanh), Dense(50, 2)) 
p, st = Lux.setup(rng, model_gpu) |> gpu
dudt(u, p, t) = model_gpu(u, p, st)[1]

# Simulation interval and intermediary points
tspan = (0.0, 10.0)
tsteps = 0.0:0.1:10.0

u0 = Float32[2.0; 0.0] |> gpu
prob_gpu = ODEProblem(dudt, u0, tspan, p)

# Runs on a GPU
sol_gpu = solve(prob_gpu, Tsit5(), saveat = tsteps)
```

Or we could directly use the neural ODE layer function, like:

```julia
prob_neuralode_gpu = NeuralODE(gpu(dudt!), tspan, Tsit5(), saveat = tsteps)
```

If one is using `Lux.Chain`, then the computation takes place on the GPU with
`f(x,p,st)` if `x`, `p` and `st` are on the GPU. This commonly looks like:

```julia
dudt2 = Chain(x -> x.^3,
              Dense(2,50,tanh),
              Dense(50,2))

u0 = Float32[2.; 0.] |> gpu
p, st = Lux.setup(rng, dudt2) |> gpu

dudt2_(u, p, t) = dudt2(u,p,st)[1]

# Simulation interval and intermediary points
tspan = (0.0, 10.0)
tsteps = 0.0:0.1:10.0

prob_gpu = ODEProblem(dudt2_, u0, tspan, p)

# Runs on a GPU
sol_gpu = solve(prob_gpu, Tsit5(), saveat = tsteps)
```

or via the NeuralODE struct:

```julia
prob_neuralode_gpu = NeuralODE(dudt2, tspan, Tsit5(), saveat = tsteps)
prob_neuralode_gpu(u0,p,st)
```

## Neural ODE Example

Here is the full neural ODE example. Note that we use the `gpu` function so that the
same code works on CPUs and GPUs, dependent on `using CUDA`.

```julia
using Lux, Optimization, OptimizationOptimJL, OrdinaryDiffEq, Optim, Plots, CUDA, DiffEqSensitivity, Random
using DiffEqFlux: NeuralODE, ADAM
CUDA.allowscalar(false) # Makes sure no slow operations are occuring

#rng for Lux.setup
rng = Random.default_rng()
# Generate Data
u0 = Float32[2.0; 0.0]
datasize = 30
tspan = (0.0f0, 1.5f0)
tsteps = range(tspan[1], tspan[2], length = datasize)

function trueODEfunc(du, u, p, t)
    true_A = [-0.1 2.0; -2.0 -0.1]
    du .= ((u.^3)'true_A)'
end

prob_trueode = ODEProblem(trueODEfunc, u0, tspan)
# Make the data into a GPU-based array if the user has a GPU
ode_data = gpu(solve(prob_trueode, Tsit5(), saveat = tsteps))


dudt2 = Chain(x -> x.^3,
              Dense(2, 50, tanh),
              Dense(50, 2))
u0 = Float32[2.0; 0.0] |> gpu
p,st = Lux.setup(rng, dudt2) 
p = Lux.ComponentArray(p) |> gpu
st = st |> gpu
prob_neuralode = NeuralODE(dudt2, tspan, Tsit5(), saveat = tsteps)

function predict_neuralode(p)
    gpu(prob_neuralode(u0,p,st)[1])
end

function loss_neuralode(p)
    pred = predict_neuralode(p)
    loss = sum(abs2, ode_data .- pred)
    return loss, pred
end
# Callback function to observe training
callback = function (p, l, pred; doplot = true)
  display(l)
  # plot current prediction against data
  plt = scatter(tsteps, ode_data[1,:], label = "data")
  scatter!(plt, tsteps, pred[1,:], label = "prediction")
  if doplot
    display(plot(plt))
  end
  return false
end

adtype = Optimization.AutoZygote()
optf = Optimization.OptimizationFunction((x,p)->loss_neuralode(x), adtype)
optprob = Optimization.OptimizationProblem(optf, p)

result_neuralode = Optimization.solve(optprob,
                                      ADAM(0.05), 
                                      callback = callback, 
                                      maxiters = 300)
```
