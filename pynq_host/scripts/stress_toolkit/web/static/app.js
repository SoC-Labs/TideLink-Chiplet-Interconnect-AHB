// TideLink stress_toolkit browser client.
// Vanilla JS + Plotly. ~400 LoC. No build step.
"use strict";

const els = {
  runForm:        document.getElementById("run-form"),
  stageDir:       document.getElementById("stage-dir"),
  masterIp:       document.getElementById("master-ip"),
  slaveIp:        document.getElementById("slave-ip"),
  board:          document.getElementById("board"),
  skipDeploy:     document.getElementById("skip-deploy"),
  skipConverge:   document.getElementById("skip-converge"),
  phySentinel:    document.getElementById("phy-sentinel"),
  runBtn:         document.getElementById("run-btn"),
  abortBtn:       document.getElementById("abort-btn"),
  refreshLease:   document.getElementById("refresh-lease-btn"),
  banner:         document.getElementById("banner"),
  log:            document.getElementById("event-log"),
  leaseInfo:      document.getElementById("lease-info"),
  leaseHolder:    document.getElementById("lease-holder"),
  statsTable:     document.querySelector("#stats-table tbody"),
  chartTitle:     document.getElementById("chart-title"),
  fcsmMaster:     document.getElementById("fcsm-master"),
  fcsmSlave:      document.getElementById("fcsm-slave"),
  tabs:           document.getElementById("tabs"),
};

let currentRunId = null;
let currentEventSource = null;
let currentMode = "packet";

// PTP chart series
const ptpSeries = { x: [], y: [] };
// PHY noise chart per lane
const phySeries = Array.from({ length: 8 }, () => ({ x: [], y: [] }));

function logEvent(kind, payload) {
  const ts = new Date().toLocaleTimeString();
  const line = `${ts}  ${kind.padEnd(20)}  ${JSON.stringify(payload).slice(0, 200)}\n`;
  els.log.textContent += line;
  els.log.scrollTop = els.log.scrollHeight;
}

function setBanner(stateName, text) {
  els.banner.className = "banner state-" + stateName;
  els.banner.textContent = text;
}

function setRunning(running) {
  els.runBtn.disabled = running;
  els.abortBtn.disabled = !running;
}

function renderStats(d) {
  const rows = [];
  for (const k of Object.keys(d)) {
    let v = d[k];
    if (typeof v === "number") v = v.toFixed ? v.toFixed(2) : v;
    if (Array.isArray(v)) v = v.join(", ");
    if (v !== null && typeof v === "object") v = JSON.stringify(v);
    rows.push(`<tr><td>${k}</td><td>${v}</td></tr>`);
  }
  els.statsTable.innerHTML = rows.join("");
}

function plotPtpOffset() {
  const trace = {
    x: ptpSeries.x, y: ptpSeries.y,
    type: "scatter", mode: "lines+markers",
    line: { color: "#58a6ff" },
    marker: { size: 4 },
    name: "offset (ns)",
  };
  const layout = {
    margin: { l: 60, r: 10, t: 10, b: 40 },
    paper_bgcolor: "#161b22",
    plot_bgcolor: "#161b22",
    font: { color: "#c9d1d9", size: 11 },
    xaxis: { title: "elapsed (s)" },
    yaxis: { title: "offset slave-master (ns)" },
    shapes: [{ type: "line", x0: 0, x1: 1, xref: "paper",
               y0: 0, y1: 0, line: { color: "#56d364", width: 1, dash: "dot" } }],
  };
  Plotly.react("plot-main", [trace], layout,
               { displayModeBar: false, responsive: true });
}

