/* KADMOS HMC App — interface logic */
(function () {
"use strict";

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const fmtN = (v, d = 2) => (v === null || v === undefined || !isFinite(v)) ? "–" : Number(v).toFixed(d);
const fmtSmart = v => {
  if (v === null || v === undefined || !isFinite(v)) return "–";
  const a = Math.abs(v);
  return a >= 1000 ? v.toFixed(0) : a >= 100 ? v.toFixed(1) : a >= 10 ? v.toFixed(2) : v.toFixed(3);
};
function fmtDur(s) {
  if (s === null || s === undefined || !isFinite(s)) return "–";
  s = Math.max(0, s);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = Math.floor(s % 60);
  return h ? `${h}h ${String(m).padStart(2, "0")}m` : m ? `${m}m ${String(sec).padStart(2, "0")}s` : `${sec}s`;
}
function toast(msg, kind = "") {
  const t = document.createElement("div");
  t.className = "toast " + kind; t.textContent = msg;
  $("#toasts").appendChild(t);
  setTimeout(() => t.remove(), kind === "error" ? 7000 : 3500);
}
async function api(path, opts = {}) {
  const o = Object.assign({ headers: {} }, opts);
  if (o.body && typeof o.body !== "string") { o.body = JSON.stringify(o.body); o.headers["Content-Type"] = "application/json"; }
  const r = await fetch(path, o);
  let data = null;
  try { data = await r.json(); } catch (e) { data = { error: `Server answered ${r.status}` }; }
  if (!r.ok && !data.errors && !data.error) data.error = `Server answered ${r.status}`;
  return data;
}

const PARAMS = [
  { key: "T0", label: "Initial temperature", unit: "°C", sym: "T₀", color: "var(--c-T0)" },
  { key: "SCR", label: "Initial cooling rate", unit: "°C/Myr", sym: "CR", color: "var(--c-SCR)" },
  { key: "Lr", label: "Effective grain size", unit: "μm", sym: "Lr", color: "var(--c-Lr)" },
  { key: "tlim", label: "Total model time", unit: "Myr", sym: "tlim", color: "var(--c-tlim)" },
];
const PRIOR_KEYS = ["T0", "SCR", "Lr", "tlim"];
const PMAP = Object.fromEntries(PARAMS.map(p => [p.key, p]));

// ------------------------------------------------------------------ defaults (= RUN_KADMOS_HMC.jl)
const DEFAULTS = {
  observed_age: 164.16, age_uncertainty: 0.37,
  T0_prior: "Gaussian", T0_mean: 630, T0_std: 20, T0_min: 500, T0_max: 700,
  SCR_prior: "Uniform", SCR_mean: 200, SCR_std: 100, SCR_min: 50, SCR_max: 500,
  Lr_prior: "Uniform", Lr_mean: 35, Lr_std: 15, Lr_min: 1, Lr_max: 70,
  tlim_prior: "Gaussian", tlim_mean: 165.5, tlim_std: 0.365, tlim_min: 164.405, tlim_max: 166.595,
  sampler_type: "NUTS", n_samples: 600, hmc_step_size: 0.05, hmc_leapfrog_steps: 80,
  random_seeds: [44, 46, 48, 49], parallel: true,
  type_path: "asy-CR", geometry: 3, mineral: "Muscovite1", Age0: 0, P0: 1100, Pmin: 10, Tmin: 25,
  ptt_data: "",
  custom_D0: 2.3, custom_Ea: 263000, custom_Va: 14, custom_Pref: 1000,
  chol_sol: 0, theta: 1.0, nt: 600, RdX: 10, nels: 100,
  run_name: "",
};
const STORE_KEY = "kadmos-hmc-settings-v2";
// Settings from older versions have no Lr / tlim prior type: Lr was Uniform, tlim Gaussian truncated at ±3σ.
function migrateSettings(o) {
  o = Object.assign({}, o);
  if (o.tlim_min === undefined && isFinite(o.tlim_mean) && isFinite(o.tlim_std)) {
    o.tlim_prior = o.tlim_prior || "Gaussian";
    o.tlim_min = +(o.tlim_mean - 3 * o.tlim_std).toFixed(6);
    o.tlim_max = +(o.tlim_mean + 3 * o.tlim_std).toFixed(6);
  }
  if (o.Lr_mean === undefined && isFinite(o.Lr_min) && isFinite(o.Lr_max)) {
    o.Lr_prior = o.Lr_prior || "Uniform";
    o.Lr_mean = +((o.Lr_min + o.Lr_max) / 2).toFixed(6);
    o.Lr_std = +((o.Lr_max - o.Lr_min) / 2).toFixed(6);
  }
  return o;
}
let cfg = Object.assign({}, DEFAULTS);
try { const s = JSON.parse(localStorage.getItem(STORE_KEY) || "null"); if (s) cfg = Object.assign({}, DEFAULTS, migrateSettings(s)); } catch (e) {}
let INFO = null;

// ------------------------------------------------------------------ navigation
function go(view) {
  $$(".tab").forEach(t => t.classList.toggle("active", t.dataset.view === view));
  $$(".view").forEach(v => v.classList.toggle("active", v.id === "view-" + view));
  if (view === "results") loadRuns();
  window.scrollTo({ top: 0 });
  try { history.replaceState(null, "", "#" + view); } catch (e) {}
}
$$(".tab").forEach(t => t.addEventListener("click", () => go(t.dataset.view)));
$$("[data-goto]").forEach(b => b.addEventListener("click", () => go(b.dataset.goto)));
window.addEventListener("hashchange", () => {
  const h = location.hash.slice(1);
  if (["setup", "monitor", "results", "guide"].includes(h) && !$("#view-" + h).classList.contains("active")) go(h);
});

$("#theme-btn").addEventListener("click", () => {
  const d = document.documentElement;
  d.dataset.theme = d.dataset.theme === "dark" ? "light" : "dark";
  try { localStorage.setItem("kadmos-theme", d.dataset.theme); } catch (e) {}
  refreshAll(); if (currentRun) renderRun(currentRun);
});

// ------------------------------------------------------------------ form binding
function numOrRaw(v) { if (v === "" || v === null) return ""; const n = Number(v); return isFinite(n) ? n : v; }

function writeForm() {
  $$("[data-k]").forEach(inp => {
    const k = inp.dataset.k, v = cfg[k];
    if (inp.type === "checkbox") inp.checked = !!v;
    else inp.value = v ?? "";
  });
  $$("[data-seg]").forEach(seg => {
    $$("button", seg).forEach(b => b.classList.toggle("on", String(cfg[seg.dataset.seg]) === b.dataset.v));
  });
  $$("[data-choice]").forEach(ch => {
    $$(".choice", ch).forEach(b => b.classList.toggle("on", String(cfg[ch.dataset.choice]) === b.dataset.v));
  });
  renderSeeds();
}
function save() { try { localStorage.setItem(STORE_KEY, JSON.stringify(cfg)); } catch (e) {} }

$$("[data-k]").forEach(inp => {
  const k = inp.dataset.k;
  const ev = inp.tagName === "SELECT" || inp.type === "checkbox" ? "change" : "input";
  inp.addEventListener(ev, () => {
    if (inp.type === "checkbox") cfg[k] = inp.checked;
    else if (inp.type === "number") cfg[k] = numOrRaw(inp.value);
    else if (k === "chol_sol") cfg[k] = Number(inp.value);
    else cfg[k] = inp.value;
    save(); refreshAll(k);
  });
});
$$("[data-seg]").forEach(seg => $$("button", seg).forEach(b => b.addEventListener("click", () => {
  const k = seg.dataset.seg;
  cfg[k] = k === "geometry" ? Number(b.dataset.v) : b.dataset.v;
  $$("button", seg).forEach(x => x.classList.toggle("on", x === b));
  save(); refreshAll(k);
})));
$$("[data-choice]").forEach(ch => $$(".choice", ch).forEach(b => b.addEventListener("click", () => {
  cfg[ch.dataset.choice] = b.dataset.v;
  $$(".choice", ch).forEach(x => x.classList.toggle("on", x === b));
  save(); refreshAll(ch.dataset.choice);
})));

// seeds
function renderSeeds() {
  const box = $("#seed-chips"), input = $("#seed-input");
  $$(".chip", box).forEach(c => c.remove());
  (cfg.random_seeds || []).forEach((s, i) => {
    const c = document.createElement("span");
    c.className = "chip";
    c.innerHTML = `${esc(s)}<button title="Remove" aria-label="Remove seed">✕</button>`;
    c.querySelector("button").addEventListener("click", () => { cfg.random_seeds.splice(i, 1); save(); renderSeeds(); refreshAll("seeds"); });
    box.insertBefore(c, input);
  });
}
function addSeed(txt) {
  const parts = String(txt).split(/[\s,;]+/).filter(Boolean);
  let bad = false;
  for (const p of parts) {
    const n = Number(p);
    if (!Number.isInteger(n) || n < 0) { bad = true; continue; }
    if (!cfg.random_seeds.includes(n)) cfg.random_seeds.push(n);
  }
  if (bad) toast("Seeds must be whole numbers ≥ 0", "error");
  save(); renderSeeds(); refreshAll("seeds");
}
$("#seed-input").addEventListener("keydown", e => {
  if (e.key === "Enter" || e.key === "," || e.key === " ") { e.preventDefault(); if (e.target.value.trim()) addSeed(e.target.value); e.target.value = ""; }
  else if (e.key === "Backspace" && !e.target.value && cfg.random_seeds.length) { cfg.random_seeds.pop(); save(); renderSeeds(); refreshAll("seeds"); }
});
$("#seed-input").addEventListener("blur", e => { if (e.target.value.trim()) { addSeed(e.target.value); e.target.value = ""; } });
$("#seed-input").addEventListener("paste", e => { e.preventDefault(); addSeed(e.clipboardData.getData("text")); });
$("#seed-random").addEventListener("click", () => {
  let s; do { s = Math.floor(Math.random() * 99999) + 1; } while (cfg.random_seeds.includes(s));
  cfg.random_seeds.push(s); save(); renderSeeds(); refreshAll("seeds");
});
$("#seed-clear").addEventListener("click", () => { cfg.random_seeds = []; save(); renderSeeds(); refreshAll("seeds"); });

// settings files
$("#btn-save").addEventListener("click", () => {
  const blob = new Blob([JSON.stringify(cfg, null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob); a.download = (cfg.run_name || "kadmos_settings") + ".json"; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
});
$("#btn-load").addEventListener("click", () => $("#file-load").click());
$("#file-load").addEventListener("change", async e => {
  const f = e.target.files[0]; if (!f) return;
  try { applySettings(JSON.parse(await f.text()), f.name); } catch (err) { toast("Could not read settings file: " + err.message, "error"); }
  e.target.value = "";
});
function applySettings(obj, from) {
  obj = migrateSettings(obj);
  const keep = {};
  for (const k of Object.keys(DEFAULTS)) if (obj[k] !== undefined) keep[k] = obj[k];
  cfg = Object.assign({}, DEFAULTS, keep);
  cfg.run_name = INFO ? INFO.next_run_name : "";
  save(); writeForm(); refreshAll(); fillForwardFromPriors();
  toast("Settings loaded" + (from ? " from " + from : ""));
}
$("#btn-reset").addEventListener("click", () => {
  if (!confirm("Reset all settings to the default values?")) return;
  cfg = Object.assign({}, DEFAULTS, { run_name: INFO ? INFO.next_run_name : "" });
  save(); writeForm(); refreshAll(); fillForwardFromPriors();
});

// loaded P–T–t file
$("#ptt-file-btn").addEventListener("click", () => $("#ptt-file").click());
$("#ptt-file").addEventListener("change", async e => {
  const f = e.target.files[0]; if (!f) return;
  cfg.ptt_data = await f.text(); $("[data-k=ptt_data]").value = cfg.ptt_data;
  save(); refreshAll("ptt_data"); e.target.value = "";
});

// ------------------------------------------------------------------ maths for previews
function erf(x) { // Abramowitz–Stegun 7.1.26
  const s = Math.sign(x); x = Math.abs(x);
  const t = 1 / (1 + 0.3275911 * x);
  const y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-x * x);
  return s * y;
}
const Phi = z => 0.5 * (1 + erf(z / Math.SQRT2));
function priorSpec(key, c = cfg) {
  c = migrateSettings(c);   // configs of older runs
  const g = c[key + "_prior"] === "Gaussian";
  return g ? { kind: "N", mu: +c[key + "_mean"], sd: +c[key + "_std"], lo: +c[key + "_min"], hi: +c[key + "_max"] }
           : { kind: "U", lo: +c[key + "_min"], hi: +c[key + "_max"] };
}
function priorPdf(sp, x) {
  if (!(x >= sp.lo && x <= sp.hi)) return 0;
  if (sp.kind === "U") return 1 / (sp.hi - sp.lo);
  const Z = Phi((sp.hi - sp.mu) / sp.sd) - Phi((sp.lo - sp.mu) / sp.sd);
  return Math.exp(-0.5 * ((x - sp.mu) / sp.sd) ** 2) / (sp.sd * Math.sqrt(2 * Math.PI)) / (Z || 1);
}
function priorOk(sp) { return [sp.lo, sp.hi].every(isFinite) && sp.lo < sp.hi && (sp.kind === "U" || (isFinite(sp.mu) && sp.sd > 0)); }
function priorCentre(key) {
  const sp = priorSpec(key);
  if (sp.kind === "N") return Math.min(sp.hi, Math.max(sp.lo, sp.mu));
  return (sp.lo + sp.hi) / 2;
}
function pathT(type, T0, SCR, t, Tmin, tlim) {
  let T;
  if (type === "lin-CR") T = T0 - SCR * t;
  else if (type === "asy-CR") T = T0 / (1 + SCR * t / T0);
  else if (type === "lin-P-T") T = T0 + (Tmin - T0) * (t / tlim);
  else T = T0;
  return Math.max(T, Tmin);
}
function parsePTT(txt) {
  const rows = [];
  for (const ln of String(txt || "").split(/\r?\n/)) {
    const s = ln.trim(); if (!s || s.startsWith("#")) continue;
    const v = s.split(/[\s,;]+/).map(Number);
    if (v.some(x => !isFinite(x))) { if (!rows.length) continue; return { error: `could not read line "${s}"` }; }
    if (v.length !== 3) return { error: `every line needs 3 values (P, T, t): "${s}"` };
    rows.push(v);
  }
  if (rows.length < 2) return { error: "at least 2 rows are required" };
  if (rows.length === 3) return { error: "use more than 3 rows (a 3×3 table is ambiguous for KADMOS)" };
  for (let i = 1; i < rows.length; i++) if (!(rows[i][2] > rows[i - 1][2])) return { error: "times (3rd column) must increase" };
  return { P: rows.map(r => r[0]), T: rows.map(r => r[1]), t: rows.map(r => r[2]) };
}

// ------------------------------------------------------------------ validation (mirrors the server)
function validate() {
  const e = [], bad = new Set();
  const need = (cond, msg, ...keys) => { if (!cond) { e.push(msg); keys.forEach(k => bad.add(k)); } };
  const num = k => typeof cfg[k] === "number" && isFinite(cfg[k]);
  const numKeys = ["observed_age", "age_uncertainty", "T0_min", "T0_max", "SCR_min", "SCR_max", "Lr_min", "Lr_max", "tlim_min", "tlim_max",
    "n_samples", "Age0", "P0", "Pmin", "Tmin", "theta", "nt", "RdX", "nels"];
  for (const k of PRIOR_KEYS) if (cfg[k + "_prior"] === "Gaussian") numKeys.push(k + "_mean", k + "_std");
  if (cfg.sampler_type === "HMC") numKeys.push("hmc_step_size", "hmc_leapfrog_steps");
  if (cfg.mineral === "custom") numKeys.push("custom_D0", "custom_Ea", "custom_Va", "custom_Pref");
  const missing = numKeys.filter(k => !num(k));
  missing.forEach(k => bad.add(k));
  if (missing.length) e.push("Some fields are empty or not numbers.");
  need(!num("age_uncertainty") || cfg.age_uncertainty > 0, "Age uncertainty must be positive.", "age_uncertainty");
  need(!num("observed_age") || cfg.observed_age > 0, "Observed age must be positive.", "observed_age");
  for (const [k, nm] of [["T0", "Initial temperature"], ["SCR", "Cooling rate"], ["Lr", "Grain size"], ["tlim", "Total model time"]]) {
    need(!(num(k + "_min") && num(k + "_max")) || cfg[k + "_min"] < cfg[k + "_max"], `${nm}: minimum must be smaller than maximum.`, k + "_min", k + "_max");
    if (cfg[k + "_prior"] === "Gaussian") need(!num(k + "_std") || cfg[k + "_std"] > 0, `${nm}: standard deviation must be positive.`, k + "_std");
  }
  need(!num("SCR_min") || cfg.SCR_min > 0 || cfg.type_path !== "asy-CR", "Cooling rate minimum must be positive.", "SCR_min");
  need(!num("Lr_min") || cfg.Lr_min > 0, "Grain size: minimum must be positive.", "Lr_min");
  need(!num("tlim_min") || cfg.tlim_min > 0, "Total model time: minimum must be positive.", "tlim_min");
  need(!num("n_samples") || (Number.isInteger(cfg.n_samples) && cfg.n_samples >= 10 && cfg.n_samples <= 200000), "Samples per chain: a whole number between 10 and 200000.", "n_samples");
  if (cfg.sampler_type === "HMC") {
    need(!num("hmc_step_size") || cfg.hmc_step_size > 0, "HMC step size must be positive.", "hmc_step_size");
    need(!num("hmc_leapfrog_steps") || cfg.hmc_leapfrog_steps >= 1, "HMC leapfrog steps must be ≥ 1.", "hmc_leapfrog_steps");
  }
  need(cfg.random_seeds.length >= 1, "Add at least one random seed (one chain per seed).");
  need(cfg.random_seeds.length <= 64, "At most 64 seeds.");
  need(!num("Age0") || cfg.Age0 >= 0, "Initial age must be ≥ 0.", "Age0");
  need(!(num("P0") && num("Pmin")) || cfg.P0 >= cfg.Pmin, "Initial pressure must be ≥ final pressure.", "P0", "Pmin");
  need(!num("nels") || (cfg.nels >= 5 && cfg.nels <= 5000 && Number.isInteger(cfg.nels)), "Elements: a whole number between 5 and 5000.", "nels");
  need(!num("nt") || (cfg.nt >= 10 && cfg.nt <= 100000 && Number.isInteger(cfg.nt)), "Time steps: a whole number between 10 and 100000.", "nt");
  need(!num("theta") || (cfg.theta >= 0.5 && cfg.theta <= 1), "θ must be between 0.5 and 1.", "theta");
  need(!num("RdX") || cfg.RdX > 0, "RdX must be positive.", "RdX");
  need(Number(cfg.chol_sol) !== 1, "Cholesky solver: not usable for the inversion (no gradient support). Choose Direct; Cholesky works only for the forward model check.", "chol_sol");
  if (cfg.mineral === "custom") need(!num("custom_D0") || cfg.custom_D0 > 0, "Custom mineral: D₀ must be positive.", "custom_D0");
  if (cfg.type_path === "loaded") {
    const p = parsePTT(cfg.ptt_data);
    need(!p.error, "Loaded P–T–t path: " + (p.error || ""), "ptt_data");
  }
  const rn = String(cfg.run_name || "").trim();
  need(!rn || (/^[A-Za-z0-9_\-. ]+$/.test(rn) && !rn.startsWith(".") && !rn.includes("..")), "Run name: only letters, digits, spaces, '-', '_' and '.'.", "run_name");
  return { errors: e, bad };
}

// ------------------------------------------------------------------ refresh UI
function refreshAll(changed) {
  // toggles
  for (const k of PRIOR_KEYS) {
    const g = cfg[k + "_prior"] === "Gaussian";
    $$(`.param[data-p=${k}] .gauss`).forEach(f => { f.querySelector(".input").classList.toggle("disabled", !g); f.querySelector("input").disabled = !g; });
  }
  const hmc = cfg.sampler_type === "HMC";
  $$(".hmc-only").forEach(f => { f.querySelector(".input").classList.toggle("disabled", !hmc); f.querySelector("input").disabled = !hmc; });
  $("#ptt-box").hidden = cfg.type_path !== "loaded";
  $("#custom-box").hidden = cfg.mineral !== "custom";
  const usesCR = ["asy-CR", "lin-CR"].includes(cfg.type_path);
  $(`.param[data-p=SCR]`).style.opacity = usesCR ? 1 : 0.6;
  $("#solver-help").innerHTML = Number(cfg.chol_sol) === 1
    ? `<span style="color:var(--warn)">Forward check only: the sparse Cholesky factorisation cannot propagate HMC gradients.</span>`
    : "Fast derivative-aware sparse solve";
  // diffusion table
  const dt = $("#diff-table");
  if (INFO && cfg.mineral !== "custom") {
    const d = INFO.diffusion.find(r => r.name === cfg.mineral);
    dt.innerHTML = d ? `<tr><td>D₀</td><td class="num">${d.D0.toExponential(3)} cm²/s</td></tr>
      <tr><td>Activation energy Ea</td><td class="num">${(d.Ea / 1000).toFixed(1)} kJ/mol</td></tr>
      <tr><td>Activation volume Va</td><td class="num">${d.Va} J/MPa/mol</td></tr>
      <tr><td>Reference pressure</td><td class="num">${d.Pref} MPa</td></tr>` : "";
    dt.hidden = !d;
  } else dt.hidden = true;
  // tlim note
  const tg = cfg.tlim_prior === "Gaussian", s3 = cfg.tlim_mean - 3 * cfg.tlim_std, e3 = cfg.tlim_mean + 3 * cfg.tlim_std;
  $("#tlim-note").textContent = tg && isFinite(s3) && cfg.tlim_std > 0
    ? `Mean ± 3σ = ${s3.toFixed(3)} – ${e3.toFixed(3)} Myr  ·  2σ = ${(2 * cfg.tlim_std).toFixed(3)} Myr` : "";
  $("#btn-tlim-3s").hidden = !tg;
  // ptt status
  if (cfg.type_path === "loaded") {
    const p = parsePTT(cfg.ptt_data);
    $("#ptt-status").innerHTML = !cfg.ptt_data ? "Paste a table or open a file (e.g. PTt_params.dat)." :
      p.error ? `<span style="color:var(--danger)">${esc(p.error)}</span>` : `<span style="color:var(--ok)">✓ ${p.t.length} points, t = ${p.t[0]} → ${p.t[p.t.length - 1]} Myr</span>`;
  }
  // parallel help
  if (INFO) {
    const n = cfg.random_seeds.length;
    $("#parallel-help").textContent = INFO.threads > 1 ? `(${Math.min(n, INFO.threads)} of ${INFO.threads} threads)` : "(only 1 thread available)";
  }
  // validation display
  const v = validate();
  $$("[data-k]").forEach(inp => { const box = inp.closest(".input"); if (box) box.classList.toggle("invalid", v.bad.has(inp.dataset.k)); });
  $("[data-k=ptt_data]").style.borderColor = v.bad.has("ptt_data") ? "var(--danger)" : "";
  const ul = $("#errors");
  ul.innerHTML = [...new Set(v.errors)].map(x => `<li>${esc(x)}</li>`).join("");
  ul.hidden = !v.errors.length;
  // summary chips
  const nC = cfg.random_seeds.length, nS = cfg.n_samples;
  const geo = { 1: "plane", 2: "cylinder", 3: "sphere" }[cfg.geometry];
  $("#run-summary").innerHTML = [
    `<span><b>${nC}</b> chain${nC === 1 ? "" : "s"} × <b>${isFinite(nS) ? nS : "?"}</b> samples</span>`,
    `<span><b>${esc(cfg.sampler_type)}</b></span>`,
    `<span>${esc(cfg.mineral)} · ${geo}</span>`,
    `<span>path <b>${esc(cfg.type_path)}</b></span>`,
    `<span>age <b>${esc(cfg.observed_age)} ± ${esc(cfg.age_uncertainty)}</b> Myr</span>`,
  ].join("");
  const par = cfg.parallel && nC > 1 && INFO && INFO.threads > 1;
  $("#run-hint").textContent = nC ? `Chains run ${par ? "in parallel" : "one after another"}. A typical NUTS draw needs ~10–30 model evaluations.` : "";
  $("#btn-run").disabled = !!v.errors.length || jobRunning;
  // plots
  drawPriors();
  drawPath();
}

function drawPriors() {
  for (const p of PARAMS) {
    const host = $(`.prior-plot[data-prior=${p.key}]`);
    const sp = priorSpec(p.key);
    if (!priorOk(sp)) { host.innerHTML = `<div style="height:62px;display:grid;place-items:center;font-size:11.5px;color:var(--ink-3)">invalid prior</div>`; host.__opts = null; continue; }
    const span = sp.hi - sp.lo, a = sp.lo - span * 0.08, b = sp.hi + span * 0.08;
    const xs = [], ys = [];
    for (let i = 0; i <= 160; i++) { const x = a + (b - a) * i / 160; xs.push(x); ys.push(priorPdf(sp, x)); }
    // make the uniform edges vertical
    if (sp.kind === "U") { xs.splice(0, xs.length, a, sp.lo, sp.lo, sp.hi, sp.hi, b); ys.splice(0, ys.length, 0, 0, 1 / span, 1 / span, 0, 0); }
    Charts.plot(host, { height: 62, margin: { t: 4, r: 4, b: 18, l: 4 }, y: { zero: true, ticks: false, grid: false, top: 0.12 }, x: { min: a, max: b },
      layers: [{ type: "area", x: xs, y: ys, color: p.color, opacity: 0.16 }, { type: "line", x: xs, y: ys, color: p.color, width: 1.8 }],
      tooltip: x => { const d = priorPdf(sp, x); return `${fmtSmart(x)} ${p.unit}` + (d > 0 ? "" : " · outside prior"); } });
  }
}

function drawPath() {
  const host = $("#path-preview");
  const Tmin = +cfg.Tmin, type = cfg.type_path;
  const legend = $("#path-legend");
  if (type === "loaded") {
    const p = parsePTT(cfg.ptt_data);
    if (p.error) { host.innerHTML = `<div class="empty" style="padding:30px 10px">Load a P–T–t table to preview it.</div>`; legend.innerHTML = ""; host.__opts = null; return; }
    Charts.plot(host, { height: 210, x: { label: "Time (Myr)" }, y: { label: "Temperature (°C)" },
      layers: [{ type: "line", x: p.t, y: p.T.map(T => Math.max(T, Tmin)), color: "var(--c-T0)", width: 2.2 },
               { type: "points", x: p.t, y: p.T.map(T => Math.max(T, Tmin)), color: "var(--c-T0)", r: 2.6, opacity: 0.9 }],
      tooltip: t => { const T = Charts.interp(p.t, p.T, t); return T === null ? null : `t = ${t.toFixed(2)} Myr · T = ${Math.max(T, Tmin).toFixed(0)} °C`; } });
    legend.innerHTML = `<span><i style="border-color:var(--c-T0)"></i>Loaded path (T ≥ T<sub>min</sub>)</span>`;
    return;
  }
  const T0c = priorCentre("T0"), CRc = priorCentre("SCR"), tl = priorCentre("tlim");
  if (![T0c, CRc, tl, Tmin].every(isFinite) || tl <= 0) { host.innerHTML = ""; host.__opts = null; return; }
  const n = 200, ts = [], Tc = [], Tlo = [], Thi = [];
  const T0s = [+cfg.T0_min, +cfg.T0_max], CRs = [+cfg.SCR_min, +cfg.SCR_max];
  for (let i = 0; i <= n; i++) {
    const t = tl * i / n; ts.push(t);
    Tc.push(pathT(type, T0c, CRc, t, Tmin, tl));
    let lo = Infinity, hi = -Infinity;
    for (const a of T0s) for (const c of CRs) { const T = pathT(type, a, c, t, Tmin, tl); lo = Math.min(lo, T); hi = Math.max(hi, T); }
    Tlo.push(lo); Thi.push(hi);
  }
  Charts.plot(host, { height: 210, x: { label: "Time since start (Myr)", min: 0, max: tl }, y: { label: "Temperature (°C)", zero: true },
    layers: [
      { type: "area", x: ts, y: Thi, y0: Tlo, color: "var(--c-T0)", opacity: 0.14 },
      { type: "hline", y: Tmin, color: "var(--ink-3)", dash: "4 4" },
      { type: "line", x: ts, y: Tc, color: "var(--c-T0)", width: 2.4 },
    ],
    tooltip: t => { const T = Charts.interp(ts, Tc, t), a = Charts.interp(ts, Tlo, t), b = Charts.interp(ts, Thi, t);
      return T === null ? null : `t = ${t.toFixed(1)} Myr<br>T = ${T.toFixed(0)} °C <span style="opacity:.7">(${a.toFixed(0)}–${b.toFixed(0)})</span>`; } });
  legend.innerHTML = `<span><i style="border-color:var(--c-T0)"></i>Prior centre (T₀ ${fmtSmart(T0c)} °C, CR ${fmtSmart(CRc)} °C/Myr)</span>
    <span><i class="box" style="background:color-mix(in srgb, var(--c-T0) 22%, transparent)"></i>Range of T₀ and CR priors</span>
    <span><i class="dash" style="border-color:var(--ink-3)"></i>T<sub>min</sub></span>`;
}

// ------------------------------------------------------------------ forward model check
function fillForwardFromPriors() {
  $("#fw_T0").value = +priorCentre("T0").toFixed(2);
  $("#fw_SCR").value = +priorCentre("SCR").toFixed(2);
  $("#fw_Lr").value = +priorCentre("Lr").toFixed(2);
  $("#fw_tlim").value = +priorCentre("tlim").toFixed(3);
}
$("#btn-fw-center").addEventListener("click", fillForwardFromPriors);
$("#btn-tlim-3s").addEventListener("click", () => {
  const m = +cfg.tlim_mean, sd = +cfg.tlim_std;
  if (!(isFinite(m) && sd > 0)) { toast("Enter the mean and a positive σ first", "error"); return; }
  cfg.tlim_min = +(m - 3 * sd).toFixed(6); cfg.tlim_max = +(m + 3 * sd).toFixed(6);
  save(); writeForm(); refreshAll("tlim_min");
});
$("#btn-forward").addEventListener("click", async () => {
  const btn = $("#btn-forward"), out = $("#fw-out");
  const body = Object.assign({}, cfg, { fw_T0: +$("#fw_T0").value, fw_SCR: +$("#fw_SCR").value, fw_Lr: +$("#fw_Lr").value, fw_tlim: +$("#fw_tlim").value });
  if (![body.fw_T0, body.fw_SCR, body.fw_Lr, body.fw_tlim].every(isFinite)) { toast("Enter all four values", "error"); return; }
  btn.disabled = true; btn.innerHTML = `<span class="spin"></span> Computing…`;
  try {
    const r = await api("/api/forward", { method: "POST", body });
    if (r.error) { out.innerHTML = `<div class="warnbox">${esc(r.error)}</div>`; return; }
    const dz = (r.max_age - r.observed_age) / r.age_uncertainty;
    const cls = Math.abs(dz) <= 1 ? "good" : Math.abs(dz) <= 3 ? "mid" : "bad";
    out.innerHTML = `<div class="fw-result">
        <div class="metric ${cls}"><div class="k">Model age</div><div class="v">${r.max_age.toFixed(2)} <small>Myr</small></div></div>
        <div class="metric"><div class="k">Observed</div><div class="v">${r.observed_age.toFixed(2)} <small>± ${r.age_uncertainty}</small></div></div>
      </div>
      <div style="font-size:12px;color:var(--ink-3);margin-bottom:8px">Difference: <b style="color:var(--ink)">${dz >= 0 ? "+" : ""}${dz.toFixed(1)}σ</b> · bulk (volume-weighted) age ${r.bulk_age.toFixed(2)} Myr · ${r.seconds.toFixed(2)} s</div>
      <div id="fw-plot"></div>
      <div class="legend" style="margin-top:4px"><span><i style="border-color:var(--accent)"></i>Apparent age across the grain</span><span><i class="box" style="background:color-mix(in srgb, var(--ok) 25%, transparent)"></i>Observed ± 1σ</span></div>`;
    const obsLo = r.observed_age - r.age_uncertainty, obsHi = r.observed_age + r.age_uncertainty;
    // the rim node is held at zero age by the boundary condition: leave it out so the profile is readable
    r.radius = r.radius.slice(0, -1); r.ages = r.ages.slice(0, -1);
    Charts.plot($("#fw-plot"), { height: 170, x: { label: "Normalised radius (centre → rim)", min: 0, max: r.radius[r.radius.length - 1] }, y: { label: "Age (Myr)" },
      layers: [{ type: "hband", y0: obsLo, y1: obsHi, color: "var(--ok)", opacity: 0.18, inDomain: true }, { type: "hline", y: r.observed_age, color: "var(--ok)", dash: "4 3" },
               { type: "line", x: r.radius, y: r.ages, color: "var(--accent)", width: 2.2 }],
      tooltip: x => { const a = Charts.interp(r.radius, r.ages, x); return a === null ? null : `r = ${x.toFixed(2)} · ${a.toFixed(2)} Myr`; } });
  } catch (e) { out.innerHTML = `<div class="warnbox">${esc(e.message)}</div>`; }
  finally { btn.disabled = false; btn.textContent = "Compute age"; }
});

// ------------------------------------------------------------------ start a run
$("#btn-run").addEventListener("click", async () => {
  const v = validate();
  if (v.errors.length) { toast(v.errors[0], "error"); return; }
  const btn = $("#btn-run");
  btn.disabled = true;
  const r = await api("/api/run", { method: "POST", body: cfg });
  if (r.errors || r.error) {
    const errs = r.errors || [r.error];
    $("#errors").innerHTML = errs.map(x => `<li>${esc(x)}</li>`).join(""); $("#errors").hidden = false;
    toast(errs[0], "error"); btn.disabled = false; return;
  }
  toast(`Run "${r.name}" started`);
  resetConsole();
  jobRunning = true;
  go("monitor");
  poll(true);
  // suggest the next free name for the following run
  setTimeout(async () => { const i = await api("/api/info"); if (i && !i.error) { INFO = i; cfg.run_name = i.next_run_name; $("[data-k=run_name]").value = cfg.run_name; save(); } }, 1500);
});

// ------------------------------------------------------------------ monitor
let jobRunning = false, lastSeq = 0, lastJobId = null, pollTimer = null;
const logEls = new Map();
function resetConsole() { $("#console").innerHTML = ""; logEls.clear(); lastSeq = 0; }

function chainColor(i, n) { // viridis-like hue sweep
  const t = n <= 1 ? 0.3 : 0.02 + 0.78 * i / (n - 1);   // skip the pale yellow end
  const stops = [[68, 1, 84], [59, 82, 139], [33, 145, 140], [94, 201, 98], [253, 231, 37]];
  const x = t * (stops.length - 1), k = Math.min(stops.length - 2, Math.floor(x)), f = x - k;
  const c = stops[k].map((v, j) => Math.round(v + f * (stops[k + 1][j] - v)));
  return `rgb(${c.join(",")})`;
}

function renderJob(s) {
  if (!s || s.state === "idle") { $("#monitor").hidden = true; $("#monitor-empty").hidden = false; return; }
  $("#monitor").hidden = false; $("#monitor-empty").hidden = true;
  if (lastJobId !== s.id) { resetConsole(); lastJobId = s.id; }
  $("#mon-name").textContent = s.name;
  const st = $("#mon-state");
  const label = { running: "Running", plotting: "Creating figures", done: "Finished", error: "Failed", cancelled: "Stopped" }[s.state] || s.state;
  st.className = "state " + s.state; st.textContent = label;
  $("#mon-phase").textContent = s.phase + (s.error ? " — " + s.error : "");
  const n = s.chains.length;
  const prog = s.state === "done" ? 1 : s.chains.reduce((a, c) => a + (c.state === "done" ? 1 : c.progress), 0) / Math.max(1, n);
  $("#mon-bar").style.width = (prog * 100).toFixed(1) + "%";
  $("#mon-pct").textContent = (prog * 100).toFixed(prog < 0.1 ? 1 : 0) + "%";
  $("#mon-elapsed").textContent = fmtDur(s.elapsed);
  let eta = "–";
  if (s.state === "running" && prog > 0.02) eta = fmtDur(s.elapsed * (1 - prog) / prog);
  else if (s.state === "plotting") eta = "< 1m";
  else if (s.state !== "running") eta = "–";
  $("#mon-eta").textContent = eta;
  $("#mon-evals").textContent = s.chains.reduce((a, c) => a + c.evals, 0).toLocaleString();
  const ndone = s.chains.filter(c => c.state === "done").length;
  $("#mon-chains").textContent = `${ndone} / ${n}`;
  const active = s.state === "running" || s.state === "plotting";
  $("#mon-cancel").hidden = s.state !== "running";
  $("#mon-results").hidden = s.state !== "done";
  $("#run-dot").hidden = !active;
  // chains
  const grid = $("#mon-chain-grid");
  if (grid.children.length !== n) grid.innerHTML = s.chains.map(() => `<div class="chain-card"></div>`).join("");
  s.chains.forEach((c, i) => {
    const card = grid.children[i];
    card.className = "chain-card " + c.state;
    const stl = { queued: "Queued", running: "Running", done: "Done", error: "Failed", cancelled: "Stopped" }[c.state];
    const rate = c.elapsed > 0 && c.evals > 0 ? (c.elapsed / c.evals) : null;
    const ceta = c.state === "running" && c.progress > 0.03 ? fmtDur(c.elapsed * (1 - c.progress) / c.progress) : "–";
    card.innerHTML = `<div class="top"><span class="name"><span style="display:inline-block;width:9px;height:9px;border-radius:50%;background:${chainColor(i, n)};margin-right:7px"></span>Chain ${c.index}</span>
        <span class="state ${c.state}">${stl}</span></div>
      <div class="bar"><div style="width:${(c.state === "done" ? 100 : c.progress * 100).toFixed(1)}%"></div></div>
      <div class="meta"><span>Seed <b>${c.seed}</b></span><span>Progress <b>${(c.state === "done" ? 100 : c.progress * 100).toFixed(0)}%</b></span>
        <span>Evaluations <b>${c.evals.toLocaleString()}</b></span><span>Elapsed <b>${fmtDur(c.elapsed)}</b></span>
        <span>s / eval <b>${rate ? rate.toFixed(3) : "–"}</b></span><span>Remaining <b>${ceta}</b></span></div>
      ${c.message ? `<div class="err">${esc(c.message)}</div>` : ""}`;
  });
  // log
  const con = $("#console");
  const warnOnly = $("#log-warn-only").checked;
  for (const l of s.log || []) {
    lastSeq = Math.max(lastSeq, l.seq);
    let row = logEls.get(l.id);
    if (!row) { row = document.createElement("div"); row.className = "ln"; logEls.set(l.id, row); con.appendChild(row); }
    row.dataset.level = l.level;
    row.hidden = warnOnly && l.level === "info";
    const t = new Date(l.time * 1000).toLocaleTimeString();
    row.innerHTML = `<span class="t">${t}</span>${l.chain ? `<span class="c">[chain ${l.chain}]</span>` : ""}<span class="${l.level}">${esc(l.msg)}</span>${l.count > 1 ? `<span class="x">×${l.count}</span>` : ""}`;
  }
  if ($("#log-follow").checked) con.scrollTop = con.scrollHeight;
  if (jobRunning && !active) {
    jobRunning = false;
    refreshAll();
    if (s.state === "done") toast(`Run "${s.name}" finished`);
    else if (s.state === "error") toast(`Run "${s.name}" failed`, "error");
    if ($("#view-results").classList.contains("active")) loadRuns();
  }
  jobRunning = active;
}
$("#log-warn-only").addEventListener("change", e => { $$("#console .ln").forEach(r => r.hidden = e.target.checked && r.dataset.level === "info"); });

async function poll(force) {
  clearTimeout(pollTimer);
  try {
    const s = await api("/api/status?since=" + lastSeq);
    setOnline(true, s);
    const wasRunning = jobRunning;
    renderJob(s);
    if (wasRunning !== jobRunning) refreshAll();
  } catch (e) { setOnline(false); }
  pollTimer = setTimeout(poll, jobRunning ? 1000 : 4000);
}
function setOnline(ok, s) {
  const pill = $("#engine-pill");
  pill.classList.toggle("off", !ok);
  pill.classList.toggle("busy", ok && s && (s.state === "running" || s.state === "plotting"));
  $("#engine-text").textContent = !ok ? "App not reachable — is Julia running?" :
    (s && s.state === "running") ? "Inversion running" : (s && s.state === "plotting") ? "Creating figures" :
    INFO ? `Ready · ${INFO.threads} threads` : "Ready";
}
$("#mon-cancel").addEventListener("click", async () => {
  if (!confirm("Stop this run? Chains that have not finished are not saved.")) return;
  await api("/api/cancel", { method: "POST" }); poll();
});
$("#mon-results").addEventListener("click", () => { go("results"); const n = $("#mon-name").textContent; openRun(n); });
$("#mon-folder").addEventListener("click", () => api(`/api/runs/${encodeURIComponent($("#mon-name").textContent)}/open`, { method: "POST" }));

// ------------------------------------------------------------------ results
let currentRun = null, currentRunName = null;
async function loadRuns() {
  const list = await api("/api/runs");
  const box = $("#run-list");
  if (!Array.isArray(list) || !list.length) { box.innerHTML = `<div style="padding:16px;color:var(--ink-3);font-size:13px">No runs yet.</div>`; return; }
  box.innerHTML = list.map(r => {
    const d = new Date(r.modified * 1000);
    const badge = r.status === "running" ? `<span class="badge mid">running</span>` : r.status === "incomplete" ? `<span class="badge neutral">no samples</span>` : "";
    return `<button class="run-item ${r.name === currentRunName ? "on" : ""}" data-run="${esc(r.name)}">
      <div class="n">${esc(r.name)} ${badge}</div>
      <div class="m"><span>${d.toLocaleDateString()} ${d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</span>
      <span>${r.chains} chain${r.chains === 1 ? "" : "s"}</span>${r.mineral ? `<span>${esc(r.mineral)}</span>` : ""}</div></button>`;
  }).join("");
  $$(".run-item", box).forEach(b => b.addEventListener("click", () => openRun(b.dataset.run)));
}
$("#runs-refresh").addEventListener("click", loadRuns);
$("#runs-folder").addEventListener("click", () => api("/api/open_results", { method: "POST" }));

async function openRun(name) {
  currentRunName = name;
  $$(".run-item").forEach(b => b.classList.toggle("on", b.dataset.run === name));
  $("#res-empty").hidden = true;
  const res = $("#res"); res.hidden = false;
  res.innerHTML = `<div class="card empty"><span class="spin" style="width:28px;height:28px"></span><h3>Loading ${esc(name)}…</h3></div>`;
  const d = await api(`/api/runs/${encodeURIComponent(name)}`);
  if (d.error) { res.innerHTML = `<div class="card empty"><h3>Could not load the run</h3><p>${esc(d.error)}</p></div>`; return; }
  currentRun = d;
  renderRun(d);
}

function rhatBadge(r) {
  if (r === null || r === undefined) return `<span class="badge neutral">n/a</span>`;
  const c = r < 1.01 ? "ok" : r < 1.05 ? "mid" : "bad";
  return `<span class="badge ${c}">${r.toFixed(3)}</span>`;
}
function essBadge(e, n) {
  if (e === null || e === undefined) return "–";
  const c = e >= 400 ? "ok" : e >= 100 ? "mid" : "bad";
  return `<span class="badge ${c}">${Math.round(e)}</span>`;
}
const fileUrl = (run, f, dl) => `/api/runs/${encodeURIComponent(run)}/file/${f.split("/").map(encodeURIComponent).join("/")}${dl ? "?download=1" : ""}`;

function renderRun(d) {
  const res = $("#res");
  const c = d.config || {};
  const geo = { 1: "plane", 2: "cylinder", 3: "sphere" }[c.geometry];
  const head = `<div class="card"><div class="res-head">
      <div><h2>${esc(d.name)}</h2>
        <div class="summary-chips" style="margin:8px 0 0">
          ${d.chains.length ? `<span><b>${d.chains.length}</b> chain${d.chains.length === 1 ? "" : "s"} · <b>${d.pooled_draws || 0}</b> draws</span>` : ""}
          ${c.sampler_type ? `<span><b>${esc(c.sampler_type)}</b></span>` : ""}
          ${c.mineral ? `<span>${esc(c.mineral)}${geo ? " · " + geo : ""}</span>` : ""}
          ${c.type_path ? `<span>path <b>${esc(c.type_path)}</b></span>` : ""}
          ${c.observed_age !== undefined ? `<span>age <b>${esc(c.observed_age)} ± ${esc(c.age_uncertainty)}</b> Myr</span>` : ""}
        </div></div>
      <div class="actions">
        <button class="btn sm" id="r-open">Open folder</button>
        ${d.config ? `<button class="btn sm" id="r-load">Load settings</button>` : ""}
        ${d.params.length ? `<button class="btn sm" id="r-replot">Regenerate figures</button>` : ""}
      </div></div></div>`;
  if (!d.params.length) {
    res.innerHTML = head + `<div class="card empty"><h3>No posterior samples</h3><p>${esc(d.error_msg || "")}</p></div>` + filesCard(d);
    bindRunActions(d); return;
  }
  const maxR = Math.max(...d.params.map(p => p.rhat ?? 0));
  const minE = Math.min(...d.params.map(p => p.ess_bulk ?? Infinity));
  const nch = d.chains.length;
  const div = d.chains.reduce((a, ch) => a + (ch.divergences || 0), 0);
  let verdict;
  if (nch < 2) verdict = `<div class="infobox">Only one chain: R̂ cannot compare chains. Use several seeds to check convergence.</div>`;
  else if (maxR < 1.01 && minE >= 400) verdict = `<div class="infobox" style="background:var(--ok-soft);color:var(--ok)"><b>Chains converged.</b> All R̂ &lt; 1.01 and bulk ESS ≥ 400.</div>`;
  else if (maxR < 1.05) verdict = `<div class="warnbox" style="margin:0"><b>Acceptable, check carefully.</b> Max R̂ = ${maxR.toFixed(3)}, min ESS = ${Math.round(minE)}. More samples would make the result more reliable.</div>`;
  else verdict = `<div class="errors" style="margin:0;padding-left:12px"><b>Chains have not converged</b> (max R̂ = ${maxR.toFixed(3)}). Run longer or check the priors.</div>`;
  if (div > 0) verdict += `<div class="warnbox">${div} draw(s) with numerical errors (divergences).</div>`;

  const rows = d.params.map(p => {
    const P = PMAP[p.key];
    const dec = p.key === "tlim" ? 2 : 1;
    return `<tr><td><span class="pname"><span class="sw" style="background:${P.color}"></span>${P.label} <span style="color:var(--ink-3);font-weight:500">${P.unit}</span></span></td>
      <td>${fmtN(p.mean, dec)}</td><td>${fmtN(p.std, dec)}</td><td>${fmtN(p.median, dec)}</td><td>${fmtN(p.mode, dec)}</td>
      <td>[${fmtN(p.q16, dec)}, ${fmtN(p.q84, dec)}]</td><td>[${fmtN(p.q025, dec)}, ${fmtN(p.q975, dec)}]</td>
      <td>${rhatBadge(p.rhat)}</td><td>${essBadge(p.ess_bulk)}</td><td>${essBadge(p.ess_tail)}</td></tr>`;
  }).join("");
  const table = `<div class="card"><div class="card-head"><h2>Posterior summary</h2><span class="hint">all chains pooled</span></div>
    <div class="card-body"><div style="margin-bottom:14px">${verdict}</div><div class="table-wrap"><table class="tbl">
    <tr><th>Parameter</th><th>Mean</th><th>Std</th><th>Median</th><th>Mode</th><th>68% interval</th><th>95% interval</th><th>R̂</th><th>ESS bulk</th><th>ESS tail</th></tr>${rows}</table></div></div></div>`;

  const dens = `<div class="card"><div class="card-head"><h2>Posterior distributions</h2></div><div class="card-body">
    <div class="legend"><span><i style="border-color:var(--ink)"></i>Posterior (pooled)</span><span><i class="box" style="background:color-mix(in srgb, var(--ink-3) 30%, transparent)"></i>68% interval</span>
    ${nch > 1 ? `<span><i style="border-color:var(--ink-3);opacity:.6"></i>Individual chains</span>` : ""}${d.config ? `<span><i class="dash" style="border-color:var(--ink-3)"></i>Prior</span>` : ""}
    <span><i class="dash" style="border-color:var(--warn)"></i>Mean</span></div>
    <div class="plot-grid">${d.params.map(p => `<div class="plot"><h4><span class="sw" style="width:10px;height:10px;border-radius:3px;background:${PMAP[p.key].color}"></span>${PMAP[p.key].label}<span class="sub">${fmtSmart(p.mean)} ± ${fmtSmart(p.std)} ${PMAP[p.key].unit}</span></h4><div data-dens="${p.key}"></div></div>`).join("")}</div></div></div>`;

  const chainLegend = nch > 1 ? `<div class="legend">${d.chains.map((ch, i) => `<span><i style="border-color:${chainColor(i, nch)}"></i>chain ${ch.index}${ch.seed !== null && ch.seed !== undefined ? " · seed " + ch.seed : ""}</span>`).join("")}</div>` : "";
  const traces = `<div class="card"><div class="card-head"><h2>Trace plots</h2><span class="hint">draws after warm-up</span></div><div class="card-body">${chainLegend}
    <div class="plot-grid">${d.params.map(p => `<div class="plot"><h4>${PMAP[p.key].label}<span class="sub">${PMAP[p.key].unit}</span></h4><div data-trace="${p.key}"></div></div>`).join("")}</div></div></div>`;

  const corner = `<div class="card"><div class="card-head"><h2>Parameter correlations</h2><span class="hint">pairs of posterior draws</span></div><div class="card-body"><div class="corner" id="corner"></div></div></div>`;

  const diagRows = d.chains.map((ch, i) => `<tr><td><span class="pname"><span class="sw" style="background:${chainColor(i, nch)};border-radius:50%"></span>Chain ${ch.index}</span></td>
    <td>${ch.seed ?? "–"}</td><td>${ch.draws}</td><td>${ch.evals !== null && ch.evals !== undefined ? Math.round(ch.evals).toLocaleString() : "–"}</td>
    <td>${ch.wall !== null && ch.wall !== undefined ? fmtDur(ch.wall) : "–"}</td><td>${ch.wall && ch.evals ? (ch.wall / ch.evals).toFixed(3) : "–"}</td>
    <td>${fmtN(ch.acceptance, 3)}</td><td>${ch.divergences ?? "–"}</td><td>${fmtN(ch.tree_depth, 1)}</td><td>${ch.step_size ? ch.step_size.toPrecision(3) : "–"}</td></tr>`).join("");
  const diag = `<div class="card"><div class="card-head"><h2>Sampler diagnostics</h2></div><div class="card-body"><div class="table-wrap"><table class="tbl">
    <tr><th>Chain</th><th>Seed</th><th>Draws</th><th>Evaluations</th><th>Wall time</th><th>s / eval</th><th>Acceptance</th><th>Divergences</th><th>Tree depth</th><th>Step size</th></tr>${diagRows}</table></div>
    ${d.chains.some(ch => ch.lp) ? `<div class="plot" style="margin-top:16px"><h4>Log posterior density<span class="sub">per chain</span></h4><div id="lp-plot"></div></div>` : ""}
    ${d.app_info ? `<details style="margin-top:14px"><summary>App run information</summary><pre class="stats">${esc(d.app_info)}</pre></details>` : ""}
    ${d.run_statistics ? `<details style="margin-top:8px"><summary>run_statistics.txt</summary><pre class="stats">${esc(d.run_statistics)}</pre></details>` : ""}
    </div></div>`;

  res.innerHTML = head + table + dens + traces + corner + diag + galleryCard(d) + filesCard(d);
  bindRunActions(d);

  // ---- draw charts
  for (const p of d.params) {
    const P = PMAP[p.key];
    const layers = [];
    const band = p.kde.x.map((x, i) => (x >= p.q16 && x <= p.q84) ? p.kde.y[i] : null);
    const bx = [], by = [];
    p.kde.x.forEach((x, i) => { if (band[i] !== null) { bx.push(x); by.push(band[i]); } });
    if (bx.length > 1) layers.push({ type: "area", x: bx, y: by, color: P.color, opacity: 0.22 });
    if (nch > 1) p.chain_kde.forEach((k, i) => { if (k) layers.push({ type: "line", x: k.x, y: k.y, color: chainColor(i, nch), width: 1.1, opacity: 0.55 }); });
    let priorXY = null;
    if (d.config) {
      const sp = priorSpec(p.key, d.config);
      if (priorOk(sp)) {
        const a = Math.min(p.kde.x[0], sp.lo), b = Math.max(p.kde.x[p.kde.x.length - 1], sp.hi);
        const lo = Math.max(a, p.kde.x[0] - (p.kde.x[p.kde.x.length - 1] - p.kde.x[0]) * 0.1);
        const hi = Math.min(b, p.kde.x[p.kde.x.length - 1] + (p.kde.x[p.kde.x.length - 1] - p.kde.x[0]) * 0.1);
        const xs = [], ys = [];
        for (let i = 0; i <= 200; i++) { const x = lo + (hi - lo) * i / 200; xs.push(x); ys.push(priorPdf(sp, x)); }
        priorXY = { xs, ys };
        layers.push({ type: "line", x: xs, y: ys, color: "var(--ink-3)", dash: "5 4", width: 1.4 });
      }
    }
    layers.push({ type: "line", x: p.kde.x, y: p.kde.y, color: P.color, width: 2.6 });
    layers.push({ type: "vline", x: p.mean, color: "var(--warn)", dash: "5 3", width: 1.6 });
    Charts.plot($(`[data-dens=${p.key}]`), { height: 240, x: { label: `${P.label} (${P.unit})` }, y: { label: "Probability density", zero: true, top: 0.1 },
      layers, tooltip: x => { const y = Charts.interp(p.kde.x, p.kde.y, x); if (y === null) return null;
        const pr = priorXY ? Charts.interp(priorXY.xs, priorXY.ys, x) : null;
        return `${fmtSmart(x)} ${P.unit}<br>posterior ${y.toPrecision(3)}${pr !== null ? `<br>prior ${pr.toPrecision(3)}` : ""}`; } });
    const tl = p.trace.map((tr, i) => ({ type: "line", x: tr.map((_, j) => j + 1), y: tr, color: chainColor(i, nch), width: 1, opacity: nch > 1 ? 0.75 : 0.9 }));
    if (nch === 1) tl[0].color = P.color;
    Charts.plot($(`[data-trace=${p.key}]`), { height: 200, x: { label: "Draw", min: 1 }, y: { label: `${P.unit}` }, layers: tl });
  }
  const lpl = d.chains.filter(ch => ch.lp).map((ch, i) => ({ type: "line", x: ch.lp.map((_, j) => j + 1), y: ch.lp, color: chainColor(i, nch), width: 1, opacity: 0.8 }));
  if (lpl.length) Charts.plot($("#lp-plot"), { height: 180, x: { label: "Draw", min: 1 }, y: { label: "log density" }, layers: lpl });
  drawCorner(d);
}

function drawCorner(d) {
  const box = $("#corner"); if (!box) return;
  const ps = d.params, n = ps.length, nch = d.chains.length;
  box.style.gridTemplateColumns = `repeat(${n}, minmax(0, 1fr))`;
  box.innerHTML = "";
  const cols = d.pair_chain.map(k => nch > 1 ? chainColor(k - 1, nch) : "var(--accent)");
  const thin = Math.max(1, Math.floor(d.pair_chain.length / 1500));
  const idx = d.pair_chain.map((_, i) => i).filter(i => i % thin === 0);
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) {
    const cell = document.createElement("div"); cell.className = "cell"; box.appendChild(cell);
    if (c > r) {
      // correlation coefficient
      const a = d.pairs[ps[c].key], b = d.pairs[ps[r].key];
      const ma = a.reduce((s, v) => s + v, 0) / a.length, mb = b.reduce((s, v) => s + v, 0) / b.length;
      let sab = 0, saa = 0, sbb = 0;
      for (let i = 0; i < a.length; i++) { sab += (a[i] - ma) * (b[i] - mb); saa += (a[i] - ma) ** 2; sbb += (b[i] - mb) ** 2; }
      const rho = sab / Math.sqrt(saa * sbb);
      const strength = Math.min(1, Math.abs(rho));
      cell.innerHTML = `<div style="height:100%;min-height:120px;display:grid;place-items:center;border-radius:10px;background:color-mix(in srgb, ${rho >= 0 ? "var(--c-SCR)" : "var(--c-T0)"} ${Math.round(strength * 35)}%, transparent)">
        <div style="text-align:center"><div style="font-size:11px;color:var(--ink-3)">${PMAP[ps[r].key].sym} – ${PMAP[ps[c].key].sym}</div><div style="font-size:20px;font-weight:650;font-variant-numeric:tabular-nums">ρ = ${isFinite(rho) ? rho.toFixed(2) : "–"}</div></div></div>`;
      continue;
    }
    const bottom = r === n - 1, left = c === 0;
    const m = { t: 6, r: 6, b: bottom ? 36 : 14, l: left ? 52 : 14 };
    const xl = bottom ? `${PMAP[ps[c].key].sym} (${PMAP[ps[c].key].unit})` : undefined;
    if (r === c) {
      const p = ps[r];
      Charts.plot(cell, { height: 150 + (bottom ? 22 : 0), margin: m, x: { label: xl }, y: { zero: true, ticks: false, label: left ? "density" : undefined, top: 0.1 },
        layers: [{ type: "area", x: p.kde.x, y: p.kde.y, color: PMAP[p.key].color, opacity: 0.2 }, { type: "line", x: p.kde.x, y: p.kde.y, color: PMAP[p.key].color, width: 2 }] });
    } else {
      const xs = idx.map(i => d.pairs[ps[c].key][i]), ys = idx.map(i => d.pairs[ps[r].key][i]);
      Charts.plot(cell, { height: 150 + (bottom ? 22 : 0), margin: m, x: { label: xl }, y: { label: left ? `${PMAP[ps[r].key].sym} (${PMAP[ps[r].key].unit})` : undefined, ticks: left },
        layers: [{ type: "points", x: xs, y: ys, colors: idx.map(i => cols[i]), r: 1.5, opacity: 0.45 }] });
    }
  }
}

function galleryCard(d) {
  const pngs = d.files.filter(f => f.toLowerCase().endsWith(".png"));
  if (!pngs.length) return "";
  const nice = f => f.replace(/\.png$/i, "").replace(/_/g, " ");
  return `<div class="card"><div class="card-head"><h2>Saved figures</h2><span class="hint">publication figures from the run folder</span></div><div class="card-body"><div class="gallery">
    ${pngs.map(f => { const pdf = f.replace(/\.png$/i, ".pdf"); const hasPdf = d.files.includes(pdf);
      return `<div class="thumb" data-img="${esc(fileUrl(d.name, f))}"><img loading="lazy" src="${esc(fileUrl(d.name, f))}" alt="${esc(nice(f))}">
      <div class="cap">${esc(nice(f))}${hasPdf ? `<a href="${esc(fileUrl(d.name, pdf, true))}" onclick="event.stopPropagation()">PDF</a>` : ""}<a href="${esc(fileUrl(d.name, f, true))}" onclick="event.stopPropagation()" style="margin-left:${hasPdf ? "6px" : "auto"}">PNG</a></div></div>`; }).join("")}
    </div></div></div>`;
}
function filesCard(d) {
  const other = d.files.filter(f => !/\.(png|pdf)$/i.test(f));
  if (!other.length) return "";
  return `<div class="card"><div class="card-head"><h2>Data files</h2></div><div class="card-body"><div class="files">
    ${other.map(f => `<a href="${esc(fileUrl(d.name, f, true))}">${esc(f)}</a>`).join("")}</div>
    ${d.chain_folders && d.chain_folders.length > 1 ? `<p class="card-sub" style="margin-top:10px">Per-chain files are in ${d.chain_folders.slice(1).map(esc).join(", ")} (open the folder).</p>` : ""}</div></div>`;
}
function bindRunActions(d) {
  const o = $("#r-open"); if (o) o.addEventListener("click", () => api(`/api/runs/${encodeURIComponent(d.name)}/open`, { method: "POST" }));
  const l = $("#r-load"); if (l) l.addEventListener("click", () => { applySettings(d.config, d.name); go("setup"); });
  const rp = $("#r-replot");
  if (rp) rp.addEventListener("click", async () => {
    rp.disabled = true; rp.innerHTML = `<span class="spin"></span> Regenerating…`;
    const r = await api(`/api/runs/${encodeURIComponent(d.name)}/replot`, { method: "POST" });
    if (r.error) toast(r.error, "error"); else { toast("Figures regenerated"); openRun(d.name); }
  });
  $$(".thumb").forEach(t => t.addEventListener("click", () => {
    const lb = document.createElement("div"); lb.className = "lightbox";
    lb.innerHTML = `<img src="${t.dataset.img}">`; lb.addEventListener("click", () => lb.remove());
    document.body.appendChild(lb);
  }));
}
document.addEventListener("keydown", e => { if (e.key === "Escape") $$(".lightbox").forEach(l => l.remove()); });

// ------------------------------------------------------------------ start
async function init() {
  writeForm();
  try {
    INFO = await api("/api/info");
    if (INFO.error) throw new Error(INFO.error);
    $("#mineral-select").innerHTML = INFO.minerals.map(m => `<option value="${m}">${m === "custom" ? "Custom (enter values)" : m}</option>`).join("");
    $("#mineral-select").value = cfg.mineral;
    if (!cfg.run_name) { cfg.run_name = INFO.next_run_name; $("[data-k=run_name]").value = cfg.run_name; }
    if (INFO.threads < 2) cfg.parallel = false;
  } catch (e) { toast("Could not reach the KADMOS engine", "error"); }
  writeForm();
  refreshAll();
  fillForwardFromPriors();
  await poll();
  const h = location.hash.slice(1);
  if (["setup", "monitor", "results", "guide"].includes(h)) go(h);
  else if (jobRunning) go("monitor");
}
init();
})();
