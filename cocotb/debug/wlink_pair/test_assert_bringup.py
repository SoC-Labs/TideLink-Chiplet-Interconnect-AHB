"""Assertive bring-up tests for the wlink_pair testbench.

Unlike test_link_bringup.py which logs but never asserts, this file asserts
that bring-up completes for *each* FC channel within reasonable time. Catches
regressions in the per-channel cr_pkt routing or `cr_pkt_seen_rx` logic.

Background: 2026-05-08 FPGA debug session captured an internal ILA showing
master and slave TideLink FC FCSM stuck at state=1 (SEND_CREDITS1) on FPGA,
despite tx_out_advance asserting 14% of the time (cr_pkts ARE going out).
Both sides' `cr_pkt_seen_tx` (CDC-synced version of `cr_pkt_seen_rx`) never
asserts, so the FCSM never advances. AXI/GenBus FC channels complete
bring-up normally. The bug appears FPGA-specific — sim showed bring-up
completes — but additional sim coverage is warranted to catch regressions.
"""
import cocotb
from cocotb.triggers import ClockCycles, Timer
from test_link_bringup import setup, lock_master, lock_slave

# All FC channel hierarchical paths inside one Wlink instance. Each path
# resolves to a `WlinkGenericFCSM*` instance (or its TideLink/GenBus variant).
FC_CHANNELS = {
    "tidelink": "wlink_tidelinktl",
    "generalbus": "wlink_generalbusgb",
    "axi_aw": "wlink_axiawFC",
    "axi_w":  "wlink_axiwFC",
    "axi_b":  "wlink_axibFC",
    "axi_ar": "wlink_axiarFC",
    "axi_r":  "wlink_axirFC",
}


def _fc_state(wlink_inst, channel_path):
    """Return the .state handle of a given FC channel inside a Wlink instance."""
    # The Chisel hierarchy nests differently for each channel kind; try the
    # canonical paths.
    candidates = [
        f"tl2wl.{channel_path}.state",
        f"gb2wl.{channel_path}.state",
        f"axi2wl.{channel_path}.state",
    ]
    for path in candidates:
        cur = wlink_inst
        try:
            for part in path.split("."):
                cur = getattr(cur, part)
            return cur
        except AttributeError:
            continue
    return None


@cocotb.test()
async def test_07_assert_all_fc_channels_bringup(dut):
    """All FC channels must reach state>=4 (LINK_EN_WAIT or LINK_IDLE) after
    role-lock. This is the assertive version of test_02 — it verifies the
    per-channel handshake completes, not just that one channel got far."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # Wait long enough for the handshake to complete on all FC channels.
    # ~80us at 50 MHz is plenty (test_02 sees full bring-up in ~40 us).
    await ClockCycles(dut.apb_clk, 5000)

    failures = []
    for label, channel_path in FC_CHANNELS.items():
        for side in ("master", "slave"):
            wlink = getattr(dut, f"u_{side}").u_wlink
            state_h = _fc_state(wlink, channel_path)
            if state_h is None:
                dut._log.warning(f"  {side}/{label}: state handle not resolvable")
                continue
            state = int(state_h.value)
            dut._log.info(f"  {side}/{label} state = {state}")
            if state < 4:
                failures.append(f"{side}/{label} stuck at state={state}")

    assert not failures, "FC channel(s) did not complete bring-up: " + "; ".join(failures)


@cocotb.test()
async def test_08_assert_tidelink_cr_pkt_seen(dut):
    """Both sides' TideLink FC `cr_pkt_seen_rx` must latch high after bring-up.
    On 2026-05-08 FPGA capture, this signal never asserts — the bug. This
    test asserts it MUST assert in sim, so any RTL regression that breaks
    the RX-side cr_pkt detection is caught immediately."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    m_seen = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx
    s_seen = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx

    # Watch for cr_pkt_seen_rx to latch over 5000 cycles
    m_latched = False
    s_latched = False
    for _ in range(5000):
        await ClockCycles(dut.apb_clk, 1)
        if int(m_seen.value): m_latched = True
        if int(s_seen.value): s_latched = True
        if m_latched and s_latched:
            break

    dut._log.info(f"  master cr_pkt_seen_rx latched: {m_latched}")
    dut._log.info(f"  slave  cr_pkt_seen_rx latched: {s_latched}")

    assert m_latched, "master TideLink FC never saw a cr_pkt from slave (cr_pkt_seen_rx stayed 0)"
    assert s_latched, "slave TideLink FC never saw a cr_pkt from master (cr_pkt_seen_rx stayed 0)"


@cocotb.test()
async def test_09_assert_tidelink_fcsm_advances_under_drift(dut):
    """Same as test_07 but with 500 ppm clock drift (representative of
    real two-board PLL skew). The FPGA bug appears to need *some*
    timing-related condition; this drift test gives sim a chance to
    expose it."""
    await setup(dut, master_period_ns=20.000, slave_period_ns=20.010)
    await lock_master(dut)
    await lock_slave(dut)

    await ClockCycles(dut.apb_clk, 8000)

    m_state = int(dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.state.value)
    s_state = int(dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.state.value)
    dut._log.info(f"  Under 500 ppm drift: master state={m_state}, slave state={s_state}")

    assert m_state >= 4, f"master TideLink FC stuck at state={m_state} under drift"
    assert s_state >= 4, f"slave TideLink FC stuck at state={s_state} under drift"
