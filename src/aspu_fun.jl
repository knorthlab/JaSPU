#returns SPU(gamma) for all gammas. Very fast
function getspu!(spu, pows, z, n)
  for i in eachindex(pows)
    @inbounds pows[i] < 0 && (spu[i] = z[1]^(pows[i]))
    @inbounds pows[i] == 0 && (spu[i] = abs(z[1]))
  end
  for j = 2:n
    for i in eachindex(pows)
      @inbounds (pows[i] < 0) && (spu[i] += z[j]^(pows[i]))
      @inbounds (pows[i] == 0) && (abs(z[j]) > spu[i]) && (spu[i] = abs(z[j]))
    end
  end
  for i = eachindex(pows)
    @inbounds spu[i] = abs(spu[i])
  end
end

function getspu(pows::Array{Int64, 1}, z::Vector{T}, n::Int64) where {T<:Real}
  tmpspu = Array{T}(undef, length(pows))
  getspu!(tmpspu,pows,z,n)
  tmpspu
end

#get highest SPU(gamma) rank across gamma
function rank_spus!(rnk::AbstractArray{Int64, 2}, zb::Array{T,2}, B = size(zb, 2)) where {T<:Real}
  rnk1_v = view(rnk,1,1:B)
  for i in 1:B
    rnk1_v[i] = i
  end
  quicksort!(zb[1,1:B], rnk1_v)
  for (i, val) in enumerate(rnk1_v)
    rnk[2,val] = i
    rnk1_v[i] = i
  end
  for i in 2:(size(zb,1)-1)
    quicksort!(zb[i,1:B], rnk1_v)
    for (j, val) in enumerate(rnk1_v)
      rnk[2,val] < j && (rnk[2,val] = j)
      rnk1_v[j] = j
    end
  end
  quicksort!(zb[size(rnk,1),1:B], rnk1_v)
  for (j, val) in enumerate(rnk1_v)
    rnk[2,val] < j && (rnk[2,val] = j)
  end
  0
end


#add values exceeding threshold to array
function create_arref(ntest, mvn, thresh, pows)
    tmp = zeros(Float64, length(pows))
    np = length(pows)
    ntraits = length(mvn)
    out = zeros(Float64, length(pows), ntest)
    n = 0
    narr = zeros(Int, length(pows))
    ran = rand(mvn, ntest)
    for i in 1:ntest
        getspu!(tmp, pows, ran[:,i], ntraits)
        topind = tmp .> thresh
        for p in eachindex(pows)[topind]
            narr[p] += 1
        end
        if sum(topind) > 0
            n += 1
            out[:, n] = tmp
        end
    end
    n, narr, out
end

#parallel functions
function do_initwork(jobs, results)
    ntest = 1
    while ntest > 0
        pows, mvn, ntest, thresh = take!(jobs)
        out = create_arref(ntest, mvn, thresh, pows)
        put!(results, out)
    end
end

function init_aspu_par(pows, mvn, ntest, maxiter; trans = Matrix{Float64}(I,length(mvn),length(mvn)))

    maxchunks = Int(maxiter/ntest)
    ntraits = length(mvn)
    ranspu = zeros(length(pows), ntest)
    tmp = zeros(length(pows))
    maxin = zeros(Int, ceil(Int, 1+log10(maxiter/ntest)))
    maxin_arr = zeros(Int, length(pows), ceil(Int, 1+log10(maxiter/ntest)))

    #for parallel; define channels and start workers
    jobs = RemoteChannel(()->Channel{Any}(maxchunks))
    results = RemoteChannel(()->Channel{Any}(maxchunks))
    for p in workers()
      remote_do(do_initwork, p, jobs, results)
    end;

    #big data structure to hold simulations
    allvals = [zeros(length(pows), ntest*10) for i in 1:ceil(Int, 1+log10(maxiter/ntest))]

    #fill first bucket to the brim
    ran = rand(mvn, ntest)
    for i in 1:ntest
        getspu!(view(allvals[1],:,i), pows, ran[:,i], ntraits)
    end
    maxin[1] = ntest
    fill!(view(maxin_arr,:,1), ntest)

    #pass each bucket of values to workers
    for i in eachindex(allvals)[2:end]
        iternow = ntest*10^(i-1)
        thresh = [partialsort(view(allvals[i-1],j,:), Int(ntest*0.10); rev = true) for j in eachindex(pows)]
        fullchunks = floor(Int, iternow/ntest)

        for chunk in 1:fullchunks
            put!(jobs, (pows, mvn, ntest, thresh))
        end
        for chunk in 1:fullchunks
            tn, tnarr, tout = take!(results)
            maxin_arr[:,i] = maxin_arr[:,i] .+ tnarr
            allvals[i][:, (maxin[i]+1) : (maxin[i]+tn)] = tout[:, 1:tn]
            maxin[i] += tn
        end
    end

    allranks = [ zeros(Int, 2, n) for n in maxin ]

    [ rank_spus!(allranks[i], allvals[i], maxin[i]) for i in eachindex(allvals) ]
    allsorted = [ [ sort(allvals[i][g,:],rev=true)[1:maxin_arr[g,i]] for g in eachindex(pows) ] for i in eachindex(allvals) ]

    allsorted, allranks, maxin_arr, maxin
