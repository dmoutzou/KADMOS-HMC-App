#=============================================================================
KADMOS HMC App — backend
A small local web server that drives the KADMOS HMC inversion
(KADMOS_functions.jl, used unchanged) from the browser interface in app/web.

  * The inversion runs on worker threads; the web server lives on the
    interactive thread, so the interface stays responsive during long runs.
  * Live progress (draws, forward-model evaluations, log messages) is taken
    from the log records that Turing and KADMOS already emit, through a
    custom logger. The same logger is used to stop a run on request.
  * Results are written exactly as RUN_KADMOS_HMC.jl writes them.

D. Moutzouris — KADMOS HMC (2025–2026)
=============================================================================#

using HTTP, JSON3, Logging, Sockets, Statistics, Printf, Dates

const WEB_DIR     = joinpath(APP_DIR, "app", "web")
const RESULTS_DIR = joinpath(APP_DIR, "results")
const APP_VERSION = "2.0"

const PARAM_SYMS   = [:T0, :SCR, :Lr, :tlim]
const PARAM_XLABEL = ["Initial Temperature (°C)", "Initial Cooling Rate (°C/Myr)",
                      "Effective Grain Size (μm)", "Total Model Time (Myr)"]
const PARAM_YLABEL = ["Probability Density (1/°C)", "Probability Density (Myr/°C)",
                      "Probability Density (1/μm)", "Probability Density (1/Myr)"]

const MINERALS = ["Muscovite1", "Muscovite2", "Hornblende1", "Hornblende2",
                  "Biotite1", "Biotite2", "Biotite3", "Biotite4", "Orthoclase", "custom"]
const PATH_TYPES = ["asy-CR", "lin-CR", "lin-P-T", "iso-T", "loaded"]

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------

# JSON cannot hold NaN/Inf: turn them into `nothing` (null) recursively
clean(x::AbstractFloat) = isfinite(x) ? Float64(x) : nothing
clean(x::Missing) = nothing
clean(x::AbstractDict) = Dict(string(k) => clean(v) for (k, v) in x)
clean(x::NamedTuple) = Dict(string(k) => clean(v) for (k, v) in pairs(x))
clean(x::AbstractVector) = [clean(v) for v in x]
clean(x::Tuple) = [clean(v) for v in x]
clean(x) = x

json_response(obj; status = 200) =
    HTTP.Response(status, ["Content-Type" => "application/json; charset=utf-8",
                           "Cache-Control" => "no-store"], JSON3.write(clean(obj)))
error_response(msg; status = 400) = json_response(Dict("error" => msg); status = status)

const MIME = Dict(".html" => "text/html; charset=utf-8", ".js" => "application/javascript; charset=utf-8",
                  ".css" => "text/css; charset=utf-8", ".png" => "image/png", ".svg" => "image/svg+xml",
                  ".pdf" => "application/pdf", ".csv" => "text/csv; charset=utf-8",
                  ".txt" => "text/plain; charset=utf-8", ".json" => "application/json; charset=utf-8",
                  ".dat" => "text/plain; charset=utf-8", ".ico" => "image/x-icon")

function file_response(path; download = false)
    isfile(path) || return error_response("File not found"; status = 404)
    headers = ["Content-Type" => get(MIME, lowercase(splitext(path)[2]), "application/octet-stream"),
               "Cache-Control" => "no-cache"]
    download && push!(headers, "Content-Disposition" => "attachment; filename=\"$(basename(path))\"")
    return HTTP.Response(200, headers, read(path))
end

valid_name(s) = !isempty(s) && length(s) <= 120 && occursin(r"^[A-Za-z0-9_\-. ]+$", s) &&
                !startswith(s, ".") && !occursin("..", s)

# path inside `root` only (no escaping through ../ or absolute paths)
function safe_join(root, rel)
    p = normpath(joinpath(root, rel))
    r = normpath(root)
    (p == r || startswith(p, r * Base.Filesystem.path_separator)) || return nothing
    return p
end

function open_in_file_browser(path)
    try
        if Sys.iswindows()
            run(`explorer $(path)`; wait = false)
        elseif Sys.isapple()
            run(`open $(path)`; wait = false)
        else
            run(`xdg-open $(path)`; wait = false)
        end
        return true
    catch e
        @warn "Could not open folder" exception = e
        return false
    end
end

# ----------------------------------------------------------------------------
# Run state
# ----------------------------------------------------------------------------

struct RunCancelled <: Exception end
Base.showerror(io::IO, ::RunCancelled) = print(io, "Run stopped by the user")

mutable struct ChainState
    index::Int
    seed::Int
    dir::String
    state::String          # queued | running | done | error | cancelled
    progress::Float64      # 0..1 of all iterations (adaptation + draws)
    evals::Int
    started::Float64
    finished::Float64
    message::String
end

mutable struct Job
    id::Int
    name::String
    dir::String
    state::String          # running | plotting | done | error | cancelled
    phase::String
    started::Float64
    finished::Float64
    parallel::Bool
    chains::Vector{ChainState}
    log::Vector{Dict{String,Any}}
    cancel::Threads.Atomic{Bool}
    lock::ReentrantLock
    error::String
end

const JOB_LOCK    = ReentrantLock()
const CURRENT_JOB = Ref{Union{Job,Nothing}}(nothing)
const JOB_COUNTER = Ref(0)
const MAX_LOG     = 3000

