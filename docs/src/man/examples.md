
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
      CPU: Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz
      WORD_SIZE: 64
      LIBM: libopenlibm
      LLVM: libLLVM-6.0.0 (ORCJIT, skylake)



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

## Example 1: How to Import Data

We use [SnpArrays.jl](https://openmendel.github.io/SnpArrays.jl/latest/) as backend to process genotype files. Internally, the genotype file is a memory mapped [SnpArray](https://openmendel.github.io/SnpArrays.jl/stable/#SnpArray-1), which will not be loaded into RAM. If you wish to run `L0_reg`, you need to convert a SnpArray into a [SnpBitMatrix](https://openmendel.github.io/SnpArrays.jl/stable/#SnpBitMatrix-1), which consumes $n \times p \times 2$ bits of RAM. Non-genetic predictors should be read into Julia in the standard way, and should be stored as an `Array{Float64, 2}`. One should include the intercept (typically in the first column), but an intercept is not required to run IHT. 

### Simulate example data (to be imported later)

First we simulate an example PLINK trio (`.bim`, `.bed`, `.fam`) and non-genetic covariates, then we illustrate how to import them. For genotype matrix simulation, we simulate under the model:

$$x_{ij} \sim \rm Binomial(2, \rho_j)$$
$$\rho_j \sim \rm Uniform(0, 0.5)$$


```julia
# rows and columns
n = 1000
p = 10000

#random seed
Random.seed!(1111)

# simulate random `.bed` file
x = simulate_random_snparray(n, p, "example.bed")

# create accompanying `.bim`, `.fam` files (randomly generated)
make_bim_fam_files(x, ones(n), "example")

# simulate non-genetic covariates (in this case, we include intercept and sex)
z = [ones(n, 1) rand(0:1, n)]
writedlm("example_nongenetic_covariates.txt", z)
```

### Reading Genotype data and Non-Genetic Covariates from disk


```julia
x = SnpArray("example.bed")
z = readdlm("example_nongenetic_covariates.txt")
```




    1000×2 Array{Float64,2}:
     1.0  1.0
     1.0  0.0
     1.0  0.0
     1.0  1.0
     1.0  0.0
     1.0  0.0
     1.0  1.0
     1.0  0.0
     1.0  1.0
     1.0  1.0
     1.0  0.0
     1.0  0.0
     1.0  1.0
     ⋮       
     1.0  0.0
     1.0  1.0
     1.0  0.0
     1.0  0.0
     1.0  0.0
     1.0  0.0
     1.0  0.0
     1.0  0.0
     1.0  0.0
     1.0  0.0
     1.0  1.0
     1.0  0.0



!!! note

    (1) MendelIHT.jl assumes there are **NO missing genotypes**, (2) 1 always encode the minor allele, and (3) the trios (`.bim`, `.bed`, `.fam`) are all be present in the same directory. 
    
### Standardizing Non-Genetic Covariates.

We recommend standardizing all genetic and non-genetic covarariates (including binary and categorical), except for the intercept. This ensures equal penalization for all predictors. For genotype matrix, `SnpBitMatrix` efficiently achieves this standardization. For non-genetic covariates, we use the built-in function `standardize!`. 


```julia
# SnpBitMatrix can automatically standardizes .bed file (without extra memory) and behaves like a matrix
xbm = SnpBitMatrix{Float64}(x, model=ADDITIVE_MODEL, center=true, scale=true);

# using view is important for correctness
standardize!(@view(z[:, 2:end])) 
z
```




    1000×2 Array{Float64,2}:
     1.0   1.0015  
     1.0  -0.997503
     1.0  -0.997503
     1.0   1.0015  
     1.0  -0.997503
     1.0  -0.997503
     1.0   1.0015  
     1.0  -0.997503
     1.0   1.0015  
     1.0   1.0015  
     1.0  -0.997503
     1.0  -0.997503
     1.0   1.0015  
     ⋮             
     1.0  -0.997503
     1.0   1.0015  
     1.0  -0.997503
     1.0  -0.997503
     1.0  -0.997503
     1.0  -0.997503
     1.0  -0.997503
     1.0  -0.997503
     1.0  -0.997503
     1.0  -0.997503
     1.0   1.0015  
     1.0  -0.997503




```julia
# remove simulated data once they are no longer needed
rm("example.bed", force=true)
rm("example.bim", force=true)
rm("example.fam", force=true)
rm("example_nongenetic_covariates.txt", force=true)
```

## Example 2: Running IHT on Quantitative Traits

Quantitative traits are continuous phenotypes whose distribution can be modeled by the normal distribution. Then using the genotype matrix $\mathbf{X}$ and phenotype vector $\mathbf{y}$, we want to recover $\beta$ such that $\mathbf{y} \approx \mathbf{X}\beta$. In this example, we assume we know the true sparsity level `k`. 

### Step 1: Import data

In Example 1 we illustrated how to import data into Julia. So here we use simulated data ([code](https://github.com/biona001/MendelIHT.jl/blob/master/src/simulate_utilities.jl#L107)) because, only then, can we compare IHT's result to the true solution. Below we simulate a GWAS data with $n=1000$ patients and $p=10000$ SNPs. Here the quantitative trait vector are affected by $k = 10$ causal SNPs, with no non-genetic confounders. 

In this example, our model is simulated as:

$$y_i \sim \mathbf{x}_i^T\mathbf{\beta} + \epsilon_i$$
$$x_{ij} \sim \rm Binomial(2, \rho_j)$$
$$\rho_j \sim \rm Uniform(0, 0.5)$$
$$\epsilon_i \sim \rm N(0, 1)$$
$$\beta_i \sim \rm N(0, 1)$$


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
x = simulate_random_snparray(n, p, "tmp.bed")

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
    	1	1927.0765190526674
    	2	1443.8788742220863
    	3	1080.041135323195
    	4	862.2385953735204
    	5	705.1014346627649
    	6	507.3949359364219
    	7	391.96868764622843
    	8	368.45440222003174
    	9	350.642794092518
    	10	345.8380848576577
    	11	350.5188147284578
    	12	359.42391568519577
    	13	363.70956969599075
    	14	377.30732985896975
    	15	381.0310879522694
    	16	392.56439238382615
    	17	396.81166049333797
    	18	397.3010019298764
    	19	406.47023764639624
    	20	410.4672260807978


!!! note 

    **DO NOT remove** intermediate files with random filenames as generated by `cv_iht()`. These are necessary auxiliary files that will be automatically removed when cross validation completes. 

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
    
    Compute time (sec):     0.4135408401489258
    Final loglikelihood:    -1406.8807653835697
    Iterations:             6
    
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

#clean up. Windows user must do this step manually (outside notebook/REPL)
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

$$y_i \sim \rm Bernoulli(\mathbf{x}_i^T\mathbf{\beta})$$
$$x_{ij} \sim \rm Binomial(2, \rho_j)$$
$$\rho_j \sim \rm Uniform(0, 0.5)$$
$$\beta_i \sim \rm N(0, 1)$$
$$\beta_{\rm intercept} = 1$$
$$\beta_{\rm sex} = 1.5$$

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
x = simulate_random_snparray(n, p, "tmp.bed")
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
prob = GLM.linkinv.(l, xbm * true_b .+ z * true_c)
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
    	1	391.44426892225727
    	2	365.7520496496987
    	3	332.3801926093215
    	4	273.2081512206048
    	5	253.31631985207758
    	6	234.93701288953315
    	7	221.997334181244
    	8	199.01688783420346
    	9	208.31087723164197
    	10	216.00575628120708
    	11	227.91834469184545
    	12	242.42456871743065
    	13	261.46346209331466
    	14	263.5229307137862
    	15	283.30379378951073
    	16	328.2771991160804
    	17	290.4512419547228
    	18	350.3516280657363
    	19	361.61016297810295
    	20	418.2370935226805


!!! tip

    In our experience, using the `ProbitLink` for logistic regressions deliver better results than `LogitLink` (which is the canonical link). But of course, one should choose the link that gives the higher loglikelihood. 

### Step 3: Run full model on the best estimated model size 

`cv_iht` finished in about a minute. 

Cross validation have declared that $k_{best} = 8$. Using this information, one can re-run the IHT algorithm on the *full* dataset to obtain the best estimated model.


```julia
k_est = argmin(mses)
result = L0_reg(x, xbm, z, y, 1, k_est, d(), l)
```




    
    IHT estimated 6 nonzero SNP predictors and 2 non-genetic predictors.
    
    Compute time (sec):     1.6644580364227295
    Final loglikelihood:    -290.4509381564733
    Iterations:             37
    
    Selected genetic predictors:
    6×2 DataFrame
    │ Row │ Position │ Estimated_β │
    │     │ [90mInt64[39m    │ [90mFloat64[39m     │
    ├─────┼──────────┼─────────────┤
    │ 1   │ 1152     │ 0.966731    │
    │ 2   │ 1576     │ 1.56183     │
    │ 3   │ 3411     │ 0.87674     │
    │ 4   │ 5765     │ -1.75611    │
    │ 5   │ 5992     │ -2.04506    │
    │ 6   │ 8781     │ 0.760213    │
    
    Selected nongenetic predictors:
    2×2 DataFrame
    │ Row │ Position │ Estimated_β │
    │     │ [90mInt64[39m    │ [90mFloat64[39m     │
    ├─────┼──────────┼─────────────┤
    │ 1   │ 1        │ 0.709909    │
    │ 2   │ 2        │ 1.65049     │



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

#clean up. Windows user must do this step manually (outside notebook/REPL)
rm("tmp.bed", force=true)
```

    compare_model_genetics = 8×2 DataFrame
    │ Row │ true_β   │ estimated_β │
    │     │ Float64  │ Float64     │
    ├─────┼──────────┼─────────────┤
    │ 1   │ 0.961937 │ 0.966731    │
    │ 2   │ 0.189267 │ 0.0         │
    │ 3   │ 1.74008  │ 1.56183     │
    │ 4   │ 0.879004 │ 0.87674     │
    │ 5   │ 0.213066 │ 0.0         │
    │ 6   │ -1.74663 │ -1.75611    │
    │ 7   │ -1.93402 │ -2.04506    │
    │ 8   │ 0.632786 │ 0.760213    │
    compare_model_nongenetics = 2×2 DataFrame
    │ Row │ true_c  │ estimated_c │
    │     │ Float64 │ Float64     │
    ├─────┼─────────┼─────────────┤
    │ 1   │ 1.0     │ 0.709909    │
    │ 2   │ 1.5     │ 1.65049     │


## Example 4: Poisson Regression with Acceleration (i.e. debias)

In this example, we show how debiasing can potentially achieve dramatic speedup. Our model is:

$$y_i \sim \rm Poisson(\mathbf{x}_i^T \mathbf{\beta})$$
$$x_{ij} \sim \rm Binomial(2, \rho_j)$$
$$\rho_j \sim \rm Uniform(0, 0.5)$$
$$\beta_i \sim \rm N(0, 0.3)$$


```julia
# Define model dimensions, true model size, distribution, and link functions
n = 1000
p = 10000
k = 10
d = Poisson
l = canonicallink(d())

# set random seed for reproducibility
Random.seed!(2019)

# construct SnpArray, SnpBitMatrix, and intercept
x = simulate_random_snparray(n, p, "tmp.bed")
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
    │ 1   │ 853      │ -0.389892  │ -0.384161   │ -0.38744     │
    │ 2   │ 877      │ -0.0653099 │ 0.0         │ 0.0          │
    │ 3   │ 924      │ 0.235865   │ 0.246213    │ 0.240514     │
    │ 4   │ 2703     │ 0.17977    │ 0.237651    │ 0.225127     │
    │ 5   │ 4241     │ 0.0851134  │ 0.0         │ 0.0894244    │
    │ 6   │ 4783     │ -0.33761   │ -0.300663   │ -0.307515    │
    │ 7   │ 5094     │ 0.208012   │ 0.223384    │ 0.215149     │
    │ 8   │ 5284     │ -0.203127  │ -0.225593   │ -0.209308    │
    │ 9   │ 7760     │ 0.0441809  │ 0.0         │ 0.0          │
    │ 10  │ 8255     │ 0.310431   │ 0.287363    │ 0.301717     │


### Compare Speed and Memory Usage

Now we illustrate that debiasing may dramatically reduce computational time (in this case ~50%), at a cost of increasing the memory usage. In practice, this extra memory usage hardly matters because the matrix size will dominate for larger problems. See [our paper for complete benchmark figure.](https://www.biorxiv.org/content/10.1101/697755v2)


```julia
@benchmark L0_reg(x, xbm, z, y, 1, k, d(), l, debias=false) seconds=15
```




    BenchmarkTools.Trial: 
      memory estimate:  2.16 MiB
      allocs estimate:  738
      --------------
      minimum time:     673.188 ms (0.00% GC)
      median time:      706.368 ms (0.00% GC)
      mean time:        708.080 ms (0.04% GC)
      maximum time:     741.125 ms (0.00% GC)
      --------------
      samples:          22
      evals/sample:     1




```julia
@benchmark L0_reg(x, xbm, z, y, 1, k, d(), l, debias=true) seconds=15
```




    BenchmarkTools.Trial: 
      memory estimate:  2.62 MiB
      allocs estimate:  1135
      --------------
      minimum time:     337.368 ms (0.00% GC)
      median time:      350.194 ms (0.00% GC)
      mean time:        349.958 ms (0.10% GC)
      maximum time:     358.095 ms (0.00% GC)
      --------------
      samples:          43
      evals/sample:     1




```julia
#clean up. Windows user must do this step manually (outside notebook/REPL)
rm("tmp.bed", force=true)
```

## Example 5: Negative Binomial regression with group information 

In this example, we show how to include group information to perform doubly sparse projections. Here the final model would contain at most $J = 5$ groups where each group contains limited number of (prespecified) SNPs. For simplicity, we assume the sparsity parameter $k$ is known. 

### Data simulation
To illustrate the effect of group information and prior weights, we generated correlated genotype matrix according to the procedure outlined in [our paper](https://www.biorxiv.org/content/biorxiv/early/2019/11/19/697755.full.pdf). In this example, each SNP belongs to 1 of 500 disjoint groups containing 20 SNPs each; $j = 5$ distinct groups are each assigned $1,2,...,5$ causal SNPs with effect sizes randomly chosen from $\{−0.2,0.2\}$. In all there 15 causal SNPs.  For grouped-IHT, we assume perfect group information. That is, the selected groups containing 1∼5 causative SNPs are assigned maximum within-group sparsity $\lambda_g = 1,2,...,5$. The remaining groups are assigned $\lambda_g = 1$ (i.e. only 1 active predictor are allowed).


```julia
# define problem size
d = NegativeBinomial
l = LogLink()
n = 1000
p = 10000
block_size = 20                  #simulation parameter
num_blocks = Int(p / block_size) #simulation parameter

# set seed
Random.seed!(2019)

# assign group membership
membership = collect(1:num_blocks)
g = zeros(Int64, p + 1)
for i in 1:length(membership)
    for j in 1:block_size
        cur_row = block_size * (i - 1) + j
        g[block_size*(i - 1) + j] = membership[i]
    end
end
g[end] = membership[end]

#simulate correlated snparray
x = simulate_correlated_snparray(n, p, "tmp.bed")
z = ones(n, 1) # the intercept
x_float = convert(Matrix{Float64}, x, model=ADDITIVE_MODEL, center=true, scale=true)

#simulate true model, where 5 groups each with 1~5 snps contribute
true_b = zeros(p)
true_groups = randperm(num_blocks)[1:5]
sort!(true_groups)
within_group = [randperm(block_size)[1:1], randperm(block_size)[1:2], 
                randperm(block_size)[1:3], randperm(block_size)[1:4], 
                randperm(block_size)[1:5]]
correct_position = zeros(Int64, 15)
for i in 1:5
    cur_group = block_size * (true_groups[i] - 1)
    cur_group_snps = cur_group .+ within_group[i]
    start, last = Int(i*(i-1)/2 + 1), Int(i*(i+1)/2)
    correct_position[start:last] .= cur_group_snps
end
for i in 1:15
    true_b[correct_position[i]] = rand(-1:2:1) * 0.2
end
sort!(correct_position)

# simulate phenotype
r = 10 #nuisance parameter
μ = GLM.linkinv.(l, x_float * true_b)
clamp!(μ, -20, 20)
prob = 1 ./ (1 .+ μ ./ r)
y = [rand(d(r, i)) for i in prob] #number of failures before r success occurs
y = Float64.(y);
```


```julia
#run IHT without groups
k = 15
ungrouped = L0_reg(x_float, z, y, 1, k, d(), l, verbose=false)
```




    
    IHT estimated 15 nonzero SNP predictors and 0 non-genetic predictors.
    
    Compute time (sec):     0.11840415000915527
    Final loglikelihood:    -1441.522293255591
    Iterations:             27
    
    Selected genetic predictors:
    15×2 DataFrame
    │ Row │ Position │ Estimated_β │
    │     │ [90mInt64[39m    │ [90mFloat64[39m     │
    ├─────┼──────────┼─────────────┤
    │ 1   │ 3464     │ -0.234958   │
    │ 2   │ 4383     │ -0.135693   │
    │ 3   │ 4927     │ 0.158171    │
    │ 4   │ 4938     │ -0.222613   │
    │ 5   │ 5001     │ -0.193739   │
    │ 6   │ 5011     │ -0.162718   │
    │ 7   │ 5018     │ -0.190532   │
    │ 8   │ 5090     │ 0.226509    │
    │ 9   │ 5092     │ -0.17756    │
    │ 10  │ 5100     │ -0.140337   │
    │ 11  │ 7004     │ 0.151748    │
    │ 12  │ 7011     │ 0.206449    │
    │ 13  │ 7015     │ -0.284706   │
    │ 14  │ 7016     │ 0.218126    │
    │ 15  │ 9902     │ 0.119059    │
    
    Selected nongenetic predictors:
    0×2 DataFrame





```julia
#run doubly sparse (group) IHT by specifying maximum number of SNPs for each group (in order)
J = 5
max_group_snps = ones(Int, num_blocks)
max_group_snps[true_groups] .= collect(1:5)
variable_group = L0_reg(x_float, z, y, J, max_group_snps, d(), l, verbose=false, group=g)
```




    
    IHT estimated 15 nonzero SNP predictors and 0 non-genetic predictors.
    
    Compute time (sec):     0.30719614028930664
    Final loglikelihood:    -1446.3808810786898
    Iterations:             16
    
    Selected genetic predictors:
    15×2 DataFrame
    │ Row │ Position │ Estimated_β │
    │     │ [90mInt64[39m    │ [90mFloat64[39m     │
    ├─────┼──────────┼─────────────┤
    │ 1   │ 3464     │ -0.245853   │
    │ 2   │ 4927     │ 0.160904    │
    │ 3   │ 4938     │ -0.213439   │
    │ 4   │ 5001     │ -0.19624    │
    │ 5   │ 5011     │ -0.149913   │
    │ 6   │ 5018     │ -0.181966   │
    │ 7   │ 5086     │ -0.0560478  │
    │ 8   │ 5090     │ 0.21164     │
    │ 9   │ 5092     │ -0.141968   │
    │ 10  │ 5100     │ -0.157655   │
    │ 11  │ 7004     │ 0.190224    │
    │ 12  │ 7011     │ 0.21294     │
    │ 13  │ 7015     │ -0.256058   │
    │ 14  │ 7016     │ 0.19746     │
    │ 15  │ 7020     │ 0.111755    │
    
    Selected nongenetic predictors:
    0×2 DataFrame




### Group IHT found 1 more SNPs than ungrouped IHT


```julia
#check result
correct_position = findall(!iszero, true_b)
compare_model = DataFrame(
    position = correct_position,
    correct_β = true_b[correct_position],
    ungrouped_IHT_β = ungrouped.beta[correct_position], 
    grouped_IHT_β = variable_group.beta[correct_position])
@show compare_model
println("\n")

#clean up. Windows user must do this step manually (outside notebook/REPL)
rm("tmp.bed", force=true)
```

    compare_model = 15×4 DataFrame
    │ Row │ position │ correct_β │ ungrouped_IHT_β │ grouped_IHT_β │
    │     │ Int64    │ Float64   │ Float64         │ Float64       │
    ├─────┼──────────┼───────────┼─────────────────┼───────────────┤
    │ 1   │ 3464     │ -0.2      │ -0.234958       │ -0.245853     │
    │ 2   │ 4927     │ 0.2       │ 0.158171        │ 0.160904      │
    │ 3   │ 4938     │ -0.2      │ -0.222613       │ -0.213439     │
    │ 4   │ 5001     │ -0.2      │ -0.193739       │ -0.19624      │
    │ 5   │ 5011     │ -0.2      │ -0.162718       │ -0.149913     │
    │ 6   │ 5018     │ -0.2      │ -0.190532       │ -0.181966     │
    │ 7   │ 5084     │ -0.2      │ 0.0             │ 0.0           │
    │ 8   │ 5090     │ 0.2       │ 0.226509        │ 0.21164       │
    │ 9   │ 5098     │ -0.2      │ 0.0             │ 0.0           │
    │ 10  │ 5100     │ -0.2      │ -0.140337       │ -0.157655     │
    │ 11  │ 7004     │ 0.2       │ 0.151748        │ 0.190224      │
    │ 12  │ 7011     │ 0.2       │ 0.206449        │ 0.21294       │
    │ 13  │ 7015     │ -0.2      │ -0.284706       │ -0.256058     │
    │ 14  │ 7016     │ 0.2       │ 0.218126        │ 0.19746       │
    │ 15  │ 7020     │ 0.2       │ 0.0             │ 0.111755      │
    
    


## Example 6: Linear Regression with prior weights

In this example, we show how to include (predetermined) prior weights for each SNP. You can check out [our paper](https://www.biorxiv.org/content/biorxiv/early/2019/11/19/697755.full.pdf) for references of why/how to choose these weights. In this case, we mimic our paper and randomly set $10\%$ of all SNPs to have a weight of $2.0$. Other predictors have weight of $1.0$. All causal SNPs have weights of $2.0$. Under this scenario, SNPs with weight $2.0$ is twice as likely to enter the model identified by IHT. 

Our model is simulated as:

$$y_i \sim \mathbf{x}_i^T\mathbf{\beta} + \epsilon_i$$
$$x_{ij} \sim \rm Binomial(2, \rho_j)$$
$$\rho_j \sim \rm Uniform(0, 0.5)$$
$$\epsilon_i \sim \rm N(0, 1)$$
$$\beta_i \sim \rm N(0, 1)$$


```julia
#random seed
Random.seed!(4)

d = Normal
l = canonicallink(d())
n = 1000
p = 10000
k = 10

# construct snpmatrix, covariate files, and true model b
x = simulate_random_snparray(n, p, "tmp.bed")
X = convert(Matrix{Float64}, x, center=true, scale=true)
z = ones(n, 1) # the intercept
    
#define true_b 
true_b = zeros(p)
true_b[1:10] .= collect(0.1:0.1:1.0)
shuffle!(true_b)
correct_position = findall(!iszero, true_b)

#simulate phenotypes (e.g. vector y)
prob = GLM.linkinv.(l, X * true_b)
clamp!(prob, -20, 20)
y = [rand(d(i)) for i in prob]
y = Float64.(y);
```


```julia
# construct weight vector
w = ones(p + 1)
w[correct_position] .= 2.0
one_tenth = round(Int, p/10)
idx = rand(1:p, one_tenth)
w[idx] .= 2.0; #randomly set ~1/10 of all predictors to 2
```


```julia
#run IHT
unweighted = L0_reg(X, z, y, 1, k, d(), l, verbose=false)
weighted   = L0_reg(X, z, y, 1, k, d(), l, verbose=false, weight=w)

#check result
compare_model = DataFrame(
    position    = correct_position,
    correct     = true_b[correct_position],
    unweighted  = unweighted.beta[correct_position], 
    weighted    = weighted.beta[correct_position])
@show compare_model
println("\n")

#clean up. Windows user must do this step manually (outside notebook/REPL)
rm("tmp.bed", force=true)
```

    compare_model = 10×4 DataFrame
    │ Row │ position │ correct │ unweighted │ weighted │
    │     │ Int64    │ Float64 │ Float64    │ Float64  │
    ├─────┼──────────┼─────────┼────────────┼──────────┤
    │ 1   │ 1254     │ 0.4     │ 0.452245   │ 0.450405 │
    │ 2   │ 1495     │ 0.3     │ 0.306081   │ 0.305738 │
    │ 3   │ 4856     │ 0.8     │ 0.853536   │ 0.862223 │
    │ 4   │ 5767     │ 0.1     │ 0.0        │ 0.117286 │
    │ 5   │ 5822     │ 0.7     │ 0.656213   │ 0.651908 │
    │ 6   │ 5945     │ 0.9     │ 0.891915   │ 0.894997 │
    │ 7   │ 6367     │ 0.5     │ 0.469718   │ 0.472524 │
    │ 8   │ 6996     │ 1.0     │ 0.963236   │ 0.973512 │
    │ 9   │ 7052     │ 0.6     │ 0.602162   │ 0.600055 │
    │ 10  │ 7980     │ 0.2     │ 0.231389   │ 0.234094 │
    
    


In this case, weighted IHT found an extra predictor than non-weighted IHT.

## Other examples and functionalities

We explored a few more examples in our manuscript, with [reproducible code](https://github.com/biona001/MendelIHT.jl/tree/master/figures). We invite users to experiment with them as well. 
