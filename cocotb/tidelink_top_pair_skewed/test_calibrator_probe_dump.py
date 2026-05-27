"""Empirical sim probe: capture calibrator + PHY signal state during the
AUTOCAL=1 failure window in `tidelink_top_pair`.

Bug context
-----------
With `AUTOCAL_ENABLE=1` (the current default at `tidelink_top.sv:1630`),
M->S sideband packets never reach the slave's FC adapter RX in
`test_tidelink_pair_doorbell.test_05_doorbell_master_to_slave`. With AUTOCAL=0
the test passes. Both sides reach `cal=DONE` so the calibrator's reported
status is symmetric — but something about the *post*-DONE pad behaviour
differs between M and S.

This test reproduces the bringup chain from
`test_tidelink_pair_doorbell.py` (we IMPORT its helpers so the bringup
path is bit-identical) and then samples a wide signal set every cycle
for 2000 cycles immediately after the M->S doorbell write.

Outputs
-------
1. `docs/agent_d_probe_dump_autocal1.log` — CSV of per-cycle samples.
2. `docs/agent_d_probe_findings.md` — human summary: histograms,
   first-divergence cycle, M-vs-S asymmetries.
"""
import os
from pathlib import Path

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB,
    APB_DOORBELL,
    APB_DOORBELL_RESP_ACC,
    run_bringup_full,
)


# ---------------------------------------------------------------------------
# Output paths — anchor to TIDELINK_HOME so we land in the worktree's docs/
# even when the cocotb sim_build/ launches us from a deeper cwd.
# ---------------------------------------------------------------------------
_HERE = Path(__file__).resolve().parent
TIDELINK_HOME = Path(os.environ.get("TIDELINK_HOME", _HERE.parent.parent))
DOCS_DIR = TIDELINK_HOME / "docs"
# Skewed variant: write to dedicated paths so we don't clobber the
# zero-skew control logs in agent_d_*.
# The scenario suffix (e.g. "_biasfix", "_prefix") can be set via the
# AGENT_L_SCENARIO env var so the (A) and (B) runs land in separate files.
_SCENARIO = os.environ.get("AGENT_L_SCENARIO", "default")
DUMP_PATH = DOCS_DIR / f"agent_l_skewed_probe_dump_{_SCENARIO}.log"
FINDINGS_PATH = DOCS_DIR / f"agent_l_skewed_probe_findings_{_SCENARIO}.md"

PROBE_WINDOW_CYCLES = 2000


# ---------------------------------------------------------------------------
# Hierarchical probe accessors. All paths are validated at runtime — we catch
# AttributeError on the first sample and substitute None so a missing path
# does not abort the dump.
# ---------------------------------------------------------------------------

