#=============================================================================
KADMOS Functions
This file involves all core functions for the present HMC model for KADMOS
=============================================================================#

using LinearAlgebra, Interpolations, SparseArrays, DelimitedFiles
using Turing, Random, DataFrames, CSV, Dates, MCMCChains, Printf, KernelDensity, Statistics
# The plotting package (CairoMakie) is only needed by the figure functions below. The app loads it later
# (app/plots.jl), so the interface starts without it; scripts such as RUN_KADMOS_HMC.jl load it here as before.
if !(isdefined(Main, :KADMOS_LAZY_PLOTS) && Main.KADMOS_LAZY_PLOTS)
    using CairoMakie
end

# One BLAS thread: the linear systems of the model are small, so multi-threaded BLAS only adds overhead (idle BLAS
# threads compete for the CPU, which makes runs slower and their wall times unstable on a busy machine).
# This does not change the results.
LinearAlgebra.BLAS.set_num_threads(1)

# Each Markov chain runs on its own thread and the model itself uses no threads, so DynamicPPL's "thread-safe"
# model evaluation is not needed. In DynamicPPL 0.36 it is also broken when Julia has an interactive thread
# (`--threads=auto,1`): it sizes its per-thread storage with nthreads() but indexes it with threadid(), so a chain
# that runs on the highest thread number fails with a BoundsError. Newer DynamicPPL versions also switch it off.
Turing.DynamicPPL.use_threadsafe_eval(::Turing.DynamicPPL.AbstractContext, ::Turing.DynamicPPL.AbstractVarInfo) = false

"""
Construct a pressure–temperature–time (P–T–t) path for a given path type and
starting conditions.

Arguments
- `type_path` : String selecting the path parameterisation ("lin-CR",
    "asy-CR", "lin-P-T", "iso-T" or "loaded").
- `T0`        : Initial temperature in °C.
- `SCR`       : Initial cooling rate in °C/Myr (used for the "*-CR" options).
- `P0`        : Initial pressure in MPa (or same units as Pmin).
- `Pmin`      : Minimum pressure allowed along the path.
- `Tmin`      : Minimum temperature in °C allowed along the path.
- `tlim0`     : Total model time in Myr for constructing the path.

Returns
- `Pres_a` : 1D array of pressures along the path (after enforcing Pmin).
- `TempK_a`: 1D array of temperatures in Kelvin along the path
    (T_arr + 273.15, after enforcing Tmin).
- `time_a` : 1D array of model times in Myr corresponding to each node.
"""
function make_PTtpath(type_path, T0, SCR, P0, Pmin, Tmin, tlim0)
    T       = promote_type(typeof(T0), typeof(SCR))
    nres    = 1000
    time_a  = range(T(0), T(tlim0); length=nres)
    T_arr   = zeros(T, nres)
    Pres_a  = zeros(T, nres)
    if type_path == "lin-CR"
        T_arr   .= T0 .- SCR .* time_a
        Pres_a  .= P0
    elseif type_path == "asy-CR"
        T_arr   .= T0 ./ (T(1) .+ SCR .* time_a ./ T0)
        Pres_a  .= P0
    elseif type_path == "lin-P-T"
        T_arr    = collect(range(T0, Tmin; length=nres))
        Pres_a   = collect(range(P0, Pmin; length=nres))
        time_a   = collect(range(T(0), tlim0; length=nres))
    elseif type_path == "iso-T"
        time_a   = collect(range(T(0), tlim0; length=nres))
        T_arr   .= T0
        Pres_a  .= P0
    elseif type_path == "loaded"
        PTt_params = readdlm("PTt_params.dat")
        n1, n2     = size(PTt_params)
        if n1 == 3 && n2 != 3
            Pres_a  = T.(PTt_params[1, :])
            TempC_a = T.(PTt_params[2, :])
            time_a  = T.(PTt_params[3, :])
        elseif n2 == 3 && n1 != 3
            Pres_a  = T.(PTt_params[:, 1])
            TempC_a = T.(PTt_params[:, 2])
            time_a  = T.(PTt_params[:, 3])
        else
            println("PTt_params must be a 3xN or a Nx3 matrix (for P,T & t arrays)")
            error("resize PTt matrix as 3xN or Nx3 matrix")
        end
        T_arr = TempC_a
    else
        error("Not recognized type of path")
    end

    # Apply Tmin and Pmin limits
    T_arr   = map(x -> x < Tmin ? Tmin : x, T_arr)
    Pres_a  = map(x -> x < Pmin ? Pmin : x, Pres_a)
    TempK_a = T_arr .+ T(273.15)
    return Pres_a, TempK_a, time_a
end

"""
Check consistency of the number of diffusion domains across all input
arrays and return the common domain count.

Arguments
- `Pres_a`  : Pressure history; either a vector (single domain) or matrix
    with last dimension indexing domains.
- `TempK_a` : Temperature history in Kelvin, same shape convention as Pres_a.
- `time_a`  : Time array associated with the P–T histories, same shape.
- `Lr`      : Vector of effective grain radii (or half-sizes) per domain.
- `ndim_a`  : Vector of geometric dimensions per domain (1, 2 or 3).
- `Age0`    : Vector of initial ages per domain (Myr).
- `Min_Sys` : Vector of mineral-system names per domain (e.g. "Biotite1").

Returns
- Integer number of domains (ndd) if all inputs are consistent; otherwise
    throws an error.
"""
function check_ndomains(Pres_a, TempK_a, time_a, Lr, ndim_a, Age0, Min_Sys)
    # get number of domains for each input (works for both vectors and matrices)
    ndd0 = length(Lr)
    ndd1 = size(Pres_a, ndims(Pres_a))
    ndd2 = size(TempK_a, ndims(TempK_a))
    ndd3 = size(time_a, ndims(time_a))
    ndd4 = length(ndim_a)
    ndd5 = length(Age0)
    ndd6 = length(Min_Sys)
    if (ndd1 != ndd0) || (ndd2 != ndd0) || (ndd3 != ndd0) || (ndd4 != ndd0) ||
       (ndd5 != ndd0) || (ndd6 != ndd0)
        println("Number of domains does not match")
        error("check size of PTt array, Size, Geometry, Initial Age or System")
    end
    return ndd1
end

"""
Return diffusion parameters for a chosen mineral system.

Arguments
- `name_sys` : Name of the diffusion system (e.g. "Muscovite1",
    "Biotite3", "Orthoclase" or "custom").
- `T`        : Numeric type used to cast all parameters (for AD and
    type-stability).

Returns
- `D0_cm2s` : Pre-exponential diffusion factor in cm^2/s.
- `Ea`      : Activation energy in J/mol.
- `Va`      : Activation volume in cm^3/mol.
- `Pref`    : Reference pressure for the diffusion law (same units as P).

If `name_sys == "custom"`, parameters are read from the file
"Custom_Diff.dat" as [D0_cm2s, Ea, Va, Pref].
"""
function diff_system(name_sys::AbstractString, T)
    kcal2kj = T(4.1868)
    # Available Systems 
    # Muscovite 1 & 2
    # Hornblende 1 & 2
    # Biotite 1 & 2 & 3 & 4
    # Orthoclase
    if name_sys == "Muscovite1"
        D0_cm2s = T(2.3)
        Ea      = T(263e3)
        Va      = T(14)
        Pref    = T(1000)
    elseif name_sys == "Muscovite2"
        D0_cm2s = T(3.35e-7)
        Ea      = T(41.8) * kcal2kj * T(1e3)
        Va      = T(10)
        Pref    = T(1e-4)
    elseif name_sys == "Hornblende1"
        D0_cm2s = T(0.061)
        Ea      = T(66.1) * kcal2kj * T(1e3)
        Va      = T(10)
        Pref    = T(1e-4)
    elseif name_sys == "Hornblende2"
        D0_cm2s = T(0.024)
        Ea      = T(64.1) * kcal2kj * T(1e3)
        Va      = T(10)
        Pref    = T(1e-1)
    elseif name_sys == "Biotite1"
        D0_cm2s = T(0.40)
        Ea      = T(50.5) * kcal2kj * T(1e3)
        Va      = T(0)
        Pref    = T(1e-4)
    elseif name_sys == "Biotite2"
        D0_cm2s = T(0.077)
        Ea      = T(47) * kcal2kj * T(1e3)
        Va      = T(10)
        Pref    = T(1e-4)
    elseif name_sys == "Biotite3"
        D0_cm2s = T(0.75)
        Ea      = T(57.9) * kcal2kj * T(1e3)
        Va      = T(10)
        Pref    = T(1e-4)
    elseif name_sys == "Biotite4"
        D0_cm2s = T(0.075)
        Ea      = T(47.1) * kcal2kj * T(1e3)
        Va      = T(0)
        Pref    = T(1e-4)
    elseif name_sys == "Orthoclase"
        D0_cm2s = T(0.00982)
        Ea      = T(43.8) * kcal2kj * T(1e3)
        Va      = T(0)
        Pref    = T(1e-4)
    elseif name_sys == "custom"
        custom_diff = readdlm("Custom_Diff.dat")
        D0_cm2s = T(custom_diff[1])
        Ea      = T(custom_diff[2])
        Va      = T(custom_diff[3])
        Pref    = T(custom_diff[4])
    else
        error("Unknown mineral system")
    end
    return D0_cm2s, Ea, Va, Pref
end


