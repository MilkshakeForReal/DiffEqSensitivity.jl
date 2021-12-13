include("operator.jl")

struct SteadyStateAdjointSensitivityFunction{C<:AdjointDiffCache,Alg<:SteadyStateAdjoint,uType,SType,fType<:ODEFunction,
                                             CV,λType,VJPType,LS} <: SensitivityFunction
    diffcache::C
    sensealg::Alg
    discrete::Bool
    y::uType
    sol::SType
    f::fType
    colorvec::CV
    λ::λType
    vjp::VJPType
    linsolve::LS
end

function SteadyStateAdjointSensitivityFunction(g, sensealg, discrete, sol, dg, colorvec, needs_jac)
    @unpack f, p, u0 = sol.prob

    diffcache, y = adjointdiffcache(g, sensealg, discrete, sol, dg, f; quad=false, needs_jac=needs_jac)

    λ = zero(y)
    linsolve = needs_jac ? nothing : sensealg.linsolve
    vjp = similar(λ, length(p))

    return SteadyStateAdjointSensitivityFunction(diffcache, sensealg, discrete, y, sol, f, colorvec, λ, vjp, linsolve)
end

@noinline function SteadyStateAdjointProblem(sol, sensealg::SteadyStateAdjoint, g, dg; save_idxs=nothing)
    @unpack f, p, u0 = sol.prob

    discrete = false
    # TODO: What is the correct heuristic? Can we afford to compute Jacobian for
    #       cases where the length(u0) > 50 and if yes till what threshold
    needs_jac = length(u0) <= 50

    p === DiffEqBase.NullParameters() &&
        error("Your model does not have parameters, and thus it is impossible to calculate the derivative of the solution with respect to the parameters. Your model must have parameters to use parameter sensitivity calculations!")

    sense = SteadyStateAdjointSensitivityFunction(g, sensealg, discrete, sol, dg, f.colorvec, needs_jac)
    @unpack diffcache, y, sol, λ, vjp, linsolve = sense

    if needs_jac
        if DiffEqBase.has_jac(f)
            f.jac(diffcache.J, y, p, nothing)
        else
            if DiffEqBase.isinplace(sol.prob)
                jacobian!(diffcache.J, diffcache.uf, y, diffcache.f_cache, sensealg, diffcache.jac_config)
            else
                temp = jacobian(diffcache.uf, y, sensealg)
                @. diffcache.J = temp
            end
        end
    end

    _save_idxs = save_idxs === nothing ? Colon() : save_idxs
    if dg !== nothing
        if g !== nothing
            dg(vec(diffcache.dg_val), y, p, nothing, nothing)
        else
            if typeof(_save_idxs) <: Number
                diffcache.dg_val[_save_idxs] = dg[_save_idxs]
            elseif typeof(dg) <: Number
                @. diffcache.dg_val[_save_idxs] = dg
            else
                @. diffcache.dg_val[_save_idxs] = dg[_save_idxs]
            end
        end
    else
        if g !== nothing
            gradient!(vec(diffcache.dg_val), diffcache.g, y, sensealg, diffcache.g_grad_config)
        end
    end

    if !needs_jac
        # NOTE: Zygote doesn't support inplace
        # Currently we are performing multiple forward and backward passes in the LinearProblem
        # solver. However, our `y` is fixed. So we can perform the forward pass and repeatedly
        # evaluate the pullback to get the vecjac product.
        if DiffEqBase.isinplace(sol.prob)
            linear_problem = LinearProblem(VecJacOperator(f, y, p; autodiff=!DiffEqBase.isinplace(sol.prob)),
                                           vec(diffcache.dg_val))
        else
            _val, back = Zygote.pullback(x -> f(x, p, nothing), y)
            s_val = size(_val)
            linear_problem = LinearProblem(ZygotePullbackMultiplyOperator{eltype(y),typeof(back),typeof(s_val)}(back,
                                                                                                                s_val),
                                           vec(diffcache.dg_val))
        end
        copyto!(vec(λ), solve(linear_problem, linsolve).u)
    else
        copyto!(vec(λ), diffcache.J' \ vec(diffcache.dg_val'))
    end

    vecjacobian!(vec(diffcache.dg_val), y, λ, p, nothing, sense; dgrad=vjp, dy=nothing)

    if g !== nothing
        # compute del g/del p
        dg_dp_val = zero(p)
        dg_dp = ParamGradientWrapper(g, nothing, y)
        dg_dp_config = build_grad_config(sensealg, dg_dp, p, p)
        gradient!(dg_dp_val, dg_dp, p, sensealg, dg_dp_config)

        @. dg_dp_val = dg_dp_val - vjp
        return dg_dp_val
    else
        return -vjp
    end
end