function push_log!(job::Job, level::String, msg::AbstractString; chain::Int = 0)
    lock(job.lock) do
        # collapse identical consecutive messages (e.g. repeated numerical-error warnings)
        if !isempty(job.log)
            last = job.log[end]
            if last["msg"] == msg && last["chain"] == chain && last["level"] == level
                last["count"] += 1
                last["time"] = time()
                last["seq"] = (JOB_LOG_SEQ[] += 1)
                return
            end
        end
        seq = (JOB_LOG_SEQ[] += 1)
        push!(job.log, Dict{String,Any}("seq" => seq, "id" => seq, "time" => time(), "level" => level,
                                        "msg" => String(msg), "chain" => chain, "count" => 1))
        length(job.log) > MAX_LOG && deleteat!(job.log, 1:(length(job.log) - MAX_LOG))
    end
end
const JOB_LOG_SEQ = Ref(0)

# ----------------------------------------------------------------------------
# Logger: live progress + cancellation, without touching KADMOS_functions.jl
# ----------------------------------------------------------------------------

struct GuiLogger <: AbstractLogger
    job::Job
    chain::Int
end
# ProgressLevel (-1) is accepted, so Turing/AbstractMCMC reports its progress to this logger
Logging.min_enabled_level(::GuiLogger) = LogLevel(-1)
Logging.shouldlog(::GuiLogger, args...) = true
Logging.catch_exceptions(::GuiLogger) = false

function Logging.handle_message(l::GuiLogger, level, message, _module, group, id, file, line; kwargs...)
    job = l.job
    cs = job.chains[l.chain]
    job.cancel[] && throw(RunCancelled())
    if haskey(kwargs, :progress)                      # sampler progress record
        p = kwargs[:progress]
        if p isa Real && isfinite(p)
            cs.progress = clamp(Float64(p), 0.0, 1.0)
        elseif p == "done"
            cs.progress = 1.0
        end
        return nothing
    end
    msg = message isa AbstractString ? message : string(message)
    m = match(r"(?:Total KADMOS evaluations|Total forward model evaluations): (\d+)", msg)
    if m !== nothing
        cs.evals = parse(Int, m.captures[1])
        startswith(msg, "Total KADMOS") && return nothing   # frequent counter: not written to the log
    end
    level < Logging.Info && return nothing
    lvl = level >= Logging.Error ? "error" : level >= Logging.Warn ? "warn" : "info"
    extra = [string(k, " = ", v isa AbstractFloat ? round(v; sigdigits = 4) : v) for (k, v) in kwargs
             if !startswith(string(k), "_") && k != :exception && (v isa Number || v isa AbstractString || v isa Symbol)]
    isempty(extra) || (msg = string(msg, " (", join(extra, ", "), ")"))
    push_log!(job, lvl, first(msg, 400); chain = l.chain)
    return nothing
end

# ----------------------------------------------------------------------------
# Configuration → KADMOS params (same NamedTuple as RUN_KADMOS_HMC.jl)
# ----------------------------------------------------------------------------

getnum(cfg, k) = (v = cfg[k]; v isa Number ? Float64(v) : parse(Float64, string(v)))
getint(cfg, k) = (v = cfg[k]; v isa Integer ? Int(v) : round(Int, getnum(cfg, k)))
getstr(cfg, k) = string(cfg[k])
getnum(cfg, k, default) = haskey(cfg, k) ? getnum(cfg, k) : Float64(default)
getstr(cfg, k, default) = haskey(cfg, k) ? getstr(cfg, k) : default

