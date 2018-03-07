##############
##ABC-Rejection code
##############

"
`abcRejection` has various methods.
Possible arguments are as follows:

* `in`
An `ABCInput` variable.

* `nsims`
How many simulations to perform.

* `k`
How many simulations to accept (an integer).

* `h`
Acceptance threshold (floating point).

* `store_init`.
Whether to return simulations used to initialise the distance function.

The methods are:

* `(in, nsims, k; store_init)`
Performs ABC accepting k simulations.

* `(in, nsims, h; store_init)`
Performs ABC accepting simulations with distance below the threshold h.

* `(in, nsims; store_init)`
Performs ABC accepting everything.

The output is a `ABCRejOutput` object.
"
function abcRejection(in::ABCInput, nsims::Integer; store_init=false)
    nparameters = length(in.prior)
    parameters = Array{Float64}(nparameters, nsims)
    sumstats = zeros(Float64, (in.nsumstats, nsims))
    successes = Array{Bool}(nsims)
    prog = Progress(nsims, 1) ##Progress meter
    for i in 1:nsims
        pars = rand(in.prior)
        parameters[:,i] = pars
        (success, stats) = in.sample_sumstats(pars)
        successes[i] = success
        if (success)
            sumstats[:,i] = stats
        end
        next!(prog)
    end
    nsuccesses = sum(successes)
    parameters = parameters[:, successes]
    sumstats = sumstats[:, successes]
    newdist = init(in.abcdist, sumstats, parameters)
    distances = Float64[evaldist(newdist, sumstats[:,i]) for i=1:nsuccesses]
    if (store_init)
        init_sims = sumstats
        init_pars = parameters
    else
        init_sims = Array{Float64}(0,0)
        init_pars = Array{Float64}(0,0)
    end
    out = ABCRejOutput(nparameters, in.nsumstats, nsims, nsuccesses, parameters, sumstats, distances, ones(nsims), newdist, init_sims, init_pars)
    sortABCOutput!(out)
    out
end

##Do abcRejection, accepting k closest matches
function abcRejection(in::ABCInput, nsims::Integer, k::Integer; store_init=false)
    out = abcRejection(in, nsims, store_init=store_init)
    out.parameters = out.parameters[:,1:k]
    out.sumstats = out.sumstats[:,1:k]
    out.distances = out.distances[1:k]
    out.weights = out.weights[1:k]
    out
end

##Do abcRejection, accepting distances <= h
function abcRejection(in::ABCInput, nsims::Integer, h::AbstractFloat; store_init=false)
    out = abcRejection(in, nsims, store_init=store_init)
    if (out.distances[nsims] <= h)
        k = out.nsuccesses
    else
        k = findfirst((x)->x>h, out.distances) - 1
    end
    ##nb the following works sensibly even if k==0
    out.parameters = out.parameters[:,1:k]
    out.sumstats = out.sumstats[:,1:k]
    out.distances = out.distances[1:k]
    out.weights = out.weights[1:k]
    out
end
