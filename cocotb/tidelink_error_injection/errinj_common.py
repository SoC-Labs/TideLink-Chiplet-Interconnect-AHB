"""F14 error-injection helpers layered on the V2 pair harness.

Injection primitives (all deposit-only on undriven regs — no shared RTL edit):
  * err_inject module u_inj_m2s / u_inj_s2m (post-skid, pre-RX, both dirs):
      inj_en, lane_mask[7:0], mode {0=stuck0,1=stuck1,2=stuckX,3=flip}, clk_kill
  * per-die POR gate m_por_gate / s_por_gate (tb_top:165) for die reset.

Recovery classification (task taxonomy):
  RECOVERS                       — link + byte-exact data resume with NO action
  RECOVERS-WITH-INTERVENTION(x)  — resumes only after SW action x
  WEDGES(x)                      — stuck; only x (e.g. full POR) unwedges
  SILENT-CORRUPTION              — link claims healthy, data wrong, no error flag
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import (
    PairV2TB, run_bringup_full, send_and_check, make_packet,
    APB_PKT_WORD_LEN, ST_CAL_DONE, APB_PAIR_CREDIT_COUNTER,
    APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_SWRESET_ON,
    LL_BOOTSTRAP_SWRESET_OFF, LL_BOOTSTRAP_ENABLE,
)

# err_inject.mode encodings
M_STUCK0, M_STUCK1, M_STUCKX, M_FLIP = 0, 1, 2, 3

# The GPIO-PHY TX SYNC / training beacon word (16-bit lane pattern). 0x1F00 is
# the raw post-deskew SYNC slice seen on silicon (MEMORY: 0x1F00>>5 slip). We
# also try the 8-lane packed value below in the collision test.
SYNC_WORD16 = 0x1F00


def _inj(dut, direction):
    """direction 'm2s' corrupts the SLAVE RX; 's2m' corrupts the MASTER RX."""
    return dut.u_inj_m2s if direction == "m2s" else dut.u_inj_s2m


def inject_data(dut, direction, mode, lane_mask=0xFF):
    inj = _inj(dut, direction)
    inj.mode.value = mode
    inj.lane_mask.value = lane_mask & 0xFF
    inj.inj_en.value = 1


def clear_data(dut, direction):
    inj = _inj(dut, direction)
    inj.inj_en.value = 0
    inj.clk_kill.value = 0


def kill_clock(dut, direction, on=True):
    _inj(dut, direction).clk_kill.value = 1 if on else 0


def clear_all(dut):
    for d in ("m2s", "s2m"):
        clear_data(dut, d)


async def send_burst(tb, src, dst, payloads, ctx, expect_pass=True, settle=3000):
    """Send a burst of independent 4-word packets src->dst, byte-check each.
    Returns list of (ok, got). expect_pass=False suppresses the assert so the
    caller can classify the failure (WEDGE / SILENT-CORRUPTION)."""
    results = []
    for i, pl in enumerate(payloads):
        ok, got = await send_and_check(tb, src, dst, pl, ctx=f"{ctx}#{i}",
                                       expect_pass=expect_pass)
        results.append((ok, got))
    return results


async def link_healthy(tb, src="m", dst="s"):
    """Independent health check: one round-trip packet each way is byte-exact
    AND both FCSMs sit in LINK_IDLE (state 4). Returns (ok, detail)."""
    okms, _ = await send_and_check(tb, "m", "s", [0xA5A50001, 0x5A5A0002],
                                   ctx="health-m2s", expect_pass=False)
    oksm, _ = await send_and_check(tb, "s", "m", [0xA5A50003, 0x5A5A0004],
                                   ctx="health-s2m", expect_pass=False)
    fm, fs = tb.fcsm_state("m"), tb.fcsm_state("s")
    return (okms and oksm and fm == 4 and fs == 4,
            f"m2s={okms} s2m={oksm} fcsm_m={fm} fcsm_s={fs}")


async def ll_swreset_one_die(tb, side):
    """Pulse ONE die's Wlink link-layer swreset via APB 0x0208 bit[3]
    (Wlink.v:2457-2463 -> resets that die's TX/RX link-clk + app-clk domains:
    FCSM state, a2l FIFO ptrs, credit maxima, exp_pkt_num). LOCAL to one die —
    does NOT propagate to the peer, so the two can desync."""
    apb = tb.apb(side)
    await apb.write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_SWRESET_ON)   # bit3=1
    await ClockCycles(tb.dut.hclk, 40)
    await apb.write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_SWRESET_OFF)  # bit3=0
    await apb.write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_ENABLE)
    await ClockCycles(tb.dut.hclk, 200)


def crc_snapshot(tb, side):
    """Sample the FCSM's CRC-error state: crc_errors[15:0] (the saturating
    error counter, WlinkGenericFCSM_6.v:439) and io_rx_crc_err (= |crc_errors,
    :1044). This is what decides whether a corrupt-but-COMMITTED packet was
    FLAGGED or truly SILENT."""
    fc = tb.fcsm(side)
    out = {}
    for name in ("crc_errors", "io_rx_crc_err"):
        try:
            out[name] = int(getattr(fc, name).value)
        except (AttributeError, ValueError):
            out[name] = -1
    return out


def credit_snapshot(tb, side):
    """Read the FC credit / a2l-replay observability regs for one die."""
    return {
        "a2l_wptr":       tb.a2l_wptr(side),
        "a2l_synced_ack": tb.a2l_synced_ack(side),
        "a2l_full":       tb.a2l_full(side),
        "fe_rx_cred_max": tb._obs(side, "io_obs_fe_rx_credit_max"),
    }


async def reset_one_die(tb, side, cycles=40):
    """Assert one die's POR gate low for `cycles` hclk, then release. Models a
    mid-burst link-layer swreset / partial POR of a single die."""
    gate = tb.dut.m_por_gate if side == "m" else tb.dut.s_por_gate
    gate.value = 0
    await ClockCycles(tb.dut.hclk, cycles)
    gate.value = 1
    await ClockCycles(tb.dut.hclk, 200)


async def rebringup_after_reset(tb):
    """Re-run the SW bring-up phases WITHOUT a fresh full POR (models the
    standard peer re-bring-up recipe: role_lock is W1S/sticky so we only need
    to re-drive to_data_mode + wait for CR/CRACK). Returns cr_crack ok."""
    await tb.do_to_data_mode()
    await ClockCycles(tb.dut.hclk, 3000)
    return await tb.wait_cr_crack(max_cycles=40000)


async def full_por_rebringup(tb):
    """The power-cycle-equivalent: full POR of BOTH dies + the complete SW
    bring-up. This is the heaviest unwedge (models `fpgahub power-cycle`)."""
    await run_bringup_full(tb)
    return await tb.wait_cr_crack(max_cycles=40000)


async def burst_during_fault(tb, src, dst, payloads, fault_setup, fault_clear,
                             ctx):
    """Faithful mid-burst injection: enable the fault, drive a burst of
    packets src->dst WHILE the fault is active, release the fault, then report
    per-packet delivery. fault_setup / fault_clear are plain (synchronous)
    callables that deposit the injector controls. Returns during_ok_list;
    nothing asserts — the caller classifies."""
    fault_setup()
    during = []
    for i, pl in enumerate(payloads):
        ok, got = await send_and_check(tb, src, dst, pl,
                                       ctx=f"{ctx}-during#{i}", expect_pass=False)
        during.append(ok)
    fault_clear()
    await ClockCycles(tb.dut.hclk, 2000)
    return during


async def classify_recovery(tb, src, dst):
    """After a fault window is cleared, walk the recovery ladder and return a
    (verdict, detail) tuple. Ladder: no-op -> SW re-bringup -> full POR."""
    ok, detail = await link_healthy(tb, src, dst)
    if ok:
        return "RECOVERS", detail
    cr = await rebringup_after_reset(tb)
    ok2, d2 = await link_healthy(tb, src, dst)
    if cr and ok2:
        return "RECOVERS-WITH-INTERVENTION(SW re-bringup: to_data_mode+CR/CRACK)", d2
    cr3 = await full_por_rebringup(tb)
    ok3, d3 = await link_healthy(tb, src, dst)
    if cr3 and ok3:
        v = "WEDGES(unwedged only by full POR of BOTH dies)"
        tb.log.warning(f"RECOVERY LADDER: {v} — the link needed a FULL POR of both "
                       f"dies. On silicon that is a bench trip. detail={d3}")
        _assert_recovery_ok(tb, v, d3)
        return v, d3
    v = "WEDGES(NOT unwedged even by full POR — hard wedge)"
    tb.log.error(f"RECOVERY LADDER: {v}  detail={d3}")
    _assert_recovery_ok(tb, v, d3)
    return v, d3


def _assert_recovery_ok(tb, verdict, detail):
    """Fail the test on an unrecoverable link.

    Until 2026-07-18 every caller of classify_recovery() discarded the verdict --
    all 7 call sites did `verdict, detail = await classify_recovery(...)` and then
    only logged. The suite headers said so out loud ("a WEDGE is a FINDING, not a
    test failure"), which is defensible while characterising a new failure mode and
    indefensible once these run as regressions: a hard wedge exited green.

    Policy, asserted here so all call sites inherit it uniformly:
      * HARD WEDGE (not recoverable even by a full POR of both dies) always fails.
        There is no configuration in which that is an acceptable outcome.
      * "unwedged only by full POR" fails only under EI_STRICT_RECOVERY=1. It is a
        real defect -- on silicon it means a bench trip -- but several of these
        tests were written to characterise exactly that, so making it fatal by
        default would turn characterisation red without a decision having been made.
      * RECOVERS / RECOVERS-WITH-INTERVENTION pass.
    """
    import os
    hard = "hard wedge" in verdict
    por_only = verdict.startswith("WEDGES") and not hard
    strict = os.environ.get("EI_STRICT_RECOVERY", "").strip() in ("1", "true", "yes")
    if hard:
        raise AssertionError(
            f"UNRECOVERABLE LINK: {verdict}. The link did not come back even after a "
            f"full POR of both dies, so no software or operator action can restore it. "
            f"detail={detail}")
    if por_only and strict:
        raise AssertionError(
            f"EI_STRICT_RECOVERY=1: {verdict}. detail={detail}")