"""
Read and check the settings sent by the interface. Returns (params, errors, extras).
"""
function build_params(cfg)
    errs = String[]
    req(cond, msg) = cond || push!(errs, msg)
    local p
    try
        observed_age    = getnum(cfg, :observed_age)
        age_uncertainty = getnum(cfg, :age_uncertainty)
        T0_prior  = getstr(cfg, :T0_prior) == "Uniform" ? 1 : 0
        SCR_prior = getstr(cfg, :SCR_prior) == "Uniform" ? 1 : 0
        T0_mean, T0_std, T0_min, T0_max = getnum.(Ref(cfg), (:T0_mean, :T0_std, :T0_min, :T0_max))
        SCR_mean, SCR_std, SCR_min, SCR_max = getnum.(Ref(cfg), (:SCR_mean, :SCR_std, :SCR_min, :SCR_max))
        # Lr and tlim priors: settings saved by older versions have no prior type (Lr Uniform, tlim Gaussian ±3σ)
        Lr_prior   = getstr(cfg, :Lr_prior, "Uniform") == "Uniform" ? 1 : 0
        tlim_prior = getstr(cfg, :tlim_prior, "Gaussian") == "Uniform" ? 1 : 0
        Lr_min, Lr_max = getnum(cfg, :Lr_min), getnum(cfg, :Lr_max)
        Lr_mean = getnum(cfg, :Lr_mean, (Lr_min + Lr_max) / 2)
        Lr_std  = getnum(cfg, :Lr_std, (Lr_max - Lr_min) / 2)
        tlim_mean, tlim_std = getnum(cfg, :tlim_mean), getnum(cfg, :tlim_std)
        tlim_min = getnum(cfg, :tlim_min, tlim_mean - 3tlim_std)
        tlim_max = getnum(cfg, :tlim_max, tlim_mean + 3tlim_std)
        sampler_type = getstr(cfg, :sampler_type)
        n_samples = getint(cfg, :n_samples)
        hmc_step_size = getnum(cfg, :hmc_step_size)
        hmc_leapfrog_steps = getint(cfg, :hmc_leapfrog_steps)
        seeds = [v isa Integer ? Int(v) : parse(Int, string(v)) for v in cfg[:random_seeds]]
        type_path = getstr(cfg, :type_path)
        geometry = getint(cfg, :geometry)
        mineral = getstr(cfg, :mineral)
        Age0 = getnum(cfg, :Age0)
        P0, Pmin, Tmin = getnum(cfg, :P0), getnum(cfg, :Pmin), getnum(cfg, :Tmin)
        chol_sol = getint(cfg, :chol_sol)
        theta, nt, RdX, nels = getnum(cfg, :theta), getint(cfg, :nt), getnum(cfg, :RdX), getint(cfg, :nels)

        req(age_uncertainty > 0, "Age uncertainty must be positive.")
        req(observed_age > 0, "Observed age must be positive.")
        for (nm, pr, mn, sd, lo, hi) in (("Initial temperature", T0_prior, T0_mean, T0_std, T0_min, T0_max),
                                          ("Cooling rate", SCR_prior, SCR_mean, SCR_std, SCR_min, SCR_max),
                                          ("Grain size", Lr_prior, Lr_mean, Lr_std, Lr_min, Lr_max),
                                          ("Total model time", tlim_prior, tlim_mean, tlim_std, tlim_min, tlim_max))
            req(lo < hi, "$nm: minimum must be smaller than maximum.")
            if pr == 0
                req(sd > 0, "$nm: standard deviation must be positive.")
            end
        end
        req(SCR_min > 0 || type_path ∉ ("asy-CR",), "Cooling rate minimum must be positive.")
        req(Lr_min > 0, "Grain size: minimum must be positive.")
        req(tlim_min > 0, "Total model time: minimum must be positive.")
        req(sampler_type in ("NUTS", "HMC"), "Unknown sampler.")
        req(10 <= n_samples <= 200_000, "Number of samples must be between 10 and 200000.")
        if sampler_type == "HMC"
            req(hmc_step_size > 0, "HMC step size must be positive.")
            req(hmc_leapfrog_steps >= 1, "HMC leapfrog steps must be ≥ 1.")
        end
        req(1 <= length(seeds) <= 64, "Give between 1 and 64 random seeds (one chain per seed).")
        req(allunique(seeds), "Random seeds must be different from each other.")
        req(type_path in PATH_TYPES, "Unknown P–T–t path type.")
        req(geometry in (1, 2, 3), "Geometry must be plane, cylinder or sphere.")
        req(mineral in MINERALS, "Unknown mineral system.")
        req(Age0 >= 0, "Initial age must be ≥ 0.")
        req(P0 >= Pmin, "Initial pressure must be ≥ final pressure.")
        req(5 <= nels <= 5000, "Number of elements must be between 5 and 5000.")
        req(10 <= nt <= 100_000, "Number of time steps must be between 10 and 100000.")
        req(0.5 <= theta <= 1.0, "θ must be between 0.5 and 1.")
        req(RdX > 0, "RdX must be positive.")
        req(chol_sol in (0, 1), "Unknown linear solver.")

        p = (
            observed_age = observed_age, age_uncertainty = age_uncertainty,
            SCR_mean = SCR_mean, SCR_std = SCR_std, SCR_min = SCR_min, SCR_max = SCR_max, SCR_prior = SCR_prior,
            T0_prior = T0_prior, T0_mean = T0_mean, T0_std = T0_std, T0_min = T0_min, T0_max = T0_max,
            Lr_prior = Lr_prior, Lr_mean = Lr_mean, Lr_std = Lr_std, Lr_min = Lr_min, Lr_max = Lr_max,
            tlim_prior = tlim_prior, tlim_mean = tlim_mean, tlim_std = tlim_std, tlim_min = tlim_min, tlim_max = tlim_max,
            sampler_type = sampler_type, n_samples = n_samples,
            hmc_step_size = hmc_step_size, hmc_leapfrog_steps = hmc_leapfrog_steps,
            random_seed = isempty(seeds) ? 0 : seeds[1], random_seeds = seeds,
            run_id = "", output_folder = "",
            type_path = type_path, ndim_a = [geometry], Age0 = [Age0], Min_Sys = [mineral],
            P0 = P0, Pmin = Pmin, Tmin = Tmin,
            chol_sol = chol_sol, theta = theta, nt = nt, RdX = RdX, nels = nels,
        )
    catch e
        push!(errs, "Invalid or missing value: " * sprint(showerror, e))
        return nothing, errs
    end
    # files needed by the "loaded" path and the "custom" mineral
    if p.type_path == "loaded"
        txt = string(get(cfg, :ptt_data, ""))
        try
            M = parse_ptt(txt)
            p.tlim_max > maximum(M[:, 3]) &&
                push!(errs, "Loaded P–T–t path: its last time ($(maximum(M[:, 3])) Myr) is shorter than the largest total model time allowed by the prior (its maximum). Temperatures beyond the path end use Tmin.")
        catch e
            push!(errs, "Loaded P–T–t path: " * sprint(showerror, e))
        end
    end
    if p.Min_Sys[1] == "custom"
        try
            vals = getnum.(Ref(cfg), (:custom_D0, :custom_Ea, :custom_Va, :custom_Pref))
            vals[1] > 0 || push!(errs, "Custom mineral: D₀ must be positive.")
        catch
            push!(errs, "Custom mineral: give D₀, Ea, Va and Pref.")
        end
    end
    return p, errs
end

# P–T–t text: rows of "P  T  t" (MPa, °C, Myr), separated by spaces, tabs, commas or semicolons
function parse_ptt(txt::AbstractString)
    rows = Vector{Vector{Float64}}()
    for ln in split(txt, r"\r?\n")
        s = strip(ln)
        (isempty(s) || startswith(s, "#")) && continue
        parts = split(s, r"[\s,;]+"; keepempty = false)
        vals = tryparse.(Float64, parts)
        any(isnothing, vals) && (isempty(rows) ? continue : error("could not read line: \"$s\""))  # allow a header line
        length(vals) == 3 || error("every line needs 3 values (P, T, t): \"$s\"")
        push!(rows, Float64.(vals))
    end
    length(rows) >= 2 || error("at least 2 rows (P T t) are required")
    M = reduce(vcat, permutedims.(rows))
    issorted(M[:, 3]) || error("times (3rd column) must increase")
    allunique(M[:, 3]) || error("times (3rd column) must be distinct")
    size(M, 1) == 3 && error("use more than 3 rows (a 3×3 table is ambiguous for KADMOS)")
    return M