"""
Assemble the finite-element mass and stiffness matrices for radial diffusion
in 1D/2D/3D and build the global left-hand (L_g) and right-hand (R_g)
systems for one domain and time step using a theta-time-integration scheme.

Arguments
- `L_g`, `R_g` : Preallocated global left-hand matrix and right-hand vector
    for the current domain; filled in-place.
- `ig`         : Index of the current domain.
- `nr`         : Number of radial nodes for each domain.
- `ndofs`      : Number of degrees of freedom (usually nr).
- `ndim`       : Geometric dimension (1 for slab, 2 for cylinder,
    3 for sphere).
- `x_1`, `x_2` : Element node radii (left and right) as vectors of length
    Nels = nr-1.
- `Dn`, `Do`   : Dimensionless diffusion coefficients at the new and old
    time levels.
- `theta`      : Time-integration parameter (0 explicit, 1 implicit,
    0.5 Crank–Nicolson).
- `dt`         : Time-step size in Myr.
- `Co`         : Global concentration vector at the previous time step.
- `M_11i`, `M_22i`, `M_12i` : Element mass-matrix contributions (workspace).
- `K_11i`, `K_12i`          : Element stiffness-matrix contributions
    (workspace).
- `M11m`, `M11s`, `K11m`, `K11s` : Global diagonals and off-diagonals used
    to construct the symmetric global matrices.
"""
function fill_MatrixFEM!(
    L_g, R_g, ig, nr, ndofs, ndim, x_1, x_2, Dn, Do, theta, dt, Co,
    M_11i, M_22i, M_12i, K_11i, K_12i,
    M11m, M11s, K11m, K11s
)
    T       = eltype(x_1)
    Nels    = length(x_1)
    Ndof    = Nels + 1
    # just fill the arrays:
    fill!(M_11i, T(0))
    fill!(M_22i, T(0))
    fill!(M_12i, T(0))
    fill!(K_11i, T(0))
    fill!(K_12i, T(0))
    fill!(M11m, T(0))
    fill!(M11s, T(0))
    fill!(K11m, T(0))
    fill!(K11s, T(0))
    if ndim != 1 && ndim != 2 && ndim != 3
        error("Dimension (ndim) ERROR")
    end
    # compute element matrices
    for i in 1:Nels
        M_11i[i] = (T(2) * x_2[i]^ndim * x_2[i]^2) / (ndim * (x_1[i] - x_2[i])^2 * (ndim^2 + 3*ndim + 2)) -
                   (x_1[i]^ndim * (ndim^2 * x_1[i]^2 - T(2)*ndim^2 * x_1[i]*x_2[i] + ndim^2 * x_2[i]^2 +
                   ndim * x_1[i]^2 - T(4)*ndim * x_1[i]*x_2[i] + T(3)*ndim * x_2[i]^2 + T(2) * x_2[i]^2)) /
                   (ndim * (x_1[i] - x_2[i])^2 * (ndim^2 + 3*ndim + 2))
        M_22i[i] = -((x_1[i]^ndim * x_1[i]^2) / ndim - (x_1[i]^2 * x_2[i]^ndim) / ndim -
                    (T(2) * x_1[i]^ndim * x_1[i]^2) / (ndim + T(1)) + (x_1[i]^ndim * x_1[i]^2) / (ndim + T(2)) -
                    (x_2[i]^ndim * x_2[i]^2) / (ndim + T(2)) + (T(2) * x_1[i] * x_2[i] * x_2[i]^ndim) / (ndim + T(1))) /
                    (x_1[i] - x_2[i])^2
        M_12i[i] = -(ndim * (x_1[i]^ndim * x_1[i]^2 - x_2[i]^ndim * x_2[i]^2 - x_1[i] * x_1[i]^ndim * x_2[i] +
                    x_1[i] * x_2[i] * x_2[i]^ndim) - T(2) * x_1[i] * x_1[i]^ndim * x_2[i] +
                    T(2) * x_1[i] * x_2[i] * x_2[i]^ndim) /
                    (ndim * (x_1[i] - x_2[i])^2 * (ndim^2 + 3*ndim + 2))
        K_11i[i] = -((x_1[i]^ndim - x_2[i]^ndim)) / (ndim * (x_1[i] - x_2[i])^2)
        K_12i[i] =  ((x_1[i]^ndim - x_2[i]^ndim)) / (ndim * (x_1[i] - x_2[i])^2)
    end
    # this is a cool way to assemble the global matrices. It works for symmetric matrices
    for i in 1:Ndof
        if i <= Nels                        # this if statement puts the diagonal entries
            M11m[i, i] += M_11i[i]
            K11m[i, i] += K_11i[i]
        end
        if i > 1                            # this if statement takes care of the connection of elements
            M11m[i, i] += M_22i[i-1]
            K11m[i, i] += K_11i[i-1]
        end
        if i < Ndof                         #this if statement only computes the upper diagonal
            M11s[i, i+1] = M_12i[i]
            K11s[i, i+1] = K_12i[i]
        end
    end

    MM      = M11m + M11s + transpose(M11s) # final MM is diagonal, upper diagonal + transpose of M11S (lower diagonal)
    KM      = K11m + K11s + transpose(K11s) # same for KM

    # global matrices
    L_g    .= MM/dt .+ KM * Dn * theta                          # left hand side based on discretization
    idx     = (1 + nr * (ig - 1)):(1 + nr * (ig - 1) + nr - 1)  # index for previous composition
    R_g    .= (MM/dt .- KM * Do * (T(1) - theta)) * Co[idx]     # right hand side based on discretization

    # boundary conditions at the end (enforces 0 concentration)
    L_g[nr, :] .= T(0)                                          #put boundary conditions for the last entry
    L_g[:, nr] .= T(0)
    L_g[nr, nr] = T(1)
    R_g[nr]     = T(0)
    # the boundary terms in the derivation of FEM are killed (see Moulas and Brandon, 2022)
    # therefore the first BC is zero-flux 
end

"""
Generate a non-uniform 1D grid between L1 and L2 using an adaptive spacing
controlled by the ratio of first-to-last cell size.

Arguments
- `L1`       : Left boundary coordinate.
- `L2`       : Right boundary coordinate.
- `nx`       : Number of nodes (including both boundaries).
- `dX1_dXN`  : Desired ratio of first to last cell width (Δx₁/Δx_N).

Returns
- `x2`    : Vector of length nx with node coordinates.
- `dx_ar` : Vector of length nx-1 with element widths Δx.
- `Cfact` : Geometric spacing factor used to construct the non-uniform grid.
"""
function linspace_adapt(L1, L2, nx, dX1_dXN)
    T   = typeof(L1)
    # compute C factor
    C   = dX1_dXN^(T(1) / (T(1) - nx))
    ndx = nx - 1
    # construct LHS matrix
    LHS = Matrix{T}(I, ndx, ndx)
    LHS[1, :] .= T(1)
    for i in 1:ndx-1
        LHS[i+1, i] = -C
    end
    # construct RHS vector
    RHS     = zeros(T, ndx)
    RHS[1]  = L2 - L1
    # solve for dx_ar
    dx_ar   = vec(LHS \ RHS)  # Make sure dx_ar is a 1D vector
    x2      = vcat(T(0), cumsum(dx_ar))
    x2    .+= L1
    dx_ar   = diff(x2)
    Cfact   = C
    return x2, dx_ar, Cfact
end

"""
Perform 1D linear interpolation of y(x) at a single query point.

Arguments
- `x`        : Monotonic grid of abscissae.
- `y`        : Values of the function at each x.
- `xq`       : Query point where y(xq) is needed.
- `extrapval`: Value to return if xq is outside [minimum(x), maximum(x)].

Returns
- Interpolated value y(xq) if xq is within the sampled range, otherwise
    `extrapval` converted to the type of xq.
"""
function interp1_linear(x, y, xq, extrapval)
    if xq < minimum(x) || xq > maximum(x)
        return convert(typeof(xq), extrapval)
    else
        itp = LinearInterpolation(x, y)
        return itp(xq)
    end
end

"""
Sparse linear solve A*x = b used in every FEM time step.

- Float64 (forward model / grid search): plain sparse solve, unchanged.
- ForwardDiff.Dual (gradients for HMC/NUTS): the sparse solvers (UMFPACK/CHOLMOD)
    do not support Dual numbers and Julia falls back to a very slow generic LU
    (~25x the cost of a forward run). Instead, factorise the Float64 values once
    and propagate the derivatives exactly:  A x = b  =>  A dx = db - dA x.
    The result is identical (to round-off) to differentiating through the generic solve.
"""
const FD = Turing.ForwardDiff
lin_solve(A, b) = A \ b
function lin_solve(A::SparseMatrixCSC{FD.Dual{Tg,V,N}}, b::AbstractVector{FD.Dual{Tg,V,N}}) where {Tg,V,N}
    Av = SparseMatrixCSC(A.m, A.n, A.colptr, A.rowval, FD.value.(A.nzval))
    F  = factorize(Av)                       # same factorisation `\` uses for Float64
    x  = F \ FD.value.(b)
    dx = ntuple(Val(N)) do k
        dA = SparseMatrixCSC(A.m, A.n, A.colptr, A.rowval, FD.partials.(A.nzval, k))
        F \ (FD.partials.(b, k) .- dA * x)
    end
    return [FD.Dual{Tg}(x[i], ntuple(k -> dx[k][i], Val(N))...) for i in eachindex(x)]
end

