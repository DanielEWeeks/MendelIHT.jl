function L0_reg(
    x         :: SnpArray,
    xbm       :: SnpBitMatrix,
    z         :: AbstractMatrix{T},
    y         :: AbstractVector{T},
    J         :: Int,
    k         :: Int,
    d         :: UnivariateDistribution,
    l         :: Link;
    use_maf   :: Bool = false,
    tol       :: T = 1e-4,
    max_iter  :: Int = 200,
    max_step  :: Int = 3,
    debias    :: Bool = false,
    show_info :: Bool = false,
    init      :: Bool = false,
) where {T <: Float}

    #start timer
    start_time = time()

    # first handle errors
    @assert J >= 0        "Value of J (max number of groups) must be nonnegative!\n"
    @assert k >= 0        "Value of k (max predictors per group) must be nonnegative!\n"
    @assert max_iter >= 0 "Value of max_iter must be nonnegative!\n"
    @assert max_step >= 0 "Value of max_step must be nonnegative!\n"
    @assert tol > eps(T)  "Value of global tol must exceed machine precision!\n"
    checky(y, d) # make sure response data y is in the form we need it to be 

    # initialize constants
    mm_iter     = 0                 # number of iterations of L0_logistic_reg
    tot_time    = 0.0               # compute time *within* L0_logistic_reg
    next_logl   = oftype(tol,-Inf)  # loglikelihood
    the_norm    = 0.0               # norm(b - b0)
    scaled_norm = 0.0               # the_norm / (norm(b0) + 1)
    η_step      = 0                 # counts number of backtracking steps for η
    converged   = false             # scaled_norm < tol?

    # Initialize variables. Compute initial guess if requested
    v = IHTVariables(x, z, y, J, k)                            # Placeholder variable for cleaner code
    temp_glm = GeneralizedLinearModel                          # Preallocated GLM variable for debiasing
    full_grad = zeros(size(x, 2) + size(z, 2))                 # Preallocated vector for efficiency
    init_iht_indices!(v, xbm, z, y, d, l, J, k, full_grad)     # initialize non-zero indices
    copyto!(v.xk, @view(x[:, v.idx]), center=true, scale=true) # store relevant components of x
    if init
        initialize_beta!(v, y, x, d, l)
        A_mul_B!(v.xb, v.zc, xbm, z, v.b, v.c)
    end

    # Begin 'iterative' hard thresholding algorithm
    for mm_iter = 1:max_iter

        # notify and return current model if maximum iteration exceeded
        if mm_iter >= max_iter
            tot_time = time() - start_time
            show_info && printstyled("Did not converge!!!!! The run time for IHT was " * string(tot_time) * "seconds and model size was" * string(k), color=:red)
            return ggIHTResults(tot_time, next_logl, mm_iter, v.b, v.c, J, k, v.group)
        end

        # save values from previous iterate and update loglikelihood
        save_prev!(v)
        logl = next_logl

        # take one IHT step in positive score direction
        (η, η_step, next_logl) = iht_one_step!(v, x, xbm, z, y, J, k, d, l, logl, full_grad, mm_iter, max_step)

        # perform debiasing if requested
        if debias && sum(v.idx) == size(v.xk, 2)
            temp_glm = fit(GeneralizedLinearModel, v.xk, y, d, l)
            all(temp_glm.pp.beta0 .≈ 0) || (view(v.b, v.idx) .= temp_glm.pp.beta0)
        end

        # track convergence
        the_norm    = max(chebyshev(v.b, v.b0), chebyshev(v.c, v.c0)) #max(abs(x - y))
        scaled_norm = the_norm / (max(norm(v.b0, Inf), norm(v.c0, Inf)) + 1.0)
        converged   = scaled_norm < tol

        if converged && mm_iter > 1
            tot_time = time() - start_time
            return ggIHTResults(tot_time, next_logl, mm_iter, v.b, v.c, J, k, v.group)
        end
    end
end #function L0_reg

function iht_one_step!(v::IHTVariable{T}, x::SnpArray, xbm::SnpBitMatrix, z::AbstractMatrix{T}, 
    y::AbstractVector{T}, J::Int, k::Int, d::UnivariateDistribution, l::Link, old_logl::T, 
    full_grad::AbstractVector{T}, iter::Int, nstep::Int) where {T <: Float}

    # first calculate step size 
    η = iht_stepsize(v, z, d)

    # update b and c by taking gradient step v.b = P_k(β + ηv) where v is the score direction
    _iht_gradstep(v, η, J, k, full_grad)

    # update xb and zc with the new computed b and c, clamping because might overflow for poisson
    copyto!(v.xk, @view(x[:, v.idx]), center=true, scale=true)
    A_mul_B!(v.xb, v.zc, v.xk, z, view(v.b, v.idx), v.c)
    clamp!(v.xb, -30, 30)
    clamp!(v.zc, -30, 30)

    # calculate current loglikelihood with the new computed xb and zc
    update_mean!(v.μ, v.xb .+ v.zc, l)
    new_logl = loglikelihood(d, y, v.μ)

    η_step = 0
    while _iht_backtrack_(new_logl, old_logl, η_step, nstep)

        # stephalving
        η /= 2

        # recompute gradient step
        copyto!(v.b, v.b0)
        copyto!(v.c, v.c0)
        _iht_gradstep(v, η, J, k, full_grad)

        # recompute xb
        copyto!(v.xk, @view(x[:, v.idx]), center=true, scale=true)
        A_mul_B!(v.xb, v.zc, v.xk, z, @view(v.b[v.idx]), v.c)
        clamp!(v.xb, -30, 30)
        clamp!(v.zc, -30, 30)

        # compute new loglikelihood again to see if we're now increasing
        update_mean!(v.μ, v.xb .+ v.zc, l)
        new_logl = loglikelihood(d, y, v.μ)

        # increment the counter
        η_step += 1
    end

    # compute score with the new mean μ
    score!(v, xbm, z, y, d, l)

    # check for finiteness before moving to the next iteration
    isnan(new_logl) && throw(error("Loglikelihood function is NaN, aborting..."))
    isinf(new_logl) && throw(error("Loglikelihood function is Inf, aborting..."))
    isinf(η) && throw(error("step size not finite! it is $η and max df is " * string(maximum(v.gk)) * "!!\n"))

    return η::T, η_step::Int, new_logl::T
end #function iht_one_step