end

# write the input files that KADMOS reads from the working directory
function write_input_files(cfg, p, dirs...)
    if p.type_path == "loaded"
        M = parse_ptt(string(cfg[:ptt_data]))
        for d in (APP_DIR, dirs...)
            open(joinpath(d, "PTt_params.dat"), "w") do io
                for r in eachrow(M)
                    println(io, join(r, " "))
                end
            end
        end
    end
    if p.Min_Sys[1] == "custom"
        vals = getnum.(Ref(cfg), (:custom_D0, :custom_Ea, :custom_Va, :custom_Pref))
        for d in (APP_DIR, dirs...)
            open(joinpath(d, "Custom_Diff.dat"), "w") do io
                println(io, join(vals, " "))
            end
        end
    end
end

# ----------------------------------------------------------------------------
# Running an inversion
# ----------------------------------------------------------------------------

function unique_run_name(name)
    isdir(joinpath(RESULTS_DIR, name)) || return name
    k = 2
    while isdir(joinpath(RESULTS_DIR, "$(name)_$k"))
        k += 1
    end
    return "$(name)_$k"
end

function next_run_name()
    n = 1
    while isdir(joinpath(RESULTS_DIR, "KADMOS_HMC_run$n"))
        n += 1
    end
    return "KADMOS_HMC_run$n"
end

function start_job(cfg)
    lock(JOB_LOCK) do
        j = CURRENT_JOB[]
        if j !== nothing && j.state in ("running", "plotting")
            return nothing, ["An inversion is already running. Stop it or wait until it finishes."]
        end
        p, errs = build_params(cfg)
        isempty(errs) || return nothing, errs
        p.chol_sol == 1 && return nothing, ["The Cholesky solver cannot be used for the inversion: the sparse Cholesky " *
            "factorisation does not support the dual numbers used for HMC gradients. Choose the Direct solver."]
        name = strip(string(get(cfg, :run_name, "")))
        isempty(name) && (name = next_run_name())
        valid_name(name) || return nothing, ["Run name may only contain letters, digits, spaces, '-', '_' and '.'."]
        name = unique_run_name(name)
        outdir = joinpath(RESULTS_DIR, name)
        mkpath(outdir)
        seeds = p.random_seeds
        chain_dirs = [k == 1 ? outdir : joinpath(outdir, "chain_$k") for k in eachindex(seeds)]
        foreach(mkpath, chain_dirs)
        write_input_files(cfg, p, outdir)
        # settings of this run, so it can be reloaded in the interface later
        cfg_saved = Dict{String,Any}(string(k) => v for (k, v) in pairs(cfg))
        cfg_saved["run_name"] = name
        cfg_saved["app_version"] = APP_VERSION
        cfg_saved["created"] = string(Dates.now())
        open(io -> JSON3.pretty(io, JSON3.write(cfg_saved)), joinpath(outdir, "config.json"), "w")

        nthreads = Threads.nthreads(:default)
        parallel = Bool(get(cfg, :parallel, true)) && length(seeds) > 1 && nthreads > 1
        chains = [ChainState(k, seeds[k], chain_dirs[k], "queued", 0.0, 0, 0.0, 0.0, "") for k in eachindex(seeds)]
        job = Job((JOB_COUNTER[] += 1), name, outdir, "running", "Sampling", time(), 0.0, parallel, chains,
                  Dict{String,Any}[], Threads.Atomic{Bool}(false), ReentrantLock(), "")
        CURRENT_JOB[] = job
        push_log!(job, "info", "Run \"$name\" started — $(length(seeds)) chain(s), $(p.n_samples) samples each, " *
                              (parallel ? "chains in parallel ($(min(nthreads, length(seeds))) at a time)" : "chains one after another") * ".")
        push_log!(job, "info", "Output folder: $outdir")
        push_log!(job, "info", "The first model evaluations include Julia compilation and are slower.")
        Threads.@spawn :default run_job(job, p, chain_dirs)
        return job, String[]
    end
end

function run_chain!(job::Job, p, k)
    cs = job.chains[k]
    job.cancel[] && (cs.state = "cancelled"; return)
    cs.state = "running"
    cs.started = time()
    try
        pk = merge(p, (random_seed = cs.seed, output_folder = cs.dir, run_id = job.name))
        with_logger(GuiLogger(job, k)) do
            Base.invokelatest(run_hmc_inversion, pk)
        end
        cs.state = "done"
        cs.progress = 1.0
        push_log!(job, "info", "Chain $k (seed $(cs.seed)) finished in $(fmt_dur(time() - cs.started)).")
    catch e
        if e isa RunCancelled || job.cancel[]
            cs.state = "cancelled"
        else
            cs.state = "error"
            cs.message = first(sprint(showerror, e), 600)
            push_log!(job, "error", "Chain $k (seed $(cs.seed)) failed: $(cs.message)"; chain = k)
            @error "Chain $k failed" exception = (e, catch_backtrace())
        end
    finally
        cs.finished = time()
    end
end