function plotPhyNoise() {
  const traces = phySeries.map((s, i) => ({
    x: s.x, y: s.y, type: "scatter", mode: "lines",
    name: `L${i}`,
  }));
  const layout = {
    margin: { l: 50, r: 10, t: 10, b: 40 },
    paper_bgcolor: "#161b22",
    plot_bgcolor: "#161b22",
    font: { color: "#c9d1d9", size: 11 },
    xaxis: { title: "sample" },
    yaxis: { title: "noise (dist)", range: [0, 16] },
    legend: { orientation: "h" },
  };
  Plotly.react("plot-main", traces, layout,
               { displayModeBar: false, responsive: true });
}

function resetChart() {
  ptpSeries.x = []; ptpSeries.y = [];
  for (const s of phySeries) { s.x.length = 0; s.y.length = 0; }
  Plotly.react("plot-main", [], {
    margin: { l: 60, r: 10, t: 10, b: 40 },
    paper_bgcolor: "#161b22",
    plot_bgcolor: "#161b22",
    font: { color: "#c9d1d9", size: 11 },
  }, { displayModeBar: false, responsive: true });
}

function renderFcsm(boardKey, ls) {
  if (!ls) return;
  const txt = [
    `raw            : 0x${(ls.raw >>> 0).toString(16).padStart(8, "0")}`,
    `locked_mask    : 0x${ls.locked_mask.toString(16).padStart(2, "0")} (${ls.locked}/8)`,
    `fault_mask     : 0x${ls.fault_mask.toString(16).padStart(2, "0")}`,
    `cal_done       : ${ls.cal_done}`,
    `fcsm_state     : ${ls.fcsm_state}${ls.link_idle ? " (LINK_IDLE)" : " (NOT IDLE!)"}`,
    `ll_rx_state    : ${ls.ll_rx_state}`,
    `cr_pkt_seen    : ${ls.cr_pkt_seen}`,
    `crack_pkt_seen : ${ls.crack_pkt_seen}`,
    `llrx_valid     : ${ls.llrx_valid}`,
  ].join("\n");
  if (boardKey === "master") els.fcsmMaster.textContent = txt;
  else els.fcsmSlave.textContent = txt;
}

