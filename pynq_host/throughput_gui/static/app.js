// TideLink throughput GUI — Run view (the original P0 client).
// Vanilla JS + Plotly (vendored). No build step. Pattern per
// stress_toolkit/static/app.js (SSE + Plotly.extendTraces).
//
// Shared helpers ($, TL) come from common.js. Behaviour of this view is
// unchanged from P0; the only additions are (a) publishing run events on
// TL.bus so the Link Monitor can draw delivered-words/s from the same
// stream, and (b) exposing TL.run so the monitor's soak controls drive
// this ONE execution path (/api/runs) instead of inventing a second.
"use strict";

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
  TL.bus.emit("run:running", running);
}

// ── Charts ────────────────────────────────────────────────────────────────

const LAYOUT_BASE = TL.LAYOUT_BASE;

function initCharts() {
  Plotly.newPlot("chart-tput", [
    { x: [], y: [], name: "master TX (M→S)", mode: "lines+markers",
      line: { color: "#4ea1ff" } },
    { x: [], y: [], name: "slave RX (delivered)", mode: "lines+markers",
      line: { color: "#41d67c" } },
  ], Object.assign({}, LAYOUT_BASE, {
       title: "Throughput (payload Mbit/s)",
       yaxis: { title: "Mbit/s", rangemode: "tozero",
                gridcolor: "#222a36" } }),
    { displayModeBar: false, responsive: true });

  Plotly.newPlot("chart-credit", [
    { x: [], y: [], name: "pair credits (master)", mode: "lines",
      line: { color: "#e0b341" } },
    { x: [], y: [], name: "slave RX occupancy", mode: "lines",
      line: { color: "#d65454" } },
  ], Object.assign({}, LAYOUT_BASE, {
       title: "Credits / occupancy",
       yaxis: { title: "words", rangemode: "tozero",
                gridcolor: "#222a36" } }),
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
  TL.bus.emit("run:sample", s);
}

// ── API ───────────────────────────────────────────────────────────────────

async function jget(url) {
  return TL.jget(url);
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

// Single admission path shared by the Run form and the Link Monitor's
// load generator. Returns {ok, status, json}; on success the SSE stream
// is attached and the banner/buttons are already updated.
async function submitRun(body, onRefused) {
  $("gate-reason").textContent = "";
  const r = await fetch("/api/runs", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  let j = null;
  try { j = await r.json(); } catch (e) { j = {}; }
  if (!r.ok) {
    // 409 = mutex / run in flight, 412 = gate/lease/provenance refused
    const msg = `refused (${r.status}): ${j.detail}`;
    $("gate-reason").textContent = msg;
    setBanner("failed", `refused (${r.status})`);
    if (onRefused) onRefused(r.status, j.detail);
    return { ok: false, status: r.status, json: j };
  }
  currentRunId = j.run_id;
  $("csv-link").classList.add("hidden");
  resetCharts();
  setRunning(true);
  setBanner("running", `run ${j.run_id} admitted (criterion ${j.criterion})`);
  log("admitted", j);
  attachSSE(j.run_id);
  loadProvenance(j.run_id);
  TL.bus.emit("run:started", j);
  return { ok: true, status: r.status, json: j };
}

async function startRun(ev) {
  ev.preventDefault();
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
  await submitRun(body);
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
    TL.bus.emit("run:finished", { run_id: runId, state: state });
  };
  es.addEventListener("state", (m) => {
    const d = JSON.parse(m.data);
    log("state", d);
    TL.bus.emit("run:state", d);
    if (d.state === "done") {
      const mean = (d.summary && d.summary.throughput_mbps_mean !== undefined
                    && d.summary.throughput_mbps_mean !== null)
        ? d.summary.throughput_mbps_mean : "?";
      finish("done", `DONE — mean ${mean} Mbit/s`);
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
  es.addEventListener("rel_threshold", (m) => {
    const d = JSON.parse(m.data);
    log("rel_threshold", d);
    TL.bus.emit("run:rel_threshold", d);
  });
  es.addEventListener("log", (m) => log("log", JSON.parse(m.data)));
  es.addEventListener("closed", () => es && es.close());
  es.onerror = () => { /* keepalive gaps are fine; SSE auto-reconnects */ };
}

async function abortRun() {
  if (!currentRunId) return;
  await fetch(`/api/runs/${currentRunId}/abort`, { method: "POST" });
}

// Exposed for the Link Monitor's load generator — same endpoint, same
// gates, same in-flight slot.
TL.run = {
  start: submitRun,
  abort: abortRun,
  currentId: () => currentRunId,
  log: log,
};

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
    TL.bus.emit("health", h);
  } catch (e) { /* leave badge empty */ }
  refreshLink();
});

TL.bus.on("tab", (name) => {
  if (name === "run") TL.resizeCharts(["chart-tput", "chart-credit"]);
});
