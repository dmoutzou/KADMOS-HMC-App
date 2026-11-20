#=============================================================================
KADMOS HMC App
Interactive interface for the Bayesian (HMC/NUTS) inversion of 40Ar/39Ar ages
with the KADMOS diffusion model: initial temperature, initial cooling rate,
effective grain size and total model time.

Start it with the launcher (KADMOS_App.bat on Windows, kadmos_app.sh on
macOS/Linux) or from a terminal in this folder:

    julia --threads=auto,1 --project=. KADMOS_App.jl

The interface opens in your web browser. Results are saved in ./results.

Original KADMOS (MATLAB): Moulas & Brandon (2022), doi: 10.5281/zenodo.7358136
Julia translation and HMC implementation: D. Moutzouris (2025),
https://doi.org/10.5281/zenodo.18247900
KADMOS HMC App: D. Moutzouris (2026), https://doi.org/10.5281/zenodo.24397573
=============================================================================#

const APP_DIR = @__DIR__

# The interface needs one interactive thread (web server) and worker threads (inversion).
# If Julia was started without them (e.g. `include("KADMOS_App.jl")` in a plain REPL), restart correctly.
if Threads.nthreads(:interactive) < 1 || Threads.nthreads(:default) < 1 ||
   (Threads.nthreads(:default) == 1 && Sys.CPU_THREADS > 1)
    println("Restarting Julia with threads enabled (--threads=auto,1)…"); flush(stdout)
    cmd = `$(Base.julia_cmd()) --threads=auto,1 --project=$(APP_DIR) $(joinpath(APP_DIR, "KADMOS_App.jl")) $(ARGS)`
    run(ignorestatus(cmd))
    exit()
end

cd(APP_DIR)   # KADMOS reads PTt_params.dat / Custom_Diff.dat from the working directory

println("""

  KADMOS HMC App
  ──────────────
  Julia $(VERSION) · $(Threads.nthreads(:default)) worker threads
""")

# Prints "still working" lines with the elapsed time while a silent step runs
# (on a worker thread: the main thread is busy loading the packages).
function with_ticker(f, what; every = 10)
    t0 = time(); done = Threads.Atomic{Bool}(false)
    ticker = Threads.@spawn :default begin
        while !done[]
            # Short OS sleeps: Julia's `sleep` needs the event loop, which the busy main thread does not
            # run, and a long OS sleep would hold up the garbage collector (it waits for every thread).
            t1 = time()
            while !done[] && time() - t1 < every
                Libc.systemsleep(0.001); GC.safepoint()
            end
            done[] || (println("      … still $what ($(round(Int, time() - t0)) s) — this is normal, please wait"); flush(stdout))
        end
    end
    try
        return f()
    finally
        done[] = true; wait(ticker)
        println("      done in $(round(Int, time() - t0)) s"); flush(stdout)
    end
end

import Pkg
Pkg.activate(APP_DIR; io = devnull)

# First start? (packages not downloaded or not precompiled yet)
first_start = let id = Base.identify_package("Turing")
    id === nothing || Base.find_package("Turing") === nothing || !Base.isprecompiled(id)
end

if first_start
    println("""
  [1/3] Installing the Julia packages (first start only).
        This needs internet and takes several minutes. Julia shows the downloads
        and a precompilation progress bar below. Please do not close this window.
        (The figure packages are prepared afterwards, in the background.)
""")
else
    println("  [1/3] Checking the Julia packages…")
end
flush(stdout)
try
    Pkg.instantiate()   # downloads and precompiles on the first start; fast afterwards
catch e
    @warn "Package installation failed; trying to continue. Check the internet connection if the app does not start." exception = e
end

# Figures (CairoMakie) live in a separate package set (./plots), installed and loaded in the background
const KADMOS_LAZY_PLOTS = true
include(joinpath(APP_DIR, "app", "plots.jl"))

# `--install-only`: install everything (also the figure packages) and quit, e.g. to prepare a computer
# that will be used offline.
if "--install-only" in ARGS
    println("\n  Installing the figure packages…"); flush(stdout)
    install_plots_env(stdout) || (println("Figure packages could not be installed."); exit(1))
    println("\n  All packages are installed."); exit(0)
end

println("\n  [2/3] Loading KADMOS and Turing (usually under a minute)…"); flush(stdout)
with_ticker("loading") do
    include(joinpath(APP_DIR, "KADMOS_functions.jl"))   # KADMOS model + HMC inversion
    include(joinpath(APP_DIR, "app", "server.jl"))
end

println("\n  [3/3] Starting the interface…"); flush(stdout)
start_plots_setup()   # background: install (first start) and load the figure packages

const NO_BROWSER = "--no-browser" in ARGS
const PORT = let i = findfirst(==("--port"), ARGS)
    i === nothing ? 8765 : parse(Int, ARGS[i+1])
end

server, url = start_app(; port = PORT, browser = !NO_BROWSER)

if !isinteractive()
    try
        wait(server)
    catch e
        e isa InterruptException || rethrow()
    finally
        println("\nKADMOS HMC App stopped.")
        close(server)
    end
end