"""
Run the forward KADMOS 40Ar/39Ar diffusion simulation for one or more
domains along a prescribed P–T–t path.

Arguments
- `Pres_a`  : Pressure history for each domain (matrix of size Npath×Ndom
    or equivalent).
- `TempK_a` : Temperature history in Kelvin for each domain, same shape as
    Pres_a.
- `time_a`  : Time array corresponding to Pres_a and TempK_a (Myr).
- `Lr`      : Vector of effective diffusion radii (μm) for each domain.
- `ndim_a`  : Vector of geometric dimensions (1, 2 or 3) for each domain.
- `Age0`    : Vector of initial ages per domain (Myr).
- `Min_Sys` : Vector of mineral systems per domain (strings used by
    `diff_system`).
- `tlim`    : Total simulation time (Myr).
- `Tmin`    : Minimum temperature in °C used for extrapolation.
- `Pmin`    : Minimum pressure used for extrapolation.

Keyword arguments
- `chol_sol` : If 1, use a Cholesky factorisation of the global matrix;
    otherwise use a direct linear solve.
- `theta`    : Time-integration parameter (0 ≤ θ ≤ 1).
- `nt`       : Number of time steps.
- `nels`     : Number of finite elements per domain (nr = nels + 1 nodes).
- `RdX`      : Ratio of first-to-last radial cell size in the adaptive grid.

Returns
- `C`    : Final concentration vector for all nodes and domains.
- `t_ArK`: Matrix of apparent 40Ar/39Ar ages (Myr) per node and domain.
- `L_G`  : Final assembled global matrix for the last time step.
"""
function run_KADMOS_simulation(
    Pres_a, TempK_a, time_a, Lr, ndim_a, Age0, Min_Sys, tlim, Tmin, Pmin;
    chol_sol    = 1,
    theta       = 1.0,
    nt          = 100,
    nels        = 100,
    RdX         = 2.0
)
    T       = eltype(Pres_a)  # use the type of your input arrays for AD compatibility
    # check number of domains
    ndd     = check_ndomains(Pres_a, TempK_a, time_a, Lr, ndim_a, Age0, Min_Sys)
    # time setup
    dt      = T(tlim) / T(nt)
    nr      = nels + 1
    r1d, dr_ar, Cfact = linspace_adapt(T(0), T(1), nr, T(RdX))
    el2n        = zeros(Int, 2, nr - 1)
    el2n[1, :]  = 1:nr - 1
    el2n[2, :]  = 2:nr
    ndofs       = nr * 1
    # constants
    c2K         = T(273.15)
    Myr2sec     = T(3600 * 24 * 365.25e6)
    mic2met     = T(1e-6)
    cm2metr     = T(1e-2)
    micr2cm     = mic2met / cm2metr
    Rgas        = T(8.3144621)
    f_loss      = T(1.1247)
    lamti       = T(5.543e10) * T(1e-6)
    lam1i       = T(0.581e10) * T(1e-6)
    lamt        = T(1.0) / lamti
    lam1        = T(1.0) / lam1i
    ke          = lam1 / lamt
    # initial Conditions
    Cloc        = (T(1) / ke) .* (T(1) .- exp.(-lamt .* Age0))
    Cplot       = repeat(Cloc, nr, 1)
    Cplot[end, :] .= T(0)
    C           = reshape(Cplot, :, 1)
    t_Myr       = T(0)
    it          = 0
    # preallocations
    Nels        = nels
    Trec        = zeros(T, nt+1, ndd)
    Prec        = zeros(T, nt+1, ndd)
    trec        = zeros(T, nt+1, ndd)
    t_ArK       = zeros(T, nr, ndd)
    Cplot       = zeros(T, nr, ndd)
    L_G         = spzeros(T, ndd*nr, ndd*nr)
    R_G         = zeros(T, ndd*nr)
    x_1         = reshape(r1d[1:end-1], :, 1)
    x_2         = reshape(r1d[2:end], :, 1)
    D_reset     = zeros(T, ndd)
    Co          = similar(C)
    L_g_dom     = [spzeros(T, nr, nr) for _ in 1:ndd]
    R_g_dom     = [zeros(T, nr) for _ in 1:ndd]
    CH_g        = nothing
    M_11i       = zeros(T, Nels)
    M_22i       = zeros(T, Nels)
    M_12i       = zeros(T, Nels)
    K_11i       = zeros(T, Nels)
    K_12i       = zeros(T, Nels)
    M11m_dom    = [spzeros(T, nr, nr) for _ in 1:ndd]
    M11s_dom    = [spzeros(T, nr, nr) for _ in 1:ndd]
    K11m_dom    = [spzeros(T, nr, nr) for _ in 1:ndd]
    K11s_dom    = [spzeros(T, nr, nr) for _ in 1:ndd]
    # define extrapolation variable
    TminK = Tmin + c2K
    # Exactly nt time steps (comparing the accumulated t_Myr with tlim could give nt+1 steps through
    # floating-point round-off, depending on tlim; for tlim = 165.5, nt = 600 both give 600 steps)
    while it < nt
        it      += 1
        t_Myr   += dt
        fill!(L_G, T(0))
        fill!(R_G, T(0))
        Sn      = (T(1) / ke) * (lamt * exp(-lamt * t_Myr))
        So      = (T(1) / ke) * (lamt * exp(-lamt * (t_Myr - dt)))
        C      .= C .+ dt * (theta * Sn + (T(1) - theta) * So)
        C[nr:nr:nr*ndd] .= T(0)
        copyto!(Co, C)
        D_reset .= T(0)
        for idd in 1:ndd
            Tn = interp1_linear(time_a[:, idd], TempK_a[:, idd], t_Myr, TminK)
            Pn = interp1_linear(time_a[:, idd], Pres_a[:, idd], t_Myr, Pmin)
            To = interp1_linear(time_a[:, idd], TempK_a[:, idd], t_Myr - dt, TminK)
            Po = interp1_linear(time_a[:, idd], Pres_a[:, idd], t_Myr - dt, Pmin)
            Trec[it, idd] = Tn - c2K
            Prec[it, idd] = Pn
            trec[it, idd] = t_Myr
            D0_cm2s, Ea, Va, Pref = diff_system(Min_Sys[idd], T)
            D0a2_myr    = (D0_cm2s / (Lr[idd] * micr2cm)^2) * Myr2sec
            Dn          = D0a2_myr * exp(-(Ea + (Pn - Pref) * Va) / Rgas / Tn)
            Do          = D0a2_myr * exp(-(Ea + (Po - Pref) * Va) / Rgas / To)
            ndim        = ndim_a[idd]
            D_reset[idd] = Dn * dt
            if D_reset[idd] > f_loss
                Dn = T(0)
            end
            fill_MatrixFEM!(
                L_g_dom[idd], R_g_dom[idd], idd, nr, ndofs, ndim, x_1, x_2, Dn, Do, theta, dt, Co,
                M_11i, M_22i, M_12i, K_11i, K_12i,
                M11m_dom[idd], M11s_dom[idd], K11m_dom[idd], K11s_dom[idd]
            )
            row_range = (idd - 1) * nr + 1 : idd * nr
            L_G[row_range, row_range] .= L_g_dom[idd]
            R_G[row_range] .= R_g_dom[idd]
        end
        # Solve the system
        if chol_sol == 1
            CH_g = cholesky(L_G)
            C = CH_g \ R_G 
        else
            C = lin_solve(L_G, R_G)
        end
        # Check reset
        for idd in 1:ndd
            if D_reset[idd] > f_loss
                C[(idd - 1) * nr + 1 : (idd - 1) * nr + nr - 1] .= T(0)
            end
        end
        copyto!(Cplot, reshape(C, nr, ndd))
        @. t_ArK = (-T(1) / lamt) * log(T(1) - ke * Cplot) #@. is equivalent to .= (efficiency trick)
    end
    return C, t_ArK,L_G
end

