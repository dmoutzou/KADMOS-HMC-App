/* Minimal SVG charts for the KADMOS HMC App (no external dependencies). */
(function () {
  const NS = "http://www.w3.org/2000/svg";

  function tickStep(min, max, count) {
    const span = Math.abs(max - min) || 1;
    const step0 = span / Math.max(1, count);
    const pow = Math.pow(10, Math.floor(Math.log10(step0)));
    const err = step0 / pow;
    const m = err >= 7.5 ? 10 : err >= 3.5 ? 5 : err >= 1.5 ? 2 : 1;
    return m * pow;
  }
  function ticks(min, max, count) {
    if (!isFinite(min) || !isFinite(max)) return [];
    const st = tickStep(min, max, count);
    const out = [];
    const start = Math.ceil(min / st - 1e-9) * st;
    for (let v = start; v <= max + st * 1e-9; v += st) out.push(Math.abs(v) < st * 1e-9 ? 0 : v);
    return out;
  }
  function fmt(v, step) {
    if (!isFinite(v)) return "";
    const a = Math.abs(v);
    if (a !== 0 && (a >= 1e5 || a < 1e-3)) return v.toExponential(1).replace("e+", "e");
    const d = step ? Math.max(0, Math.min(6, -Math.floor(Math.log10(step) + 1e-9))) : 2;
    return v.toFixed(d);
  }
  function el(name, attrs, parent) {
    const e = document.createElementNS(NS, name);
    for (const k in attrs) if (attrs[k] !== undefined && attrs[k] !== null) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  function extent(arrs) {
    let lo = Infinity, hi = -Infinity;
    for (const a of arrs) for (const v of a) if (v !== null && isFinite(v)) { if (v < lo) lo = v; if (v > hi) hi = v; }
    return [lo, hi];
  }
  function pathD(xs, ys, sx, sy) {
    let d = "", pen = false;
    for (let i = 0; i < xs.length; i++) {
      const x = xs[i], y = ys[i];
      if (x === null || y === null || !isFinite(x) || !isFinite(y)) { pen = false; continue; }
      d += (pen ? "L" : "M") + sx(x).toFixed(1) + "," + sy(y).toFixed(1);
      pen = true;
    }
    return d;
  }

  let tipEl = null;
  function tip(show, text, ev) {
    if (!tipEl) { tipEl = document.createElement("div"); tipEl.className = "chart-tip"; document.body.appendChild(tipEl); }
    if (!show) { tipEl.style.display = "none"; return; }
    tipEl.innerHTML = text; tipEl.style.display = "block";
    const w = tipEl.offsetWidth;
    let x = ev.clientX + 14; if (x + w > innerWidth - 8) x = ev.clientX - w - 14;
    tipEl.style.left = x + "px"; tipEl.style.top = (ev.clientY - 30) + "px";
  }

  function render(host, o) {
    const W = Math.max(120, o.width || host.clientWidth || 300);
    const H = o.height || 220;
    const m = Object.assign(o.bare ? { t: 2, r: 2, b: 2, l: 2 } : { t: 10, r: 14, b: o.x && o.x.label ? 40 : 24, l: o.y && o.y.label ? 56 : 44 }, o.margin || {});
    host.innerHTML = "";
    const svg = el("svg", { width: W, height: H, class: "chart", viewBox: `0 0 ${W} ${H}` }, host);
    const layers = o.layers || [];
    const xo = o.x || {}, yo = o.y || {};
    // domains
    let [x0, x1] = extent(layers.filter(l => Array.isArray(l.x)).map(l => l.x).concat(layers.filter(l => l.type === "vline" && l.inDomain).map(l => [l.x])));
    if (xo.min !== undefined) x0 = xo.min;
    if (xo.max !== undefined) x1 = xo.max;
    if (!isFinite(x0) || !isFinite(x1)) { x0 = 0; x1 = 1; }
    if (x0 === x1) { x0 -= 0.5; x1 += 0.5; }
    let [y0, y1] = extent(layers.filter(l => Array.isArray(l.y)).map(l => l.y).concat(layers.filter(l => Array.isArray(l.y0)).map(l => l.y0))
      .concat(layers.filter(l => l.inDomain && l.type === "hline").map(l => [l.y]))
      .concat(layers.filter(l => l.inDomain && l.type === "hband").map(l => [l.y0, l.y1])));
    if (yo.zero) y0 = Math.min(0, y0);
    if (!isFinite(y0) || !isFinite(y1)) { y0 = 0; y1 = 1; }
    if (y0 === y1) { y0 -= 0.5; y1 += 0.5; }
    const pad = yo.pad === undefined ? 0.06 : yo.pad;
    if (!yo.zero) y0 -= (y1 - y0) * pad;
    y1 += (y1 - y0) * (yo.top === undefined ? pad : yo.top);
    if (yo.min !== undefined) y0 = yo.min;
    if (yo.max !== undefined) y1 = yo.max;
    const iw = W - m.l - m.r, ih = H - m.t - m.b;
    const sx = v => m.l + (v - x0) / (x1 - x0) * iw;
    const sy = v => m.t + ih - (v - y0) / (y1 - y0) * ih;
    const clipId = "c" + Math.random().toString(36).slice(2);
    el("rect", { x: m.l, y: m.t, width: iw, height: ih }, el("clipPath", { id: clipId }, el("defs", {}, svg)));

    if (!o.bare) {
      const g = el("g", { class: "grid" }, svg);
      const xt = ticks(x0, x1, Math.max(2, Math.floor(iw / 70))), yt = ticks(y0, y1, Math.max(2, Math.floor(ih / 40)));
      const xs = xt.length > 1 ? xt[1] - xt[0] : 1, ys = yt.length > 1 ? yt[1] - yt[0] : 1;
      if (yo.grid !== false) for (const v of yt) el("line", { x1: m.l, x2: m.l + iw, y1: sy(v), y2: sy(v) }, g);
      for (const v of xt) {
        el("line", { x1: sx(v), x2: sx(v), y1: m.t + ih, y2: m.t + ih + 4, stroke: "var(--line-2)" }, svg);
        const t = el("text", { x: sx(v), y: m.t + ih + 15, "text-anchor": "middle" }, svg); t.textContent = (xo.format || (z => fmt(z, xs)))(v);
      }
      if (yo.ticks !== false) for (const v of yt) {
        const t = el("text", { x: m.l - 6, y: sy(v) + 3.5, "text-anchor": "end" }, svg); t.textContent = (yo.format || (z => fmt(z, ys)))(v);
      }
      el("rect", { x: m.l, y: m.t, width: iw, height: ih, class: "frame" }, svg);
      if (xo.label) { const t = el("text", { x: m.l + iw / 2, y: H - 6, "text-anchor": "middle", class: "axis-label" }, svg); t.textContent = xo.label; }
      if (yo.label) { const t = el("text", { x: 0, y: 0, transform: `translate(13,${m.t + ih / 2}) rotate(-90)`, "text-anchor": "middle", class: "axis-label" }, svg); t.textContent = yo.label; }
    }
    const plotG = el("g", { "clip-path": `url(#${clipId})` }, svg);
    for (const l of layers) {
      const c = l.color || "var(--accent)";
      if (l.type === "area") {
        const xs = l.x, ys = l.y;
        const base = Array.isArray(l.y0) ? l.y0 : xs.map(() => (l.y0 === undefined ? Math.max(y0, 0) : l.y0));
        let d = "";
        for (let i = 0; i < xs.length; i++) d += (i ? "L" : "M") + sx(xs[i]).toFixed(1) + "," + sy(ys[i]).toFixed(1);
        for (let i = xs.length - 1; i >= 0; i--) d += "L" + sx(xs[i]).toFixed(1) + "," + sy(base[i]).toFixed(1);
        if (xs.length) el("path", { d: d + "Z", fill: c, "fill-opacity": l.opacity === undefined ? 0.18 : l.opacity, stroke: "none" }, plotG);
      } else if (l.type === "line") {
        el("path", { d: pathD(l.x, l.y, sx, sy), fill: "none", stroke: c, "stroke-width": l.width || 1.8, "stroke-opacity": l.opacity === undefined ? 1 : l.opacity,
          "stroke-dasharray": l.dash || null, "stroke-linejoin": "round", "stroke-linecap": "round" }, plotG);
      } else if (l.type === "vline") {
        el("line", { x1: sx(l.x), x2: sx(l.x), y1: m.t, y2: m.t + ih, stroke: c, "stroke-width": l.width || 1.4, "stroke-dasharray": l.dash || null, "stroke-opacity": l.opacity === undefined ? 1 : l.opacity }, plotG);
      } else if (l.type === "hline") {
        el("line", { x1: m.l, x2: m.l + iw, y1: sy(l.y), y2: sy(l.y), stroke: c, "stroke-width": l.width || 1.2, "stroke-dasharray": l.dash || null, "stroke-opacity": l.opacity === undefined ? 1 : l.opacity }, plotG);
      } else if (l.type === "vband") {
        const a = sx(Math.max(l.x0, x0)), b = sx(Math.min(l.x1, x1));
        if (b > a) el("rect", { x: a, y: m.t, width: b - a, height: ih, fill: c, "fill-opacity": l.opacity === undefined ? 0.12 : l.opacity }, plotG);
      } else if (l.type === "hband") {
        const a = sy(Math.min(l.y1, y1)), b = sy(Math.max(l.y0, y0));
        if (b > a) el("rect", { x: m.l, y: a, width: iw, height: b - a, fill: c, "fill-opacity": l.opacity === undefined ? 0.12 : l.opacity }, plotG);
      } else if (l.type === "points") {
        const g = el("g", { "fill-opacity": l.opacity === undefined ? 0.5 : l.opacity }, plotG);
        const r = l.r || 1.6;
        for (let i = 0; i < l.x.length; i++) {
          el("circle", { cx: sx(l.x[i]).toFixed(1), cy: sy(l.y[i]).toFixed(1), r, fill: l.colors ? l.colors[i] : c }, g);
        }
      }
    }
    // hover
    if (o.tooltip && !o.bare) {
      const cross = el("line", { y1: m.t, y2: m.t + ih, stroke: "var(--ink-3)", "stroke-dasharray": "3 3", visibility: "hidden" }, svg);
      const ov = el("rect", { x: m.l, y: m.t, width: iw, height: ih, fill: "transparent" }, svg);
      ov.addEventListener("mousemove", ev => {
        const r = svg.getBoundingClientRect();
        const px = (ev.clientX - r.left) * (W / r.width);
        const xv = x0 + (px - m.l) / iw * (x1 - x0);
        cross.setAttribute("x1", px); cross.setAttribute("x2", px); cross.setAttribute("visibility", "visible");
        const t = o.tooltip(xv); if (t) tip(true, t, ev); else tip(false);
      });
      ov.addEventListener("mouseleave", () => { cross.setAttribute("visibility", "hidden"); tip(false); });
    }
    return { sx, sy, x0, x1, y0, y1 };
  }

  const ro = new ResizeObserver(entries => {
    for (const e of entries) {
      const h = e.target;
      if (!h.__opts) continue;
      const w = Math.round(e.contentRect.width);
      if (w > 0 && w !== h.__w) { h.__w = w; render(h, h.__opts); }
    }
  });

  function plot(host, opts) {
    host.__opts = opts;
    host.__w = host.clientWidth;
    const r = render(host, opts);
    ro.observe(host);
    return r;
  }

  // linear interpolation helper for tooltips
  function interp(xs, ys, x) {
    if (!xs || !xs.length || x < xs[0] || x > xs[xs.length - 1]) return null;
    let lo = 0, hi = xs.length - 1;
    while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (xs[mid] <= x) lo = mid; else hi = mid; }
    const t = (x - xs[lo]) / ((xs[hi] - xs[lo]) || 1);
    return ys[lo] + t * (ys[hi] - ys[lo]);
  }

  window.Charts = { plot, ticks, fmt, interp };
})();
