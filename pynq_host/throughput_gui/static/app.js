// TideLink throughput GUI — browser client.
// Vanilla JS + Plotly (vendored). No build step. Pattern per
// stress_toolkit/static/app.js (SSE + Plotly.extendTraces).
"use strict";

const $ = (id) => document.getElementById(id);
let currentRunId = null;
let es = null;

function log(kind, payload) {
  const ts = new Date().toLocaleTimeString();
  $("event-log").textContent +=
    `${ts}  ${kind.padEnd(16)} ${JSON.stringify(payload).slice(0, 220)}\n`;
  $("event-log").scrollTop = $("event-log").scrollHeight;
}

function setBanner(state, text) {
  const b = $("banner");
  b.className = "banner state-" + state;
  b.textContent = text;
}

function setRunning(running) {
  $("run-btn").disabled = running;
  $("abort-btn").disabled = !running;
}

// ── Charts ────────────────────────────────────────────────────────────────

const LAYOUT_BASE = {
  margin: { t: 36, r: 16, b: 40, l: 56 },
  paper_bgcolor: "#11151c", plot_bgcolor: "#11151c",
  font: { color: "#c8d2e0", size: 11 },
  xaxis: { title: "t (s)", gridcolor: "#222a36" },
  showlegend: true,
  legend: { orientation: "h", y: 1.15 },
};

function initCharts() {
  Plotly.newPlot("chart-tput", [
    { x: [], y: [], name: "master TX (M→S)", mode: "lines+markers",
      line: { color: "#4ea1ff" } },
    { x: [], y: [], name: "slave RX (delivered)", mode: "lines+markers",
      line: { color: "#41d67c" } },
  ], { ...LAYOUT_BASE, title: "Throughput (payload Mbit/s)",
       yaxis: { title: "Mbit/s", rangemode: "tozero",
                gridcolor: "#222a36" } },
    { displayModeBar: false, responsive: true });

  Plotly.newPlot("chart-credit", [
    { x: [], y: [], name: "pair credits (master)", mode: "lines",
      line: { color: "#e0b341" } },
    { x: [], y: [], name: "slave RX occupancy", mode: "lines",
      line: { color: "#d65454" } },
  ], { ...LAYOUT_BASE, title: "Credits / occupancy",
       yaxis: { title: "words", rangemode: "tozero",
                gridcolor: "#222a36" } },
    { displayModeBar: false, responsive: true });
}

function resetCharts() {
  ["chart-tput", "chart-credit"].forEach((id) => Plotly.purge(id));
  initCharts();
}

function onSample(s) {
  const t = s.t_ns / 1e9;
  if (s.board === "master") {
    Plotly.extendTraces("chart-tput", { x: [[t]], y: [[s.throughput_mbps]] }, [0]);
    Plotly.extendTraces("chart-credit", { x: [[t]], y: [[s.credit_obs]] }, [0]);
  } else {
    Plotly.extendTraces("chart-tput", { x: [[t]], y: [[s.throughput_mbps]] }, [1]);
    Plotly.extendTraces("chart-credit", { x: [[t]], y: [[s.occupancy]] }, [1]);
  }
}

// ── API ───────────────────────────────────────────────────────────────────

async function jget(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return r.json();
}

async function refreshLink() {
  $("link-status").textContent = "probing…";
  try {
    const st = await jget("/api/link/status");
    $("link-status").textContent =
      (st.ok ? `UP (criterion ${st.criterion})` : "DOWN") +
      ` — ${st.reason}\n` + JSON.stringify(st.snapshot, null, 1);
  } catch (e) {
    $("link-status").textContent = "probe error: " + e;
  }
}

async function startRun(ev) {
  ev.preventDefault();
  $("gate-reason").textContent = "";
  const body = {
    test: "throughput_m2s",
    params: {
      burst_words: Number($("p-burst").value),
      duration_s: Number($("p-duration").value),
      win_s: Number($("p-win").value),
      rate_pps: Number($("p-rate").value),
    },
  };
  const ver = $("p-version").value.trim();
  if (ver) body.artefact_version = ver;

  const r = await fetch("/api/runs", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const j = await r.json();
  if (!r.ok) {
    // 409 = mutex / run in flight, 412 = gate/lease/provenance refused
    $("gate-reason").textContent = `refused (${r.status}): ${j.detail}`;
    setBanner("failed", `refused (${r.status})`);
    return;
  }
  currentRunId = j.run_id;
  $("csv-link").classList.add("hidden");
  resetCharts();
  setRunning(true);
  setBanner("running", `run ${j.run_id} admitted (criterion ${j.criterion})`);
  log("admitted", j);
  attachSSE(j.run_id);
  loadProvenance(j.run_id);
}

async function loadProvenance(runId) {
  try {
    const rec = await jget(`/api/runs/${runId}`);
    const p = rec.provenance;
    $("provenance").textContent =
      `version: ${p.artefact_version}  fifo: ${p.fifo_label}\n` +
      `master: ${p.master.label}\n  sha256 ${p.master.sha256.slice(0, 16)}…` +
      ` commit ${p.master.source_commit}\n` +
      `slave:  ${p.slave.label}\n  sha256 ${p.slave.sha256.slice(0, 16)}…\n` +
      `verified_on_board: ${p.verified_on_board}`;
  } catch (e) { /* non-fatal */ }
}

function attachSSE(runId) {
  if (es) es.close();
  es = new EventSource(`/api/runs/${runId}/events`);
  const finish = (state, msg) => {
    setRunning(false);
    setBanner(state, msg);
    $("csv-link").href = `/api/runs/${runId}/samples.csv`;
    $("csv-link").classList.remove("hidden");
    es.close();
  };
  es.addEventListener("state", (m) => {
    const d = JSON.parse(m.data);
    log("state", d);
    if (d.state === "done") {
      finish("done", `DONE — mean ${d.summary?.throughput_mbps_mean ?? "?"} Mbit/s`);
    } else if (d.state === "failed") {
      finish("failed", `FAILED — ${d.error}`);
    } else if (d.state === "aborted") {
      finish("aborted", "ABORTED");
    } else {
      setBanner("running", `run ${runId}: ${d.state}`);
    }
  });
  es.addEventListener("sample", (m) => onSample(JSON.parse(m.data)));
  es.addEventListener("delivery_proof", (m) => log("delivery_proof", JSON.parse(m.data)));
  es.addEventListener("agent_done", (m) => log("agent_done", JSON.parse(m.data)));
  es.addEventListener("log", (m) => log("log", JSON.parse(m.data)));
  es.addEventListener("closed", () => es && es.close());
  es.onerror = () => { /* keepalive gaps are fine; SSE auto-reconnects */ };
}

async function abortRun() {
  if (!currentRunId) return;
  await fetch(`/api/runs/${currentRunId}/abort`, { method: "POST" });
}

// ── wire-up ───────────────────────────────────────────────────────────────

window.addEventListener("DOMContentLoaded", async () => {
  initCharts();
  $("run-form").addEventListener("submit", startRun);
  $("abort-btn").addEventListener("click", abortRun);
  $("link-refresh").addEventListener("click", refreshLink);
  try {
    const h = await jget("/healthz");
    $("mode-badge").textContent = h.fake ? "FAKE MODE (no boards)" : "bridge1";
    $("mode-badge").className = "badge " + (h.fake ? "fake" : "real");
    if (h.default_artefact_version)
      $("p-version").placeholder = h.default_artefact_version + " (default)";
  } catch (e) { /* leave badge empty */ }
  refreshLink();
});
