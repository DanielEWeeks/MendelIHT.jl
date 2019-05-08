
# Examples

Here we give numerous example analysis of GWAS data with MendelIHT. 


```julia
# machine information for reproducibility
versioninfo()
```

    Julia Version 1.0.3
    Commit 099e826241 (2018-12-18 01:34 UTC)
    Platform Info:
      OS: macOS (x86_64-apple-darwin14.5.0)
      CPU: Intel(R) Core(TM) i7-3740QM CPU @ 2.70GHz
      WORD_SIZE: 64
      LIBM: libopenlibm
      LLVM: libLLVM-6.0.0 (ORCJIT, ivybridge)



```julia
#first add workers needed for parallel computing. Add only as many CPU cores available
using Distributed
addprocs(4)

#load necessary packages for running all examples below
using MendelIHT
using SnpArrays
using DataFrames
using Distributions
using Random
using LinearAlgebra
using GLM
using DelimitedFiles
using Statistics
using BenchmarkTools
```

    ┌ Info: Recompiling stale cache file /Users/biona001/.julia/compiled/v1.0/MendelIHT/eaqWB.ji for MendelIHT [921c7187-1484-5754-b919-5d3ed9ac03c4]
    └ @ Base loading.jl:1190


## Example 1: How to Import Data

We use [SnpArrays.jl](https://openmendel.github.io/SnpArrays.jl/latest/) as backend to process genotype files. Internally, the genotype file is a memory mapped [SnpArray](https://openmendel.github.io/SnpArrays.jl/stable/#SnpArray-1), which will not be loaded into RAM. If you wish to run `L0_reg`, you need to convert a SnpArray into a [SnpBitMatrix](https://openmendel.github.io/SnpArrays.jl/stable/#SnpBitMatrix-1), which consumes $n \times p \times 2$ bits of RAM. Non-genetic predictors should be read into Julia in the standard way, and should be stored as an `Array{Float64, 2}`. One should include the intercept (typically in the first column), but an intercept is not required to run IHT. 

### Reading Genotype data and Non-Genetic Covariates


```julia
x   = SnpArray("../data/test1.bed")
xbm = SnpBitMatrix{Float64}(x, model=ADDITIVE_MODEL, center=true, scale=true);
z   = readdlm("../data/test1_covariates.txt") # 1st column intercept, 2nd column sex
```




    1000×2 Array{Float64,2}:
     1.0  2.0
     1.0  1.0
     1.0  2.0
     1.0  1.0
     1.0  1.0
     1.0  1.0
     1.0  2.0
     1.0  1.0
     1.0  1.0
     1.0  1.0
     1.0  1.0
     1.0  2.0
     1.0  1.0
     ⋮       
     1.0  1.0
     1.0  1.0
     1.0  1.0
     1.0  2.0
     1.0  2.0
     1.0  2.0
     1.0  1.0
     1.0  2.0
     1.0  1.0
     1.0  1.0
     1.0  2.0
     1.0  1.0




```julia
@show typeof(x)
@show typeof(xbm)
@show typeof(z); #non genetic covariates must be Array{Float64, 2} even if only the intercept is included
```

    typeof(x) = SnpArray
    typeof(xbm) = SnpBitMatrix{Float64}
    typeof(z) = Array{Float64,2}


!!! note

    (1) MendelIHT.jl assumes there are **NO missing genotypes**, and (2) the trios (`.bim`, `.bed`, `.fam`) must all be present in the same directory. 
    
### Standardizing Non-Genetic Covariates.

We recommend standardizing all genetic and non-genetic covarariates (including binary and categorical), except for the intercept. This ensures equal penalization for all predictors. `SnpBitMatrix` efficiently achieves this standardization for genotype data, but this must be done manually for non-genetic covariates prior to using `z` in `L0_reg` or `cv_iht`, as below:


```julia
# standardize all covariates (other than intercept) to mean 0 variance 1
standardize!(@view(z[:, 2:end]))
z
```




    1000×2 Array{Float64,2}:
     1.0   1.01969 
     1.0  -0.979706
     1.0   1.01969 
     1.0  -0.979706
     1.0  -0.979706
     1.0  -0.979706
     1.0   1.01969 
     1.0  -0.979706
     1.0  -0.979706
     1.0  -0.979706
     1.0  -0.979706
     1.0   1.01969 
     1.0  -0.979706
     ⋮             
     1.0  -0.979706
     1.0  -0.979706
     1.0  -0.979706
     1.0   1.01969 
     1.0   1.01969 
     1.0   1.01969 
     1.0  -0.979706
     1.0   1.01969 
     1.0  -0.979706
     1.0  -0.979706
     1.0   1.01969 
     1.0  -0.979706



## Example 2: Quantitative Traits

Quantitative traits are continuous phenotypes whose distribution can be modeled by the normal distribution. Then using the genotype matrix $\mathbf{X}$ and phenotype vector $\mathbf{y}$, we want to recover $\beta$ such that $\mathbf{y} \approx \mathbf{X}\beta$. 

### Step 1: Import data

In Example 1 we illustrated how to import data into Julia. So here we use simulated data ([code](https://github.com/biona001/MendelIHT.jl/blob/master/src/simulate_utilities.jl#L107)) because, only then, can we compare IHT's result to the true solution. Below we simulate a GWAS data with $n=1000$ patients and $p=10000$ SNPs. Here the quantitative trait vector are affected by $k = 10$ causal SNPs, with no non-genetic confounders. 

In this example, our model is simulated as:

$$y_i \sim \mathbf{x}_i^T\mathbf{\beta} + \epsilon_i$$

$$x_{ij} \sim Binomial(2, p_j)$$

$$p_j \sim Uniform(0, 0.5)$$

$$\epsilon_i \sim N(0, 1)$$

$$\beta_i \sim N(0, 1)$$


```julia
# Define model dimensions, true model size, distribution, and link functions
n = 1000
p = 10000
k = 10
d = Normal
l = canonicallink(d())

# set random seed for reproducibility
Random.seed!(2019) 

# simulate SNP matrix, store the result in a file called tmp.bed
x, = simulate_random_snparray(n, p, "tmp.bed")

#construct the SnpBitMatrix type (needed for L0_reg() and simulate_random_response() below)
xbm = SnpBitMatrix{Float64}(x, model=ADDITIVE_MODEL, center=true, scale=true); 

# intercept is the only nongenetic covariate
z = ones(n, 1) 

# simulate response y, true model b, and the correct non-0 positions of b
y, true_b, correct_position = simulate_random_response(x, xbm, k, d, l);
```

### Step 2: Run cross validation to determine best model size

To run `cv_iht`, you must specify `path` and `num_fold`, defined below:

+ `path` are all the model sizes you wish to test, stored in a vector of integers.
+ `num_fold` indicates how many disjoint partitions of the samples is requested. 

By default, we partition the training/testing data randomly, but you can change this by inputing the `fold` vector as optional argument. In this example we tested $k = 1, 2, ..., 20$ across 3 fold cross validation. This is equivalent to running IHT across 60 different models, and hence, is ideal for parallel computing (which you specify by `parallel=true`). 


```julia
path = collect(1:20)
num_folds = 3
mses = cv_iht(d(), l, x, z, y, 1, path, num_folds, parallel=true); #here 1 is for number of groups
```

    
    
    Crossvalidation Results:
    	k	MSE
    	1	1927.0765190526672
    	2	1443.8788742220866
    	3	1080.041135323195
    	4	862.2385953735205
    	5	705.1014346627649
    	6	507.394935936422
    	7	391.9686876462285
    	8	368.45440222003174
    	9	350.64279409251793
    	10	345.8380848576577
    	11	350.51881472845776
    	12	359.42391568519577
    	13	363.7095696959907
    	14	377.30732985896975
    	15	381.0310879522695
    	16	392.5643923838261
    	17	396.81166049333797
    	18	397.3010019298764
    	19	406.47023764639624
    	20	410.4672260807978
    
    The lowest MSE is achieved at k = 10 
    


!!! note 

    `cv_iht()` generates intermediate files such as `train.tmp`. **DO NOT remove these files before the algorithm terminate.** These are necessary auxiliary files that will be automatically removed when cross validation completes. 

!!! tip

    Because Julia employs a JIT compiler, the first round of any function call run will always take longer and consume extra memory. Therefore it is advised to always run a small "test example" (such as this one!) before running cross validation on a large dataset. 

### Step 3: Run full model on the best estimated model size 

`cv_iht` finished in less than a minute. 

According to our cross validation result, the best model size that minimizes deviance residuals (i.e. MSE on the q-th subset of samples) is attained at $k = 10$. That is, cross validation detected that we need 10 SNPs to achieve the best model size. Using this information, one can re-run the IHT algorithm on the *full* dataset to obtain the best estimated model.


```julia
k_est = argmin(mses)
result = L0_reg(x, xbm, z, y, 1, k_est, d(), l)
```




    
    IHT estimated 10 nonzero SNP predictors and 0 non-genetic predictors.
    
    Compute time (sec):     0.5801961421966553
    Final loglikelihood:    -1406.8807653835697
    Iterations:             6
    Max number of groups:   1
    Max predictors/group:   10
    
    Selected genetic predictors:
    10×2 DataFrame
    │ Row │ Position │ Estimated_β │
    │     │ [90mInt64[39m    │ [90mFloat64[39m     │
    ├─────┼──────────┼─────────────┤
    │ 1   │ 853      │ -1.24117    │
    │ 2   │ 877      │ -0.234676   │
    │ 3   │ 924      │ 0.82014     │
    │ 4   │ 2703     │ 0.583403    │
    │ 5   │ 4241     │ 0.298304    │
    │ 6   │ 4783     │ -1.14459    │
    │ 7   │ 5094     │ 0.673012    │
    │ 8   │ 5284     │ -0.709736   │
    │ 9   │ 7760     │ 0.16866     │
    │ 10  │ 8255     │ 1.08117     │
    
    Selected nongenetic predictors:
    0×2 DataFrame




### Step 4 (only for simulated data): Check final model against simulation

Since all our data and model was simulated, we can see how well `cv_iht` combined with `L0_reg` estimated the true model. For this example, we find that IHT found every simulated predictor, with 0 false positives. 


```julia
compare_model = DataFrame(
    true_β      = true_b[correct_position], 
    estimated_β = result.beta[correct_position])
@show compare_model

#clean up
rm("tmp.bed", force=true)
```

    compare_model = 10×2 DataFrame
    │ Row │ true_β   │ estimated_β │
    │     │ Float64  │ Float64     │
    ├─────┼──────────┼─────────────┤
    │ 1   │ -1.29964 │ -1.24117    │
    │ 2   │ -0.2177  │ -0.234676   │
    │ 3   │ 0.786217 │ 0.82014     │
    │ 4   │ 0.599233 │ 0.583403    │
    │ 5   │ 0.283711 │ 0.298304    │
    │ 6   │ -1.12537 │ -1.14459    │
    │ 7   │ 0.693374 │ 0.673012    │
    │ 8   │ -0.67709 │ -0.709736   │
    │ 9   │ 0.14727  │ 0.16866     │
    │ 10  │ 1.03477  │ 1.08117     │


## Example 3: Logistic Regression Controlling for Sex

We show how to use IHT to handle case-control studies, while handling non-genetic covariates. In this example, we fit a logistic regression model with IHT using simulated case-control data, while controling for sex as a nongenetic covariate. 

### Step 1: Import Data

Again we use a simulated model:

$$y_i \sim Bernoulli(\mathbf{x}_i^T\mathbf{\beta})$$

$$x_{ij} \sim Binomial(2, p_j)$$

$$p_j \sim Uniform(0, 0.5)$$

$$\beta_i \sim N(0, 1)$$

$$\beta_{intercept} = 1$$

$$\beta_{sex} = 1.5$$

We assumed there are $k=8$ genetic predictors and 2 non-genetic predictors (intercept and sex) that affects the trait. The simulation code in our package does not yet handle simulations with non-genetic predictors, so we must simulate these phenotypes manually. 


```julia
# Define model dimensions, true model size, distribution, and link functions
n = 1000
p = 10000
k = 10
d = Bernoulli
l = canonicallink(d())

# set random seed for reproducibility
Random.seed!(2019)

# construct SnpArray and SnpBitMatrix
x, = simulate_random_snparray(n, p, "tmp.bed")
xbm = SnpBitMatrix{Float64}(x, model=ADDITIVE_MODEL, center=true, scale=true);

# nongenetic covariate: first column is the intercept, second column is sex: 0 = male 1 = female
z = ones(n, 2) 
z[:, 2] .= rand(0:1, n)

# randomly set genetic predictors
true_b = zeros(p) 
true_b[1:k-2] = randn(k-2)
shuffle!(true_b)

# find correct position of genetic predictors
correct_position = findall(!iszero, true_b)

# define effect size of non-genetic predictors: intercept & sex
true_c = [1.0; 1.5] 

# simulate phenotype using genetic and nongenetic predictors
prob = linkinv.(l, xbm * true_b .+ z * true_c)
y = [rand(d(i)) for i in prob]
y = Float64.(y); # y must be floating point numbers
```

### Step 2: Run cross validation to determine best model size

To run `cv_iht`, you must specify `path` and `num_fold`, defined below:

+ `path` are all the model sizes you wish to test, stored in a vector of integers.
+ `num_fold` indicates how many disjoint partitions of the samples is requested. 

By default, we partition the training/testing data randomly, but you can change this by inputing the `fold` vector as optional argument. In this example we tested $k = 1, 2, ..., 20$ across 3 fold cross validation. This is equivalent to running IHT across 60 different models, and hence, is ideal for parallel computing (which you specify by `parallel=true`). 


```julia
path = collect(1:20)
num_folds = 3
mses = cv_iht(d(), l, x, z, y, 1, path, num_folds, parallel=true); #here 1 is for number of groups
```

    
    
    Crossvalidation Results:
    	k	MSE
    	1	391.44413742296507
    	2	365.75172666211597
    	3	332.3877206652262
    	4	273.2076336536057
    	5	238.71565721188784
    	6	230.23676864994815
    	7	214.8917395180223
    	8	199.01560091101322
    	9	208.3101897282104
    	10	219.82354033490867
    	11	230.12560285605036
    	12	240.7100189430074
    	13	265.89197902031015
    	14	272.29213890904106
    	15	271.7833424289932
    	16	298.34625245932193
    	17	317.85972029019524
    	18	367.31668485042815
    	19	379.8081201465501
    	20	407.72418511154956
    
    The lowest MSE is achieved at k = 8 
    


!!! tip

    In our experience, using the `ProbitLink` for logistic regressions deliver better results than `LogitLink` (which is the canonical link). 

### Step 3: Run full model on the best estimated model size 

`cv_iht` finished in about a minute. 

Cross validation have declared that $k_{best} = 8$. Using this information, one can re-run the IHT algorithm on the *full* dataset to obtain the best estimated model.


```julia
k_est = argmin(mses)
result = L0_reg(x, xbm, z, y, 1, k_est, d(), l)
```




    
    IHT estimated 6 nonzero SNP predictors and 2 non-genetic predictors.
    
    Compute time (sec):     1.8014729022979736
    Final loglikelihood:    -290.45093915185475
    Iterations:             33
    Max number of groups:   1
    Max predictors/group:   8
    
    Selected genetic predictors:
    6×2 DataFrame
    │ Row │ Position │ Estimated_β │
    │     │ [90mInt64[39m    │ [90mFloat64[39m     │
    ├─────┼──────────┼─────────────┤
    │ 1   │ 1152     │ 0.96664     │
    │ 2   │ 1576     │ 1.56174     │
    │ 3   │ 3411     │ 0.876702    │
    │ 4   │ 5765     │ -1.75602    │
    │ 5   │ 5992     │ -2.04509    │
    │ 6   │ 8781     │ 0.760146    │
    
    Selected nongenetic predictors:
    2×2 DataFrame
    │ Row │ Position │ Estimated_β │
    │     │ [90mInt64[39m    │ [90mFloat64[39m     │
    ├─────┼──────────┼─────────────┤
    │ 1   │ 1        │ 0.710066    │
    │ 2   │ 2        │ 1.6505      │



### Step 4 (only for simulated data): Check final model against simulation

Since all our data and model was simulated, we can see how well `cv_iht` combined with `L0_reg` estimated the true model. For this example, we find that IHT found both nongenetic predictor, but missed 2 genetic predictors. The 2 genetic predictors that we missed had much smaller effect size, so given that we only had 1000 samples, this is hardly surprising. 


```julia
compare_model_genetics = DataFrame(
    true_β      = true_b[correct_position], 
    estimated_β = result.beta[correct_position])

compare_model_nongenetics = DataFrame(
    true_c      = true_c[1:2], 
    estimated_c = result.c[1:2])

@show compare_model_genetics
@show compare_model_nongenetics

#clean up
rm("tmp.bed", force=true)
```

    compare_model_genetics = 8×2 DataFrame
    │ Row │ true_β   │ estimated_β │
    │     │ Float64  │ Float64     │
    ├─────┼──────────┼─────────────┤
    │ 1   │ 0.961937 │ 0.96664     │
    │ 2   │ 0.189267 │ 0.0         │
    │ 3   │ 1.74008  │ 1.56174     │
    │ 4   │ 0.879004 │ 0.876702    │
    │ 5   │ 0.213066 │ 0.0         │
    │ 6   │ -1.74663 │ -1.75602    │
    │ 7   │ -1.93402 │ -2.04509    │
    │ 8   │ 0.632786 │ 0.760146    │
    compare_model_nongenetics = 2×2 DataFrame
    │ Row │ true_c  │ estimated_c │
    │     │ Float64 │ Float64     │
    ├─────┼─────────┼─────────────┤
    │ 1   │ 1.0     │ 0.710066    │
    │ 2   │ 1.5     │ 1.6505      │


## Example 4: Poisson Regression with Convergence Acceleration

In this example, we show how debiasing can achieve dramatic speedup. Our model is:

$$y_i \sim Poisson(\mathbf{x}_i^T\mathbf{\beta})$$

$$x_{ij} \sim Binomial(2, p_j)$$

$$p_j \sim Uniform(0, 0.5)$$

$$\beta_i \sim N(0, 0.3)$$


```julia
# Define model dimensions, true model size, distribution, and link functions
n = 5000
p = 30000
k = 10
d = Poisson
l = canonicallink(d())

# set random seed for reproducibility
Random.seed!(2019)

# construct SnpArray, SnpBitMatrix, and intercept
x, = simulate_random_snparray(n, p, "tmp.bed")
xbm = SnpBitMatrix{Float64}(x, model=ADDITIVE_MODEL, center=true, scale=true);
z = ones(n, 1) 

# simulate response, true model b, and the correct non-0 positions of b
y, true_b, correct_position = simulate_random_response(x, xbm, k, d, l);
```

### First Compare Reconstruction Result

First we show that, with or without debiasing, we obtain comparable results with `L0_reg`.


```julia
no_debias  = L0_reg(x, xbm, z, y, 1, k, d(), l, debias=false)
yes_debias = L0_reg(x, xbm, z, y, 1, k, d(), l, debias=true);
```


```julia
compare_model = DataFrame(
    position    = correct_position,
    true_β      = true_b[correct_position], 
    no_debias_β = no_debias.beta[correct_position],
    yes_debias_β = yes_debias.beta[correct_position])
@show compare_model;
```

    compare_model = 10×4 DataFrame
    │ Row │ position │ true_β     │ no_debias_β │ yes_debias_β │
    │     │ Int64    │ Float64    │ Float64     │ Float64      │
    ├─────┼──────────┼────────────┼─────────────┼──────────────┤
    │ 1   │ 2105     │ 0.0155232  │ 0.0         │ 0.0          │
    │ 2   │ 5852     │ 0.0747323  │ 0.0764579   │ 0.0776816    │
    │ 3   │ 9219     │ 0.0233952  │ 0.0         │ 0.0          │
    │ 4   │ 10362    │ -0.241167  │ -0.244755   │ -0.242612    │
    │ 5   │ 15755    │ 0.278812   │ 0.281372    │ 0.282154     │
    │ 6   │ 21188    │ 0.0540703  │ 0.060669    │ 0.0622104    │
    │ 7   │ 21324    │ -0.216701  │ -0.222539   │ -0.220426    │
    │ 8   │ 21819    │ -0.0331256 │ -0.0582902  │ -0.0602985   │
    │ 9   │ 25655    │ 0.0217997  │ 0.0         │ 0.0          │
    │ 10  │ 29986    │ 0.354062   │ 0.359734    │ 0.360543     │


### Compare Speed and Memory Usage

Now we illustrate that debiasing may dramatically reduce computational time (in this case 75%), at a cost of increasing the memory usage. In practice, this extra memory usage hardly matters because the matrix size will dominate for larger problems. See [here for complete benchmark figure.](https://github.com/biona001/MendelIHT.jl)


```julia
@benchmark L0_reg(x, xbm, z, y, 1, k, d(), l, debias=false) seconds=30
```




    BenchmarkTools.Trial: 
      memory estimate:  7.44 MiB
      allocs estimate:  783
      --------------
      minimum time:     10.013 s (0.04% GC)
      median time:      10.098 s (0.00% GC)
      mean time:        10.085 s (0.01% GC)
      maximum time:     10.144 s (0.00% GC)
      --------------
      samples:          3
      evals/sample:     1




```julia
@benchmark L0_reg(x, xbm, z, y, 1, k, d(), l, debias=true) seconds=30
```




    BenchmarkTools.Trial: 
      memory estimate:  15.53 MiB
      allocs estimate:  1610
      --------------
      minimum time:     7.816 s (0.00% GC)
      median time:      7.855 s (0.02% GC)
      mean time:        7.883 s (0.02% GC)
      maximum time:     8.006 s (0.03% GC)
      --------------
      samples:          4
      evals/sample:     1




```julia
#clean up
rm("tmp.bed", force=true)
```

## Other examples and functionalities

We invite users to experiment with additional functionalities. We explored a significant portion of them in our manuscript, with [reproducible code](https://github.com/biona001/MendelIHT.jl/tree/master/figures). This includes:

+ Modeling some exotic distributions and using noncanonical link functions [listed here](https://biona001.github.io/MendelIHT.jl/latest/man/getting_started/#Supported-GLM-models-and-Link-functions-1)
+ Modeling SNP-SNP or SNP-environment interaction effects by explicitly including them in the nongenetic covariates `z`.
+ Doubly sparse projection (requires group information)
+ Weighted projections to favor certain SNPs (requires weight information)
