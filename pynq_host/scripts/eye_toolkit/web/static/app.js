// TideLink live-eye browser client.
// Vanilla JS + Plotly. ~250 LoC. No build step.
"use strict";

const N_PHASES = 16;
const N_LANES = 8;

const els = {
  runForm:        document.getElementById("run-form"),
  stageDir:       document.getElementById("stage-dir"),
  masterIp:       document.getElementById("master-ip"),
  slaveIp:        document.getElementById("slave-ip"),
  board:          document.getElementById("board"),
  skipDeploy:     document.getElementById("skip-deploy"),
  skipConverge:   document.getElementById("skip-converge"),
  runBtn:         document.getElementById("run-btn"),
  abortBtn:       document.getElementById("abort-btn"),
  refreshLease:   document.getElementById("refresh-lease-btn"),
  banner:         document.getElementById("banner"),
  log:            document.getElementById("event-log"),
  leaseInfo:      document.getElementById("lease-info"),
  leaseHolder:    document.getElementById("lease-holder"),
  masterLabel:    document.getElementById("master-label"),
  slaveLabel:     document.getElementById("slave-label"),
};

let currentRunId = null;
let currentEventSource = null;

function emptyMatrix() {
  const m = [];
  for (let p = 0; p < N_PHASES; p++) {
    m.push(new Array(N_LANES).fill(null));
  }
  return m;
}

const matrices = {
  master: emptyMatrix(),
  slave:  emptyMatrix(),
};

function plotHeatmap(divId, mat) {
  const z = mat.map(row => row.slice());
  const data = [{
    z,
    x: ["L0","L1","L2","L3","L4","L5","L6","L7"],
    y: Array.from({length: N_PHASES}, (_, i) => i),
    type: "heatmap",
    zmin: 0, zmax: 1,
    colorscale: [[0, "#5a1015"], [0.5, "#5a4015"], [1, "#1f6f3a"]],
    showscale: false,
    hovertemplate: "phase %{y}<br>lane %{x}<br>lock=%{z}<extra></extra>",
  }];
  const layout = {
    margin: { l: 50, r: 10, t: 10, b: 40 },
    paper_bgcolor: "#161b22",
    plot_bgcolor:  "#161b22",
    font: { color: "#c9d1d9", size: 11 },
    xaxis: { title: "lane", side: "bottom" },
    yaxis: { title: "swi_phase_offset", autorange: "reversed" },
  };
  Plotly.react(divId, data, layout, { displayModeBar: false, responsive: true });
}

function resetMatrices() {
  matrices.master = emptyMatrix();
  matrices.slave = emptyMatrix();
  plotHeatmap("plot-master", matrices.master);
  plotHeatmap("plot-slave", matrices.slave);
}

function applySweepRow(ev) {
  const mat = matrices[ev.board];
  if (!mat) return;
  const phase = ev.phase;
  const mask = ev.lock_mask;
  for (let lane = 0; lane < N_LANES; lane++) {
    mat[phase][lane] = (mask >> lane) & 1;
  }
  plotHeatmap(ev.board === "master" ? "plot-master" : "plot-slave", mat);
}

function setBanner(stateName, text) {
  els.banner.className = "banner state-" + stateName;
  els.banner.textContent = text;
}

function logEvent(kind, payload) {
  const ts = new Date().toLocaleTimeString();
  const line = `${ts}  ${kind.padEnd(16)}  ${JSON.stringify(payload)}\n`;
  els.log.textContent += line;
  els.log.scrollTop = els.log.scrollHeight;
}

function setRunning(running) {
  els.runBtn.disabled = running;
  els.abortBtn.disabled = !running;
}

async function refreshLease() {
  const board = els.board.value || "bridge1";
  try {
    const r = await fetch(`/api/lease?board=${encodeURIComponent(board)}`);
    if (!r.ok) {
      els.leaseInfo.className = "lease-pill state-unknown";
      els.leaseHolder.textContent = `error ${r.status}`;
      return;
    }
    const j = await r.json();
    els.leaseInfo.className = "lease-pill state-" + (j.state || "unknown");
    if (j.state === "held") {
      els.leaseHolder.textContent = `${j.holder} (queue ${j.queue_length})`;
    } else {
      els.leaseHolder.textContent = `${j.state} (queue ${j.queue_length})`;
    }
  } catch (e) {
    els.leaseHolder.textContent = "fetch error";
  }
}

