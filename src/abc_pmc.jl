"
Perform a version of ABC-PMC.
This is the new algorithm proposed by the paper, Algorithm 4.
Its arguments are as follows:

* `abcinput`
An `ABCInput` variable.

* `N`
Number of accepted particles in each iteration.

* `α`
A tuning parameter between 0 and 1 determining how fast the acceptance threshold is reduced. (In more detai, the acceptance threshold in iteration t is the α quantile of distances from particles which meet the acceptance criteria of the previous iteration.)

* `maxsims`
The algorithm terminates once this many simulations have been performed.

* `nsims_for_init`
How many simulations are stored to initialise the distance function (by default 10,000).

* `adaptive` (optional)
Whether the distance function should be adapted at each iteration.
By default this is false, giving the variant algorithm mentioned in Section 4.1 of the paper.
When true Algorithm 4 of the paper is implemented.

* `store_init` (optional)
Whether to store the parameters and simulations used to initialise the distance function in each iteration (useful to produce many of the paper's figures).
These are stored for every iteration even if `adaptive` is false.
By default false.

* `diag_perturb` (optional)
Whether perturbation should be based on a diagonalised estimate of the covariance.
By default this is false, giving the perturbation described in Section 2.2 of the paper.

* `silent` (optional)
When true no progress bar or messages are shown during execution.
By default false.

The output is a `ABCPMCOutput` object.
"
function abcPMC(abcinput::ABCInput, N::Integer, α::Float64, maxsims::Integer, nsims_for_init=10000; adaptive=false, store_init=false, diag_perturb=false, silent=false)
    if !silent
        prog = Progress(maxsims, 1) ##Progress meter
    end
    M::Int = ceil(N/α)
    nparameters = length(abcinput.prior)
    itsdone = 0
    simsdone = 0
    firstit = true
    ##We record a sequence of distances and thresholds
    ##(for non-adaptive case all distances the same, and we only use most recent threshold)
    dists = ABCDistance[]
    thresholds = Float64[]
    rejOutputs = ABCRejOutput[]
    cusims = Int[]
    ##Main loop
    while (simsdone < maxsims)
        if !firstit
            wv = WeightVec(curroutput.weights)
            if (diag_perturb)
                ##Calculate diagonalised variance of current weighted particle approximation
                diagvar = Float64[var(vec(curroutput.parameters[i,:]), wv) for i in 1:nparameters]
                perturbdist = MvNormal(2.0 .* diagvar)
            else
                ##Calculate variance of current weighted particle approximation
                currvar = cov(curroutput.parameters, wv, vardim=2)
                perturbdist = MvNormal(2.0 .* currvar)
            end
        end
        ##Initialise new reference table
        newparameters = Array(Float64, (nparameters, M))
        newsumstats = Array(Float64, (abcinput.nsumstats, M))
        newpriorweights = Array(Float64, M)
        successes_thisit = 0
        if (firstit || adaptive || store_init)
            ##Initialise storage of simulated parameter/summary pairs
            sumstats_forinit = Array(Float64, (abcinput.nsumstats, nsims_for_init))
            pars_forinit = Array(Float64, (nparameters, nsims_for_init))
        end
        nextparticle = 1
        ##Loop to fill up new reference table
        while (nextparticle <= M && simsdone<maxsims)
            ##Sample parameters from importance density
            if (firstit)
                proppars = rand(abcinput.prior)
            else
                proppars = rimportance(curroutput, perturbdist)
            end
            ##Calculate prior weight and reject if zero
            priorweight = pdf(abcinput.prior, proppars)
            if (priorweight == 0.0)
                continue
            end          
            ##Draw summaries
            (success, propstats) = abcinput.sample_sumstats(proppars)
            simsdone += 1
            if !silent
                next!(prog)
            end
            if (!success)
                ##If rejection occurred during simulation
                continue
            end
            if ((firstit || adaptive || store_init) && successes_thisit < nsims_for_init)
                successes_thisit += 1
                sumstats_forinit[:,successes_thisit] = propstats
                pars_forinit[:,successes_thisit] = proppars
            end
            if (firstit)
                ##No rejection at this stage in first iteration
                accept = true
            elseif (adaptive)
                ##Accept if all prev distances less than corresponding thresholds
                accept = propgood(propstats, dists, thresholds)
            else
                ##Accept if distance less than current threshold
                accept = propgood(propstats, dists[itsdone], thresholds[itsdone])
            end
            if (accept)
                newparameters[:,nextparticle] = copy(proppars)
                newsumstats[:,nextparticle] = copy(propstats)                
                newpriorweights[nextparticle] = priorweight
                nextparticle += 1
            end
        end
        ##Stop if not all sims required to continue have been done (because simsdone==maxsims)
        if nextparticle<=M
            continue
        end
        ##Update counters
        itsdone += 1
        push!(cusims, simsdone)
        ##Trim pars_forinit and sumstats_forinit to correct size
        if (firstit || adaptive || store_init)
            if (successes_thisit < nsims_for_init)
                sumstats_forinit = sumstats_forinit[:,1:successes_thisit]
                pars_forinit = pars_forinit[:,1:successes_thisit]
            end
        else
            ##Create some empty arrays to use as arguments
            sumstats_forinit = Array(Float64, (0,0))
            pars_forinit = Array(Float64, (0,0))
        end
        ##Create new distance if needed
        if (firstit || adaptive)
            newdist = init(abcinput.abcdist, sumstats_forinit, pars_forinit)
        else
            newdist = dists[1]
        end
        push!(dists, newdist)
        
        ##Calculate distances
        distances = Float64[ evaldist(newdist, newsumstats[:,i]) for i=1:M ]
        if !firstit
            oldoutput = copy(curroutput)
        end
        curroutput = ABCRejOutput(nparameters, abcinput.nsumstats, M, N, newparameters, newsumstats, distances, newpriorweights, newdist, sumstats_forinit, pars_forinit) ##Temporarily use prior weights
        sortABCOutput!(curroutput)
        ##Calculate, store and use new threshold
        newthreshold = curroutput.distances[N]
        push!(thresholds, newthreshold)
        curroutput.parameters = curroutput.parameters[:,1:N]
        curroutput.sumstats = curroutput.sumstats[:,1:N]
        curroutput.distances = curroutput.distances[1:N]
        if firstit
            curroutput.weights = ones(N)
        else
            curroutput.weights = getweights(curroutput, curroutput.weights, oldoutput, perturbdist)
        end
            
        ##Record output
        push!(rejOutputs, curroutput)
        ##Report status
        if !silent
            print("\n Iteration $itsdone, $simsdone sims done\n")
            if firstit
                accrate = N/simsdone            
            else
            accrate = N/(simsdone-cusims[itsdone-1])
            end
            @printf("Acceptance rate %.1e percent\n", 100*accrate)
            print("Output of most recent stage:\n")
            print(curroutput)
            ##TO DO: make some plots as well?
        end
        ##TO DO: consider alternative stopping conditions? (e.g. zero threshold reached)
        firstit = false
    end
        
    ##Put results into ABCPMCOutput object
    parameters = Array(Float64, (nparameters, N, itsdone))
    sumstats = Array(Float64, (abcinput.nsumstats, N, itsdone))
    distances = Array(Float64, (N, itsdone))
    weights = Array(Float64, (N, itsdone))
    for i in 1:itsdone        
        parameters[:,:,i] = rejOutputs[i].parameters
        sumstats[:,:,i] = rejOutputs[i].sumstats
        distances[:,i] = rejOutputs[i].distances
        weights[:,i] = rejOutputs[i].weights
    end
    if (store_init)
        init_sims = Array(Array{Float64, 2}, itsdone)
        init_pars = Array(Array{Float64, 2}, itsdone)
        for i in 1:itsdone
            init_sims[i] = rejOutputs[i].init_sims
            init_pars[i] = rejOutputs[i].init_pars
        end
    else
        init_sims = Array(Array{Float64, 2}, 0)
        init_pars = Array(Array{Float64, 2}, 0)
    end
    output = ABCPMCOutput(nparameters, abcinput.nsumstats, itsdone, simsdone, cusims, parameters, sumstats, distances, weights, dists, thresholds, init_sims, init_pars)
end

##Check if summary statistics meet acceptance requirement
function propgood(s::Array{Float64, 1}, dist::ABCDistance, threshold::Float64)
    return evaldist(dist, s)<=threshold
end

##Check if summary statistics meet all of previous acceptance requirements
function propgood(s::Array{Float64, 1}, dists::Array{ABCDistance, 1}, thresholds::Array{Float64, 1})
    for i in length(dists):-1:1 ##Check the most stringent case first
        if !propgood(s, dists[i], thresholds[i])
            return false
        end
    end
    return true
end

##Samples from importance density defined by prev output
function rimportance(out::ABCRejOutput, dist::MvNormal)
    i = sample(WeightVec(out.weights))
    out.parameters[:,i] + rand(dist)
end

##Calculate a single importance weight        
function get1weight(x::Array{Float64,1}, priorweight::Float64, old::ABCRejOutput, perturbdist::MvNormal)
    nparticles = size(old.parameters)[2]
    temp = Float64[pdf(perturbdist, x-old.parameters[:,i]) for i in 1:nparticles]
    priorweight / sum(old.weights .* temp)
end

##Calculates importance weights
function getweights(current::ABCRejOutput, priorweights::Array{Float64,1}, old::ABCRejOutput, perturbdist::MvNormal)
    nparticles = size(current.parameters)[2]
    weights = Float64[get1weight(current.parameters[:,i], priorweights[i], old, perturbdist) for i in 1:nparticles]
    weights ./ sum(weights)
end

"
Perform a version of ABC-PMC.
This implements the older algorithms reviewed by the paper, Algorithms 2 and 3.
Arguments are as for `abcPMC` with one removal (`adaptive`) and two additions

* `initialise_dist` (optional)
If true (the default) then the distance will be initialised at the end of the first iteration, giving Algorithm 3. If false a distance must be specified which does not need initialisation, giving Algorithm 2.

* `h1` (optional)
The acceptance threshold for the first iteration, by default Inf (accept everything).
If `initialise_dist` is true, then this must be left at its default value.

The output is a `ABCPMCOutput` object.
"   
function abcPMC_comparison(abcinput::ABCInput, N::Integer, α::Float64, maxsims::Integer, nsims_for_init=10000; initialise_dist=true, store_init=false, diag_perturb=false, silent=false, h1=Inf)
    if initialise_dist && h1<Inf
        error("To initialise distance during the algorithm the first threshold must be Inf")
    end
    if !silent
        prog = Progress(maxsims, 1) ##Progress meter
    end
    k::Int = ceil(N*α)
    nparameters = length(abcinput.prior)
    itsdone = 0
    simsdone = 0
    firstit = true
    ##We record a sequence of distances and thresholds
    ##(all distances the same but we record a sequence for consistency with other algorithm)
    dists = ABCDistance[abcinput.abcdist]
    thresholds = Float64[h1]
    rejOutputs = ABCRejOutput[]
    cusims = Int[]
    ##Main loop
    while (simsdone < maxsims)
        if !firstit
            wv = WeightVec(curroutput.weights)
            if (diag_perturb)
                ##Calculate diagonalised variance of current weighted particle approximation
                diagvar = Float64[var(vec(curroutput.parameters[i,:]), wv) for i in 1:nparameters]
                perturbdist = MvNormal(2.0 .* diagvar)
            else
                ##Calculate variance of current weighted particle approximation
                currvar = cov(curroutput.parameters, wv, vardim=2)
                perturbdist = MvNormal(2.0 .* currvar)
            end
        end
        ##Initialise new reference table
        newparameters = Array(Float64, (nparameters, N))
        newsumstats = Array(Float64, (abcinput.nsumstats, N))
        newpriorweights = Array(Float64, N)
        successes_thisit = 0
        if (firstit || store_init)
            ##Initialise storage of simulated parameter/summary pairs
            sumstats_forinit = Array(Float64, (abcinput.nsumstats, nsims_for_init))
            pars_forinit = Array(Float64, (nparameters, nsims_for_init))
        end
        nextparticle = 1
        ##Loop to fill up new reference table
        while (nextparticle <= N && simsdone<maxsims)
            ##Sample parameters from importance density
            if (firstit)
                proppars = rand(abcinput.prior)
            else
                proppars = rimportance(curroutput, perturbdist)
            end
            ##Calculate prior weight and reject if zero
            priorweight = pdf(abcinput.prior, proppars)
            if (priorweight == 0.0)
                continue
            end          
            ##Draw summaries
            (success, propstats) = abcinput.sample_sumstats(proppars)
            simsdone += 1
            if !silent
                next!(prog)
            end
            if (!success)
                ##If rejection occurred during simulation
                continue
            end
            if (((firstit && initialise_dist) || store_init) && successes_thisit < nsims_for_init)
                successes_thisit += 1
                sumstats_forinit[:,successes_thisit] = propstats
                pars_forinit[:,successes_thisit] = proppars
            end
            if (firstit && initialise_dist)
                ##No rejection at this stage in first iteration if we want to initialise distance
                accept = true
            else
                ##Accept if distance less than current threshold
                accept = propgood(propstats, dists[1], thresholds[itsdone+1])
            end
            if (accept)
                newparameters[:,nextparticle] = copy(proppars)
                newsumstats[:,nextparticle] = copy(propstats)                
                newpriorweights[nextparticle] = priorweight
                nextparticle += 1
            end
        end
        ##Stop if not all sims required to continue have been done (because simsdone==maxsims)
        if nextparticle<=N
            continue
        end
        ##Update counters
        itsdone += 1
        push!(cusims, simsdone)
        ##Trim pars_forinit and sumstats_forinit to correct size
        if ((firstit && initialise_dist) || store_init)
            if (successes_thisit < nsims_for_init)
                sumstats_forinit = sumstats_forinit[:,1:successes_thisit]
                pars_forinit = pars_forinit[:,1:successes_thisit]
            end
        end
        ##Create new distance if needed
        if (firstit && initialise_dist)
            newdist = init(dists[1], sumstats_forinit, pars_forinit)
        else
            newdist = dists[1]
        end
        ##Store new distance
        if (firstit)
            dists[1] = newdist
        else
            push!(dists, newdist)
        end
        
        ##Calculate distances
        distances = Float64[ evaldist(newdist, newsumstats[:,i]) for i=1:N ]
        if !firstit
            oldoutput = copy(curroutput)
        end
        curroutput = ABCRejOutput(nparameters, abcinput.nsumstats, N, N, newparameters, newsumstats, distances, newpriorweights, newdist, sumstats_forinit, pars_forinit) ##Temporarily use prior weights
        ##Calculate and store threshold for next iteration
        sortABCOutput!(curroutput)
        newthreshold = curroutput.distances[k]
        push!(thresholds, newthreshold)
        if firstit
            curroutput.weights = ones(N)
        else
            curroutput.weights = getweights(curroutput, curroutput.weights, oldoutput, perturbdist)
        end
            
        ##Record output
        push!(rejOutputs, curroutput)
        ##Report status
        if !silent
            print("\n Iteration $itsdone, $simsdone sims done\n")
            if firstit
                accrate = k/simsdone            
            else
            accrate = k/(simsdone-cusims[itsdone-1])
            end
            @printf("Acceptance rate %.1e percent\n", 100*accrate)
            print("Output of most recent stage:\n")
            print(curroutput)
            print("Next threshold: $(convert(Float32, newthreshold))\n") ##Float64 shows too many significant figures
            ##TO DO: make some plots as well?
        end
        ##TO DO: consider alternative stopping conditions? (e.g. zero threshold reached)
        firstit = false
    end
        
    ##Put results into ABCPMCOutput object
    parameters = Array(Float64, (nparameters, N, itsdone))
    sumstats = Array(Float64, (abcinput.nsumstats, N, itsdone))
    distances = Array(Float64, (N, itsdone))
    weights = Array(Float64, (N, itsdone))
    for i in 1:itsdone        
        parameters[:,:,i] = rejOutputs[i].parameters
        sumstats[:,:,i] = rejOutputs[i].sumstats
        distances[:,i] = rejOutputs[i].distances
        weights[:,i] = rejOutputs[i].weights
    end
    if (store_init)
        init_sims = Array(Array{Float64, 2}, itsdone)
        init_pars = Array(Array{Float64, 2}, itsdone)
        for i in 1:itsdone
            init_sims[i] = rejOutputs[i].init_sims
            init_pars[i] = rejOutputs[i].init_pars
        end
    else
        init_sims = Array(Array{Float64, 2}, 0)
        init_pars = Array(Array{Float64, 2}, 0)
    end
    output = ABCPMCOutput(nparameters, abcinput.nsumstats, itsdone, simsdone, cusims, parameters, sumstats, distances, weights, dists, thresholds, init_sims, init_pars)
end