function run_job(job::Job, p, chain_dirs)
    try
        if job.parallel
            sem = Base.Semaphore(Threads.nthreads(:default))
            @sync for k in eachindex(job.chains)
                Threads.@spawn :default begin
                    Base.acquire(sem) do
                        run_chain!(job, p, k)
                    end
                end
            end
        else
            for k in eachindex(job.chains)
                run_chain!(job, p, k)
            end
        end
        if job.cancel[]
            job.state = "cancelled"
            job.phase = "Stopped by the user"
            push_log!(job, "warn", "Run stopped. Chains that were not finished are not saved.")
            return
        end
        good = [cs.dir for cs in job.chains if cs.state == "done"]
        if isempty(good)
            job.state = "error"
            job.phase = "All chains failed"
            i = findfirst(cs -> cs.state == "error", job.chains)
            job.error = i === nothing ? "unknown error" : job.chains[i].message
            return
        end
        # ---- figures and statistics (as in RUN_KADMOS_HMC.jl) ----
        job.state = "plotting"
        job.phase = "Creating figures and statistics"
        push_log!(job, "info", "All chains finished. Creating figures and statistics…")
        seeds = [cs.seed for cs in job.chains if cs.state == "done"]
        if !ensure_plots(msg -> (job.phase = "Preparing the figure packages"; push_log!(job, "info", msg)))
            # Without the figure packages: still write the statistics files (they need no plotting)
            try
                Base.invokelatest(write_run_statistics, [CSV.read(joinpath(d, "posterior_samples.csv"), DataFrame) for d in good],
                                  good, job.dir, PARAM_SYMS; seeds = seeds)
            catch e
                @warn "Could not write the run statistics" exception = (e, catch_backtrace())
            end
            write_app_run_info(job, p)
            job.state = "done"
            job.phase = "Finished (figures not created)"
            push_log!(job, "warn", "Run finished in $(fmt_dur(time() - job.started)) without figures. Results: $(job.dir)")
            return
        end
        steps = [
            ("per-chain diagnostic plots", () -> foreach(d -> Base.invokelatest(create_diagnostic_plots, d), good)),
            ("chain comparison, statistics and autocorrelation", () -> Base.invokelatest(create_chain_comparison_plots,
                good, job.dir, PARAM_SYMS, PARAM_XLABEL, PARAM_YLABEL; seeds = seeds)),
            ("pooled density and trace plots", () -> Base.invokelatest(create_diagnostic_plots, job.dir; chain_dirs = good)),
        ]
        for (what, f) in steps
            job.phase = "Creating $what"
            try
                f()
            catch e
                push_log!(job, "warn", "Could not create $what: " * first(sprint(showerror, e), 400))
                @warn "Post-processing step failed" what exception = (e, catch_backtrace())
            end
        end
        write_app_run_info(job, p)
        nfail = count(cs -> cs.state == "error", job.chains)
        job.state = "done"
        job.phase = nfail == 0 ? "Finished" : "Finished ($nfail chain(s) failed)"
        push_log!(job, "info", "Run finished in $(fmt_dur(time() - job.started)). Results: $(job.dir)")
    catch e
        job.state = job.cancel[] ? "cancelled" : "error"
        job.error = first(sprint(showerror, e), 600)
        job.phase = job.state == "cancelled" ? "Stopped by the user" : "Failed"
        push_log!(job, "error", "Run failed: $(job.error)")
        @error "Run failed" exception = (e, catch_backtrace())
    finally
        job.finished = time()
        foreach(cs -> cs.state in ("queued", "running") && (cs.state = "cancelled"), job.chains)
    end
end

function write_app_run_info(job::Job, p)
    open(joinpath(job.dir, "app_run_info.txt"), "w") do io
        println(io, "KADMOS HMC App v$APP_VERSION")
        println(io, "Run: $(job.name)")
        println(io, "Started:  $(Dates.unix2datetime(job.started))  (UTC)")
        println(io, "Finished: $(Dates.now(Dates.UTC))  (UTC)")
        println(io, "Chain execution: ", job.parallel ? "parallel (threads: $(Threads.nthreads(:default)))" : "sequential")
        println(io, "Elapsed wall-clock time of the whole run: $(fmt_dur(time() - job.started))")
        job.parallel && println(io, "Note: chains ran in parallel, so the elapsed time is shorter than the sum of the chain wall times in run_statistics.txt.")
        println(io, "\nChains:")
        for cs in job.chains
            println(io, @sprintf("  chain %-3d seed %-8d %-10s evaluations %-8d wall %s", cs.index, cs.seed, cs.state, cs.evals,
                                 cs.finished > 0 ? fmt_dur(cs.finished - cs.started) : "-"))
        end
    end
end

function fmt_dur(s)
    s = max(0.0, s)
    h = floor(Int, s / 3600); m = floor(Int, (s % 3600) / 60); sec = floor(Int, s % 60)
    h > 0 ? @sprintf("%dh %02dm %02ds", h, m, sec) : m > 0 ? @sprintf("%dm %02ds", m, sec) : @sprintf("%.1fs", s)
end

function job_status(job::Union{Job,Nothing}, since::Int)
    job === nothing && return Dict("state" => "idle")
    now_ = time()
    logs = lock(job.lock) do
        [copy(l) for l in job.log if l["seq"] > since]
    end
    Dict(
        "id" => job.id, "name" => job.name, "dir" => job.dir, "state" => job.state, "phase" => job.phase,
        "error" => job.error, "parallel" => job.parallel,
        "elapsed" => (job.finished > 0 ? job.finished : now_) - job.started,
        "chains" => [Dict("index" => c.index, "seed" => c.seed, "state" => c.state, "progress" => c.progress,
                          "evals" => c.evals, "message" => c.message,
                          "elapsed" => c.started == 0 ? 0.0 : (c.finished > 0 ? c.finished : now_) - c.started)
                     for c in job.chains],
        "log" => logs,
    )
end

