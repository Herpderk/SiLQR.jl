"""
"""
mutable struct Parameters
    system::HybridSystem
    cost::TrajectoryCost
    integrator::ExplicitIntegrator
    N::Int
    Δt::Float64
    xrefs::Vector{Vector{Float64}}
    urefs::Vector{Vector{Float64}}
    x0::Vector{Float64}
    mI::Symbol
end

function Parameters(
    system::HybridSystem,
    stage_cost::Function,
    terminal_cost::Function,
    integrator::ExplicitIntegrator,
    N::Int,
    Δt::Float64,
    xrefs::Vector{Vector{Float64}} =Vector{Float64}[],
    urefs::Vector{Vector{Float64}} = Vector{Float64}[],
    x0::Vector{Float64} = Float64[],
    mI::Symbol = :nothing,
)::Parameters
    cost = TrajectoryCost(stage_cost, terminal_cost)
    return Parameters(system, cost, integrator, N, Δt, xrefs, urefs, x0, mI)
end

"""
"""
mutable struct Solution
    xs::Vector{Vector{Float64}}
    us::Vector{Vector{Float64}}
    f̂s::Vector{Vector{Float64}}
    f̂norm::Float64
    J::Float64
end

function Solution(
    nx::Int,
    nu::Int,
    N::Int
)::Solution
    xs = [zeros(nx) for k = 1:N]
    us = [zeros(nu) for k = 1:(N-1)]
    f̂s = [zeros(nx) for k = 1:N]
    f̂norm = 0.0
    J = 0.0
    return Solution(xs, us, f̂s, f̂norm, J)
end

function Solution(
    params::Parameters
)::Solution
    return Solution(params.system.nx, params.system.nu, params.N)
end

"""
"""
mutable struct ForwardTerms
    xs::Vector{Vector{Float64}}
    us::Vector{Vector{Float64}}
    f̂s::Vector{Vector{Float64}}
    α::Float64
end

function ForwardTerms(
    nx::Int,
    nu::Int,
    N::Int
)::ForwardTerms
    xs = [zeros(nx) for k = 1:N]
    us = [zeros(nu) for k = 1:(N-1)]
    f̂s = [zeros(nx) for k = 1:N]
    α = 1.0
    return ForwardTerms(xs, us, f̂s, α)
end

"""
"""
mutable struct BackwardTerms
    Ks::Vector{Matrix{Float64}}
    ds::Vector{Vector{Float64}}
    ΔJ::Float64
end

function BackwardTerms(
    nx::Int,
    nu::Int,
    N::Int
)::BackwardTerms
    Ks = [zeros(nu,nx) for k = 1:(N-1)]
    ds = [zeros(nu) for k = 1:(N-1)]
    ΔJ = 0.0
    return BackwardTerms(Ks, ds, ΔJ)
end

"""
"""
mutable struct Cache
    fwd::ForwardTerms
    bwd::BackwardTerms
    Jexp::CostExpansion
    Qexp::ActionValueExpansion
end

function Cache(
    nx::Int,
    nu::Int,
    N::Int
)::Cache
    fwd = ForwardTerms(nx, nu, N)
    bwd = BackwardTerms(nx, nu, N)
    Jexp = CostExpansion(nx, nu)
    Qexp = ActionValueExpansion(nx, nu)
    return Cache(fwd, bwd, Jexp, Qexp)
end

function Cache(
    params::Parameters
)::Cache
    return Cache(params.system.nx, params.system.nu, params.N)
end

"""
"""
function get_flow_jacobians!(
    Qexp::ActionValueExpansion,
    params::Parameters,
    flow::Function,
    x::Vector{Float64},
    u::Vector{Float64}
)::Nothing
    ForwardDiff.jacobian!(
        Qexp.A, δx -> params.integrator(flow, δx, u, params.Δt), x
    )
    ForwardDiff.jacobian!(
        Qexp.B, δu -> params.integrator(flow, x, δu, params.Δt), u
    )
    return nothing
end

"""
"""
function update_backward_terms!(
    bwd::BackwardTerms,
    Qexp::ActionValueExpansion,
    k::Int
)::Nothing
    Quu_reg = Qexp.Quu + 1e-6*I
    try
        bwd.Ks[k] .= Quu_reg \ Qexp.Qux
        bwd.ds[k] .= Quu_reg \ Qexp.Qu
    catch e
        @show Quu_reg
        error()
    end
    bwd.ΔJ += Qexp.Qu' * bwd.ds[k]
    return nothing
end

"""
"""
function backward_pass!(
    bwd::BackwardTerms,
    Jexp::CostExpansion,
    Qexp::ActionValueExpansion,
    sol::Solution,
    params::Parameters,
    #sequence::Vector{TransitionTiming}, # TODO
)::Nothing
    bwd.ΔJ = 0.0

    xerr = sol.xs[end] - params.xrefs[end]
    uerr = zeros(params.system.nu)
    expand_terminal_cost!(Qexp, Jexp, params.cost, xerr)

    for k = (params.N-1) : -1 : 1
        get_flow_jacobians!(
            Qexp, params, params.system.modes[params.mI].flow,
            sol.xs[k], sol.us[k]
        )
        xerr .= sol.xs[k] - params.xrefs[k]
        uerr .= sol.us[k] - params.urefs[k]
        expand_stage_cost!(Jexp, params.cost, xerr, uerr)
        expand_Q!(Qexp, Jexp, sol.f̂s[k])
        update_backward_terms!(bwd, Qexp, k)
        expand_V!(Qexp, bwd.Ks[k], bwd.ds[k])
    end
    return nothing
