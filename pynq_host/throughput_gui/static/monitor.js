// TideLink GUI — Link Monitor view.
//
// Subscribes to /api/monitor/events (SSE, event names mon/perf/status/ping)
// and degrades to 1 Hz polling of /api/monitor/state when the stream errors
// — the documented degrade path of the sibling toolkits.
//
// EVERY displayed field is decoded server-side by regmap.decode_monitor().
// There is deliberately NO bit-slicing in this file: a second, divergent
// decode in the browser is exactly how an instrument starts lying, and this
// project has already burned five debugging sagas on instrument bugs.
"use strict";

(function () {

const DIES = ["master", "slave"];
const CHART_CREDIT = "chart-mon-credit";
const CHART_PAIR = "chart-mon-pair";
const CHART_WORDS = "chart-mon-words";
const CHART_PERF = "chart-mon-perf";
const MON_CHARTS = [CHART_CREDIT, CHART_PAIR, CHART_WORDS];

const S = {
  es: null,
  poll: null,
  transport: "off",          // off | sse | poll | unavailable
  session: "idle",
  t0: null,
  charts: false,
  perfSeen: false,
  perfEnabled: false,
  perfWindows: { master: null, slave: null },
  faults: { master: {}, slave: {} },
  last: { master: null, slave: null },
  soakRunning: false,
  relThresholdParam: true,   // does the server's param schema accept it?
};

const FAULT_KEYS = [
  ["overrun", "STICKY overrun — an RX-FIFO write was dropped. The write " +
              "side has no hardware backpressure, so this means the credit " +
              "protocol was violated; the data stream is NOT trustworthy."],
  ["underrun", "STICKY underrun — the data window was read with no packet " +
               "present (a read got phantom/stale data)."],
  ["master_error", "STICKY master_error — the AHB returner saw an ERROR " +
                   "response."],
];

// ── little builders ─────────────────────────────────────────────────────

function chip(text, cls, title) {
  return '<span class="chip ' + cls + '" title="' + TL.esc(title || "") +
         '">' + TL.esc(text) + "</span>";
}

function kv(label, value, title) {
  return '<div class="kv" title="' + TL.esc(title || "") + '">' +
         '<span class="kv-k">' + TL.esc(label) + "</span>" +
         '<span class="kv-v">' + TL.esc(value) + "</span></div>";
}

function gauge(label, value, max, note, cls) {
  const frac = (max > 0 && value !== undefined && value !== null)
    ? Math.max(0, Math.min(1, Number(value) / max)) : 0;
  const shown = (value === undefined || value === null) ? "—" : TL.num(value);
  return '<div class="gauge">' +
    '<div class="gauge-head"><span>' + TL.esc(label) + "</span>" +
    '<span class="gauge-val">' + TL.esc(shown) +
    (max ? " / " + TL.num(max) : "") + "</span></div>" +
    '<div class="gauge-track"><div class="gauge-fill ' + (cls || "") +
    '" style="width:' + (frac * 100).toFixed(2) + '%"></div></div>' +
    '<div class="gauge-note">' + TL.esc(note || "") + "</div></div>";
}

// ── normalisation (SSE event and /state snapshot may differ in shape) ───

function normalizeDie(o) {
  if (!o) return null;
  if (o.dec || o.health || o.derived || o.raw) {
    return {
      dec: o.dec || {},
      health: o.health || null,
      derived: o.derived || {},
      raw: o.raw || {},
      sticky: o.sticky || {},
      perf_window: o.perf_window || null,
      seq: o.seq,
      t: o.t,
      stale: !!o.stale || o.state === "stale" || o.state === "failed",
      reason: o.reason || null,
    };
  }
  // A flat decoded dict (server chose to inline decode_monitor output).
  const dec = {};
  for (const k in o) {
    if (k !== "health" && k !== "stale" && k !== "sticky") dec[k] = o[k];
  }
  return { dec: dec, health: o.health || null, derived: {}, raw: {},
           sticky: o.sticky || {}, perf_window: null, stale: !!o.stale };
}

// ── chips ───────────────────────────────────────────────────────────────

function dieChips(dec, health) {
  const out = [];

  if (health) {
    if (health.jam) {
      out.push(chip("JAM " + health.jam, "bad",
        "jam signature reported by the server (classify_jam) — see " +
        "scripts/unjam_fc_node.sh"));
    }
    out.push(chip(
      health.link_up
        ? "link UP" + (health.criterion ? " (crit " + health.criterion + ")" : "")
        : "link DOWN",
      health.link_up ? "ok" : "bad",
      (health.reasons && health.reasons.length)
        ? health.reasons.join(" · ")
        : "single-die verdict from regmap.health()"));
  } else {
    out.push(chip("health n/a", "mute",
      "the server did not send a health object for this die"));
  }

  const fcsm = dec.fcsm;
  if (fcsm === undefined) {
    out.push(chip("fcsm —", "mute", "SWI_LANE_STATUS absent from this poll"));
  } else {
    out.push(chip("fcsm=" + fcsm, (fcsm === 4 || fcsm === 5) ? "ok" : "bad",
      "4 = LINK_IDLE, 5 = LINK_DATA. FCSM healthy is NOT proof that data " +
      "crosses — it is a necessary condition only."));
  }

  if (dec.cal_done === undefined) {
    out.push(chip("cal —", "mute", "not in this poll"));
  } else {
    out.push(chip("cal=" + dec.cal_done, dec.cal_done ? "ok" : "bad",
      "cal_done from SWI_LANE_STATUS[16]" +
      (dec.cal_state !== undefined ? "; cal FSM state " + dec.cal_state : "")));
  }

  if (dec.lock_count === undefined) {
    out.push(chip("lanes —", "mute", "not in this poll"));
  } else {
    const lk = dec.lock_count;
    out.push(chip("lanes " + lk + "/8",
      lk === 8 ? "ok" : (lk === 0 ? "info" : "warn"),
      lk === 0
        ? "lane_locked reads 0 once swi_training_mode clears — EXPECTED in " +
          "data mode (criterion B), not a fault"
        : "locked mask 0x" + (dec.locked_mask || 0).toString(16) +
          ", fault mask 0x" + (dec.fault_mask || 0).toString(16)));
  }

  if (dec.mask_hs_match === undefined) {
    out.push(chip("mask_hs —", "mute", "OBS_MASK_HS absent from this poll"));
  } else {
    out.push(chip("mask_hs " + (dec.mask_hs_match ? "match" : "NO match"),
      dec.mask_hs_match ? "ok" : "warn",
      "OBS_MASK_HS[19]: did this die actually match the peer's lane mask?"));
  }

  if (dec.gate_open === undefined) {
    out.push(chip("gate —", "mute", "OBS_MASK_HS absent from this poll"));
  } else if (dec.gate_open && dec.mask_hs_match === 0) {
    // The distinction this register exists for: a forced-open gate is not
    // autonomy. Amber, never green.
    out.push(chip("gate FORCED", "warn",
      "gate_open=1 with mask_hs_match=0 — the gate was strapped/forced " +
      "open rather than earned. Data may still cross, but this is NOT " +
      "genuine autonomy and must not be reported as such."));
  } else if (dec.gate_open) {
    out.push(chip("gate open (earned)", "ok",
      "gate_open=1 with mask_hs_match=1 — handshake genuinely completed"));
  } else {
    out.push(chip("gate closed", "mute", "gate_open=0"));
  }

  if (dec.training === undefined) {
    out.push(chip("train —", "mute", "SWI_TRAINING_MODE absent"));
  } else {
    out.push(chip("train " + (dec.training ? "on" : "off"),
      dec.training ? "info" : "mute",
      "SWI_TRAINING_MODE[0]" +
      (dec.training_live !== undefined
        ? "; live training_mode in the calibrator = " + dec.training_live : "")));
  }

  if (dec.epoch_anchored === undefined) {
    out.push(chip("epoch —", "mute", "SWI_EPOCH_STATUS absent"));
  } else if (dec.epoch_anchored) {
    out.push(chip("epoch ✓ span " + dec.epoch_span, "ok",
      "epoch anchored, span " + dec.epoch_span + " words (V2 only)"));
  } else {
    out.push(chip("epoch —", "mute",
      "not anchored. V2-only register: a V1 image has the eye block here " +
      "and reads 0, so this is not evidence of a fault."));
  }

  return out.join("");
}

// ── per-die panel ───────────────────────────────────────────────────────

function renderDie(die, entry) {
  const el = $("die-" + die);
  if (!el) return;
  if (!entry) {
    el.innerHTML = '<div class="die-head"><h3>' + die +
      '</h3></div><div class="muted">no data yet</div>';
    return;
  }
  const dec = entry.dec || {};
  const derived = entry.derived || {};
  const credit = dec.credit_count;
  const creditCls = credit === undefined ? ""
    : (credit < 0.05 * 4096 ? "fill-bad"
       : (credit < 0.25 * 4096 ? "fill-warn" : "fill-ok"));

  let html = '<div class="die-head"><h3>' + TL.esc(die) + "</h3>" +
    (entry.stale
      ? '<span class="chip bad" title="' + TL.esc(
          "the agent channel for this die died" +
          (entry.reason ? " (" + entry.reason + ")" : "") +
          "; the values below are the last ones received") +
        '">STALE</span>'
      : "") +
    (entry.seq !== undefined
      ? '<span class="seq">seq ' + TL.esc(entry.seq) + "</span>" : "") +
    "</div>";

  html += '<div class="chips">' + dieChips(dec, entry.health) + "</div>";

  html += gauge("free credits (CREDIT_COUNT)", credit, 4096,
    "credits FREE in this die's RX FIFO — NOT occupancy. " +
    (dec.occupancy !== undefined
      ? "occupancy = 4096 − free = " + TL.num(dec.occupancy) + " words" : ""),
    creditCls);

  html += gauge("pair credits (toward peer)", dec.pair_credits, 4096,
    "credits this die may spend on the peer's RX FIFO", "fill-accent");

  html += kv("RELEASE_ACC", TL.num(dec.release_acc),
    "credits freed but still below RELEASE_THRESHOLD — a large value that " +
    "never drains is the POR-threshold=20 starvation signature");
  html += kv("CRC errors", dec.crc_errors === undefined
    ? "not read" : TL.num(dec.crc_errors),
    dec.crc_errors === undefined
      ? "enable 'read CRC' in the monitor controls to poll the Wlink FC " +
        "node CRC counter"
      : "Wlink FC node CRC error count, accumulating (not read-clear)");

  html += '<div class="kv-grid">';
  html += kv("pkt word len", TL.num(dec.pkt_word_len));
  html += kv("sync_detected", TL.num(dec.sync_detected));
  html += kv("occupancy", TL.num(dec.occupancy));
  html += kv("cal state", TL.num(dec.cal_state));
  html += kv("cal resweeps", TL.num(dec.cal_resweep_ctr));
  html += kv("fe_rx credit max", TL.num(dec.fe_rx_credit_max));
  html += kv("fe_rx ptr", TL.num(dec.fe_rx_ptr));
  html += kv("fe_rx full", TL.num(dec.fe_rx_is_full));
  html += kv("llrx state", TL.num(dec.llrx_state));
  html += kv("cr_seen", TL.num(dec.cr_seen));
  html += kv("committed", TL.num(dec.packet_committed));
  html += kv("returner busy", TL.num(dec.returner_busy));
  html += kv("fc obs live", dec.fc_obs_live === undefined ? "—"
    : (dec.fc_obs_live ? "yes (0xFC marker)" : "no (old image)"));
  if (dec.ctrl_lock !== undefined) {
    html += kv("CTRL.LOCK", dec.ctrl_lock ? "SET" : "clear",
      dec.ctrl_lock ? "RELEASE_THRESHOLD writes are blocked on this die"
                    : "RELEASE_THRESHOLD is writable");
  }
  if (dec.sync_lane_mask !== undefined) {
    html += kv("sync lane mask", "0x" + Number(dec.sync_lane_mask).toString(16),
      "lanes on which SYNC was detected (V2 obs)");
  }
  html += kv("PHY align id", dec.phy_align_id || "—");
  if (derived.pair_credit_rate !== undefined) {
    html += kv("pair credit rate", TL.num(derived.pair_credit_rate, 1) + " /s");
  }
  if (derived.sync_rate !== undefined) {
    html += kv("sync rate", TL.num(derived.sync_rate, 1) + " /s");
  }
  html += "</div>";

  if (entry.health && entry.health.reasons && entry.health.reasons.length) {
    html += '<ul class="reasons">';
    for (let i = 0; i < entry.health.reasons.length; i++) {
      html += "<li>" + TL.esc(entry.health.reasons[i]) + "</li>";
    }
    html += "</ul>";
  }

  if (entry.raw && Object.keys(entry.raw).length) {
    html += "<details class=\"raw\"><summary>raw registers</summary><pre>";
    const keys = Object.keys(entry.raw).sort();
    for (let i = 0; i < keys.length; i++) {
      html += TL.esc(keys[i] + "  " + entry.raw[keys[i]]) + "\n";
    }
    html += "</pre></details>";
  }

  el.innerHTML = html;
}

// ── sticky faults ───────────────────────────────────────────────────────

// `sticky` is the server's own session latch (overrun_seen/...): it carries
// faults that fired BEFORE this browser attached, which a client-side latch
// alone would silently miss.
function updateFaults(die, dec, sticky) {
  const latch = S.faults[die];
  let changed = false;
  for (let i = 0; i < FAULT_KEYS.length; i++) {
    const key = FAULT_KEYS[i][0];
    const live = !!dec[key];
    const seen = live || !!(sticky && sticky[key + "_seen"]);
    if (seen) {
      if (!latch[key]) {
        latch[key] = { first: TL.clock(), count: 0, acked: false,
                       live: live, earlier: !live };
        changed = true;
      }
      latch[key].count += 1;
      if (latch[key].live !== live) changed = true;
      latch[key].live = live;
      latch[key].last = TL.clock();
    } else if (latch[key] && latch[key].live) {
      // Only CTRL.FLUSH can clear these in hardware; if we ever see a 0
      // after a 1, keep the record — it happened.
      latch[key].live = false;
      changed = true;
    }
  }
  if (changed) renderFaults();
}

function anyFault(pred) {
  for (let d = 0; d < DIES.length; d++) {
    const latch = S.faults[DIES[d]];
    for (const k in latch) { if (pred(latch[k])) return true; }
  }
  return false;
}

function renderFaults() {
  const el = $("mon-faults");
  if (!el) return;
  const rows = [];
  for (let d = 0; d < DIES.length; d++) {
    const die = DIES[d];
    const latch = S.faults[die];
    for (let i = 0; i < FAULT_KEYS.length; i++) {
      const key = FAULT_KEYS[i][0];
      const f = latch[key];
      if (!f) continue;
      rows.push('<li title="' + TL.esc(FAULT_KEYS[i][1]) + '"><b>' +
        TL.esc(key.toUpperCase()) + "</b> on <b>" + TL.esc(die) +
        "</b> — " + (f.earlier
          ? "latched by the server before this page attached, first shown "
          : "first seen ") + TL.esc(f.first) +
        (f.live ? ", still asserted in hardware"
                : ", no longer reading back (a CTRL.FLUSH happened)") +
        (f.acked ? " · acknowledged" : "") +
        "<br><span class=\"muted\">" + TL.esc(FAULT_KEYS[i][1]) +
        "</span></li>");
    }
  }
  if (!rows.length) {
    el.className = "fault-banner hidden";
    el.innerHTML = "";
    return;
  }
  const unacked = anyFault((f) => !f.acked);
  el.className = "fault-banner " + (unacked ? "alarm" : "acked");
  el.innerHTML =
    '<div class="fault-head"><b>' +
    (unacked ? "STICKY FAULT LATCHED" : "sticky fault (acknowledged)") +
    "</b><button type=\"button\" id=\"fault-ack\">acknowledge</button></div>" +
    "<ul>" + rows.join("") + "</ul>" +
    '<div class="muted">These bits are sticky in hardware (cleared only by ' +
    "CTRL.FLUSH). Acknowledging mutes the alarm; it never clears the " +
    "record, and a new fault re-arms it.</div>";
  const btn = $("fault-ack");
  if (btn) {
    btn.addEventListener("click", function () {
      for (let d = 0; d < DIES.length; d++) {
        const latch = S.faults[DIES[d]];
        for (const k in latch) latch[k].acked = true;
      }
      renderFaults();
    });
  }
}

// ── charts ──────────────────────────────────────────────────────────────

function ensureCharts() {
  if (S.charts) return;
  const base = TL.LAYOUT_BASE;
  Plotly.newPlot(CHART_CREDIT, [
    { x: [], y: [], name: "master free credits", mode: "lines",
      line: { color: TL.COLORS.master } },
    { x: [], y: [], name: "slave free credits", mode: "lines",
      line: { color: TL.COLORS.slave } },
  ], Object.assign({}, base, {
    title: "Free credits (CREDIT_COUNT, max 4096)",
    yaxis: { title: "credits free", rangemode: "tozero",
             gridcolor: TL.COLORS.grid },
  }), TL.PLOT_CFG);

  Plotly.newPlot(CHART_PAIR, [
    { x: [], y: [], name: "master pair credits", mode: "lines",
      line: { color: TL.COLORS.master } },
    { x: [], y: [], name: "slave pair credits", mode: "lines",
      line: { color: TL.COLORS.slave } },
  ], Object.assign({}, base, {
    title: "Pair credits (toward peer)",
    yaxis: { title: "credits", rangemode: "tozero",
             gridcolor: TL.COLORS.grid },
  }), TL.PLOT_CFG);

  Plotly.newPlot(CHART_WORDS, [
    { x: [], y: [], name: "master TX words/s", mode: "lines",
      line: { color: TL.COLORS.master } },
    { x: [], y: [], name: "slave RX words/s (delivered)", mode: "lines",
      line: { color: TL.COLORS.slave } },
  ], Object.assign({}, base, {
    title: "Delivered words/s (from run samples)",
    yaxis: { title: "words/s", rangemode: "tozero",
             gridcolor: TL.COLORS.grid },
  }), TL.PLOT_CFG);

  S.charts = true;
}

function clock() {
  if (S.t0 === null) S.t0 = Date.now();
  return (Date.now() - S.t0) / 1000;
}

// ── stream handling ─────────────────────────────────────────────────────

function setTransport(kind, note) {
  S.transport = kind;
  const el = $("mon-transport");
  if (!el) return;
  const map = {
    off: ["idle", "mute"],
    sse: ["stream (SSE)", "ok"],
    poll: ["polling 1 Hz (stream dropped)", "warn"],
    unavailable: ["monitor API not available", "bad"],
  };
  const m = map[kind] || map.off;
  el.className = "chip " + m[1];
  el.textContent = m[0];
  el.title = note || "";
}

function setSession(st) {
  S.session = st;
  const el = $("mon-state");
  if (!el) return;
  el.textContent = "session: " + st;
  el.className = "chip " + (st === "running" ? "ok"
    : (st === "failed" ? "bad" : "mute"));
}

function note(msg, cls) {
  const el = $("mon-note");
  if (!el) return;
  el.className = "mon-note " + (cls || "");
  el.innerHTML = msg ? TL.esc(msg) : "";
}

function onMon(ev) {
  const die = ev.die;
  if (DIES.indexOf(die) < 0) return;
  const entry = normalizeDie(ev);
  S.last[die] = entry;
  renderDie(die, entry);
  updateFaults(die, entry.dec || {}, entry.sticky);
  ensureCharts();
  const t = clock();
  const idx = die === "master" ? 0 : 1;
  if (entry.dec && entry.dec.credit_count !== undefined) {
    TL.extend(CHART_CREDIT, [idx], [t], [entry.dec.credit_count]);
  }
  if (entry.dec && entry.dec.pair_credits !== undefined) {
    TL.extend(CHART_PAIR, [idx], [t], [entry.dec.pair_credits]);
  }
}

function onSnapshot(snap) {
  if (!snap) return;
  if (snap.state) setSession(snap.state);
  const dies = snap.dies || {};
  for (let i = 0; i < DIES.length; i++) {
    const die = DIES[i];
    const entry = normalizeDie(dies[die]);
    if (!entry) continue;
    entry.die = die;
    S.last[die] = entry;
    renderDie(die, entry);
    updateFaults(die, entry.dec || {}, entry.sticky);
    // Polling fallback: the perf window rides inside the die snapshot.
    if (entry.perf_window && entry.perf_window.utilisation !== undefined
        && entry.perf_window.utilisation !== null) {
      onPerf({ die: die, window: entry.perf_window });
    }
    ensureCharts();
    const t = clock();
    if (entry.dec.credit_count !== undefined) {
      TL.extend(CHART_CREDIT, [i], [t], [entry.dec.credit_count]);
    }
    if (entry.dec.pair_credits !== undefined) {
      TL.extend(CHART_PAIR, [i], [t], [entry.dec.pair_credits]);
    }
  }
  if (snap.errors) {
    note("monitor reported " + snap.errors + " read error(s)", "warn");
  }
}

function attachSSE() {
  if (S.es) { try { S.es.close(); } catch (e) { } S.es = null; }
  let opened = false;
  const es = new EventSource("/api/monitor/events");
  S.es = es;
  es.onopen = function () { opened = true; setTransport("sse"); };
  es.addEventListener("mon", function (m) {
    opened = true;
    setTransport("sse");
    try { onMon(JSON.parse(m.data)); } catch (e) { console.error(e); }
  });
  es.addEventListener("perf", function (m) {
    try { onPerf(JSON.parse(m.data)); } catch (e) { console.error(e); }
  });
  es.addEventListener("status", function (m) {
    try {
      const d = JSON.parse(m.data);
      if (d.state) setSession(d.state);
      if (d.state === "stopped" || d.state === "failed") stopStream();
    } catch (e) { console.error(e); }
  });
  es.addEventListener("ping", function () { setTransport("sse"); });
  // Not in the frozen contract, but the agent emits mon_err on a failed
  // read; surface it if the server chooses to forward it.
  es.addEventListener("mon_err", function (m) {
    try {
      const d = JSON.parse(m.data);
      note("read error on " + (d.die || "a die") + ": " +
           (d.reason || "unknown"), "warn");
    } catch (e) { /* ignore */ }
  });
  es.onerror = function () {
    // Documented degrade path: drop to 1 Hz polling rather than sitting
    // on a dead stream. A manual "retry stream" button re-arms SSE.
    try { es.close(); } catch (e) { }
    S.es = null;
    startPolling(opened
      ? "the event stream dropped"
      : "the event stream never opened");
  };
}

function stopStream() {
  if (S.es) { try { S.es.close(); } catch (e) { } S.es = null; }
  if (S.poll) { clearInterval(S.poll); S.poll = null; }
  setTransport("off");
}

async function pollOnce() {
  try {
    const snap = await TL.jget("/api/monitor/state");
    onSnapshot(snap);
  } catch (e) {
    if (e.status === 404) {
      markUnavailable();
    } else {
      note("poll error: " + e.message, "warn");
    }
  }
}

function startPolling(why) {
  if (S.poll) return;
  setTransport("poll", why || "");
  note((why ? why + " — " : "") +
       "falling back to 1 Hz polling of /api/monitor/state.", "warn");
  pollOnce();
  S.poll = setInterval(pollOnce, 1000);
}

function markUnavailable() {
  stopStream();
  setTransport("unavailable");
  setSession("idle");
  note("The monitor API (/api/monitor/*) is not available on this server " +
       "build. The Run and Compare tabs are unaffected.", "warn");
}

// ── phase-B perf ────────────────────────────────────────────────────────

function pickWindow(d) {
  const cands = [d, d.window, d.win, d.derived, d.perf, d.dec];
  for (let i = 0; i < cands.length; i++) {
    const c = cands[i];
    if (c && c.utilisation !== undefined && c.utilisation !== null) return c;
  }
  return null;
}

function onPerf(d) {
  const w = pickWindow(d);
  if (!w) return;               // an empty window means "no data", not 0%
  const die = DIES.indexOf(d.die) >= 0 ? d.die : "master";
  S.perfWindows[die] = w;
  S.perfSeen = true;
  renderPerf();
}

function renderPerf() {
  const panel = $("perf-panel");
  const missing = $("perf-missing");
  if (!panel) return;
  if (!S.perfSeen) {
    panel.classList.add("hidden");
    if (missing) {
      missing.classList.remove("hidden");
      missing.textContent = S.perfEnabled
        ? "No perf window has arrived. Utilisation is UNKNOWN — the " +
          "deployed image predates the PERF_CTRL decode fix, so the " +
          "counters never advance. \"Counters read zero\" is not \"the " +
          "link is 0% busy\", so nothing is plotted."
        : "Phase-B perf sampling is not enabled for this session (tick " +
          "\"sample perf counters\" before starting). PERF_ID proves the " +
          "block exists; it does not prove PERF_CTRL is writable.";
    }
    return;
  }
  if (missing) missing.classList.add("hidden");
  panel.classList.remove("hidden");

  let html = "";
  const yLabels = [];
  const busy = [];
  const stall = [];
  const rest = [];
  for (let i = 0; i < DIES.length; i++) {
    const die = DIES[i];
    const w = S.perfWindows[die];
    if (!w) continue;
    const util = Number(w.utilisation);
    const tx = Number(w.tx_stall_frac || 0);
    const remainder = Math.max(0, 1 - util - tx);
    yLabels.push(die);
    busy.push(util * 100);
    stall.push(tx * 100);
    rest.push(remainder * 100);

    let perWord = null;
    if (w.d_sample && w.d_rx_words) {
      perWord = (util * Number(w.d_sample)) / Number(w.d_rx_words);
    }
    html += '<div class="perf-die"><h4>' + TL.esc(die) + "</h4>" +
      kv("utilisation", TL.pct(w.utilisation),
         "ΔLINK_BUSY / ΔSAMPLE_COUNT over one frozen window") +
      kv("TX stall", TL.pct(w.tx_stall_frac)) +
      kv("RX stall", TL.pct(w.rx_stall_frac)) +
      kv("credit starve", TL.pct(w.credit_starve_frac)) +
      kv("Δsample", TL.num(w.d_sample)) +
      kv("Δwords rx", TL.num(w.d_rx_words)) +
      kv("link-busy cycles / delivered word",
         perWord === null ? "—" : TL.num(perWord, 2),
         "the metric that moves when wire efficiency improves — " +
         "delivered words/s will NOT, because the PS bus is the " +
         "bottleneck on this rig") +
      "</div>";
  }
  const grid = $("perf-grid");
  if (grid) grid.innerHTML = html;

  if (yLabels.length) {
    Plotly.react(CHART_PERF, [
      { x: busy, y: yLabels, name: "link busy", type: "bar",
        orientation: "h", marker: { color: TL.COLORS.slave } },
      { x: stall, y: yLabels, name: "TX stall", type: "bar",
        orientation: "h", marker: { color: TL.COLORS.accent } },
      { x: rest, y: yLabels, name: "remainder (PS round trip)", type: "bar",
        orientation: "h", marker: { color: TL.COLORS.mute } },
    ], Object.assign({}, TL.LAYOUT_BASE, {
      title: "Where each word's time goes (% of sampled cycles)",
      barmode: "stack",
      xaxis: { title: "% of window", range: [0, 100],
               gridcolor: TL.COLORS.grid },
      yaxis: { gridcolor: TL.COLORS.grid },
      margin: { t: 36, r: 16, b: 40, l: 70 },
    }), TL.PLOT_CFG);
  }
}

// ── monitor session control ─────────────────────────────────────────────

async function startMonitor() {
  const body = {
    period_ms: Number($("mon-period").value),
    perf: $("mon-perf").checked,
    crc: $("mon-crc").checked,
  };
  S.perfEnabled = body.perf;
  note("");
  setSession("starting");
  const res = await TL.jpost("/api/monitor/start", body);
  if (res.status === 404) { markUnavailable(); return; }
  if (!res.ok && res.status !== 409) {
    setSession("failed");
    note("start refused (" + res.status + "): " +
         (res.json && res.json.detail ? res.json.detail : "unknown"), "warn");
    return;
  }
  if (res.status === 409) {
    note("a monitor session was already running — attached to it.", "");
  }
  setSession((res.json && res.json.state) || "running");
  $("mon-start").disabled = true;
  $("mon-stop").disabled = false;
  ensureCharts();
  renderPerf();
  attachSSE();
}

async function stopMonitor() {
  const res = await TL.jpost("/api/monitor/stop", {});
  stopStream();
  if (res.status === 404) { markUnavailable(); return; }
  setSession((res.json && res.json.state) || "stopped");
  $("mon-start").disabled = false;
  $("mon-stop").disabled = true;
}

// ── load generator ──────────────────────────────────────────────────────

function syncN(from) {
  const slider = $("lg-n");
  const box = $("lg-n-box");
  let n = Number(from === "box" ? box.value : slider.value);
  if (isNaN(n)) n = 16;
  n = Math.max(1, Math.min(256, Math.round(n)));
  slider.value = n;
  box.value = n;
  const eff = n / (n + 2);
  $("lg-eff").innerHTML =
    "header efficiency <b>N/(N+2) = " + n + "/" + (n + 2) + " = " +
    TL.pct(eff, 1) + "</b>" +
    '<span class="muted"> · wire payload efficiency stays 25% ' +
    "(32 useful bits per 128-bit beat) whatever N is</span>";
}

function setThr(v) {
  $("lg-thr").value = v;
  renderThrNote();
}

function renderThrNote() {
  const v = Number($("lg-thr").value);
  const el = $("lg-thr-note");
  if (!el) return;
  if (v < 0) {
    el.textContent = "-1 = leave the deployed image's threshold alone.";
    el.className = "muted";
  } else if (v === 0) {
    el.textContent = "0 = release credits on every drain (the setting that " +
      "keeps the credit loop alive on small drains).";
    el.className = "ok-text";
  } else if (v === 20) {
    el.textContent = "20 = the RTL POR. Small drains free fewer than 20 " +
      "credits and return NOTHING, so the sender starves — this is the " +
      "setting that produced the 'dead recycle' signature.";
    el.className = "warn-text";
  } else {
    el.textContent = "credits are only returned once " + v +
      " have been freed.";
    el.className = "muted";
  }
}

function soakParams() {
  const params = {
    burst_words: Number($("lg-n-box").value),
    duration_s: Number($("lg-duration").value),
    win_s: Number($("lg-win").value),
    rate_pps: Number($("lg-rate").value),
  };
  if (S.relThresholdParam) {
    params.rel_threshold = Number($("lg-thr").value);
  }
  return params;
}

async function startSoak() {
  const el = $("lg-result");
  el.textContent = "";
  el.className = "lg-result";
  let res = await TL.run.start({ test: "throughput_m2s",
                                 params: soakParams() });
  if (!res.ok && res.status === 400 && res.json && res.json.detail &&
      String(res.json.detail).indexOf("rel_threshold") >= 0) {
    // Older server build: the run schema has no rel_threshold. Retry
    // without it and say so rather than silently dropping the control.
    S.relThresholdParam = false;
    res = await TL.run.start({ test: "throughput_m2s",
                               params: soakParams() });
    el.textContent = "this server build does not accept rel_threshold as a " +
      "run parameter — the soak ran with the image's own threshold.";
    el.className = "lg-result warn-text";
  }
  if (!res.ok) {
    el.textContent = "refused (" + res.status + "): " +
      (res.json && res.json.detail ? res.json.detail : "unknown");
    el.className = "lg-result warn-text";
    return;
  }
  if (!el.textContent) {
    el.textContent = "run " + res.json.run_id + " admitted (criterion " +
      res.json.criterion + ") — see the Run tab for the full event log.";
    el.className = "lg-result ok-text";
  }
}

async function stopSoak() {
  await TL.run.abort();
}

// Delivered words/s comes from the run stream, not from a second poller.
TL.bus.on("run:sample", function (s) {
  ensureCharts();
  const t = clock();
  const win = Number(s.win_s) || 0;
  if (!win) return;
  if (s.board === "master") {
    TL.extend(CHART_WORDS, [0], [t], [Number(s.words_tx || 0) / win]);
  } else {
    TL.extend(CHART_WORDS, [1], [t], [Number(s.words_rx || 0) / win]);
  }
});

TL.bus.on("run:running", function (running) {
  S.soakRunning = running;
  const a = $("lg-start");
  const b = $("lg-stop");
  if (a) a.disabled = running;
  if (b) b.disabled = !running;
});

TL.bus.on("run:rel_threshold", function (d) {
  const el = $("lg-result");
  if (!el) return;
  const got = d.rel_threshold;
  const wrote = d.wrote;
  if (got !== undefined && wrote !== undefined && got !== wrote) {
    el.textContent = "RELEASE_THRESHOLD readback " + got + " ≠ requested " +
      wrote + " — the measurement does NOT reflect the requested threshold.";
    el.className = "lg-result warn-text";
  } else if (got !== undefined) {
    el.textContent = "RELEASE_THRESHOLD applied and read back = " + got + ".";
    el.className = "lg-result ok-text";
  }
});

TL.bus.on("tab", function (name) {
  if (name !== "monitor") return;
  ensureCharts();
  TL.resizeCharts(MON_CHARTS.concat([CHART_PERF]));
  if (S.transport === "off" && S.session === "idle") probeOnce();
});

// One read-only probe so an already-running session (or a server without
// the monitor API) is reflected before the operator clicks anything.
let probed = false;
async function probeOnce() {
  if (probed) return;
  probed = true;
  try {
    const snap = await TL.jget("/api/monitor/state");
    onSnapshot(snap);
    if (snap.state === "running") {
      $("mon-start").disabled = true;
      $("mon-stop").disabled = false;
      attachSSE();
    }
  } catch (e) {
    if (e.status === 404) markUnavailable();
  }
}

// Offline verification hook. Feeding a recorded/synthetic event through
// the SAME render path is how this view gets checked when the monitor API
// is absent (and how a shape mismatch with the server gets caught early).
// Display path only — it can neither read nor write a board.
TL.monitor = {
  onMon: onMon, onSnapshot: onSnapshot, onPerf: onPerf, _state: S,
};

window.addEventListener("DOMContentLoaded", function () {
  $("mon-start").addEventListener("click", startMonitor);
  $("mon-stop").addEventListener("click", stopMonitor);
  $("mon-retry").addEventListener("click", function () {
    if (S.poll) { clearInterval(S.poll); S.poll = null; }
    note("");
    attachSSE();
  });
  $("lg-n").addEventListener("input", function () { syncN("slider"); });
  $("lg-n-box").addEventListener("input", function () { syncN("box"); });
  $("lg-thr").addEventListener("input", renderThrNote);
  $("lg-thr-por").addEventListener("click", function () { setThr(20); });
  $("lg-thr-zero").addEventListener("click", function () { setThr(0); });
  $("lg-thr-leave").addEventListener("click", function () { setThr(-1); });
  $("lg-start").addEventListener("click", startSoak);
  $("lg-stop").addEventListener("click", stopSoak);
  syncN("box");
  renderThrNote();
  setTransport("off");
  setSession("idle");
  renderDie("master", null);
  renderDie("slave", null);
  renderPerf();
  ensureCharts();
});

})();