def _top(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _safe_int(handle):
    try:
        return int(handle.value)
    except (AttributeError, ValueError, TypeError):
        return None


# --- Calibrator interior -----------------------------------------------------
# Everything below the chiplet controller boundary needs the
# u_chiplet_controller intermediate hop. Without it cocotb raises
# AttributeError because tidelink_top exposes the calibrator only through
# u_chiplet_controller.
#

def _cc(dut, side):
    return _top(dut, side).u_chiplet_controller


def cal_training_mode_w(dut, side):
    """OR-mux output of cal_training_mode_w in chiplet_controller — drives
    swi_training_mode_w into Wlink.
    """
    return _safe_int(_cc(dut, side).cal_training_mode_w)


def cal_state_int(dut, side):
    return _safe_int(_cc(dut, side).cal_state_w)


def cal_done_w(dut, side):
    return _safe_int(_cc(dut, side).cal_calibration_done_w)


def cal_lane_fault_w(dut, side):
    return _safe_int(_cc(dut, side).cal_lane_fault_w)


def cal_phase_lane(dut, side, lane):
    """Per-lane latched phase reg inside the calibrator (post S_DONE)."""
    try:
        return int(_cc(dut, side).u_calibrator.phase[lane].value)
    except (AttributeError, ValueError, IndexError):
        return None


def cal_slip_lane(dut, side, lane):
    try:
        return int(_cc(dut, side).u_calibrator.slip[lane].value)
    except (AttributeError, ValueError, IndexError):
        return None


# --- Effective training-mode at PHY -----------------------------------------
# Path: u_chiplet_controller.u_wlink.phy.gpio.{effective_training_mode,
#                                              io_swi_training_mode_in}

def phy_effective_training_mode(dut, side):
    """The PHY-internal effective_training_mode = io_swi_training_mode_in |
    swi_training_mode. This is what actually gates the per-lane TX serialisers.
    """
    try:
        return int(_cc(dut, side).u_wlink.phy.gpio.effective_training_mode.value)
    except (AttributeError, ValueError):
        return None


def phy_swi_training_mode_in(dut, side):
    """Pre-mux PHY input from chiplet_controller (apb_clk domain)."""
    try:
        return int(_cc(dut, side).u_wlink.phy.gpio.io_swi_training_mode_in.value)
    except (AttributeError, ValueError):
        return None


# --- Lane checker locked[7:0] -----------------------------------------------

def lane_locked(dut, side):
    """8-bit per-lane lock from the wlink_lane_checker (rx_link_clk domain).
    The lane_checker lives inside the chiplet controller:
      u_<side>.u_chiplet_controller.u_lane_checker.lane_locked
    """
    try:
        return int(_top(dut, side).u_chiplet_controller.u_lane_checker.lane_locked.value)
    except (AttributeError, ValueError):
        return None


# --- 8-bit pad TX / pad RX (cross-wired) ------------------------------------

def m_pad_tx(dut):
    try:
        return int(dut.m_pad_tx.value)
    except (AttributeError, ValueError):
        return None


def s_pad_rx_seen(dut):
    """Slave's RX is wired from m_pad_tx via the m2s skid block. With
    SKID_BITS=0 default the skid is a passthrough so m_pad_tx_skid == m_pad_tx.
    """
    try:
        return int(dut.m_pad_tx_skid.value)
    except (AttributeError, ValueError):
        return None


def s_pad_tx(dut):
    try:
        return int(dut.s_pad_tx.value)
    except (AttributeError, ValueError):
        return None


def m_pad_rx_seen(dut):
    try:
        return int(dut.s_pad_tx_skid.value)
    except (AttributeError, ValueError):
        return None


# --- FC adapter --------------------------------------------------------------

def fc_a2l_valid(dut, side):
    try:
        return int(_top(dut, side).u_fc_adapter.tl_fc_a2l_valid.value)
    except (AttributeError, ValueError):
        return None


def fc_a2l_ready(dut, side):
    try:
        return int(_top(dut, side).u_fc_adapter.tl_fc_a2l_ready.value)
    except (AttributeError, ValueError):
        return None


def fc_l2a_valid(dut, side):
    try:
        return int(_top(dut, side).u_fc_adapter.tl_fc_l2a_valid.value)
    except (AttributeError, ValueError):
        return None


# --- Wlink FCSM cur_state ----------------------------------------------------

def fcsm_state(dut, side):
    """Wlink FCSM cur_state — at
    u_<side>.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state
    """
    try:
        return int(_cc(dut, side).u_wlink.tl2wl.wlink_tidelinktl.state.value)
    except (AttributeError, ValueError):
        return None


# ---------------------------------------------------------------------------
# Column schema for the per-cycle CSV. Each entry: (header, callable(dut)).
# ---------------------------------------------------------------------------

def _column_schema():
    cols = [
        ("cycle", None),  # filled by index
        ("m_cal_state", lambda d: cal_state_int(d, "m")),
        ("s_cal_state", lambda d: cal_state_int(d, "s")),
        ("m_cal_done", lambda d: cal_done_w(d, "m")),
        ("s_cal_done", lambda d: cal_done_w(d, "s")),
        ("m_cal_train_mode", lambda d: cal_training_mode_w(d, "m")),
        ("s_cal_train_mode", lambda d: cal_training_mode_w(d, "s")),
        ("m_phy_train_in", lambda d: phy_swi_training_mode_in(d, "m")),
        ("s_phy_train_in", lambda d: phy_swi_training_mode_in(d, "s")),
        ("m_phy_eff_train", lambda d: phy_effective_training_mode(d, "m")),
        ("s_phy_eff_train", lambda d: phy_effective_training_mode(d, "s")),
        ("m_lane_locked", lambda d: lane_locked(d, "m")),
        ("s_lane_locked", lambda d: lane_locked(d, "s")),
        ("m_lane_fault", lambda d: cal_lane_fault_w(d, "m")),
        ("s_lane_fault", lambda d: cal_lane_fault_w(d, "s")),
        ("m_pad_tx", m_pad_tx),
        ("s_pad_rx_seen", s_pad_rx_seen),
        ("s_pad_tx", s_pad_tx),
        ("m_pad_rx_seen", m_pad_rx_seen),
        ("m_fc_a2l_v", lambda d: fc_a2l_valid(d, "m")),
        ("m_fc_a2l_r", lambda d: fc_a2l_ready(d, "m")),
        ("m_fc_l2a_v", lambda d: fc_l2a_valid(d, "m")),
        ("s_fc_a2l_v", lambda d: fc_a2l_valid(d, "s")),
        ("s_fc_a2l_r", lambda d: fc_a2l_ready(d, "s")),
        ("s_fc_l2a_v", lambda d: fc_l2a_valid(d, "s")),
        ("m_fcsm_state", lambda d: fcsm_state(d, "m")),
        ("s_fcsm_state", lambda d: fcsm_state(d, "s")),
    ]
    # Per-lane phase + slip — only sampled lightly (start/end) to keep CSV
    # narrow. They are written into the findings doc rather than the CSV.
    return cols


def _format_value(v):
    if v is None:
        return "x"
    return f"{v}"


# ---------------------------------------------------------------------------
# The cocotb test
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_calibrator_probe_dump(dut):
    """Bring up the link with AUTOCAL=1 (default for tidelink_top), fire an
    M->S doorbell, and sample the full probe set for 2000 cycles.
    """
    DOCS_DIR.mkdir(parents=True, exist_ok=True)

    tb = PairTB(dut)
    dut._log.info("=== Calibrator probe dump (AUTOCAL=1) ===")
    dut._log.info(f"DUMP_PATH={DUMP_PATH}")
    dut._log.info(f"FINDINGS_PATH={FINDINGS_PATH}")

    # Run the existing bringup_full sequence: reset, role-lock, wait for
    # cal_done on both sides, drop training and run LL bootstrap. This is the
    # same path test_05_doorbell_master_to_slave uses.
    snap_p1, snap_p2 = await run_bringup_full(tb)
    dut._log.info(
        "Post-bringup snapshot: "
        f"M lane_locked=0x{snap_p2['m_lane_status'] & 0xff:02x} "
        f"S lane_locked=0x{snap_p2['s_lane_status'] & 0xff:02x} "
        f"M cal_done={(snap_p2['m_lane_status'] >> 16) & 1} "
        f"S cal_done={(snap_p2['s_lane_status'] >> 16) & 1} "
        f"M cr={snap_p2['m_cr_seen']} S cr={snap_p2['s_cr_seen']} "
        f"M pcc={snap_p2['m_pair_credit']} S pcc={snap_p2['s_pair_credit']}"
    )

    # Capture per-lane phase / slip values latched by the calibrators
    # immediately after S_DONE.
    m_phase = [cal_phase_lane(dut, "m", i) for i in range(8)]
    s_phase = [cal_phase_lane(dut, "s", i) for i in range(8)]
    m_slip = [cal_slip_lane(dut, "m", i) for i in range(8)]
    s_slip = [cal_slip_lane(dut, "s", i) for i in range(8)]
    dut._log.info(f"Calibrator latched M phase={m_phase} slip={m_slip}")
    dut._log.info(f"Calibrator latched S phase={s_phase} slip={s_slip}")

    # Read DOORBELL_RESP_ACC pre-doorbell.
    s_db_before = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_before = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    dut._log.info(f"Pre-doorbell DOORBELL_RESP_ACC: M={m_db_before} S={s_db_before}")

    # Build the column schema BEFORE the probe loop so the dict-key order is
    # frozen and any AttributeErrors on bad paths surface on the very first
    # sample.
    cols = _column_schema()
    headers = [c[0] for c in cols]

    # Fire the M->S doorbell.
    await tb.m_apb.write(APB_DOORBELL, 1)
    dut._log.info("M->S doorbell fired; beginning 2000-cycle probe sample")

    # Per-cycle sample loop.
    rows = []
    for cyc in range(PROBE_WINDOW_CYCLES):
        await RisingEdge(dut.hclk)
        row = [cyc]
        for hdr, getter in cols[1:]:
            row.append(getter(dut))
        rows.append(row)

    # Re-read the doorbell counters post-window.
    s_db_after = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_after = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    dut._log.info(f"Post-doorbell DOORBELL_RESP_ACC: M={m_db_after} S={s_db_after}")

    # -----------------------------------------------------------------------
    # Write the CSV dump.
    # -----------------------------------------------------------------------
    with open(DUMP_PATH, "w") as f:
        f.write("# Agent D probe dump (AUTOCAL=1)\n")
        f.write(f"# Window: {PROBE_WINDOW_CYCLES} cycles starting at hclk edge "
                "AFTER the M->S doorbell APB write.\n")
        f.write(f"# Cell value 'x' = signal could not be resolved at sample time.\n")
        f.write(f"# Pre-doorbell DOORBELL_RESP_ACC: M={m_db_before} S={s_db_before}\n")
        f.write(f"# Post-doorbell DOORBELL_RESP_ACC: M={m_db_after} S={s_db_after}\n")
        f.write(f"# Calibrator latched M phase={m_phase} slip={m_slip}\n")
        f.write(f"# Calibrator latched S phase={s_phase} slip={s_slip}\n")
        f.write(",".join(headers) + "\n")
        for row in rows:
            f.write(",".join(_format_value(v) for v in row) + "\n")
    dut._log.info(f"Wrote {len(rows)} samples to {DUMP_PATH}")

    # -----------------------------------------------------------------------
    # Build the human findings summary: per-column M-vs-S histogram, first
    # divergence cycle for the paired signals, pad-tx activity rate, FC valid
    # counts.
    # -----------------------------------------------------------------------
    findings = _build_findings(headers, rows, snap_p2,
                               m_phase, s_phase, m_slip, s_slip,
                               m_db_before, m_db_after,
                               s_db_before, s_db_after)
    with open(FINDINGS_PATH, "w") as f:
        f.write(findings)
    dut._log.info(f"Wrote findings summary to {FINDINGS_PATH}")

    # The whole point of the probe is to record data, not to assert anything
    # about it. The test always passes; the verdict lives in the .md file.
    dut._log.info("Probe complete; see findings doc for verdict.")


# ---------------------------------------------------------------------------
# Findings generator — runs in-process so we don't have to spawn a second
# Python interpreter.
# ---------------------------------------------------------------------------

def _build_findings(headers, rows, snap_p2,
                    m_phase, s_phase, m_slip, s_slip,
                    m_db_before, m_db_after,
                    s_db_before, s_db_after):
    # Index columns by name.
    idx = {h: i for i, h in enumerate(headers)}

    def col(name):
        i = idx[name]
        return [r[i] for r in rows]

    # Helper: histogram of a column.
    def hist(name):
        c = col(name)
        bins = {}
        for v in c:
            bins[v] = bins.get(v, 0) + 1
        return bins

    # Helper: first cycle where two columns disagree.
    def first_divergence(m_name, s_name, ignore_xx=True):
        m_c = col(m_name)
        s_c = col(s_name)
        for cyc in range(len(m_c)):
            mv, sv = m_c[cyc], s_c[cyc]
            if ignore_xx and (mv is None or sv is None):
                continue
            if mv != sv:
                return cyc, mv, sv
        return None

    # Helper: pad activity rate (fraction of cycles where pad changed value).
    def transitions(name):
        c = col(name)
        prev = c[0]
        n = 0
        for v in c[1:]:
            if v is not None and prev is not None and v != prev:
                n += 1
            prev = v
        return n

    lines = []
    lines.append("# Agent D probe findings — calibrator AUTOCAL=1 dump\n")
    lines.append("\n")
    lines.append("Dump file: `docs/agent_d_probe_dump_autocal1.log` "
                 f"({PROBE_WINDOW_CYCLES} cycles)\n")
    lines.append("\n")
    lines.append("## Doorbell crossing\n\n")
    lines.append(f"- Pre-doorbell  DOORBELL_RESP_ACC: M={m_db_before} S={s_db_before}\n")
    lines.append(f"- Post-doorbell DOORBELL_RESP_ACC: M={m_db_after} S={s_db_after}\n")
    crossed = (s_db_after > s_db_before) or (m_db_after > 0)
    lines.append(f"- Doorbell crossed: **{crossed}**\n\n")

    lines.append("## Calibrator latched per-lane state (after S_DONE)\n\n")
    lines.append("| lane | M phase | S phase | M slip | S slip | phase ==? | slip ==? |\n")
    lines.append("|------|---------|---------|--------|--------|-----------|-----------|\n")
    for i in range(8):
        ph_eq = "OK" if m_phase[i] == s_phase[i] else "**DIFFER**"
        sl_eq = "OK" if m_slip[i] == s_slip[i] else "**DIFFER**"
        lines.append(f"| {i} | {m_phase[i]} | {s_phase[i]} | "
                     f"{m_slip[i]} | {s_slip[i]} | {ph_eq} | {sl_eq} |\n")
    lines.append("\n")

    lines.append("## Pad activity (transitions per signal over window)\n\n")
    for name in ("m_pad_tx", "s_pad_rx_seen", "s_pad_tx", "m_pad_rx_seen"):
        lines.append(f"- `{name}` transitions: {transitions(name)}\n")
    lines.append("\n")

    lines.append("## Symmetric-signal first-divergence summary\n\n")
    lines.append("Cycle at which M and S samples first disagree (None = stayed identical).\n\n")
    paired = [
        ("m_cal_state", "s_cal_state"),
        ("m_cal_done", "s_cal_done"),
        ("m_cal_train_mode", "s_cal_train_mode"),
        ("m_phy_train_in", "s_phy_train_in"),
        ("m_phy_eff_train", "s_phy_eff_train"),
        ("m_lane_locked", "s_lane_locked"),
        ("m_lane_fault", "s_lane_fault"),
        ("m_fc_a2l_v", "s_fc_a2l_v"),
        ("m_fc_l2a_v", "s_fc_l2a_v"),
        ("m_fcsm_state", "s_fcsm_state"),
    ]
    for mn, sn in paired:
        d = first_divergence(mn, sn)
        if d is None:
            lines.append(f"- `{mn}` vs `{sn}`: identical throughout window\n")
        else:
            cyc, mv, sv = d
            lines.append(f"- `{mn}` vs `{sn}`: first diverge @ cy={cyc} M={mv} S={sv}\n")
    lines.append("\n")

    # Special pair: M's pad TX vs S's pad RX (should match because skid=0
    # passthrough). Same for S TX vs M RX.
    lines.append("## Pad-wire integrity\n\n")
    for tx_name, rx_name in (("m_pad_tx", "s_pad_rx_seen"),
                              ("s_pad_tx", "m_pad_rx_seen")):
        d = first_divergence(tx_name, rx_name)
        if d is None:
            lines.append(f"- `{tx_name}` matches `{rx_name}` throughout (passthrough OK).\n")
        else:
            cyc, mv, sv = d
            lines.append(f"- `{tx_name}` vs `{rx_name}`: first diverge @ cy={cyc} TX={mv} RX={sv} **(skid bug?)**\n")
    lines.append("\n")

    lines.append("## Per-signal histograms\n\n")
    for name in headers[1:]:
        h = hist(name)
        # Trim: if a signal is constant, just say "all=<value>"
        if len(h) == 1:
            (v, _), = h.items()
            lines.append(f"- `{name}`: constant={v}\n")
        else:
            # Sort by count desc, take top 8.
            items = sorted(h.items(), key=lambda kv: -kv[1])[:8]
            pretty = ", ".join(f"{v}:{c}" for v, c in items)
            lines.append(f"- `{name}`: {pretty}\n")
    lines.append("\n")

    # FC adapter pulse counts.
    lines.append("## FC adapter pulse counts (cycles asserted in window)\n\n")
    def count_asserted(name):
        return sum(1 for v in col(name) if v == 1)
    lines.append(f"- M a2l_valid: {count_asserted('m_fc_a2l_v')}  "
                 f"a2l_ready: {count_asserted('m_fc_a2l_r')}  "
                 f"l2a_valid: {count_asserted('m_fc_l2a_v')}\n")
    lines.append(f"- S a2l_valid: {count_asserted('s_fc_a2l_v')}  "
                 f"a2l_ready: {count_asserted('s_fc_a2l_r')}  "
                 f"l2a_valid: {count_asserted('s_fc_l2a_v')}\n\n")

    # Verdict heuristic.
    lines.append("## Verdict heuristic\n\n")
    m_a2l = count_asserted('m_fc_a2l_v')
    s_l2a = count_asserted('s_fc_l2a_v')
    if m_a2l == 0:
        lines.append("- **M.a2l_valid never asserts** => master's FC adapter "
                     "never submits the doorbell packet. Bug is upstream of "
                     "tl_fc_a2l_valid (returner / credit / address decode).\n")
    elif s_l2a == 0:
        lines.append("- **M.a2l_valid asserts but S.l2a_valid never does** => "
                     "packet leaves master's FC adapter but is dropped on the "
                     "wire or by slave's Wlink stack.\n")
    else:
        lines.append("- M.a2l_valid AND S.l2a_valid both fire => the FC "
                     "adapter handshake completed. The drop is in the "
                     "slave's RX consumer (sideband decode → DOORBELL reg).\n")

    # Symmetry summary
    cal_train_div = first_divergence("m_cal_train_mode", "s_cal_train_mode")
    if cal_train_div is None:
        lines.append("- `cal_training_mode_w` symmetric on M and S throughout — "
                     "no calibrator-level asymmetry observed.\n")
    else:
        cyc, mv, sv = cal_train_div
        lines.append(f"- `cal_training_mode_w` diverges @ cy={cyc} (M={mv} S={sv}) — "
                     "calibrator-level asymmetry.\n")

    return "".join(lines)