end

"""
"""
function linear_rollout!()
end

"""
"""
function nonlinear_rollout!(
    fwd::ForwardTerms,
    bwd::BackwardTerms,
    sol::Solution,
    params::Parameters
)::Nothing
    mI = params.system.modes[params.mI]

    for k = 1:(params.N-1)
        x = fwd.xs[k]

        # Reset and update mode if a guard is hit
        for (transition, mJ) in mI.transitions
            if transition.guard(x) <= 0.0
                x = transition.reset(x)
                mI = mJ
                break
            end
        end

        #fwd.us[k] .= prev_us[k] + fwd.α*bwd.ds[k] + bwd.Ks[k]*(x - prev_xs[k])
        #fwd.f̂s[k] .= params.integrator(mI.flow, x, u, params.Δt) - fwd.xs[k+1]

        #c = 1 - fwd.α
        #x̂ = x - c*fwd.f̂s[k]
        fwd.us[k] = sol.us[k] - fwd.α*bwd.ds[k] - bwd.Ks[k]*(x - sol.xs[k])
        fwd.xs[k+1] = params.integrator(mI.flow, x, fwd.us[k], params.Δt)
        fwd.f̂s[k] .= zeros(params.system.nx)
        #fwd.xs[k+1] .= -c*fwd.f̂s[k] + params.integrator(
        #    mI.flow, x, fwd.us[k], params.Δt
        #)
    end
    return nothing
end

"""
"""
function forward_pass!(
    sol::Solution,
    fwd::ForwardTerms,
    bwd::BackwardTerms,
    params::Parameters,
    ls_iter::Int
)::Nothing
    fwd.α = 1.0
    Jls = 0.0

    for i = 1:ls_iter
        nonlinear_rollout!(fwd, bwd, sol, params)
        Jls = params.cost(params.xrefs, params.urefs, fwd.xs, fwd.us)
        Jls < sol.J ? break : nothing
        fwd.α *= 0.5
    end

    sol.J = Jls
    sol.xs .= fwd.xs
    sol.us .= fwd.us
    sol.f̂s .= fwd.f̂s
    sol.f̂norm = norm(sol.f̂s, Inf)
    return nothing
end

"""
"""
function init_forward_terms!(
    sol::Solution,
    fwd::ForwardTerms,
    bwd::BackwardTerms,
    params::Parameters
)::Nothing
    fwd.xs[1] = params.x0
    sol.xs[1] = params.x0
    sol.J = Inf
    forward_pass!(sol, fwd, bwd, params, 1)
    return nothing
end

"""
"""
function log(
    sol::Solution,
    fwd::ForwardTerms,
    bwd::BackwardTerms,
    iter::Int
)::Nothing
    if rem(iter-1, 20) == 0
        println("------------------------------------------------")
        println("iter       J          ΔJ         ‖f̂‖        α")
        println("------------------------------------------------")
    end
    @printf(
        "%3d    %9.2e  %9.2e  %9.2e   %6.4f\n",
        iter, sol.J, bwd.ΔJ, sol.f̂norm, fwd.α
    )
end

"""
"""
function terminate(
    sol::Solution,
    bwd::BackwardTerms,
    defect_tol::Float64,
    stat_tol::Float64
)::Bool
    return (sol.f̂norm < defect_tol) && (bwd.ΔJ < stat_tol)
end

"""
"""
function inner_solve!(
    sol::Solution,
    cache::Cache,
    params::Parameters,
    defect_tol::Float64,
    stat_tol::Float64,
    max_iter::Int,
    max_ls_iter::Int,
    verbose::Bool
)::Nothing
    fwd = cache.fwd
    bwd = cache.bwd
    Jexp = cache.Jexp
    Qexp = cache.Qexp
    init_forward_terms!(sol, fwd, bwd, params)

    for i = 1:max_iter
        backward_pass!(bwd, Jexp, Qexp, sol, params)
        forward_pass!(sol, fwd, bwd, params, max_ls_iter)

        verbose ? log(sol, fwd, bwd, i) : nothing
        if terminate(sol, bwd, defect_tol, stat_tol)
            verbose ? println("Optimal solution found!") : nothing
            return nothing
        end
    end

    verbose ? println("Maximum iterations exceeded!") : nothing
    return nothing
end

function solve!(
    sol::Solution,
    cache::Cache,
    params::Parameters;
    defect_tol::Float64 = 1e-6,
    stat_tol::Float64 = 1e-4,
    max_iter::Int = 100,
    max_ls_iter::Int = 10,
    verbose::Bool = true
)::Nothing
    inner_solve!(
        sol, cache, params,
        defect_tol, stat_tol,
        max_iter, max_ls_iter,
        verbose
    )
    return nothing
end

function solve(
    params::Parameters;
    defect_tol::Float64 = 1e-6,
    stat_tol::Float64 = 1e-4,
    max_iter::Int = 100,
    max_ls_iter::Int = 10,
    verbose::Bool = true
)::Solution
    sol = Solution(params)
    cache = Cache(params)
    inner_solve!(
        sol, cache, params,
        defect_tol, stat_tol,
        max_iter, max_ls_iter,
        verbose
    )
    return sol
end