"""
Set up and run the Hamiltonian Monte Carlo (HMC or NUTS) inversion using
the KADMOS forward model.

Arguments
- `params` : Struct or named-tuple carrying all inversion settings,
    including:
        • Observational data: `observed_age`, `age_uncertainty`.
        • Priors for SCR and T0: means, standard deviations, min/max bounds
            and prior-type flags (`SCR_mean`, `SCR_std`, `SCR_min`, `SCR_max`,
            `SCR_prior`, and analogous fields for T0).
        • Grain-size bounds: `Lr_min`, `Lr_max`.
        • Total model time prior: `tlim_mean`, `tlim_std` (truncated at ±3σ).
        • Sampler settings: `sampler_type` ("HMC" or "NUTS"), `n_samples`,
            `hmc_step_size`, `hmc_leapfrog_steps`, `random_seed`.
        • Forward-model settings: `type_path`, `ndim_a`, `Age0`, `Min_Sys`,
            `P0`, `Pmin`, `Tmin`, `chol_sol`, `theta`, `nt`, `RdX`,
            `nels`.
        • Output control: `run_id`, `output_folder`.

Returns
- A Turing `Chains` object containing posterior samples of SCR, T0, Lr and tlim.
    Posterior samples, convergence diagnostics and a text summary are also
    written to `output_folder`.
"""
    function run_hmc_inversion(params)
            # extract all parameters from the tuple
    observed_age = params.observed_age
    age_uncertainty = params.age_uncertainty
    
    SCR_mean = params.SCR_mean
    SCR_std = params.SCR_std
    SCR_min = params.SCR_min
    SCR_max = params.SCR_max
    SCR_prior = params.SCR_prior
    
    T0_mean = params.T0_mean
    T0_std = params.T0_std
    T0_min = params.T0_min
    T0_max = params.T0_max
    T0_prior = params.T0_prior

    Lr_min = params.Lr_min
    Lr_max = params.Lr_max
    # optional (default: Uniform, as in RUN_KADMOS_HMC.jl); 1 = Uniform, otherwise truncated Normal
    Lr_prior = get(params, :Lr_prior, 1)
    Lr_mean = get(params, :Lr_mean, (Lr_min + Lr_max) / 2)
    Lr_std = get(params, :Lr_std, (Lr_max - Lr_min) / 2)
    
    sampler_type = params.sampler_type
    n_samples = params.n_samples
    hmc_step_size = params.hmc_step_size
    hmc_leapfrog_steps = params.hmc_leapfrog_steps
    random_seed = params.random_seed
    
    run_id = params.run_id
    output_folder = params.output_folder
    
    type_path = params.type_path
    ndim_a = params.ndim_a
    Age0 = params.Age0
    Min_Sys = params.Min_Sys
    tlim_mean = params.tlim_mean
    tlim_std = params.tlim_std
    # optional (default: truncated Normal at ±3σ, as in RUN_KADMOS_HMC.jl); 1 = Uniform
    tlim_prior = get(params, :tlim_prior, 0)
    tlim_min = get(params, :tlim_min, tlim_mean - 3 * tlim_std)
    tlim_max = get(params, :tlim_max, tlim_mean + 3 * tlim_std)
    P0 = params.P0
    Pmin = params.Pmin
    Tmin = params.Tmin
    
    chol_sol = params.chol_sol
    theta = params.theta
    nt = params.nt
    RdX = params.RdX
    nels = params.nels


    MODEL_COUNTER = Ref(0)
    
        """
        Forward-model helper used inside the Turing model.

        Arguments
        - `SCR` : Cooling rate parameter (°C/Myr).
        - `T0`  : Initial temperature (°C).
        - `Lr`  : Effective grain size (μm) for the single domain case.
        - `tlim`: Total model time (Myr).

        Returns
        - Maximum apparent 40Ar/39Ar age (Myr) over all nodes of the domain
            for the given parameters.
        """
    function main(SCR, T0, Lr, tlim)
        MODEL_COUNTER[] += 1
        if MODEL_COUNTER[] % 10 == 0 || MODEL_COUNTER[] == 1
            @info "Total KADMOS evaluations: $(MODEL_COUNTER[])"
        end
        # generate the PTt path
        Pres_A, TempK_A, time_A = make_PTtpath(type_path, T0, SCR, P0, Pmin, Tmin, tlim)
        # replicate arrays for each mineral domain
        ndd = length([Lr])
        Npath = length(Pres_A)
        Pres_a = reshape(Pres_A, 1, Npath)' .+ zeros(ndd, Npath)'
        TempK_a = reshape(TempK_A, 1, Npath)' .+ zeros(ndd, Npath)'
        time_a = reshape(time_A, 1, Npath)' .+ zeros(ndd, Npath)'
        # run KADMOS
        C, t_ArK, L_G = run_KADMOS_simulation(
            Pres_a, TempK_a, time_a, [Lr], ndim_a, Age0, Min_Sys, tlim, Tmin, Pmin;
            chol_sol = chol_sol,
            theta = theta,
            nt = nt,
            nels = nels,
            RdX = RdX
        )
        max_t = maximum(t_ArK[:])
        return max_t
    end
        # Turing model
        """
        Turing probabilistic model for the inversion.

        Arguments
        - `max_t` : Observed apparent age (Myr) used as data.

        Description
        - Defines priors for SCR, T0, Lr and tlim (uniform or truncated normal,
            depending on the prior flags; without `Lr_prior` Lr is uniform and without
            `tlim_prior` tlim is a normal truncated at ±3σ, e.g. from the hornblende age).
        - Calls `main(SCR, T0, Lr, tlim)` to obtain the model-predicted maximum age.
        - Assumes a Normal likelihood for `max_t` with mean `max_t_hat` and
            standard deviation `age_uncertainty`.
        """
    @model function turing_model(max_t)
        if SCR_prior == 1
            SCR ~ Uniform(SCR_min,SCR_max)
        else
            SCR ~ truncated(Normal(SCR_mean, SCR_std), SCR_min, SCR_max)
        end

        if T0_prior == 1
            T0 ~ Uniform(T0_min, T0_max)
        else
        T0 ~ truncated(Normal(T0_mean, T0_std), T0_min, T0_max)
        end
        if Lr_prior == 1
            Lr ~ Uniform(Lr_min, Lr_max)
        else
            Lr ~ truncated(Normal(Lr_mean, Lr_std), Lr_min, Lr_max)
        end

        if tlim_prior == 1
            tlim ~ Uniform(tlim_min, tlim_max)
        else
            tlim ~ truncated(Normal(tlim_mean, tlim_std), tlim_min, tlim_max)
        end

        max_t_hat = main(SCR, T0, Lr, tlim)
        max_t ~ Normal(max_t_hat, age_uncertainty) 
    end
    # run HMC sampling
    model = turing_model(observed_age)
    MODEL_COUNTER[] = 0
    rng = Random.MersenneTwister(random_seed)
    @info "Starting Hamiltonian Monte Carlo"
    # start timing
    start_time = time()
    if sampler_type == "NUTS"
        chain = sample(rng,model, NUTS(), n_samples)
    elseif sampler_type == "HMC"
        chain = sample(rng,model, HMC(hmc_step_size, hmc_leapfrog_steps), n_samples)
    else
        error("Unknown sampler_type: $sampler_type. Choose 'NUTS' or 'HMC'")
    end
    # calculate elapsed time
    elapsed_time = time() - start_time
    elapsed_minutes = elapsed_time / 60
    elapsed_hours = elapsed_time / 3600
    @info "Total forward model evaluations: $(MODEL_COUNTER[])"
    @info "Total wall time: $(round(elapsed_time, digits=2)) seconds ($(round(elapsed_minutes, digits=2)) minutes)"
    # save results
    mkpath(output_folder)
    # sSave posterior samples
    df = DataFrame(chain)
    CSV.write(joinpath(output_folder, "posterior_samples.csv"), df)
    # save summary
    txtfile = joinpath(output_folder, "run_summary.txt")
    open(txtfile, "w") do io
        println(io, "Run ID: $run_id")
        println(io, "Date: $(Dates.now())\n")
        println(io, "Priors:")
        prior_str(u, m, s, lo, hi) = u == 1 ? "Uniform($lo, $hi)" : "truncated(Normal($m, $s), $lo, $hi)"
        println(io, "  SCR ~ ", prior_str(SCR_prior, SCR_mean, SCR_std, SCR_min, SCR_max))
        println(io, "  T0  ~ ", prior_str(T0_prior, T0_mean, T0_std, T0_min, T0_max))
        println(io, "  Lr  ~ ", prior_str(Lr_prior, Lr_mean, Lr_std, Lr_min, Lr_max))
        println(io, "  tlim ~ ", prior_str(tlim_prior, tlim_mean, tlim_std, tlim_min, tlim_max))
        println(io, "\nHMC Sampler Settings:")
        println(io, "  sampler: $sampler_type")
        if sampler_type == "HMC"
            println(io, "  step size (ϵ): $hmc_step_size")
            println(io, "  leapfrog steps: $hmc_leapfrog_steps")
        else
            println(io, "  step size (ϵ): AUTO")
            println(io, "  leapfrog steps: AUTO")
        end
        println(io, "  samples: $n_samples")
        println(io, "  Random seed: $random_seed")
        println(io, "\nPerformance:")
        println(io, "  Total evaluations: $(MODEL_COUNTER[])")
        println(io, "  Wall time: $(round(elapsed_time, digits=2)) seconds")
        println(io, "  Wall time: $(round(elapsed_minutes, digits=2)) minutes")
        println(io, "  Wall time: $(round(elapsed_hours, digits=2)) hours")
        println(io, "  Avg time per evaluation: $(round(elapsed_time/MODEL_COUNTER[], digits=3)) seconds")
        println(io, "\nOther Model Settings:")
        println(io, "  observed_age: $observed_age")
        println(io, "  age_uncertainty: $age_uncertainty")
        println(io, "  P0: $P0")
        println(io, "  Pmin: $Pmin")
        println(io, "  Tmin: $Tmin")
        println(io, "  type of path: $type_path")
        println(io, "  Mineral system: $(Min_Sys[1])")
    end
    # R-hat
    rhat_vals = rhat(chain)
    CSV.write(joinpath(output_folder, "rhat_values.csv"), rhat_vals)
    println("Results saved in folder: $output_folder")
    return chain
end

# Keeps an in-axis legend clear of the density curve: puts it in the top corner (right or left) where the
# curve is lowest and raises the upper y-limit just enough that the curve passes below the legend box.
function fit_legend!(fig, ax, leg, x, y; gap = 12)
    best = nothing
    for side in (:right, :left)
        leg.halign = side
        Makie.update_state_before_display!(fig)
        vp = ax.scene.viewport[]
        bb = leg.layoutobservables.computedbbox[]
        lims = ax.finallimits[]
        xa = minimum(lims)[1] + (minimum(bb)[1] - minimum(vp)[1]) / widths(vp)[1] * widths(lims)[1]
        xb = minimum(lims)[1] + (maximum(bb)[1] - minimum(vp)[1]) / widths(vp)[1] * widths(lims)[1]
        frac = (minimum(bb)[2] - minimum(vp)[2] - gap) / widths(vp)[2]   # axis height fraction below the legend
        ycurve = maximum((yi for (xi, yi) in zip(x, y) if xa <= xi <= xb); init = 0.0)
        y_upper = max(maximum(y) * 1.1, ycurve / frac)
        (isnothing(best) || y_upper < best[2]) && (best = (side, y_upper))
    end
    leg.halign = best[1]
    ylims!(ax, 0, best[2])
    return nothing
end

