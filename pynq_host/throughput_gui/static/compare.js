// TideLink GUI — Compare view.
//
// Quantifies throughput differences between tagged RTL versions via
// /api/versions and /api/compare. Two rules drive the design:
//
//   1. The server's `warnings` array is rendered PROMINENTLY, above the
//      chart. A comparison that silently mixes params_key / fifo_label /
//      n<3 is worse than no comparison — this rig has already produced one
//      structurally-confounded rate ladder.
//   2. A delta that does not exceed the groups' spread is labelled
//      "within noise" and is NOT coloured as a win.
"use strict";

(function () {

const CHART = "chart-compare";
const METRICS = [
  "throughput_mbps_mean",
  "throughput_mbps_p5",
  "throughput_mbps_p95",
  "rx_throughput_mbps_mean",
  "rx_drained_words",
  "packets",
];

const C = { versions: [], selected: {}, last: null, available: null };

// Metric values span Mbit/s (units) and word counts (tens of thousands),
// so keep a column readable without pretending to precision we lack.
function stat(v) {
  if (v === undefined || v === null || v === "" || isNaN(Number(v))) return "—";
  const n = Number(v);
  return Math.abs(n) >= 1000 ? n.toLocaleString() : n.toFixed(3);
}

function note(msg, cls) {
  const el = $("cmp-note");
  el.className = "mon-note " + (cls || "");
  el.textContent = msg || "";
}

function versionKey(v) {
  return v.artefact_version || v.rtl_tag || v.source_commit || "(unknown)";
}

async function loadVersions() {
  note("loading versions…");
  try {
    const list = await TL.jget("/api/versions");
    C.available = true;
    C.versions = Array.isArray(list) ? list : [];
    renderVersions();
    note(C.versions.length ? "" : "no runs recorded yet — the version list " +
         "fills in as runs complete.", "");
  } catch (e) {
    if (e.status === 404) {
      C.available = false;
      $("cmp-versions").innerHTML =
        '<div class="muted">/api/versions is not available on this ' +
        "server build.</div>";
      note("The comparison API is not available on this server build. " +
           "The Run and Link Monitor tabs are unaffected.", "warn");
    } else {
      note("version list error: " + e.message, "warn");
    }
  }
}

function renderVersions() {
  const el = $("cmp-versions");
  if (!C.versions.length) {
    el.innerHTML = '<div class="muted">(none)</div>';
    return;
  }
  let html = "";
  for (let i = 0; i < C.versions.length; i++) {
    const v = C.versions[i];
    const key = versionKey(v);
    const checked = C.selected[key] ? " checked" : "";
    html += '<label class="ver-row"><input type="checkbox" value="' +
      TL.esc(key) + '"' + checked + ">" +
      '<span class="ver-name">' + TL.esc(key) + "</span>" +
      '<span class="ver-meta">' +
      (v.rtl_tag ? "tag " + TL.esc(v.rtl_tag) + " · " : "") +
      (v.source_commit ? TL.esc(String(v.source_commit).slice(0, 8)) + " · " : "") +
      TL.esc(v.runs) + " runs" +
      (v.last ? " · last " + TL.esc(String(v.last).slice(0, 19)) : "") +
      "</span></label>";
  }
  el.innerHTML = html;
  const boxes = el.querySelectorAll("input[type=checkbox]");
  for (let i = 0; i < boxes.length; i++) {
    boxes[i].addEventListener("change", function () {
      C.selected[this.value] = this.checked;
      renderBaselineOptions();
    });
  }
  renderBaselineOptions();
}

function selectedVersions() {
  const out = [];
  for (let i = 0; i < C.versions.length; i++) {
    const key = versionKey(C.versions[i]);
    if (C.selected[key]) out.push(key);
  }
  return out;
}

function renderBaselineOptions() {
  const sel = $("cmp-baseline");
  const cur = sel.value;
  const versions = selectedVersions();
  let html = '<option value="">(oldest selected — server default)</option>';
  for (let i = 0; i < versions.length; i++) {
    html += '<option value="' + TL.esc(versions[i]) + '">' +
      TL.esc(versions[i]) + "</option>";
  }
  sel.innerHTML = html;
  if (versions.indexOf(cur) >= 0) sel.value = cur;
}

// ── delta significance ──────────────────────────────────────────────────
//
// Prefer the server's verdict. When it is absent, fall back to a spread
// overlap test on the p5/p95 the server DID send — and say which test was
// used, so nobody mistakes a local heuristic for a server verdict.
function significance(g, baseline) {
  if (g.delta_exceeds_spread === true) return { sig: true, how: "server" };
  if (g.delta_exceeds_spread === false) return { sig: false, how: "server" };
  if (!baseline || g === baseline) return { sig: null, how: null };
  const lo = (x) => (x.p5 !== undefined && x.p5 !== null ? x.p5 : x.mean);
  const hi = (x) => (x.p95 !== undefined && x.p95 !== null ? x.p95 : x.mean);
  if (lo(g) === undefined || lo(baseline) === undefined) {
    return { sig: null, how: null };
  }
  const overlap = !(lo(g) > hi(baseline) || hi(g) < lo(baseline));
  return { sig: !overlap, how: "p5/p95 overlap (computed here)" };
}

function renderWarnings(resp) {
  const el = $("cmp-warnings");
  const w = (resp && resp.warnings) || [];
  if (!w.length) {
    el.className = "warn-box clean";
    el.innerHTML = "<b>no warnings</b> — the compared groups share their " +
      "comparison-relevant parameters" +
      (resp && resp.included_states
        ? " (states included: " + TL.esc(resp.included_states.join(", ")) + ")"
        : "");
    return;
  }
  let html = "<b>⚠ " + w.length + " warning" + (w.length > 1 ? "s" : "") +
    " — read these before believing any delta below</b><ul>";
  for (let i = 0; i < w.length; i++) html += "<li>" + TL.esc(w[i]) + "</li>";
  html += "</ul>";
  el.className = "warn-box";
  el.innerHTML = html;
}

function renderChart(resp) {
  const groups = resp.groups || [];
  const x = [];
  const y = [];
  const plus = [];
  const minus = [];
  const colors = [];
  let haveErr = false;
  for (let i = 0; i < groups.length; i++) {
    const g = groups[i];
    x.push(g.version + (g.rtl_tag ? "<br>" + g.rtl_tag : ""));
    y.push(g.mean);
    const p95 = (g.p95 === undefined || g.p95 === null) ? g.mean : g.p95;
    const p5 = (g.p5 === undefined || g.p5 === null) ? g.mean : g.p5;
    plus.push(Math.max(0, p95 - g.mean));
    minus.push(Math.max(0, g.mean - p5));
    if (p95 !== g.mean || p5 !== g.mean) haveErr = true;
    colors.push(g.version === resp.baseline
      ? TL.COLORS.accent : TL.COLORS.master);
  }
  const trace = {
    x: x, y: y, type: "bar", marker: { color: colors },
    name: resp.metric,
    hovertemplate: "%{x}<br>%{y}<extra></extra>",
  };
  if (haveErr) {
    trace.error_y = { type: "data", symmetric: false, array: plus,
                      arrayminus: minus, color: TL.COLORS.mute,
                      thickness: 1.4, width: 6 };
  }
  Plotly.react(CHART, [trace], Object.assign({}, TL.LAYOUT_BASE, {
    title: resp.metric + " by version (baseline highlighted, whiskers p5–p95)",
    showlegend: false,
    xaxis: { gridcolor: TL.COLORS.grid },
    yaxis: { title: resp.metric, rangemode: "tozero",
             gridcolor: TL.COLORS.grid },
    margin: { t: 40, r: 16, b: 60, l: 66 },
  }), TL.PLOT_CFG);
}

function renderTable(resp) {
  const groups = resp.groups || [];
  let baseline = null;
  for (let i = 0; i < groups.length; i++) {
    if (groups[i].version === resp.baseline) baseline = groups[i];
  }
  let html = "<table class=\"cmp-table\"><thead><tr>" +
    "<th>version</th><th>rtl tag</th><th>commit</th><th>n</th>" +
    "<th>mean</th><th>median</th><th>p5</th><th>p95</th><th>stdev</th>" +
    "<th>Δ vs baseline</th><th>provenance</th></tr></thead><tbody>";
  for (let i = 0; i < groups.length; i++) {
    const g = groups[i];
    const isBase = g.version === resp.baseline;
    let deltaCell;
    if (isBase || g.delta_vs_baseline_pct === null ||
        g.delta_vs_baseline_pct === undefined) {
      deltaCell = '<td class="muted">' + (isBase ? "baseline" : "—") + "</td>";
    } else {
      const d = Number(g.delta_vs_baseline_pct);
      const sg = significance(g, baseline);
      const txt = (d >= 0 ? "+" : "") + d.toFixed(1) + "%";
      if (sg.sig === false) {
        deltaCell = '<td class="delta-noise" title="the difference does not ' +
          'exceed the run-to-run spread (' + TL.esc(sg.how) +
          ') — not a demonstrated improvement">' + TL.esc(txt) +
          " <span class=\"muted\">within noise</span></td>";
      } else {
        const cls = d >= 0 ? "delta-up" : "delta-down";
        const title = sg.sig === true
          ? "exceeds the run-to-run spread (" + sg.how + ")"
          : "significance not reported by the server and not computable " +
            "from the spread — treat with care";
        deltaCell = '<td class="' + cls + '" title="' + TL.esc(title) + '">' +
          TL.esc(txt) + (sg.sig === true ? "" :
            " <span class=\"muted\">?</span>") + "</td>";
      }
    }
    // Provenance the server already computed — a mixed params_key or a
    // different fifo_label means the two bars are not the same experiment.
    const prov = [];
    if (g.params_keys && g.params_keys.length > 1) {
      prov.push('<span class="warn-text">MIXED params_key (' +
        g.params_keys.length + ")</span>");
    } else if (g.params_key) {
      prov.push('<span class="muted">' + TL.esc(g.params_key) + "</span>");
    }
    if (g.fifo_labels && g.fifo_labels.length > 1) {
      prov.push('<span class="warn-text">MIXED fifo_label</span>');
    } else if (g.fifo_label) {
      prov.push('<span class="muted">fifo ' + TL.esc(g.fifo_label) + "</span>");
    }
    if (g.error_runs) {
      prov.push('<span class="warn-text">' + TL.esc(g.errors) +
        " agent error(s) in " + TL.esc(g.error_runs) + " run(s)</span>");
    }
    if (g.runs_total !== undefined && Number(g.runs_total) !== Number(g.n)) {
      prov.push('<span class="warn-text">' +
        (Number(g.runs_total) - Number(g.n)) +
        " run(s) had no value for this metric</span>");
    }

    html += "<tr" + (isBase ? ' class="baseline-row"' : "") + ">" +
      "<td>" + TL.esc(g.version) + "</td>" +
      "<td>" + TL.esc(g.rtl_tag || "—") + "</td>" +
      "<td>" + TL.esc(g.source_commit ? String(g.source_commit).slice(0, 8) : "—") + "</td>" +
      '<td class="' + (Number(g.n) < 3 ? "warn-text" : "") + '">' +
      TL.esc(g.n) + "</td>" +
      "<td>" + stat(g.mean) + "</td>" +
      "<td>" + stat(g.median) + "</td>" +
      "<td>" + stat(g.p5) + "</td>" +
      "<td>" + stat(g.p95) + "</td>" +
      "<td>" + stat(g.stdev) + "</td>" +
      deltaCell +
      '<td class="prov">' + prov.join("<br>") + "</td></tr>";
  }
  html += "</tbody></table>";
  html += '<div class="muted">params_key: ' +
    TL.esc(resp.params_key || "(not pinned — deltas may be confounded)") +
    " · test: " + TL.esc(resp.test) +
    (resp.included_states
      ? " · states: " + TL.esc(resp.included_states.join(", ")) : "") +
    "</div>";
  $("cmp-table").innerHTML = html;
}

async function runCompare() {
  const versions = selectedVersions();
  const test = $("cmp-test").value.trim();
  const metric = $("cmp-metric").value.trim();
  const paramsKey = $("cmp-params").value.trim();
  const baseline = $("cmp-baseline").value;
  if (!test) { note("pick a test", "warn"); return; }
  let url = "/api/compare?test=" + encodeURIComponent(test) +
            "&metric=" + encodeURIComponent(metric);
  if (versions.length) url += "&versions=" + encodeURIComponent(versions.join(","));
  if (paramsKey) url += "&params_key=" + encodeURIComponent(paramsKey);
  if (baseline) url += "&baseline=" + encodeURIComponent(baseline);
  note("comparing…");
  try {
    const resp = await TL.jget(url);
    C.last = resp;
    note("");
    renderWarnings(resp);
    renderChart(resp);
    renderTable(resp);
    $("cmp-results").classList.remove("hidden");
    if (!resp.groups || !resp.groups.length) {
      note("no completed runs matched that selection.", "warn");
    }
  } catch (e) {
    if (e.status === 404) {
      note("/api/compare is not available on this server build.", "warn");
    } else {
      note("compare error (" + e.status + "): " +
           (e.detail || e.message), "warn");
    }
  }
}

async function loadTests() {
  try {
    const reg = await TL.jget("/api/tests");
    const sel = $("cmp-test");
    let html = "";
    for (const k in reg) {
      html += '<option value="' + TL.esc(k) + '">' + TL.esc(k) + "</option>";
    }
    if (html) sel.innerHTML = html;
  } catch (e) { /* keep the hardcoded default */ }
}

window.addEventListener("DOMContentLoaded", function () {
  const dl = $("cmp-metrics");
  let html = "";
  for (let i = 0; i < METRICS.length; i++) {
    html += '<option value="' + METRICS[i] + '">';
  }
  dl.innerHTML = html;
  $("cmp-refresh").addEventListener("click", loadVersions);
  $("cmp-go").addEventListener("click", runCompare);
  loadTests();
});

let loaded = false;
TL.bus.on("tab", function (name) {
  if (name !== "compare") return;
  TL.resizeCharts([CHART]);
  if (!loaded) { loaded = true; loadVersions(); }
});

})();