function handleEvent(eventName, dataStr) {
  let data;
  try { data = JSON.parse(dataStr); } catch (e) { return; }
  logEvent(eventName, data);

  if (eventName === "ping") return;

  if (eventName === "state" || data.state) {
    const s = data.state || "unknown";
    const txt = data.reason ? `${s}: ${data.reason}` : s;
    setBanner(s, `state: ${txt}`);
  }
  if (eventName === "sweep_row") {
    applySweepRow(data);
  }
  if (eventName === "lease_acquired") {
    setBanner("sweeping",
      `Lease acquired (holder=${data.holder}). Deploying...`);
    refreshLease();
  }
  if (eventName === "deploy") {
    const dk = data.deploy_kind || "deploy";
    if (dk === "lane_count" && data.count != null) {
      setBanner("converging",
        `converging: ${data.count}/${data.max || 16} lanes (iter ${data.iteration ?? "?"})`);
    } else if (dk === "deploy_failed") {
      setBanner("failed", `deploy failed: ${data.reason || "?"}`);
    } else if (dk === "bringup_failed") {
      setBanner("failed",
        `bringup did not converge (max retries reached)`);
    } else if (dk === "deploying" || dk === "deployed") {
      setBanner("deploying", `${dk} on ${data.board || "?"}`);
    } else if (dk === "bringup_started") {
      setBanner("converging", "bringup_pair_converge running");
    } else if (dk === "unreachable") {
      setBanner("failed", `board unreachable`);
    }
  }
  if (eventName === "lease_lost") {
    setBanner("failed", `lease lost: ${data.reason}`);
  }
  if (eventName === "closed") {
    setRunning(false);
    if (currentEventSource) {
      currentEventSource.close();
      currentEventSource = null;
    }
    refreshLease();
  }
}

function subscribe(runId) {
  if (currentEventSource) {
    currentEventSource.close();
  }
  const url = `/api/runs/${encodeURIComponent(runId)}/events`;
  const es = new EventSource(url);
  currentEventSource = es;
  ["state", "lease_acquired", "lease_lost", "deploy", "sweep_row",
   "closed", "ping"].forEach((name) => {
    es.addEventListener(name, (e) => handleEvent(name, e.data));
  });
  es.onerror = () => {
    setBanner("failed", "SSE connection lost");
    setRunning(false);
    es.close();
    currentEventSource = null;
  };
}

async function startRun(e) {
  e.preventDefault();
  resetMatrices();
  els.log.textContent = "";
  setBanner("lease_acquiring", "starting…");
  setRunning(true);

  const body = {
    stage_dir:   els.stageDir.value,
    master_ip:   els.masterIp.value,
    slave_ip:    els.slaveIp.value,
    board:       els.board.value,
    skip_deploy: els.skipDeploy.checked,
    skip_converge: els.skipConverge.checked,
  };
  els.masterLabel.textContent = body.master_ip;
  els.slaveLabel.textContent = body.slave_ip;

  let r;
  try {
    r = await fetch("/api/runs", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (exc) {
    setBanner("failed", `network error: ${exc}`);
    setRunning(false);
    return;
  }
  if (r.status === 409) {
    setBanner("failed",
      "a run is already in flight — abort it first");
    setRunning(false);
    return;
  }
  if (!r.ok) {
    setBanner("failed", `start failed: HTTP ${r.status}`);
    setRunning(false);
    return;
  }
  const j = await r.json();
  currentRunId = j.run_id;
  subscribe(currentRunId);
}

async function abortRun() {
  if (!currentRunId) return;
  setBanner("aborted", "aborting…");
  await fetch(`/api/runs/${encodeURIComponent(currentRunId)}/abort`, {
    method: "POST",
  });
}

els.runForm.addEventListener("submit", startRun);
els.abortBtn.addEventListener("click", abortRun);
els.refreshLease.addEventListener("click", refreshLease);

window.addEventListener("beforeunload", () => {
  if (currentRunId) {
    navigator.sendBeacon(`/api/lease/release`);
  }
});

resetMatrices();
refreshLease();