# ----------------------------------------------------------------------------
# Forward model check (one KADMOS run with given parameter values)
# ----------------------------------------------------------------------------

function forward_check(cfg)
    p, errs = build_params(cfg)
    p === nothing && return Dict("error" => join(errs, "\n"))
    # only errors of the model settings matter here (prior issues do not block a forward run)
    try
        write_input_files(cfg, p)
    catch e
        return Dict("error" => sprint(showerror, e))
    end
    T0, SCR, Lr, tlim = getnum(cfg, :fw_T0), getnum(cfg, :fw_SCR), getnum(cfg, :fw_Lr), getnum(cfg, :fw_tlim)
    (Lr > 0 && tlim > 0) || return Dict("error" => "Grain size and model time must be positive.")
    t0 = time()
    Pres_A, TempK_A, time_A = Base.invokelatest(make_PTtpath, p.type_path, T0, SCR, p.P0, p.Pmin, p.Tmin, tlim)
    N = length(Pres_A)
    C, t_ArK, _ = Base.invokelatest(run_KADMOS_simulation,
        reshape(collect(Pres_A), N, 1), reshape(collect(TempK_A), N, 1), reshape(collect(time_A), N, 1),
        [Lr], p.ndim_a, p.Age0, p.Min_Sys, tlim, p.Tmin, p.Pmin;
        chol_sol = p.chol_sol, theta = p.theta, nt = p.nt, nels = p.nels, RdX = p.RdX)
    r, _, _ = Base.invokelatest(linspace_adapt, 0.0, 1.0, p.nels + 1, Float64(p.RdX))
    ages = vec(t_ArK[:, 1])
    # bulk (volume-weighted) age for reference: weights r^(ndim-1)
    nd = p.ndim_a[1]
    w = [ri^(nd - 1) for ri in r]
    idx = 1:length(r)-1
    wseg = [(w[i] + w[i+1]) / 2 * (r[i+1] - r[i]) for i in idx]
    bulk = sum(wseg .* [(ages[i] + ages[i+1]) / 2 for i in idx]) / sum(wseg)
    step = max(1, N ÷ 300)
    Dict(
        "max_age" => maximum(ages), "bulk_age" => bulk, "observed_age" => p.observed_age,
        "age_uncertainty" => p.age_uncertainty, "seconds" => time() - t0,
        "radius" => r, "ages" => ages,
        "path_t" => collect(time_A)[1:step:end], "path_T" => (collect(TempK_A) .- 273.15)[1:step:end],
        "path_P" => collect(Pres_A)[1:step:end],
    )
end

# ----------------------------------------------------------------------------
# Results browser
# ----------------------------------------------------------------------------

function chain_dirs_of(dir)
    dirs = String[]
    isfile(joinpath(dir, "posterior_samples.csv")) && push!(dirs, dir)
    ks = Int[]
    for d in readdir(dir)
        m = match(r"^chain_(\d+)$", d)
        m !== nothing && isfile(joinpath(dir, d, "posterior_samples.csv")) && push!(ks, parse(Int, m.captures[1]))
    end
    append!(dirs, [joinpath(dir, "chain_$k") for k in sort(ks)])
    return dirs
end

read_config(dir) = (f = joinpath(dir, "config.json"); isfile(f) ? (try JSON3.read(read(f, String)) catch; nothing end) : nothing)

function list_runs()
    isdir(RESULTS_DIR) || return []
    runs = []
    for name in readdir(RESULTS_DIR)
        dir = joinpath(RESULTS_DIR, name)
        isdir(dir) || continue
        cds = chain_dirs_of(dir)
        cfg = read_config(dir)
        status = isempty(cds) ? "incomplete" : "complete"
        j = CURRENT_JOB[]
        if j !== nothing && j.name == name && j.state in ("running", "plotting")
            status = "running"
        end
        mt = isempty(cds) ? mtime(dir) : mtime(joinpath(cds[1], "posterior_samples.csv"))
        push!(runs, Dict("name" => name, "chains" => length(cds), "status" => status, "modified" => mt,
                         "mineral" => cfg === nothing ? nothing : get(cfg, :mineral, nothing),
                         "samples" => cfg === nothing ? nothing : get(cfg, :n_samples, nothing),
                         "observed_age" => cfg === nothing ? nothing : get(cfg, :observed_age, nothing),
                         "has_config" => cfg !== nothing))
    end
    sort!(runs; by = r -> -r["modified"])
    return runs
end

downsample(v, n) = length(v) <= n ? collect(v) : v[round.(Int, range(1, length(v); length = n))]

function hpd_mode(x)
    k = kde(x)
    return k.x[argmax(k.density)], k
end

