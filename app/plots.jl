#=============================================================================
KADMOS HMC App — figure packages
CairoMakie (and its ~120 dependencies) is only needed to save the PNG/PDF
figures of a finished run. It lives in its own package set (./plots, the same
package versions as the main set plus CairoMakie), so the first start only has
to install the packages for the model and the interface. The figure packages
are then installed and loaded in the background while the interface is used.
=============================================================================#

const PLOTS_ENV    = joinpath(APP_DIR, "plots")
const PLOTS_LOG    = joinpath(PLOTS_ENV, "install.log")
const PLOTS_TASK   = Ref{Union{Task,Nothing}}(nothing)
const PLOTS_LOADED = Threads.Atomic{Bool}(false)
const PLOTS_ERROR  = Ref("")
const PLOTS_LOCK   = ReentrantLock()

# Right after the app's own environment, so a CairoMakie in the user's global environment is never used
PLOTS_ENV in LOAD_PATH || insert!(LOAD_PATH, min(2, length(LOAD_PATH) + 1), PLOTS_ENV)

"""CairoMakie downloaded and precompiled?"""
function plots_installed()
    id = Base.identify_package("CairoMakie")
    id !== nothing && Base.locate_package(id) !== nothing && Base.isprecompiled(id)
end

"""Install and precompile the figure packages in a separate Julia process; output goes to `io`."""
function install_plots_env(io; background = false)
    cmd = `$(Base.julia_cmd()) --startup-file=no --threads=1 --project=$PLOTS_ENV -e "import Pkg; Pkg.instantiate()"`
    # In the background, leave half of the CPU to the interface / a running inversion
    background && (cmd = addenv(cmd, "JULIA_NUM_PRECOMPILE_TASKS" => string(max(1, Sys.CPU_THREADS ÷ 2))))
    return success(pipeline(ignorestatus(cmd); stdout = io, stderr = io)) && plots_installed()
end

function load_plots()
    lock(PLOTS_LOCK) do
        PLOTS_LOADED[] && return
        Base.eval(Main, :(using CairoMakie))
        PLOTS_LOADED[] = true
    end
end

"""Start installing (first start) and loading the figure packages in the background."""
function start_plots_setup()
    PLOTS_TASK[] = Threads.@spawn :default begin
        try
            if !plots_installed()
                println("""
  Preparing the figure packages in the background (first start only, a few minutes).
  You can already use the interface. Details: plots/install.log""")
                flush(stdout)
                open(io -> install_plots_env(io; background = true), PLOTS_LOG, "w") ||
                    error("installation failed, see plots/install.log")
                println("  Figure packages are ready."); flush(stdout)
            end
            load_plots()
        catch e
            PLOTS_ERROR[] = first(sprint(showerror, e), 400)
            println("  NOTE: the figure packages are not available yet ($(PLOTS_ERROR[])).")
            println("        Results are still saved; figures are made when they are available."); flush(stdout)
        end
    end
    return nothing
end

"""
Make sure the figure functions can be used: waits for the background setup, retries once if it failed.
`notify(msg)` reports what is happening (e.g. to the run log). Returns false if figures cannot be made.
"""
function ensure_plots(notify = msg -> nothing)
    PLOTS_LOADED[] && return true
    t = PLOTS_TASK[]
    if t !== nothing && !istaskdone(t)
        notify("Waiting for the figure packages (being prepared in the background, first start only)…")
        wait(t)
    end
    PLOTS_LOADED[] && return true
    try   # retry once, e.g. the internet connection is back
        if !plots_installed()
            notify("Installing the figure packages…")
            open(io -> install_plots_env(io), PLOTS_LOG, "w")
        end
        # load on a worker thread, never on the interactive thread that serves the interface
        plots_installed() && fetch(Threads.@spawn :default load_plots())
    catch e
        PLOTS_ERROR[] = first(sprint(showerror, e), 400)
    end
    PLOTS_LOADED[] || notify("The figure packages are not available ($(PLOTS_ERROR[] == "" ? "see plots/install.log" : PLOTS_ERROR[])). " *
                             "Check the internet connection, then use Regenerate figures on the Results page.")
    return PLOTS_LOADED[]
end