"""
Create and save diagnostic density and trace plots for a finished HMC/NUTS
run.

Arguments
- `outdir` : Directory containing a `posterior_samples.csv` file produced
    by `run_hmc_inversion`. The figures are saved here.
- `chain_dirs` : Folders whose `posterior_samples.csv` are pooled (all seeds
    combined) for the densities; each one is drawn as its own trace.

Output
- Saves `density_plots.(png|pdf)` showing posterior densities of T0, SCR
    and Lr with mean, mode, ±1σ and 68% credible intervals.
- Saves `trace_plots.(png|pdf)` showing the MCMC traces for T0, SCR and Lr.
"""
function create_diagnostic_plots(outdir; chain_dirs = [outdir])
    try_save = function(path::AbstractString, fig; kwargs...)
        try
            save(path, fig; kwargs...)
        catch e
            base, ext = splitext(path)
            ts = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
            alt = string(base, "_", ts, ext)
            @warn "Save failed for $(basename(path)) -> saving as $(basename(alt))" exception=(e, catch_backtrace())
            save(alt, fig; kwargs...)
        end
    end
    # all chains (seeds) in chain_dirs pooled together; by default only the chain in outdir is used
    dfs = [CSV.read(joinpath(d, "posterior_samples.csv"), DataFrame) for d in chain_dirs]
    df = vcat(dfs...; cols = :union)
    T0_samples = df[!, :T0]
    SCR_samples = df[!, :SCR]
    Lr_samples = df[!, :Lr]
    has_tlim = hasproperty(df, :tlim)    # 4-parameter run: total model time also inverted (4th panel)
    purple_pink = RGBf(0.7, 0.3, 0.6)
    pastel_green = RGBf(0.5, 0.8, 0.5)  # Darker pastel green
    dark_green = RGBf(0.3, 0.6, 0.3)     # Dark green for std
    orange = RGBf(1.0, 0.6, 0.2)
    # one trace per chain: single chain keeps the usual colour, several chains get one colour each
    chain_colors = length(dfs) == 1 ? [purple_pink] : Makie.resample_cmap(:viridis, length(dfs))
    set_theme!(Theme(fonts = (regular = "Times New Roman", bold = "Times New Roman Bold")))
    # panel positions: one row for 3 parameters, 2 x 2 grid when tlim is also inverted
    cell(i) = has_tlim ? (cld(i, 2), mod1(i, 2)) : (1, i)
    fig_density = Figure(size = has_tlim ? (1600, 1600) : (2400, 800))
    legend_fits = []
    ax1 = Axis(fig_density[1, 1], 
               xlabel = "Initial Temperature (°C)", 
               ylabel = "Probability Density (1/°C)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    kde_T0 = kde(T0_samples)
    x_T0 = kde_T0.x
    y_T0 = kde_T0.density
    mean_T0 = mean(T0_samples)
    std_T0 = std(T0_samples)
    mode_T0 = x_T0[argmax(y_T0)]
    sorted_T0 = sort(T0_samples)
    n = length(sorted_T0)
    lower_idx = max(1, floor(Int, n * 0.16))
    upper_idx = min(n, ceil(Int, n * 0.84))
    ci_lower_T0 = sorted_T0[lower_idx]
    ci_upper_T0 = sorted_T0[upper_idx]
    mask_T0 = (x_T0 .>= ci_lower_T0) .& (x_T0 .<= ci_upper_T0)
    band!(ax1, x_T0[mask_T0], zeros(sum(mask_T0)), y_T0[mask_T0], color = (purple_pink, 0.3))
    lines!(ax1, x_T0, y_T0, color = purple_pink, linewidth = 3)
    vlines!(ax1, [mode_T0], color = orange, linestyle = :solid, linewidth = 2)
    vlines!(ax1, [mean_T0], color = pastel_green, linestyle = :dash, linewidth = 2.5)
    vlines!(ax1, [mean_T0 - std_T0, mean_T0 + std_T0], color = dark_green, linestyle = :solid, linewidth = 1.5)
    leg_elements = [LineElement(color = orange, linestyle = :solid, linewidth = 2),
                   LineElement(color = pastel_green, linestyle = :dash, linewidth = 2.5),
                   LineElement(color = dark_green, linestyle = :solid, linewidth = 1.5),
                   []]  
    leg_labels = [@sprintf("Mode: %.0f °C", mode_T0),
                  @sprintf("Mean: %.0f °C", mean_T0),
                  @sprintf("±1σ: %.0f °C", std_T0),
                  @sprintf("68%% : [%.0f, %.0f]", ci_lower_T0, ci_upper_T0)]
    leg_T0 = axislegend(ax1, leg_elements, leg_labels,
               position = :rt,
               labelsize = 32,
               framevisible = true,
               backgroundcolor = (:white, 0.8))
    push!(legend_fits, (ax1, leg_T0, x_T0, y_T0))   # placed clear of the curve before saving
    y_upper_T0 = maximum(y_T0) * 1.25
    xlims!(ax1, 500, nothing)
    ylims!(ax1, 0, y_upper_T0)
    ax2 = Axis(fig_density[1, 2], 
               xlabel = "Initial Cooling Rate (°C/Myr)", 
               ylabel = "Probability Density (Myr/°C)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    kde_SCR = kde(SCR_samples)
    x_SCR = kde_SCR.x
    y_SCR = kde_SCR.density
    mean_SCR = mean(SCR_samples)
    std_SCR = std(SCR_samples)
    mode_SCR = x_SCR[argmax(y_SCR)]
    sorted_SCR = sort(SCR_samples)
    ci_lower_SCR = sorted_SCR[lower_idx]
    ci_upper_SCR = sorted_SCR[upper_idx]
    mask_SCR = (x_SCR .>= ci_lower_SCR) .& (x_SCR .<= ci_upper_SCR)
    band!(ax2, x_SCR[mask_SCR], zeros(sum(mask_SCR)), y_SCR[mask_SCR], color = (purple_pink, 0.3))
    lines!(ax2, x_SCR, y_SCR, color = purple_pink, linewidth = 3)
    vlines!(ax2, [mode_SCR], color = orange, linestyle = :solid, linewidth = 2)
    vlines!(ax2, [mean_SCR], color = pastel_green, linestyle = :dash, linewidth = 2.5)
    vlines!(ax2, [mean_SCR - std_SCR, mean_SCR + std_SCR], color = dark_green, linestyle = :solid, linewidth = 1.5)
    leg_elements_SCR = [LineElement(color = orange, linestyle = :solid, linewidth = 2),
                       LineElement(color = pastel_green, linestyle = :dash, linewidth = 2.5),
                       LineElement(color = dark_green, linestyle = :solid, linewidth = 1.5),
                       []]  
    leg_labels_SCR = [@sprintf("Mode: %.0f °C/Myr", mode_SCR),
                      @sprintf("Mean: %.0f °C/Myr", mean_SCR),
                      @sprintf("±1σ: %.0f °C/Myr", std_SCR),
                      @sprintf("68%% : [%.0f, %.0f]", ci_lower_SCR, ci_upper_SCR)]
    leg_SCR = axislegend(ax2, leg_elements_SCR, leg_labels_SCR,
               position = :rt,
               labelsize = 32,
               framevisible = true,
               backgroundcolor = (:white, 0.8))
    push!(legend_fits, (ax2, leg_SCR, x_SCR, y_SCR))   # placed clear of the curve before saving
    y_upper_SCR = maximum(y_SCR) * 1.25
    xlims!(ax2, 0, nothing)
    ylims!(ax2, 0, y_upper_SCR)
    ax3 = Axis(fig_density[cell(3)...],
               xlabel = "Effective Grain Size (μm)", 
               ylabel = "Probability Density (1/μm)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    kde_Lr = kde(Lr_samples)
    x_Lr = kde_Lr.x
    y_Lr = kde_Lr.density
    mean_Lr = mean(Lr_samples)
    std_Lr = std(Lr_samples)
    mode_Lr = x_Lr[argmax(y_Lr)]
    sorted_Lr = sort(Lr_samples)
    ci_lower_Lr = sorted_Lr[lower_idx]
    ci_upper_Lr = sorted_Lr[upper_idx]
    mask_Lr = (x_Lr .>= ci_lower_Lr) .& (x_Lr .<= ci_upper_Lr)
    band!(ax3, x_Lr[mask_Lr], zeros(sum(mask_Lr)), y_Lr[mask_Lr], color = (purple_pink, 0.3))
    lines!(ax3, x_Lr, y_Lr, color = purple_pink, linewidth = 3)
    vlines!(ax3, [mode_Lr], color = orange, linestyle = :solid, linewidth = 2)
    vlines!(ax3, [mean_Lr], color = pastel_green, linestyle = :dash, linewidth = 2.5)
    vlines!(ax3, [mean_Lr - std_Lr, mean_Lr + std_Lr], color = dark_green, linestyle = :solid, linewidth = 1.5)
    leg_elements_Lr = [LineElement(color = orange, linestyle = :solid, linewidth = 2),
                      LineElement(color = pastel_green, linestyle = :dash, linewidth = 2.5),
                      LineElement(color = dark_green, linestyle = :solid, linewidth = 1.5),
                      []]  
    leg_labels_Lr = [@sprintf("Mode: %.0f μm", mode_Lr),
                     @sprintf("Mean: %.0f μm", mean_Lr),
                     @sprintf("±1σ: %.0f μm", std_Lr),
                     @sprintf("68%% : [%.0f, %.0f]", ci_lower_Lr, ci_upper_Lr)]
    leg_Lr = axislegend(ax3, leg_elements_Lr, leg_labels_Lr,
               position = :rt,
               labelsize = 32,
               framevisible = true,
               backgroundcolor = (:white, 0.8))
    push!(legend_fits, (ax3, leg_Lr, x_Lr, y_Lr))   # placed clear of the curve before saving
    y_upper_Lr = maximum(y_Lr) * 1.25
    xlims!(ax3, 0, nothing)
    ylims!(ax3, 0, y_upper_Lr)
    if has_tlim
        tlim_samples = df[!, :tlim]
        ax7 = Axis(fig_density[cell(4)...],
                   xlabel = "Total Model Time (Myr)",
                   ylabel = "Probability Density (1/Myr)",
                   aspect = 1,
                   xticksmirrored = true,
                   yticksmirrored = true,
                   xtickalign = 1,
                   ytickalign = 1,
                   xlabelsize = 40,
                   ylabelsize = 40,
                   xticklabelsize = 32,
                   yticklabelsize = 32)
        kde_tlim = kde(tlim_samples)
        x_tlim = kde_tlim.x
        y_tlim = kde_tlim.density
        mean_tlim = mean(tlim_samples)
        std_tlim = std(tlim_samples)
        mode_tlim = x_tlim[argmax(y_tlim)]
        sorted_tlim = sort(tlim_samples)
        ci_lower_tlim = sorted_tlim[lower_idx]
        ci_upper_tlim = sorted_tlim[upper_idx]
        mask_tlim = (x_tlim .>= ci_lower_tlim) .& (x_tlim .<= ci_upper_tlim)
        band!(ax7, x_tlim[mask_tlim], zeros(sum(mask_tlim)), y_tlim[mask_tlim], color = (purple_pink, 0.3))
        lines!(ax7, x_tlim, y_tlim, color = purple_pink, linewidth = 3)
        vlines!(ax7, [mode_tlim], color = orange, linestyle = :solid, linewidth = 2)
        vlines!(ax7, [mean_tlim], color = pastel_green, linestyle = :dash, linewidth = 2.5)
        vlines!(ax7, [mean_tlim - std_tlim, mean_tlim + std_tlim], color = dark_green, linestyle = :solid, linewidth = 1.5)
        leg_elements_tlim = [LineElement(color = orange, linestyle = :solid, linewidth = 2),
                             LineElement(color = pastel_green, linestyle = :dash, linewidth = 2.5),
                             LineElement(color = dark_green, linestyle = :solid, linewidth = 1.5),
                             []]
        # one decimal: the total time spans less than ~2 Myr, whole numbers would hide the result
        leg_labels_tlim = [@sprintf("Mode: %.1f Myr", mode_tlim),
                           @sprintf("Mean: %.1f Myr", mean_tlim),
                           @sprintf("±1σ: %.1f Myr", std_tlim),
                           @sprintf("68%% : [%.1f, %.1f]", ci_lower_tlim, ci_upper_tlim)]
        leg_tlim = axislegend(ax7, leg_elements_tlim, leg_labels_tlim,
                   position = :rt,
                   labelsize = 32,
                   framevisible = true,
                   backgroundcolor = (:white, 0.8))
        push!(legend_fits, (ax7, leg_tlim, x_tlim, y_tlim))   # placed clear of the curve before saving
        ylims!(ax7, 0, maximum(y_tlim) * 1.25)
    end
    foreach(f -> fit_legend!(fig_density, f...), legend_fits)
    try_save(joinpath(outdir, "density_plots.png"), fig_density; px_per_unit = 3)
    try_save(joinpath(outdir, "density_plots.pdf"), fig_density)
    fig_trace = Figure(size = has_tlim ? (1600, 1600) : (2400, 800))
    ax4 = Axis(fig_trace[1, 1], 
               xlabel = "Iteration", 
               ylabel = "Initial Temperature (°C)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    foreach(k -> lines!(ax4, 1:nrow(dfs[k]), dfs[k][!, :T0], color = chain_colors[k], linewidth = 1), eachindex(dfs))
    xlims!(ax4, 0, nothing)                       # y-axis automatic: fitted to the sampled range
    ax5 = Axis(fig_trace[1, 2], 
               xlabel = "Iteration", 
               ylabel = "Initial Cooling Rate (°C/Myr)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    foreach(k -> lines!(ax5, 1:nrow(dfs[k]), dfs[k][!, :SCR], color = chain_colors[k], linewidth = 1), eachindex(dfs))
    xlims!(ax5, 0, nothing)                       # y-axis automatic: fitted to the sampled range
    ax6 = Axis(fig_trace[cell(3)...],
               xlabel = "Iteration", 
               ylabel = "Effective Grain Size (μm)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    foreach(k -> lines!(ax6, 1:nrow(dfs[k]), dfs[k][!, :Lr], color = chain_colors[k], linewidth = 1), eachindex(dfs))
    xlims!(ax6, 0, nothing)
    ylims!(ax6, 0, nothing)
    if has_tlim
        ax8 = Axis(fig_trace[cell(4)...],
                   xlabel = "Iteration",
                   ylabel = "Total Model Time (Myr)",
                   aspect = 1,
                   xticksmirrored = true,
                   yticksmirrored = true,
                   xtickalign = 1,
                   ytickalign = 1,
                   xlabelsize = 40,
                   ylabelsize = 40,
                   xticklabelsize = 32,
                   yticklabelsize = 32)
        foreach(k -> lines!(ax8, 1:nrow(dfs[k]), dfs[k][!, :tlim], color = chain_colors[k], linewidth = 1), eachindex(dfs))
        xlims!(ax8, 0, nothing)                   # y-axis automatic: values stay close to ~165 Myr
    end
    try_save(joinpath(outdir, "trace_plots.png"), fig_trace; px_per_unit = 3)
    try_save(joinpath(outdir, "trace_plots.pdf"), fig_trace)
    set_theme!()
    println("Diagnostic plots saved in: $outdir")
    println("  - density_plots.png/.pdf: Posterior density distributions")
    println("  - trace_plots.png/.pdf: MCMC trace plots")
end

"""
Load previously computed posterior samples from a results directory and
recreate the density and trace diagnostic plots with automatic axis limits.

Arguments
- `outdir` : Directory containing an existing `posterior_samples.csv`
    (e.g. from a previous distribution or parallel-chain run).

Output
- Overwrites or creates `density_plots.(png|pdf)` and
    `trace_plots.(png|pdf)` in `outdir`, using autoscaled axes.
"""
function plot_existing_results(outdir)
    """
    Plot existing MCMC results from a folder containing posterior_samples.csv
    with automatic axis limits for both posterior density and trace plots.
    
    Usage:
        plot_existing_results("600samples_run1")
    """
    try_save = function(path::AbstractString, fig; kwargs...)
        try
            save(path, fig; kwargs...)
        catch e
            base, ext = splitext(path)
            ts = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
            alt = string(base, "_", ts, ext)
            @warn "Save failed for $(basename(path)) -> saving as $(basename(alt))" exception=(e, catch_backtrace())
            save(alt, fig; kwargs...)
        end
    end
    
    # Read the posterior samples
    df = CSV.read(joinpath(outdir, "posterior_samples.csv"), DataFrame)
    T0_samples = df[!, :T0]
    SCR_samples = df[!, :SCR]
    Lr_samples = df[!, :Lr]
    
    # Color scheme
    purple_pink = RGBf(0.7, 0.3, 0.6)
    pastel_green = RGBf(0.5, 0.8, 0.5)
    dark_green = RGBf(0.3, 0.6, 0.3)
    orange = RGBf(1.0, 0.6, 0.2)
    
    # Set theme
    set_theme!(Theme(fonts = (regular = "Times New Roman", bold = "Times New Roman Bold")))
    
    # ===== DENSITY PLOTS =====
    fig_density = Figure(size = (2400, 800))
    legend_fits = []
    
    # T0 Density Plot
    ax1 = Axis(fig_density[1, 1], 
               xlabel = "Initial Temperature (°C)", 
               ylabel = "Probability Density (1/°C)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    
    kde_T0 = kde(T0_samples)
    x_T0 = kde_T0.x
    y_T0 = kde_T0.density
    mean_T0 = mean(T0_samples)
    std_T0 = std(T0_samples)
    mode_T0 = x_T0[argmax(y_T0)]
    
    sorted_T0 = sort(T0_samples)
    n = length(sorted_T0)
    lower_idx = max(1, floor(Int, n * 0.16))
    upper_idx = min(n, ceil(Int, n * 0.84))
    ci_lower_T0 = sorted_T0[lower_idx]
    ci_upper_T0 = sorted_T0[upper_idx]
    
    mask_T0 = (x_T0 .>= ci_lower_T0) .& (x_T0 .<= ci_upper_T0)
    band!(ax1, x_T0[mask_T0], zeros(sum(mask_T0)), y_T0[mask_T0], color = (purple_pink, 0.3))
    lines!(ax1, x_T0, y_T0, color = purple_pink, linewidth = 3)
    vlines!(ax1, [mode_T0], color = orange, linestyle = :solid, linewidth = 2)
    vlines!(ax1, [mean_T0], color = pastel_green, linestyle = :dash, linewidth = 2.5)
    vlines!(ax1, [mean_T0 - std_T0, mean_T0 + std_T0], color = dark_green, linestyle = :solid, linewidth = 1.5)
    
    leg_elements = [LineElement(color = orange, linestyle = :solid, linewidth = 2),
                   LineElement(color = pastel_green, linestyle = :dash, linewidth = 2.5),
                   LineElement(color = dark_green, linestyle = :solid, linewidth = 1.5),
                   []]  
    leg_labels = [@sprintf("Mode: %.0f °C", mode_T0),
                  @sprintf("Mean: %.0f °C", mean_T0),
                  @sprintf("±1σ: %.0f °C", std_T0),
                  @sprintf("68%% : [%.0f, %.0f]", ci_lower_T0, ci_upper_T0)]
    leg_T0 = axislegend(ax1, leg_elements, leg_labels,
               position = :rt,
               labelsize = 32,
               framevisible = true,
               backgroundcolor = (:white, 0.8))
    push!(legend_fits, (ax1, leg_T0, x_T0, y_T0))   # placed clear of the curve before saving
    
    # Automatic axis limits for T0 density
    y_upper_T0 = maximum(y_T0) * 1.25
    autolimits!(ax1)
    ylims!(ax1, 0, y_upper_T0)
    
    # SCR Density Plot
    ax2 = Axis(fig_density[1, 2], 
               xlabel = "Initial Cooling Rate (°C/Myr)", 
               ylabel = "Probability Density (Myr/°C)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    
    kde_SCR = kde(SCR_samples)
    x_SCR = kde_SCR.x
    y_SCR = kde_SCR.density
    mean_SCR = mean(SCR_samples)
    std_SCR = std(SCR_samples)
    mode_SCR = x_SCR[argmax(y_SCR)]
    
    sorted_SCR = sort(SCR_samples)
    ci_lower_SCR = sorted_SCR[lower_idx]
    ci_upper_SCR = sorted_SCR[upper_idx]
    
    mask_SCR = (x_SCR .>= ci_lower_SCR) .& (x_SCR .<= ci_upper_SCR)
    band!(ax2, x_SCR[mask_SCR], zeros(sum(mask_SCR)), y_SCR[mask_SCR], color = (purple_pink, 0.3))
    lines!(ax2, x_SCR, y_SCR, color = purple_pink, linewidth = 3)
    vlines!(ax2, [mode_SCR], color = orange, linestyle = :solid, linewidth = 2)
    vlines!(ax2, [mean_SCR], color = pastel_green, linestyle = :dash, linewidth = 2.5)
    vlines!(ax2, [mean_SCR - std_SCR, mean_SCR + std_SCR], color = dark_green, linestyle = :solid, linewidth = 1.5)
    
    leg_elements_SCR = [LineElement(color = orange, linestyle = :solid, linewidth = 2),
                       LineElement(color = pastel_green, linestyle = :dash, linewidth = 2.5),
                       LineElement(color = dark_green, linestyle = :solid, linewidth = 1.5),
                       []]  
    leg_labels_SCR = [@sprintf("Mode: %.0f °C/Myr", mode_SCR),
                      @sprintf("Mean: %.0f °C/Myr", mean_SCR),
                      @sprintf("±1σ: %.0f °C/Myr", std_SCR),
                      @sprintf("68%% : [%.0f, %.0f]", ci_lower_SCR, ci_upper_SCR)]
    leg_SCR = axislegend(ax2, leg_elements_SCR, leg_labels_SCR,
               position = :rt,
               labelsize = 32,
               framevisible = true,
               backgroundcolor = (:white, 0.8))
    push!(legend_fits, (ax2, leg_SCR, x_SCR, y_SCR))   # placed clear of the curve before saving
    
    # Automatic axis limits for SCR density
    y_upper_SCR = maximum(y_SCR) * 1.25
    autolimits!(ax2)
    ylims!(ax2, 0, y_upper_SCR)
    
    # Lr Density Plot
    ax3 = Axis(fig_density[1, 3], 
               xlabel = "Effective Grain Size (μm)", 
               ylabel = "Probability Density (1/μm)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    
    kde_Lr = kde(Lr_samples)
    x_Lr = kde_Lr.x
    y_Lr = kde_Lr.density
    mean_Lr = mean(Lr_samples)
    std_Lr = std(Lr_samples)
    mode_Lr = x_Lr[argmax(y_Lr)]
    
    sorted_Lr = sort(Lr_samples)
    ci_lower_Lr = sorted_Lr[lower_idx]
    ci_upper_Lr = sorted_Lr[upper_idx]
    
    mask_Lr = (x_Lr .>= ci_lower_Lr) .& (x_Lr .<= ci_upper_Lr)
    band!(ax3, x_Lr[mask_Lr], zeros(sum(mask_Lr)), y_Lr[mask_Lr], color = (purple_pink, 0.3))
    lines!(ax3, x_Lr, y_Lr, color = purple_pink, linewidth = 3)
    vlines!(ax3, [mode_Lr], color = orange, linestyle = :solid, linewidth = 2)
    vlines!(ax3, [mean_Lr], color = pastel_green, linestyle = :dash, linewidth = 2.5)
    vlines!(ax3, [mean_Lr - std_Lr, mean_Lr + std_Lr], color = dark_green, linestyle = :solid, linewidth = 1.5)
    
    leg_elements_Lr = [LineElement(color = orange, linestyle = :solid, linewidth = 2),
                      LineElement(color = pastel_green, linestyle = :dash, linewidth = 2.5),
                      LineElement(color = dark_green, linestyle = :solid, linewidth = 1.5),
                      []]  
    leg_labels_Lr = [@sprintf("Mode: %.0f μm", mode_Lr),
                     @sprintf("Mean: %.0f μm", mean_Lr),
                     @sprintf("±1σ: %.0f μm", std_Lr),
                     @sprintf("68%% : [%.0f, %.0f]", ci_lower_Lr, ci_upper_Lr)]
    leg_Lr = axislegend(ax3, leg_elements_Lr, leg_labels_Lr,
               position = :rt,
               labelsize = 32,
               framevisible = true,
               backgroundcolor = (:white, 0.8))
    push!(legend_fits, (ax3, leg_Lr, x_Lr, y_Lr))   # placed clear of the curve before saving
    
    # Automatic axis limits for Lr density
    y_upper_Lr = maximum(y_Lr) * 1.25
    autolimits!(ax3)
    ylims!(ax3, 0, y_upper_Lr)
    
    # Save density plots
    foreach(f -> fit_legend!(fig_density, f...), legend_fits)
    try_save(joinpath(outdir, "density_plots.png"), fig_density; px_per_unit = 3)
    try_save(joinpath(outdir, "density_plots.pdf"), fig_density)
    
    # ===== TRACE PLOTS =====
    fig_trace = Figure(size = (2400, 800))
    
    # T0 Trace Plot
    ax4 = Axis(fig_trace[1, 1], 
               xlabel = "Iteration", 
               ylabel = "Initial Temperature (°C)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    
    lines!(ax4, 1:length(T0_samples), T0_samples, color = purple_pink, linewidth = 1)
    autolimits!(ax4)
    
    # SCR Trace Plot
    ax5 = Axis(fig_trace[1, 2], 
               xlabel = "Iteration", 
               ylabel = "Initial Cooling Rate (°C/Myr)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    
    lines!(ax5, 1:length(SCR_samples), SCR_samples, color = purple_pink, linewidth = 1)
    autolimits!(ax5)
    
    # Lr Trace Plot
    ax6 = Axis(fig_trace[1, 3], 
               xlabel = "Iteration", 
               ylabel = "Effective Grain Size (μm)",
               aspect = 1,
               xticksmirrored = true,
               yticksmirrored = true,
               xtickalign = 1,
               ytickalign = 1,
               xlabelsize = 40,
               ylabelsize = 40,
               xticklabelsize = 32,
               yticklabelsize = 32)
    
    lines!(ax6, 1:length(Lr_samples), Lr_samples, color = purple_pink, linewidth = 1)
    autolimits!(ax6)
    
    # Save trace plots
    try_save(joinpath(outdir, "trace_plots.png"), fig_trace; px_per_unit = 3)
    try_save(joinpath(outdir, "trace_plots.pdf"), fig_trace)
    
    # Reset theme
    set_theme!()
    
    println("Diagnostic plots saved in: $outdir")
    println("  - density_plots.png/.pdf: Posterior density distributions (automatic axis limits)")
    println("  - trace_plots.png/.pdf: MCMC trace plots (automatic axis limits)")
end



function create_chain_comparison_plots(chain_dirs, outdir, param_syms, xlabels, ylabels;
                                       seeds = nothing)
    try_save = function(path::AbstractString, fig; kwargs...)
        try
            save(path, fig; kwargs...)
        catch e
            base, ext = splitext(path)
            ts = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
            alt = string(base, "_", ts, ext)
            @warn "Save failed for $(basename(path)) -> saving as $(basename(alt))" exception=(e, catch_backtrace())
            save(alt, fig; kwargs...)
        end
    end
    dfs = [CSV.read(joinpath(d, "posterior_samples.csv"), DataFrame) for d in chain_dirs]
    n_iter = minimum(nrow.(dfs))
    samples = cat([Matrix{Float64}(df[1:n_iter, param_syms]) for df in dfs]...; dims = 3)
    multichain = Chains(samples, collect(param_syms))
    mkpath(outdir)
    CSV.write(joinpath(outdir, "multichain_diagnostics.csv"), DataFrame(summarystats(multichain)))
    rhat_df = DataFrame(rhat(multichain))
    rhat_of(p) = rhat_df[findfirst(==(Symbol(p)), Symbol.(rhat_df[!, 1])), end]
    # Any number of chains (seeds): one distinct colour per chain in the trace plots; no per-seed legend
    # (the seeds are listed in the console output), so the figures stay readable with many seeds.
    nchains = length(dfs)
    chain_colors = nchains == 1 ? [RGBf(0.7, 0.3, 0.6)] : Makie.resample_cmap(:viridis, nchains)
    color_of(k) = chain_colors[k]
    purple_pink = RGBf(0.7, 0.3, 0.6)
    chains_label = isnothing(seeds) ? "Individual chains ($nchains)" : "Individual chains ($nchains seeds)"
    np = length(param_syms)
    axis_style = (aspect = 1,
                  xticksmirrored = true,
                  yticksmirrored = true,
                  xtickalign = 1,
                  ytickalign = 1,
                  titlesize = 36,
                  titlefont = :regular,
                  xlabelsize = 40,
                  ylabelsize = 40,
                  xticklabelsize = 32,
                  yticklabelsize = 32)
    set_theme!(Theme(fonts = (regular = "Times New Roman", bold = "Times New Roman Bold")))
    fig_density = Figure(size = (800 * np, 800))
    for (j, p) in enumerate(param_syms)
        ax = Axis(fig_density[1, j]; xlabel = xlabels[j], ylabel = ylabels[j],
                  title = @sprintf("R-hat = %.3f", rhat_of(p)), axis_style...)
        y_max = 0.0
        for df in dfs                                    # every chain as a thin, semi-transparent line
            kd = kde(df[!, p])
            lines!(ax, kd.x, kd.density, color = (purple_pink, 0.45), linewidth = 2)
            y_max = max(y_max, maximum(kd.density))
        end
        kd_all = kde(vcat([df[!, p] for df in dfs]...)) # all chains pooled
        lines!(ax, kd_all.x, kd_all.density, color = :black, linewidth = 3.5)
        y_max = max(y_max, maximum(kd_all.density))
        ylims!(ax, 0, y_max * 1.25)
        j == 1 && axislegend(ax, [LineElement(color = (purple_pink, 0.45), linewidth = 2),
                                  LineElement(color = :black, linewidth = 3.5)],
                             [chains_label, "All chains pooled"],
                             position = :rt, labelsize = 28, framevisible = true, backgroundcolor = (:white, 0.8))
    end
    try_save(joinpath(outdir, "chain_comparison_density.png"), fig_density; px_per_unit = 3)
    try_save(joinpath(outdir, "chain_comparison_density.pdf"), fig_density)
    fig_trace = Figure(size = (800 * np, 800))
    for (j, p) in enumerate(param_syms)
        ax = Axis(fig_trace[1, j]; xlabel = "Iteration", ylabel = xlabels[j], axis_style...)
        for (k, df) in enumerate(dfs)
            lines!(ax, 1:nrow(df), df[!, p], color = (color_of(k), 0.7), linewidth = 1)
        end
    end
    Label(fig_trace[0, :], nchains == 1 ? "1 chain" : "$nchains chains (one colour per chain)", fontsize = 32)
    try_save(joinpath(outdir, "chain_comparison_trace.png"), fig_trace; px_per_unit = 3)
    try_save(joinpath(outdir, "chain_comparison_trace.pdf"), fig_trace)
    set_theme!()
    isnothing(seeds) || println("  Chains: ", join(["chain $k = seed $(seeds[k])" for k in eachindex(seeds)], ", "))
    println("  - chain_comparison_density.png/.pdf: Posterior densities of all chains")
    println("  - chain_comparison_trace.png/.pdf: Trace plots of all chains")
    println("  - multichain_diagnostics.csv: Multi-chain R-hat and ESS")
    write_run_statistics(dfs, chain_dirs, outdir, param_syms; seeds = seeds)
    create_autocorrelation_plots(chain_dirs, outdir, param_syms, xlabels; seeds = seeds)
end

# Wall time (s), number of forward-model evaluations and seed of one chain, read from its run_summary.txt
# (KADMOS, GDIFF and JOINT formats). Values that are not in the file are returned as `missing`.
function read_chain_timing(dir)
    path = joinpath(dir, "run_summary.txt")
    txt = isfile(path) ? read(path, String) : ""
    num(re) = (m = match(re, txt); isnothing(m) ? missing : parse(Float64, m.captures[1]))
    wall = num(r"Wall time: ([\d.]+) seconds")                           # KADMOS
    ismissing(wall) && (wall = num(r"Total wall time \(s\): ([\d.]+)"))  # JOINT
    if ismissing(wall)                                                    # GDIFF (HH:MM:SS)
        m = match(r"Total wall time: (\d+):(\d+):([\d.]+)", txt)
        isnothing(m) || (wall = 3600 * parse(Float64, m[1]) + 60 * parse(Float64, m[2]) + parse(Float64, m[3]))
    end
    evals = num(r"Total (?:forward model )?evaluations: (\d+)")
    seed = num(r"[Rr]andom seed: (\d+)")
    return (wall = wall, evals = evals, seed = ismissing(seed) ? missing : Int(seed))
end

# Writes run_statistics.txt in outdir: multi-chain (pooled) mean, std, MCSE, ESS and R-hat; ESS and R-hat of
# every chain; average time per forward-model evaluation of every chain; total wall time of all chains.
# The same per-chain numbers are written to run_statistics_per_chain.csv.
function write_run_statistics(dfs, chain_dirs, outdir, param_syms; seeds = nothing)
    stats_of(mats) = DataFrame(summarystats(Chains(cat(mats...; dims = 3), collect(param_syms))))
    row_of(st, p) = st[findfirst(==(Symbol(p)), Symbol.(st[!, 1])), :]
    fmt(x, f = "%.3f") = ismissing(x) ? "n/a" : Printf.format(Printf.Format(f), x)
    hms(s) = ismissing(s) ? "n/a" : @sprintf("%02d:%02d:%05.2f", floor(Int, s / 3600), floor(Int, (s % 3600) / 60), s % 60)
    nchains = length(dfs)
    n_iter = minimum(nrow.(dfs))
    pooled = stats_of([Matrix{Float64}(df[1:n_iter, param_syms]) for df in dfs])
    per_chain = [stats_of([Matrix{Float64}(df[!, param_syms])]) for df in dfs]
    timing = [read_chain_timing(d) for d in chain_dirs]
    seed_of(k) = isnothing(seeds) ? timing[k].seed : seeds[k]
    seed_str(k) = string(something(seed_of(k), "?"))
    walls = [t.wall for t in timing]
    evals = [t.evals for t in timing]
    avg_eval = walls ./ evals                                        # missing if either is missing
    total_wall = any(ismissing, walls) ? missing : sum(walls)
    total_evals = any(ismissing, evals) ? missing : sum(evals)

    # per-chain CSV
    csv = DataFrame(chain = 1:nchains, seed = [seed_of(k) for k in 1:nchains], draws = nrow.(dfs),
                    evaluations = evals, wall_time_s = walls, avg_time_per_evaluation_s = avg_eval)
    for p in param_syms
        csv[!, "ess_bulk_$p"] = [row_of(st, p).ess_bulk for st in per_chain]
        csv[!, "ess_tail_$p"] = [row_of(st, p).ess_tail for st in per_chain]
        csv[!, "rhat_$p"] = [row_of(st, p).rhat for st in per_chain]
    end
    mkpath(outdir)
    CSV.write(joinpath(outdir, "run_statistics_per_chain.csv"), csv)

    open(joinpath(outdir, "run_statistics.txt"), "w") do io
        println(io, "MULTI-CHAIN RUN STATISTICS")
        println(io, "="^78)
        println(io, "Date: $(Dates.now())")
        println(io, "Chains: $nchains (seeds: ", join([seed_str(k) for k in 1:nchains], ", "), ")")
        println(io, "Draws per chain: ", join(nrow.(dfs), ", "), " (pooled: $(sum(nrow.(dfs))))")

        println(io, "\nPOOLED POSTERIOR (all chains; first $n_iter draws of each chain for ESS/R-hat)")
        println(io, @sprintf("  %-10s %12s %12s %10s %10s %10s %8s", "parameter", "mean", "std", "mcse", "ess_bulk", "ess_tail", "rhat"))
        for p in param_syms
            r = row_of(pooled, p)
            println(io, @sprintf("  %-10s %12.3f %12.3f %10.4f %10.1f %10.1f %8.4f", p, r.mean, r.std, r.mcse, r.ess_bulk, r.ess_tail, r.rhat))
        end

        println(io, "\nPER-CHAIN ESS AND R-HAT")
        println(io, @sprintf("  %-6s %-6s %-10s %10s %10s %8s", "chain", "seed", "parameter", "ess_bulk", "ess_tail", "rhat"))
        for k in 1:nchains, p in param_syms
            r = row_of(per_chain[k], p)
            println(io, @sprintf("  %-6d %-6s %-10s %10.1f %10.1f %8.4f", k, seed_str(k), p, r.ess_bulk, r.ess_tail, r.rhat))
        end

        println(io, "\nPER-CHAIN TIMING")
        println(io, @sprintf("  %-6s %-6s %8s %12s %14s %14s %14s", "chain", "seed", "draws", "evaluations", "wall time (s)", "HH:MM:SS", "avg s / eval"))
        for k in 1:nchains
            println(io, @sprintf("  %-6d %-6s %8d %12s %14s %14s %14s", k, seed_str(k), nrow(dfs[k]),
                                 fmt(evals[k], "%.0f"), fmt(walls[k], "%.2f"), hms(walls[k]), fmt(avg_eval[k], "%.4f")))
        end

        println(io, "\nTOTALS")
        println(io, "  Total wall time of all chains: ", fmt(total_wall, "%.2f"), " s = ", hms(total_wall),
                " (", fmt(ismissing(total_wall) ? missing : total_wall / 3600, "%.2f"), " h)")
        println(io, "  Total forward-model evaluations: ", fmt(total_evals, "%.0f"))
        println(io, "  Average time per evaluation (total wall time / total evaluations): ",
                fmt(ismissing(total_wall) || ismissing(total_evals) ? missing : total_wall / total_evals, "%.4f"), " s")
        known = collect(skipmissing(avg_eval))
        println(io, "  Mean of the per-chain average evaluation times: ", isempty(known) ? "n/a" : @sprintf("%.4f s", mean(known)))
        if !ismissing(total_wall)
            for p in param_syms
                println(io, @sprintf("  Pooled bulk ESS per hour of wall time (%s): %.1f", p, row_of(pooled, p).ess_bulk / (total_wall / 3600)))
            end
        end
        println(io, "\nNotes:")
        println(io, "  - Chains run one after another, so the total wall time is the sum of the chain wall times.")
        println(io, "  - Average time per evaluation = chain wall time / forward-model evaluations, so it includes")
        println(io, "    the sampler's own overhead. Wall times and evaluation counts come from each run_summary.txt.")
        any(ismissing, evals) && println(io, "  - n/a: the evaluation count was not saved in that chain's run_summary.txt.")
    end
    println("  - run_statistics.txt / run_statistics_per_chain.csv: ESS, R-hat, evaluation times and total wall time")
end

# Sample autocorrelation of x for lags 0..max_lag (normalised so that the value at lag 0 is 1)
function sample_acf(x::AbstractVector, max_lag::Int)
    n = length(x)
    y = x .- mean(x)
    c0 = sum(abs2, y) / n
    return [sum(y[1:n-k] .* y[1+k:n]) / n / c0 for k in 0:min(max_lag, n - 1)]
end

# Autocorrelation of every chain (seed) for every parameter, plus the mean over the chains.
# Saves chain_autocorrelation.png/.pdf and autocorrelation_per_chain.csv in outdir.
function create_autocorrelation_plots(chain_dirs, outdir, param_syms, xlabels; seeds = nothing, max_lag = 50)
    dfs = [CSV.read(joinpath(d, "posterior_samples.csv"), DataFrame) for d in chain_dirs]
    nchains = length(dfs)
    n_iter = minimum(nrow.(dfs))
    max_lag = min(max_lag, n_iter - 1)
    lags = 0:max_lag
    purple_pink = RGBf(0.7, 0.3, 0.6)
    chains_label = isnothing(seeds) ? "Individual chains ($nchains)" : "Individual chains ($nchains seeds)"
    seed_of(k) = isnothing(seeds) ? missing : seeds[k]
    # ESS (bulk) of every single chain, from MCMCChains
    ess_of(df, p) = DataFrame(summarystats(Chains(reshape(Float64.(df[1:n_iter, p]), :, 1, 1), [p])))[1, :ess_bulk]
    rows = DataFrame(chain = Int[], seed = Union{Int,Missing}[], parameter = String[], n_samples = Int[],
                     acf_lag1 = Float64[], first_lag_below_0p1 = Union{Int,Missing}[], ess_bulk = Float64[])
    set_theme!(Theme(fonts = (regular = "Times New Roman", bold = "Times New Roman Bold")))
    np = length(param_syms)
    fig = Figure(size = (800 * np, 800))
    for (j, p) in enumerate(param_syms)
        acfs = [sample_acf(Float64.(df[1:n_iter, p]), max_lag) for df in dfs]
        esses = [ess_of(df, p) for df in dfs]
        ax = Axis(fig[1, j]; xlabel = "Lag (iterations)", ylabel = "Autocorrelation",
                  title = @sprintf("%s\nESS per chain: %.0f–%.0f (of %d)", xlabels[j], minimum(esses), maximum(esses), n_iter),
                  aspect = 1, xticksmirrored = true, yticksmirrored = true, xtickalign = 1, ytickalign = 1,
                  titlesize = 32, titlefont = :regular, xlabelsize = 40, ylabelsize = 40,
                  xticklabelsize = 32, yticklabelsize = 32)
        bound = 1.96 / sqrt(n_iter)                       # approximate 95% band of an uncorrelated chain
        band!(ax, [0, max_lag], [-bound, -bound], [bound, bound], color = (:gray, 0.25))
        hlines!(ax, [0.0], color = :gray40, linewidth = 1)
        for a in acfs
            lines!(ax, lags, a, color = (purple_pink, 0.45), linewidth = 2)
        end
        lines!(ax, lags, mean(acfs), color = :black, linewidth = 3.5)
        xlims!(ax, 0, max_lag)
        ylims!(ax, min(-0.2, minimum(minimum.(acfs)) - 0.05), 1.05)
        j == 1 && axislegend(ax, [LineElement(color = (purple_pink, 0.45), linewidth = 2),
                                  LineElement(color = :black, linewidth = 3.5),
                                  PolyElement(color = (:gray, 0.25))],
                             [chains_label, "Mean over chains", "95% band, no correlation"],
                             position = :rt, labelsize = 28, framevisible = true, backgroundcolor = (:white, 0.8))
        for k in 1:nchains
            below = findfirst(<(0.1), acfs[k])
            push!(rows, (k, seed_of(k), String(p), n_iter, acfs[k][2],
                         isnothing(below) ? missing : below - 1, esses[k]))
        end
    end
    save(joinpath(outdir, "chain_autocorrelation.png"), fig; px_per_unit = 3)
    save(joinpath(outdir, "chain_autocorrelation.pdf"), fig)
    set_theme!()
    CSV.write(joinpath(outdir, "autocorrelation_per_chain.csv"), rows)
    println("  - chain_autocorrelation.png/.pdf: Autocorrelation of all chains")
    println("  - autocorrelation_per_chain.csv: lag-1 autocorrelation, first lag below 0.1 and ESS of every chain")
    return rows
end