function run_details(name)
    dir = joinpath(RESULTS_DIR, name)
    isdir(dir) || return Dict("error" => "Run not found")
    cds = chain_dirs_of(dir)
    cfg = read_config(dir)
    files = sort([f for f in readdir(dir) if isfile(joinpath(dir, f)) &&
                  lowercase(splitext(f)[2]) in (".png", ".pdf", ".csv", ".txt", ".json", ".dat")])
    isempty(cds) && return Dict("name" => name, "dir" => dir, "files" => files, "config" => cfg, "chains" => [],
                                "params" => [], "error_msg" => "This run has no posterior samples (it was stopped or failed).")
    dfs = [CSV.read(joinpath(d, "posterior_samples.csv"), DataFrame) for d in cds]
    syms = [s for s in PARAM_SYMS if all(df -> hasproperty(df, s), dfs)]
    n_iter = minimum(nrow.(dfs))
    stats = nothing
    if n_iter >= 4
        try
            stats = DataFrame(summarystats(Chains(cat([Matrix{Float64}(df[1:n_iter, syms]) for df in dfs]...; dims = 3), collect(syms))))
        catch e
            @warn "Could not compute summary statistics" exception = e
        end
    end
    statrow(s) = stats === nothing ? nothing : stats[findfirst(==(s), Symbol.(stats[!, 1])), :]
    seeds_cfg = cfg === nothing ? nothing : get(cfg, :random_seeds, nothing)
    params = []
    for (j, s) in enumerate(syms)
        pooled = vcat([Float64.(df[!, s]) for df in dfs]...)
        q = quantile(pooled, [0.025, 0.16, 0.5, 0.84, 0.975])
        mode, kd = hpd_mode(pooled)
        xs = range(minimum(kd.x), maximum(kd.x); length = 240)
        r = statrow(s)
        per_chain_kde = []
        for df in dfs
            v = Float64.(df[!, s])
            if length(v) >= 5 && std(v) > 0
                kc = kde(v)
                push!(per_chain_kde, Dict("x" => downsample(kc.x, 160), "y" => downsample(kc.density, 160)))
            else
                push!(per_chain_kde, nothing)
            end
        end
        idx = findfirst(==(s), PARAM_SYMS)
        push!(params, Dict(
            "key" => string(s), "label" => PARAM_XLABEL[idx],
            "mean" => mean(pooled), "std" => std(pooled), "median" => q[3],
            "q025" => q[1], "q16" => q[2], "q84" => q[4], "q975" => q[5], "mode" => mode,
            "min" => minimum(pooled), "max" => maximum(pooled),
            "rhat" => r === nothing ? nothing : r.rhat, "ess_bulk" => r === nothing ? nothing : r.ess_bulk,
            "ess_tail" => r === nothing ? nothing : r.ess_tail, "mcse" => r === nothing ? nothing : r.mcse,
            "kde" => Dict("x" => collect(xs), "y" => [pdf(kd, x) for x in xs]),
            "chain_kde" => per_chain_kde,
            "trace" => [downsample(Float64.(df[!, s]), 1200) for df in dfs],
        ))
    end
    # sampler diagnostics per chain
    chains = []
    for (k, (d, df)) in enumerate(zip(cds, dfs))
        t = read_chain_timing(d)
        col(c) = hasproperty(df, c) ? Float64.(df[!, c]) : nothing
        acc, nerr, depth, step, lp = col(:acceptance_rate), col(:numerical_error), col(:tree_depth), col(:step_size), col(:lp)
        seed = seeds_cfg !== nothing && k <= length(seeds_cfg) ? seeds_cfg[k] : t.seed
        push!(chains, Dict("index" => k, "seed" => seed, "draws" => nrow(df),
            "dir" => relpath(d, dir), "wall" => t.wall, "evals" => t.evals,
            "acceptance" => acc === nothing ? nothing : mean(acc),
            "divergences" => nerr === nothing ? nothing : Int(sum(nerr .> 0)),
            "tree_depth" => depth === nothing ? nothing : mean(depth),
            "step_size" => step === nothing ? nothing : step[end],
            "lp" => lp === nothing ? nothing : downsample(lp, 1200)))
    end
    # joint samples for the pair plot (pooled, thinned)
    pooled_df = vcat([df[!, syms] for df in dfs]...)
    sel = round.(Int, range(1, nrow(pooled_df); length = min(nrow(pooled_df), 2500)))
    pairs_ = Dict(string(s) => Float64.(pooled_df[sel, s]) for s in syms)
    chain_of = vcat([fill(k, nrow(df)) for (k, df) in enumerate(dfs)]...)[sel]
    Dict("name" => name, "dir" => dir, "files" => files, "config" => cfg, "params" => params,
         "chains" => chains, "pairs" => pairs_, "pair_chain" => chain_of, "n_iter" => n_iter,
         "pooled_draws" => sum(nrow.(dfs)),
         "chain_folders" => [relpath(d, dir) for d in cds],
         "run_statistics" => isfile(joinpath(dir, "run_statistics.txt")) ? read(joinpath(dir, "run_statistics.txt"), String) : nothing,
         "app_info" => isfile(joinpath(dir, "app_run_info.txt")) ? read(joinpath(dir, "app_run_info.txt"), String) : nothing)
end

function replot_run(name)
    dir = joinpath(RESULTS_DIR, name)
    cds = chain_dirs_of(dir)
    isempty(cds) && return "This run has no posterior samples."
    j = CURRENT_JOB[]
    (j !== nothing && j.state in ("running", "plotting")) && return "Please wait until the current run has finished."
    cfg = read_config(dir)
    seeds = cfg === nothing ? nothing : [Int(s) for s in get(cfg, :random_seeds, Int[])][1:min(end, length(cds))]
    (seeds !== nothing && length(seeds) != length(cds)) && (seeds = nothing)
    first_df = CSV.read(joinpath(cds[1], "posterior_samples.csv"), DataFrame; limit = 2)
    syms = [s for s in PARAM_SYMS if hasproperty(first_df, s)]
    idx = [findfirst(==(s), PARAM_SYMS) for s in syms]
    ensure_plots() || return "The figure packages are not available yet. Check the internet connection and try again."
    foreach(d -> Base.invokelatest(create_diagnostic_plots, d), cds)
    Base.invokelatest(create_chain_comparison_plots, cds, dir, syms, PARAM_XLABEL[idx], PARAM_YLABEL[idx]; seeds = seeds)
    Base.invokelatest(create_diagnostic_plots, dir; chain_dirs = cds)
    return ""
end

# ----------------------------------------------------------------------------
# HTTP routing
# ----------------------------------------------------------------------------

function body_json(req)
    b = String(req.body)
    isempty(b) ? Dict{Symbol,Any}() : JSON3.read(b, Dict{Symbol,Any})