// ── SSE event handlers ────────────────────────────────────────────────

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
  if (eventName === "lease_acquired") {
    setBanner("running", `Lease acquired (${data.holder})`);
    refreshLease();
  }
  if (eventName === "lease_lost") {
    setBanner("failed", `lease lost: ${data.reason}`);
  }

  if (eventName === "deploy") {
    const dk = data.deploy_kind || "deploy";
    if (dk === "lane_count" && data.count != null) {
      setBanner("converging",
        `converging: ${data.count}/${data.max || 16} lanes`);
    } else if (dk === "deploy_failed") {
      setBanner("failed", `deploy failed: ${data.reason || "?"}`);
    } else if (dk === "bringup_failed") {
      setBanner("failed", `bringup failed`);
    } else if (dk === "bringup_started") {
      setBanner("converging", "bringup_pair_converge running");
    }
  }

  // Packet stress
  if (eventName === "packet_stress_progress" || eventName === "packet_stress_done") {
    renderStats(data);
    els.chartTitle.textContent = "AHB packet throughput";
  }
  if (eventName === "packet_stress_done") {
    if ((data.errors || 0) === 0) setBanner("done", "AHB packet stress: PASS");
    else setBanner("failed", `AHB packet stress: ${data.errors} errors`);
  }
  if (eventName === "packet_fcsm_alarm") {
    setBanner("failed", `FCSM left LINK_IDLE during AHB stress (iter ${data.iteration})`);
  }

  // Doorbell
  if (eventName === "doorbell_progress" || eventName === "doorbell_done") {
    renderStats(data);
  }
  if (eventName === "doorbell_done") {
    const results = data.results || [];
    const ok = results.every(r => r.ok);
    setBanner(ok ? "done" : "failed",
      `Doorbell: ${ok ? "PASS" : "FAIL"} (sent ${data.total_sent})`);
  }

  // PTP
  if (eventName === "ptp_sample") {
    ptpSeries.x.push(data.elapsed_s);
    ptpSeries.y.push(data.offset_ns);
    els.chartTitle.textContent = "PTP offset (slave - master)";
    plotPtpOffset();
    renderStats({
      elapsed_s: data.elapsed_s,
      offset_ns: data.offset_ns,
      locked: data.locked,
      locked_streak: data.locked_streak,
    });
  }
  if (eventName === "ptp_baseline") {
    setBanner("running", `PTP baseline offset=${data.offset_ns} ns`);
  }
  if (eventName === "ptp_done") {
    const v = data.verdict;
    setBanner(v === "PASS" ? "done" : "failed",
      `PTP: ${v} (streak ${data.locked_streak}/${data.required})`);
  }

  // PHY health
  if (eventName === "phy_health_sample" || eventName === "phy_sentinel") {
    const ev = data.sentinel_kind || eventName;
    if (ev === "phy_health_sample") {
      const m = data.master;
      if (m && m.noise_voted) {
        const t = phySeries[0].x.length;
        for (let i = 0; i < 8; i++) {
          phySeries[i].x.push(t);
          phySeries[i].y.push(m.noise_voted[i]);
          if (phySeries[i].x.length > 300) {
            phySeries[i].x.shift();
            phySeries[i].y.shift();
          }
        }
        els.chartTitle.textContent = "PHY noise (voted) — master";
        plotPhyNoise();
        renderStats({
          noise_raw_master: m.noise_raw.join(","),
          noise_voted_master: m.noise_voted.join(","),
          wiring_master: m.wiring_status.join(","),
          canary_master: m.canary_pass.join(","),
          anomalies_m: (data.master_anomalies || []).join("; "),
          anomalies_s: (data.slave_anomalies || []).join("; "),
        });
      }
    }
  }
  if (eventName === "phy_health_anomaly") {
    setBanner("failed",
      `PHY anomaly: ${(data.master || []).concat(data.slave || []).join("; ")}`);
  }

  // FCSM
  if (eventName === "fcsm_sample" || eventName === "fcsm_transition") {
    renderFcsm("master", data.master);
    renderFcsm("slave", data.slave);
    if (eventName === "fcsm_transition") {
      setBanner("failed",
        `FCSM transition: master=${data.master?.fcsm_state} slave=${data.slave?.fcsm_state}`);
    }
  }

  // Auto
  if (eventName === "auto_pick") {
    setBanner("running", `AUTO: picked ${data.mode} (elapsed ${data.elapsed_s.toFixed(1)}s)`);
  }
  if (eventName === "auto_step_done") {
    renderStats({ last_mode: data.mode, last_verdict: data.verdict,
                  elapsed_s: data.elapsed_s });
  }
  if (eventName === "auto_summary") {
    setBanner("done", "AUTO complete");
    renderStats({
      elapsed_s: data.elapsed_s,
      summary: JSON.stringify(data.summary),
    });
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
  if (currentEventSource) currentEventSource.close();
  const url = `/api/runs/${encodeURIComponent(runId)}/events`;
  const es = new EventSource(url);
  currentEventSource = es;
  const names = [
    "state", "lease_acquired", "lease_lost", "deploy", "closed", "ping",
    "packet_stress_progress", "packet_stress_done", "packet_error",
    "packet_fcsm_alarm",
    "doorbell_progress", "doorbell_done", "doorbell_error",
    "ptp_phase", "ptp_baseline", "ptp_sample", "ptp_done",
    "ptp_warn", "ptp_failed",
    "phy_health_sample", "phy_health_anomaly", "phy_health_warn",
    "phy_sentinel", "phy_sentinel_error",
    "fcsm_sample", "fcsm_transition", "fcsm_warn",
    "auto_pick", "auto_step_done", "auto_summary",
    "auto_health_alarm", "auto_exception",
  ];
  names.forEach(n => es.addEventListener(n, (e) => handleEvent(n, e.data)));
  es.onerror = () => {
    setBanner("failed", "SSE connection lost");
    setRunning(false);
    es.close();
    currentEventSource = null;
  };
}

