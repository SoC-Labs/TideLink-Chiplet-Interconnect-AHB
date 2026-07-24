// TideLink GUI — shared helpers for every view.
//
// Loaded first, with plain <script> tags (there is NO build step and there
// must not be one). Everything shared lives on the single `TL` global;
// per-view files wrap themselves in an IIFE so nothing else collides.
//
// Deliberately conservative syntax (no ?. / ?? / fromEntries) so the files
// can be syntax-checked with the node 10 on this host.
"use strict";

const $ = (id) => document.getElementById(id);

const TL = {};

// Rolling-chart cap: Plotly shifts the oldest point out once a trace
// exceeds this, so a monitor left open for hours does not grow arrays
// without bound.
TL.MAX_POINTS = 600;

TL.COLORS = {
  master: "#4ea1ff",
  slave: "#41d67c",
  accent: "#e0b341",
  bad: "#d65454",
  mute: "#8696ac",
  grid: "#222a36",
};

TL.LAYOUT_BASE = {
  margin: { t: 36, r: 16, b: 40, l: 56 },
  paper_bgcolor: "#11151c", plot_bgcolor: "#11151c",
  font: { color: "#c8d2e0", size: 11 },
  xaxis: { title: "t (s)", gridcolor: TL.COLORS.grid },
  showlegend: true,
  legend: { orientation: "h", y: 1.15 },
};

TL.PLOT_CFG = { displayModeBar: false, responsive: true };

// ── tiny pub/sub so views can observe each other without importing ──────
TL.bus = (function () {
  const subs = {};
  return {
    on: function (ev, fn) {
      if (!subs[ev]) subs[ev] = [];
      subs[ev].push(fn);
    },
    emit: function (ev, data) {
      const list = subs[ev] || [];
      for (let i = 0; i < list.length; i++) {
        try { list[i](data); } catch (e) { console.error(ev, e); }
      }
    },
  };
})();

// ── fetch helpers ───────────────────────────────────────────────────────

// Throws an Error carrying .status and .detail so callers can distinguish
// "endpoint not built yet" (404) from a real refusal (409/412).
TL.jget = async function (url) {
  const r = await fetch(url);
  if (!r.ok) {
    const err = new Error(url + ": " + r.status);
    err.status = r.status;
    try { err.detail = (await r.json()).detail; } catch (e) { /* html/plain */ }
    throw err;
  }
  return r.json();
};

// Never throws: returns {ok, status, json}. Used where the UI must degrade
// rather than blow up (the monitor/compare APIs may not exist on an older
// server build).
TL.jpost = async function (url, body) {
  try {
    const r = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body || {}),
    });
    let j = null;
    try { j = await r.json(); } catch (e) { j = null; }
    return { ok: r.ok, status: r.status, json: j };
  } catch (e) {
    return { ok: false, status: 0, json: { detail: String(e) } };
  }
};

// ── formatting ──────────────────────────────────────────────────────────

TL.esc = function (s) {
  return String(s === undefined || s === null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
};

TL.num = function (v, digits) {
  if (v === undefined || v === null || v === "" || isNaN(Number(v))) return "—";
  const n = Number(v);
  if (digits === undefined) {
    return Number.isInteger(n) ? n.toLocaleString() : n.toFixed(3);
  }
  return n.toFixed(digits);
};

TL.pct = function (frac, digits) {
  if (frac === undefined || frac === null || isNaN(Number(frac))) return "—";
  return (Number(frac) * 100).toFixed(digits === undefined ? 1 : digits) + "%";
};

TL.clock = function () {
  return new Date().toLocaleTimeString();
};

// ── charts ──────────────────────────────────────────────────────────────

// Append one point to each of `idxs`, letting Plotly shift the window.
TL.extend = function (divId, idxs, xs, ys) {
  const gd = document.getElementById(divId);
  if (!gd || !gd.data) return;              // chart not initialised yet
  const xa = [];
  const ya = [];
  for (let i = 0; i < idxs.length; i++) { xa.push([xs[i]]); ya.push([ys[i]]); }
  try {
    Plotly.extendTraces(divId, { x: xa, y: ya }, idxs, TL.MAX_POINTS);
  } catch (e) { /* chart torn down mid-stream */ }
};

TL.resizeCharts = function (ids) {
  for (let i = 0; i < ids.length; i++) {
    const gd = document.getElementById(ids[i]);
    if (gd && gd.data) { try { Plotly.Plots.resize(gd); } catch (e) { } }
  }
};

// ── tabs ────────────────────────────────────────────────────────────────

TL.TABS = ["run", "monitor", "compare"];
TL.activeTab = "run";

TL.initTabs = function () {
  const btns = [].slice.call(document.querySelectorAll(".tab"));
  function show(name) {
    if (TL.TABS.indexOf(name) < 0) name = "run";
    TL.activeTab = name;
    for (let i = 0; i < btns.length; i++) {
      const on = btns[i].getAttribute("data-tab") === name;
      btns[i].classList.toggle("active", on);
    }
    for (let i = 0; i < TL.TABS.length; i++) {
      const v = $("view-" + TL.TABS[i]);
      if (v) v.classList.toggle("hidden", TL.TABS[i] !== name);
    }
    if (("#" + name) !== window.location.hash) {
      try { history.replaceState(null, "", "#" + name); } catch (e) { }
    }
    TL.bus.emit("tab", name);
  }
  for (let i = 0; i < btns.length; i++) {
    btns[i].addEventListener("click", function () {
      show(this.getAttribute("data-tab"));
    });
  }
  TL.showTab = show;
  show((window.location.hash || "#run").slice(1));
};

window.addEventListener("DOMContentLoaded", TL.initTabs);
