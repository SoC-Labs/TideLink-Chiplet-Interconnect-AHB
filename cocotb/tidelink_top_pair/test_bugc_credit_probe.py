"""Bug C credit-ledger forensic probe (2026-05-31).

Adds hierarchical probes to the canonical bug-c reproducer to localise WHY
fe_rx_credit_max / fe_tx_credit_max stay at 0 despite cr_pkt_seen=1 and
crack_pkt_seen=1 on both sides.

Hypothesis under test:
   The Tier 2 swi_enable hardening shim at tidelink_top.sv:1780 only fires
   when apb_pwdata[3]==1 (swreset bit). The Wlink LL bootstrap sequence in
   do_to_data_mode() writes 0x208 = 0x00027f00 in the MIDDLE step with
   swreset=0 AND swi_enable=0. The hardening does NOT mask that, so
   swi_enable transiently drops to 0. The drop propagates through
   en_ff2_rx_demet into io_rx_clk domain. Per FC.scala 201:
       _fe_tx_credit_max_in_T = ~en_ff2_rx_demet_io_out
   That signal SYNCHRONOUSLY CLEARS fe_rx_credit_max and fe_tx_credit_max
   to 0 (the cr/crack-load path is mutually exclusive).
   cr_pkt_seen_rx / crack_pkt_seen_rx are sticky-in-reset (SoC Labs L0 fix
   at WlinkGenericFCSM_6.v:946-958) so they don't lose state — but the
   credit_max regs DO lose state.

Probes capture:
   * swi_enable (apb_clk)
   * en_ff2_rx_demet_io_out (io_rx_clk)
   * fe_rx_credit_max, fe_tx_credit_max (io_rx_clk)
   * pkt_is_cr_pkt, pkt_is_crack_pkt, auto_rx_in_word_count (combinational)

Both sides sampled. The test runs the standard bringup, then dumps a
timeline of these signals around the to_data_mode bootstrap window.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_through_phase1,
    APB_R8_SLOT0,
    APB_WL_LINK_ENABLE_RESET,
    R8_SLOT0_OFF,
    LL_BOOTSTRAP_SWRESET_ON,
    LL_BOOTSTRAP_SWRESET_OFF,
    LL_BOOTSTRAP_ENABLE,
)


def _fcsm(tb, side):
    """Hierarchical handle to the TideLink FCSM internals."""
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _wlink(tb, side):
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_chiplet_controller.u_wlink


def _sample(tb, side, label):
    """Snapshot the credit-relevant signals on `side` (m or s)."""
    fc = _fcsm(tb, side)
    wl = _wlink(tb, side)
    sigs = {}
    for name in ("fe_rx_credit_max", "fe_tx_credit_max",
                 "en_ff2_rx_demet_io_out", "cr_pkt_seen_rx",
                 "crack_pkt_seen_rx", "pkt_is_cr_pkt", "pkt_is_crack_pkt",
                 "auto_rx_in_word_count", "auto_rx_in_data_id",
                 "swi_cr_id", "out_prepend_swi_crack_id",
                 "io_app_enable", "state"):
        try:
            sigs[name] = int(getattr(fc, name).value)
        except (AttributeError, ValueError):
            sigs[name] = -1
    try:
        sigs["wlink_swi_enable"] = int(wl.swi_enable.value)
    except (AttributeError, ValueError):
        sigs["wlink_swi_enable"] = -1
    tb.log.info(
        f"  [{label} {side}] swi_en={sigs['wlink_swi_enable']} "
        f"app_en={sigs['io_app_enable']} en_demet={sigs['en_ff2_rx_demet_io_out']} "
        f"state={sigs['state']} "
        f"cr_seen={sigs['cr_pkt_seen_rx']} crack_seen={sigs['crack_pkt_seen_rx']} "
        f"is_cr={sigs['pkt_is_cr_pkt']} is_crack={sigs['pkt_is_crack_pkt']} "
        f"wc=0x{sigs['auto_rx_in_word_count']:04x} "
        f"did=0x{sigs['auto_rx_in_data_id']:02x} "
        f"(cr_id=0x{sigs['swi_cr_id']:02x} crack_id=0x{sigs['out_prepend_swi_crack_id']:02x}) "
        f"fe_rx_cmax=0x{sigs['fe_rx_credit_max']:02x} "
        f"fe_tx_cmax=0x{sigs['fe_tx_credit_max']:02x}"
    )
    return sigs


async def _watch_credit_window(tb, label, cycles):
    """Sample every cycle for `cycles`, log only on credit_max or en_demet
    transitions to keep output tractable."""
    m_prev = _sample(tb, "m", f"{label} start")
    s_prev = _sample(tb, "s", f"{label} start")
    for i in range(cycles):
        await RisingEdge(tb.dut.hclk)
        m_now = {}
        s_now = {}
        for side, prev, now in (("m", m_prev, m_now), ("s", s_prev, s_now)):
            fc = _fcsm(tb, side)
            for name in ("fe_rx_credit_max", "fe_tx_credit_max",
                         "en_ff2_rx_demet_io_out", "io_app_enable",
                         "pkt_is_cr_pkt", "pkt_is_crack_pkt",
                         "auto_rx_in_word_count"):
                try:
                    now[name] = int(getattr(fc, name).value)
                except (AttributeError, ValueError):
                    now[name] = -1
            # Print on any change in app_en/en_demet/credit_max OR on cr/crack pulse
            changed = (
                now["fe_rx_credit_max"] != prev["fe_rx_credit_max"]
                or now["fe_tx_credit_max"] != prev["fe_tx_credit_max"]
                or now["en_ff2_rx_demet_io_out"] != prev["en_ff2_rx_demet_io_out"]
                or now["io_app_enable"] != prev["io_app_enable"]
                or now["pkt_is_cr_pkt"] == 1
                or now["pkt_is_crack_pkt"] == 1
            )
            if changed:
                tb.log.info(
                    f"  [{label} cy+{i} {side}] "
                    f"app_en={now['io_app_enable']} en_demet={now['en_ff2_rx_demet_io_out']} "
                    f"is_cr={now['pkt_is_cr_pkt']} is_crack={now['pkt_is_crack_pkt']} "
                    f"wc=0x{now['auto_rx_in_word_count']:04x} "
                    f"fe_rx_cmax=0x{now['fe_rx_credit_max']:02x} "
                    f"fe_tx_cmax=0x{now['fe_tx_credit_max']:02x}"
                )
            if side == "m":
                m_prev = dict(now)
            else:
                s_prev = dict(now)


@cocotb.test()
async def test_bugc_credit_probe(dut):
    """Trace the credit ledger across the to_data_mode bootstrap."""
    tb = PairTB(dut)

    # Phase 0 + 1 only — leave training high.
    await run_bringup_through_phase1(tb)

    tb.log.info("=== PHASE 1 COMPLETE ===")
    _sample(tb, "m", "phase1-end m")
    _sample(tb, "s", "phase1-end s")

    # Manually replay do_to_data_mode while watching credit ledger.
    tb.log.info("=== STEP A: slot0 = 0 (drop training_mode) ===")
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 20)
    _sample(tb, "m", "post-slot0=0 m")
    _sample(tb, "s", "post-slot0=0 s")

    for label, val in (("SWRESET_ON",  LL_BOOTSTRAP_SWRESET_ON),
                       ("SWRESET_OFF", LL_BOOTSTRAP_SWRESET_OFF),
                       ("ENABLE",      LL_BOOTSTRAP_ENABLE)):
        tb.log.info(f"=== STEP B[{label}]: APB write 0x208 = 0x{val:08x} ===")
        await tb.m_apb.write(APB_WL_LINK_ENABLE_RESET, val)
        await tb.s_apb.write(APB_WL_LINK_ENABLE_RESET, val)
        # Tight watch immediately after the write — capture any swi_en dip.
        await _watch_credit_window(tb, f"post-{label}", cycles=40)
        _sample(tb, "m", f"post-{label}-m settled")
        _sample(tb, "s", f"post-{label}-s settled")

    # Final long watch after full bootstrap.
    tb.log.info("=== STEP C: full bootstrap complete — watch credit window ===")
    await _watch_credit_window(tb, "final", cycles=5000)

    # Snapshot summary
    tb.log.info("=== FINAL STATE ===")
    m_final = _sample(tb, "m", "final m")
    s_final = _sample(tb, "s", "final s")

    # Diagnostic only — no assertion. We want the timeline, not pass/fail.
    if m_final["fe_rx_credit_max"] == 0 and s_final["fe_rx_credit_max"] == 0:
        tb.log.warning("BUG C REPRO: both fe_rx_credit_max stayed at 0 — check above for the en_demet dip window.")
    else:
        tb.log.info(f"Credit ledger populated: m=0x{m_final['fe_rx_credit_max']:02x} s=0x{s_final['fe_rx_credit_max']:02x}")
