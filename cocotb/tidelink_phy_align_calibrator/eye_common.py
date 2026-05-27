"""eye_common — shared helpers + register-map constants for the v2 Eye
Visibility cocotb test suite (docs/EYE_VISIBILITY_RTL_PROPOSAL.md).

Centralises:
  * Region 10 APB offsets (LOCAL_BASE-relative).
  * SWI_EYE_CTRL bit layout (ENTER, RESET, MODE, FORCE_FULL_SWEEP,
    AUTO_INCREMENT_LANE).
  * SWI_EYE_STATUS state encoding (IDLE, SWEEPING, DONE, TIMED_OUT,
    DRAINING).
  * Async APB driver helpers (apb_write / apb_read) that use the tb_top
    pin naming convention (psel/penable/pwrite/paddr/pwdata/prdata/pready).

The APB driver is intentionally simple — single-cycle setup, single-cycle
access — matching the tidelink_apb_regs cocotb test harness. The v2
eye_regs shim is a thin combinational decoder (no wait states), so this
is sufficient.
"""

from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


# ── Region 10 offsets (proposal §5) ───────────────────────────────────────
# Offsets are quoted relative to the MMIO base 0x4403_2140; the cocotb
# testbench's APB slave sees only the low 12 bits of paddr, so we use the
# 12-bit offsets directly (0x140..0x174).
SWI_EYE_CTRL        = 0x140
SWI_EYE_LANE_SEL    = 0x144
SWI_EYE_DWELL_US    = 0x148
SWI_EYE_STATUS      = 0x14C
SWI_FORCE_PHASE_EN  = 0x150
SWI_FORCE_PHASE_VAL = 0x154
SWI_FORCE_SLIP_VAL  = 0x158
EYE_CRC_ERR_LANE_LO = 0x15C
EYE_CRC_ERR_LANE_HI = 0x160
EYE_SCORE_IDX       = 0x164
EYE_SCORE_DATA      = 0x168
EYE_BURST_DATA      = 0x16C
EYE_LAST_LATCHED    = 0x170
PHY_EYE_ID          = 0x174

PHY_EYE_ID_EXPECTED = 0x5045_0200   # "PE" v2.0 magic, proposal §5

# ── SWI_EYE_CTRL bit positions ────────────────────────────────────────────
CTRL_ENTER              = 1 << 0
CTRL_RESET              = 1 << 1
CTRL_MODE_SHIFT         = 4
CTRL_MODE_MASK          = 0b11 << CTRL_MODE_SHIFT
CTRL_MODE_OFF           = 0b00 << CTRL_MODE_SHIFT
CTRL_MODE_SINGLE        = 0b01 << CTRL_MODE_SHIFT
CTRL_MODE_RESERVED_B    = 0b10 << CTRL_MODE_SHIFT
CTRL_MODE_RESERVED_FUT  = 0b11 << CTRL_MODE_SHIFT
CTRL_REMOTE_TRIGGER_EN  = 1 << 7      # RAZ/WI in v2
CTRL_FORCE_FULL_SWEEP   = 1 << 8
CTRL_AUTO_INC_LANE      = 1 << 9
CTRL_CAPTURE_ARM_ALIAS  = 1 << 16     # legacy alias of ENTER

# ── SWI_EYE_STATUS state encoding (low 3 bits) ────────────────────────────
STATE_IDLE       = 0
STATE_SWEEPING   = 1
STATE_DONE       = 2
STATE_TIMED_OUT  = 3
STATE_DRAINING   = 4

# ── SWI_FORCE_PHASE_EN bits ───────────────────────────────────────────────
FORCE_EN_OVERRIDE     = 1 << 0
FORCE_EN_SKIP_CAL     = 1 << 1
FORCE_EN_FREEZE_DONE  = 1 << 2

# ── EYE_SCORE_IDX bits ────────────────────────────────────────────────────
SCORE_IDX_POINT_MASK  = 0x7F    # [6:0] (slip[2:0], phase[3:0])
SCORE_IDX_AUTO_INC    = 1 << 16

# ── EYE_BURST_DATA shape ──────────────────────────────────────────────────
BURST_SCORES_PER_READ = 5       # five packed 6-bit scores in [29:0]
BURST_READS_PER_LANE  = 26      # ceil(128 / 5); last read holds 3 valid scores
SCORES_PER_LANE       = 128

# Calibrator FSM state — mirrors tidelink_phy_align_calibrator.sv. Used
# when we hierarchically poke at u_dut state in tests that bypass APB
# (legacy single-DUT TB pattern; see test_calibrator_t3.py).
S_IDLE   = 0
S_ARM    = 1
S_SWEEP  = 2
S_FINISH = 3
S_DONE   = 4
S_CANCEL = 5
S_HOLD   = 6
S_PROBE  = 7

# tb_top_eye.sv parameter overrides — keep these in sync with the
# `parameter int DWELL_CYCLES = 8` declared in the wrapper.
DWELL_CYCLES = 8
LOCK_THRESH  = 2
HOLD_CYCLES  = 2 * 128 * DWELL_CYCLES
# Sim clock is 10 ns / 100 MHz; CLK_MHZ parameter in tb_top_eye = 100.
CLK_MHZ      = 100
CLK_PERIOD_NS = 10

# One natural full 128-point sweep: 16 phase × 8 slip × DWELL_CYCLES.
ONE_SWEEP_CYCLES = 16 * 8 * DWELL_CYCLES + DWELL_CYCLES + 16