// ── Form / tab wiring ─────────────────────────────────────────────────

function selectTab(mode) {
  currentMode = mode;
  document.querySelectorAll(".tab").forEach(b => {
    b.classList.toggle("active", b.dataset.mode === mode);
  });
  document.querySelectorAll(".tab-panel").forEach(p => {
    p.hidden = p.dataset.mode !== mode;
  });
}

els.tabs.addEventListener("click", (e) => {
  const tgt = e.target;
  if (tgt && tgt.classList.contains("tab")) {
    selectTab(tgt.dataset.mode);
  }
});

document.querySelectorAll(".preset").forEach(b => {
  b.addEventListener("click", () => {
    document.getElementById("pkt-size").value = b.dataset.size;
  });
});

function readModeBody() {
  const body = {
    mode: currentMode,
    stage_dir: els.stageDir.value,
    master_ip: els.masterIp.value,
    slave_ip: els.slaveIp.value,
    board: els.board.value,
    skip_deploy: els.skipDeploy.checked,
    skip_converge: els.skipConverge.checked,
    enable_phy_sentinel: els.phySentinel.checked,
  };
  if (currentMode === "packet") {
    body.packet = {
      packet_size_words: parseInt(document.getElementById("pkt-size").value, 10),
      packet_count:      parseInt(document.getElementById("pkt-count").value, 10),
      direction:         document.getElementById("pkt-direction").value,
      inter_packet_us:   parseFloat(document.getElementById("pkt-gap-us").value),
    };
  } else if (currentMode === "doorbell") {
    body.doorbell = {
      doorbell_count: parseInt(document.getElementById("db-count").value, 10),
      rate_hz:        parseFloat(document.getElementById("db-rate").value),
      direction:      document.getElementById("db-direction").value,
    };
  } else if (currentMode === "ptp") {
    body.ptp = {
      duration_s:        parseFloat(document.getElementById("ptp-duration").value),
      sample_period_s:   parseFloat(document.getElementById("ptp-period").value),
      offset_ok_ns:      parseInt(document.getElementById("ptp-thresh").value, 10),
      lock_hold_samples: parseInt(document.getElementById("ptp-hold").value, 10),
    };
  } else if (currentMode === "phy") {
    body.phy = {
      poll_period_s: parseFloat(document.getElementById("phy-period").value),
      duration_s:    parseFloat(document.getElementById("phy-duration").value),
    };
  } else if (currentMode === "fcsm") {
    body.fcsm = {
      poll_period_s: parseFloat(document.getElementById("fcsm-period").value),
      duration_s:    parseFloat(document.getElementById("fcsm-duration").value),
    };
  } else if (currentMode === "auto") {
    body.auto = {
      duration_s: parseFloat(document.getElementById("auto-duration").value),
      seed:       parseInt(document.getElementById("auto-seed").value, 10),
    };
  }
  return body;
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

async function startRun(e) {
  e.preventDefault();
  resetChart();
  renderStats({});
  els.log.textContent = "";
  els.fcsmMaster.textContent = "--";
  els.fcsmSlave.textContent = "--";
  setBanner("lease_acquiring", `starting ${currentMode}...`);
  setRunning(true);

  const body = readModeBody();
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
    setBanner("failed", "a run is already in flight — abort it first");
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
  setBanner("aborted", "aborting...");
  await fetch(`/api/runs/${encodeURIComponent(currentRunId)}/abort`, {
    method: "POST",
  });
}

els.runForm.addEventListener("submit", startRun);
els.abortBtn.addEventListener("click", abortRun);
els.refreshLease.addEventListener("click", refreshLease);

window.addEventListener("beforeunload", () => {
  if (currentRunId) navigator.sendBeacon(`/api/lease/release`);
});

selectTab("packet");
resetChart();
refreshLease();