end

function diffusion_table()
    rows = []
    for m in MINERALS
        m == "custom" && continue
        D0, Ea, Va, Pref = Base.invokelatest(diff_system, m, Float64)
        push!(rows, Dict("name" => m, "D0" => D0, "Ea" => Ea, "Va" => Va, "Pref" => Pref))
    end
    rows
end

function handle(req::HTTP.Request)
    uri = HTTP.URI(req.target)
    path = HTTP.unescapeuri(uri.path)
    q = HTTP.queryparams(uri)
    m = req.method
    try
        # ---------- static files ----------
        if m == "GET" && (path == "/" || path == "/index.html")
            return file_response(joinpath(WEB_DIR, "index.html"))
        elseif m == "GET" && startswith(path, "/static/")
            f = safe_join(WEB_DIR, path[9:end])
            f === nothing && return error_response("Not found"; status = 404)
            return file_response(f)
        # ---------- API ----------
        elseif m == "GET" && path == "/api/info"
            return json_response(Dict(
                "version" => APP_VERSION, "threads" => Threads.nthreads(:default),
                "interactive_threads" => Threads.nthreads(:interactive),
                "julia" => string(VERSION), "results_dir" => RESULTS_DIR, "app_dir" => APP_DIR,
                "minerals" => MINERALS, "paths" => PATH_TYPES, "diffusion" => diffusion_table(),
                "next_run_name" => next_run_name()))
        elseif m == "GET" && path == "/api/status"
            since = parse(Int, get(q, "since", "0"))
            return json_response(job_status(CURRENT_JOB[], since))
        elseif m == "POST" && path == "/api/validate"
            p, errs = build_params(body_json(req))
            return json_response(Dict("errors" => errs))
        elseif m == "POST" && path == "/api/run"
            job, errs = start_job(body_json(req))
            job === nothing && return json_response(Dict("errors" => errs); status = 400)
            return json_response(Dict("ok" => true, "name" => job.name, "dir" => job.dir))
        elseif m == "POST" && path == "/api/cancel"
            j = CURRENT_JOB[]
            if j !== nothing && j.state == "running"
                j.cancel[] = true
                j.phase = "Stopping…"
                push_log!(j, "warn", "Stop requested — the chains stop at their next model evaluation.")
            end
            return json_response(Dict("ok" => true))
        elseif m == "POST" && path == "/api/forward"
            cfg = body_json(req)
            res = fetch(Threads.@spawn :default forward_check(cfg))
            return json_response(res)
        elseif m == "POST" && path == "/api/parse_ptt"
            cfg = body_json(req)
            try
                M = parse_ptt(string(get(cfg, :text, "")))
                return json_response(Dict("P" => M[:, 1], "T" => M[:, 2], "t" => M[:, 3], "rows" => size(M, 1)))
            catch e
                return json_response(Dict("error" => sprint(showerror, e)))
            end
        elseif m == "GET" && path == "/api/runs"
            return json_response(list_runs())
        elseif startswith(path, "/api/runs/")
            rest = split(path[11:end], "/"; limit = 3)
            name = String(rest[1])
            valid_name(name) && isdir(joinpath(RESULTS_DIR, name)) || return error_response("Run not found"; status = 404)
            dir = joinpath(RESULTS_DIR, name)
            if length(rest) == 1 && m == "GET"
                res = fetch(Threads.@spawn :default run_details(name))
                return json_response(res)
            elseif length(rest) >= 2 && rest[2] == "file" && m == "GET"
                f = length(rest) == 3 ? safe_join(dir, rest[3]) : nothing
                f === nothing && return error_response("Not found"; status = 404)
                return file_response(f; download = get(q, "download", "0") == "1")
            elseif length(rest) == 2 && rest[2] == "open" && m == "POST"
                return json_response(Dict("ok" => open_in_file_browser(dir)))
            elseif length(rest) == 2 && rest[2] == "replot" && m == "POST"
                msg = fetch(Threads.@spawn :default replot_run(name))
                return json_response(isempty(msg) ? Dict("ok" => true) : Dict("error" => msg))
            end
        elseif m == "POST" && path == "/api/open_results"
            mkpath(RESULTS_DIR)
            return json_response(Dict("ok" => open_in_file_browser(RESULTS_DIR)))
        end
        return error_response("Not found"; status = 404)
    catch e
        @error "Request failed: $m $path" exception = (e, catch_backtrace())
        return error_response(first(sprint(showerror, e), 800); status = 500)
    end
end

function find_port(start)
    for port in start:start+40
        try
            s = Sockets.listen(Sockets.localhost, port)
            close(s)
            return port
        catch
        end
    end
    error("No free port found between $start and $(start + 40)")
end

function open_browser(url)
    try
        if Sys.iswindows()
            run(`cmd /c start "" $url`; wait = false)
        elseif Sys.isapple()
            run(`open $url`; wait = false)
        else
            run(`xdg-open $url`; wait = false)
        end
    catch
        println("Open this address in your browser: $url")
    end
end

function start_app(; port = 8765, browser = true)
    mkpath(RESULTS_DIR)
    port = find_port(port)
    server = HTTP.serve!(handle, Sockets.localhost, port; verbose = false)
    url = "http://localhost:$port"
    println()
    println("  ┌──────────────────────────────────────────────────────────┐")
    println("  │  KADMOS HMC App is running                               │")
    println("  │  Open: ", rpad(url, 50), "│")
    println("  │  Results folder: results/                                │")
    println("  │  Keep this window open. Press Ctrl+C to quit.            │")
    println("  └──────────────────────────────────────────────────────────┘")
    println()
    flush(stdout)
    browser && open_browser(url)
    return server, url
end