# ── APB driver helpers ───────────────────────────────────────────────────

def _resolve(handle, prefix, name):
    """Return getattr(handle, f"{prefix}{name}") if prefix else
    getattr(handle, name). Lets us point the same driver at the bare
    tb_top.sv (no prefix) or at the side-A/side-B variants
    (a_psel, b_psel) on the paired-entry TB.
    """
    return getattr(handle, f"{prefix}{name}" if prefix else name)


async def apb_idle(dut, prefix=""):
    """Park the APB lines low."""
    _resolve(dut, prefix, "psel").value    = 0
    _resolve(dut, prefix, "penable").value = 0
    _resolve(dut, prefix, "pwrite").value  = 0
    _resolve(dut, prefix, "paddr").value   = 0
    _resolve(dut, prefix, "pwdata").value  = 0


async def apb_write(dut, addr, data, prefix=""):
    """Single-cycle APB write at offset `addr` (low 12 bits)."""
    clk = _resolve(dut, "", "clk")
    psel    = _resolve(dut, prefix, "psel")
    penable = _resolve(dut, prefix, "penable")
    pwrite  = _resolve(dut, prefix, "pwrite")
    paddr   = _resolve(dut, prefix, "paddr")
    pwdata  = _resolve(dut, prefix, "pwdata")
    pready  = _resolve(dut, prefix, "pready")

    await RisingEdge(clk)
    psel.value    = 1
    penable.value = 0
    pwrite.value  = 1
    paddr.value   = addr & 0xFFF
    pwdata.value  = data & 0xFFFFFFFF
    await RisingEdge(clk)
    penable.value = 1
    # Wait for pready (the v2 eye_regs shim returns pready=1
    # combinationally on the access phase).
    for _ in range(64):
        await RisingEdge(clk)
        if int(pready.value):
            break
    psel.value    = 0
    penable.value = 0
    pwrite.value  = 0


async def apb_read(dut, addr, prefix=""):
    """Single-cycle APB read at offset `addr` (low 12 bits). Returns the
    raw 32-bit prdata word."""
    clk = _resolve(dut, "", "clk")
    psel    = _resolve(dut, prefix, "psel")
    penable = _resolve(dut, prefix, "penable")
    pwrite  = _resolve(dut, prefix, "pwrite")
    paddr   = _resolve(dut, prefix, "paddr")
    prdata  = _resolve(dut, prefix, "prdata")
    pready  = _resolve(dut, prefix, "pready")

    await RisingEdge(clk)
    psel.value    = 1
    penable.value = 0
    pwrite.value  = 0
    paddr.value   = addr & 0xFFF
    await RisingEdge(clk)
    penable.value = 1
    rdata = 0
    for _ in range(64):
        await RisingEdge(clk)
        if int(pready.value):
            try:
                rdata = int(prdata.value)
            except ValueError:
                rdata = 0
            break
    psel.value    = 0
    penable.value = 0
    return rdata


# ── Bring-up helpers ──────────────────────────────────────────────────────

async def start_clock_and_reset(dut, period_ns=CLK_PERIOD_NS):
    """Start the testbench clock and drive a clean active-high reset."""
    import cocotb
    cocotb.start_soon(Clock(dut.clk, period_ns, unit="ns").start())
    dut.rst.value = 1
    # Park all the test-driven inputs at their idle values.
    await ClockCycles(dut.clk, 4)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


async def trigger_eye_sweep(dut, lane, *, dwell_us=10_000,
                            mode=CTRL_MODE_SINGLE, force_full_sweep=True,
                            prefix=""):
    """Program lane_sel + dwell, then write ENTER. Returns immediately —
    caller polls SWI_EYE_STATUS for DONE / TIMED_OUT.
    """
    await apb_write(dut, SWI_EYE_LANE_SEL, lane & 0x7, prefix=prefix)
    await apb_write(dut, SWI_EYE_DWELL_US, dwell_us, prefix=prefix)
    ctrl = CTRL_ENTER | mode
    if force_full_sweep:
        ctrl |= CTRL_FORCE_FULL_SWEEP
    await apb_write(dut, SWI_EYE_CTRL, ctrl, prefix=prefix)


async def poll_status_state(dut, target_states, *, max_polls=20_000,
                            poll_interval=8, prefix=""):
    """Poll SWI_EYE_STATUS[2:0] until it matches one of `target_states`
    (a list/tuple of int) or `max_polls` × `poll_interval` cycles elapse.

    Returns the final 32-bit STATUS word.
    """
    if isinstance(target_states, int):
        target_states = (target_states,)
    target_states = tuple(target_states)

    last = 0
    for _ in range(max_polls):
        last = await apb_read(dut, SWI_EYE_STATUS, prefix=prefix)
        if (last & 0x7) in target_states:
            return last
        # Read includes its own clock-edge cost; add small spacing so we
        # don't hammer the bus.
        await ClockCycles(dut.clk, poll_interval)
    return last


def status_decode(status_word):
    """Unpack a raw 32-bit SWI_EYE_STATUS read into a dict."""
    return {
        "state":              status_word & 0x7,
        "last_swept_lane":    (status_word >> 4) & 0x7,
        "capture_valid":      (status_word >> 7) & 0x1,
        "cal_state_mirror":   (status_word >> 8)  & 0xF,
        "sweep_phase_mirror": (status_word >> 12) & 0xF,
        "dwell_remaining_ms": (status_word >> 16) & 0xFFFF,
    }