end


function getaspu(z, allsorted, allranks, maxin_arr, maxin, pows)
    spu = getspu(pows, z, length(z))
    pval = zeros(Int, size(allsorted[1],1))
    ind_p = fill(length(allsorted), length(pows))
    i = 0
    B = maxin[1]
    while minimum(pval) < 850 && i < length(allsorted)
        i += 1
        for k in eachindex(pows)
            pval[k] = sum( spu[k] .< allsorted[i][k][1:maxin_arr[k, i]] )
            (ind_p[k] > i && pval[k] > 850) && (ind_p[k] = i)
        end
    end
    minp, gamma = findmin(pval)
    aspu_n = count(x->(x > maxin[i] - minp), allranks[i][2,:])
    aspu_p = (aspu_n + 1) / (B*10^(i-1) + 1)
    p_out = (pval .+ 1) ./ (B .* 10 .^ (ind_p .- 1) .+ 1)

    aspu_p, p_out, gamma
end

#Arguments are passed once through the channel, then workers are started
function do_aspuwork(vars, jobs, results)
    allsorted, allranks, maxin_arr, maxin, pows, delim, trans = take!(vars)
    while true
        line = take!(jobs)
        ls = split(line, delim)
        z = trans*parse.(Float64, ls[2:end])
        out = getaspu(z, allsorted, allranks, maxin_arr, maxin, pows)
        put!(results, (ls, out))
    end
end

function aspu(
    filename, outfile=string("aspu_results_", basename(filename));
    covfile="", delim = '\t',
    pows = collect(0:8), invcor=false, plim = 1e-5,
    maxiter = Int(1e7), ntest = Int(1e4),
    header = true, skip = 1,
    outtest=Inf, verbose = true
    )

    Σ = cov_io(filename; delim = delim)
    mvn = invcor ? MvNormal(inv(Σ)) : MvNormal(Σ)
    trans = invcor ? inv(Σ) : one(Σ)
    ntraits = length(mvn)

    verbose && begin
        println("Covariance matrix computed")
        display(Σ)
    end

    #Run simulations, and store forever
    allsorted, allranks, maxin_arr, maxin = init_aspu_par(pows, mvn, ntest, maxiter)
    verbose && println("\nSimulations initialized")

    #Open input and output files
    fout = outfile == "" ? stdout : open(outfile, "w")
    f = open(filename, "r")

    #write header
    line1 = header ? readline(f) : join(["snpid",[string("z",i) for i in 1:ntraits]...], delim)
    join(fout, vcat(line1, "aspu_p", map(*, fill("p_spu_",length(pows)), string.(pows)), "gamma", '\n'), delim, "")

    #for parallel
    buffer_s = min(10*nworkers(), outtest)
    jobs = RemoteChannel(()->Channel{String}(buffer_s))
    results = RemoteChannel(()->Channel{Any}(buffer_s))
    vars = RemoteChannel(()->Channel{Any}(length(workers())))

    for p in workers()
        put!(vars, (allsorted, allranks, maxin_arr, maxin, pows, delim, trans))
        remote_do(do_aspuwork, p, vars, jobs, results)
    end

    verbose && println("Processing file...")
    #start jobs
    buffer_n = 0
    for i in 1:buffer_s
        line = readline(f)
        eof(f) && break
        put!(jobs, line)
        buffer_n += 1
    end

    #cycle through input file
    outtest2 = outtest - length(buffer_s)
    for (n, line) in enumerate(eachline(f))
        n > outtest2 && break
        put!(jobs, line)
        out = take!(results)
        join(fout, vcat(out[1], out[2]..., '\n'), delim, "")
    end

    #clear out buffer
    for i in 1:buffer_n
        out = take!(results)
        join(fout, vcat(out[1], out[2]..., '\n'), delim, "")
    end

    #close files
    close(fout)
    close(f)
end
