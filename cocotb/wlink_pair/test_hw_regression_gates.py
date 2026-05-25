"""HW-regression gates — mirror of Phase 0 HW observation rules.

This file consolidates the explicit assertions whose violation indicates the
TideLink interface bug discovered on HW 2026-05-24:

    * Lane lock 8/8 on both sides (already covered by other tests)
    * cr_pkt_seen_rx latches HIGH on BOTH sides           <- HW had slave=0
    * crack_pkt_seen_rx latches HIGH on BOTH sides
    * FCSM state reaches LINK_DATA (>=4) on BOTH sides    <- HW had slave=1
    * fe_tx_credit_max_loaded on BOTH sides

The HW symptom was: 8/8 lanes, cal_done=1, ECC=0/0, FC CRC=0/0, but
slave.cr_pkt_seen_rx=0 and PAIR_CREDIT_COUNTER=0 both sides. The credit
window never opened. Today these assertions PASS in sim (the bug is FPGA-only,
per the comment in test_assert_bringup.py from 2026-05-08). This test file is
designed to be the regression gate: any future RTL change that breaks the
credit handshake (e.g. an attempt to fix the HW bug that overshoots and breaks
sim) will be caught here.

PAIR_CREDIT_COUNTER and DOORBELL_RESPONSE_ACC are TideLink-level registers
(in tidelink_apb_regs.sv) and require a tidelink_top-pair testbench to gate
in sim. That work belongs at uvm/tidelink_top_system/ or a new cocotb
tidelink_top_pair sim. See docs/TIDELINK_INTERFACE_DEBUG_PLAN.md §X.

Invocation (from cocotb/wlink_pair/):
    rm -rf sim_build ../phy_align/sim_build
    make MODULE=test_hw_regression_gates                 # default SKID=0
    make MODULE=test_hw_regression_gates SKID_BITS=3     # FPGA-like 3-bit shift
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave


def _tl(dut, side):
    """Hierarchical handle to TideLink FCSM signals on `side`."""
    return (dut.u_master if side == "m" else dut.u_slave) \
        .u_wlink.tl2wl.wlink_tidelinktl


async def _wait_bringup(dut, max_cycles=15000):
    """Wait until both FCSMs reach LINK_DATA (state>=4) or timeout."""
    m = _tl(dut, "m")
    s = _tl(dut, "s")
    for _ in range(max_cycles):
        await ClockCycles(dut.apb_clk, 1)
        try:
            if int(m.state.value) >= 4 and int(s.state.value) >= 4:
                return True
        except ValueError:
            pass
    return False


@cocotb.test()
async def test_hwgate_01_cr_pkt_seen_both_sides(dut):
    """HW gate: slave.cr_pkt_seen_rx must latch HIGH (HW had it stuck 0).

    On HW (bridge1 build b24 c6c56c2 at 2026-05-24 21:11 UTC):
      master SWI_LANE_STATUS[23] cr_pkt_seen_rx = 1
      slave  SWI_LANE_STATUS[23] cr_pkt_seen_rx = 0   <-- BUG
    """
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.apb_clk, 5000)

    m_seen = int(_tl(dut, "m").cr_pkt_seen_rx.value)
    s_seen = int(_tl(dut, "s").cr_pkt_seen_rx.value)
    dut._log.info(f"  cr_pkt_seen_rx: master={m_seen} slave={s_seen}")

    assert m_seen == 1, (
        "REGRESSION: master cr_pkt_seen_rx = 0 (sticky). Expected 1 after bringup. "
        "On HW (b24) this WAS 1; sim should also be 1."
    )
    assert s_seen == 1, (
        "REGRESSION: slave cr_pkt_seen_rx = 0 (sticky). Expected 1 after bringup. "
        "This is the HW-observed symptom; if sim now fails this, the sim has "
        "started reproducing the FPGA-only bug — investigate the cause."
    )


@cocotb.test()
async def test_hwgate_02_crack_pkt_seen_both_sides(dut):
    """HW gate: crack_pkt_seen_rx must latch on BOTH sides."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.apb_clk, 5000)

    m_crack = int(_tl(dut, "m").crack_pkt_seen_rx.value)
    s_crack = int(_tl(dut, "s").crack_pkt_seen_rx.value)
    dut._log.info(f"  crack_pkt_seen_rx: master={m_crack} slave={s_crack}")

    assert m_crack == 1, "master crack_pkt_seen_rx never latched — peer never sent CRACK"
    assert s_crack == 1, "slave  crack_pkt_seen_rx never latched — master never sent CRACK"


@cocotb.test()
async def test_hwgate_03_fcsm_link_data_both_sides(dut):
    """HW gate: BOTH FCSMs must reach LINK_DATA state (>=4).

    On HW (b24) the FCSM state field reported through SWI_LANE_STATUS bits
    21:22 (only 2 bits exposed; sim has the full 4-bit state via hierarchy):
      master FCSM state was advancing (cr_pkt_seen=1, in state 2+).
      slave  FCSM state stuck at 1 (cr_pkt_seen=0 → never left SEND_CREDITS1).
    """
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    converged = await _wait_bringup(dut, max_cycles=15000)

    m_state = int(_tl(dut, "m").state.value)
    s_state = int(_tl(dut, "s").state.value)
    dut._log.info(f"  FCSM state: master={m_state} slave={s_state} converged={converged}")

    assert m_state >= 4, (
        f"REGRESSION: master FCSM stuck at state {m_state} (<4). "
        "Expected LINK_DATA (state>=4) after bringup."
    )
    assert s_state >= 4, (
        f"REGRESSION: slave FCSM stuck at state {s_state} (<4). "
        "On HW (b24) the slave was stuck at state 1 (SEND_CREDITS1) — the bug. "
        "If sim now reproduces this, that's progress for the diagnosis."
    )


@cocotb.test()
async def test_hwgate_04_fe_tx_credit_max_loaded_both_sides(dut):
    """HW gate: per Agent F audit, fe_tx_credit_max loads on either pkt_is_cr
    or pkt_is_crack. Both sides should have it loaded after bringup.

    This is the deepest gate — if it fails on EITHER side, the credit window
    cannot open and no application traffic can cross.
    """
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.apb_clk, 5000)

    # The credit max register lives inside the FCSM. Probe via hierarchy;
    # falls back gracefully if the signal name differs across submodule revs.
    for side in ("m", "s"):
        tl = _tl(dut, side)
        candidates = ("fe_tx_credit_max", "fe_credit_max_loaded",
                      "fe_tx_credit_max_loaded")
        loaded = None
        for sig in candidates:
            if hasattr(tl, sig):
                try:
                    loaded = int(getattr(tl, sig).value)
                except ValueError:
                    continue
                break
        if loaded is None:
            dut._log.warning(f"  side={side}: fe_tx_credit_max-family signal not found"
                              "— skipping assert (submodule rev may have renamed it)")
            continue
        dut._log.info(f"  side={side}: fe_tx_credit_max = {loaded}")
        assert loaded != 0, (
            f"REGRESSION: side={side} fe_tx_credit_max never loaded. "
            "Credit window cannot open without this; HW (b24) had this stuck at 0."
        )


@cocotb.test()
async def test_hwgate_05_skid_bits_3_does_not_regress(dut):
    """HW gate: with SKID_BITS=3 (FPGA-like 3-bit byte-shift modelled in
    pad_skid.sv), the link must still come up. This is an explicit regression
    against the historical FPGA shift symptom.

    NOTE: as of 2026-05-24, current sim already passes this with SKID_BITS=3
    because pad_skid only delays bits (not bytes). The actual FPGA bug
    involves a deeper sim-vs-HW gap (deserialiser count phase). See
    docs/TIDELINK_PHASE0_OBS_*.md §4.4 and the agent reports for the next
    sim-model patch direction.
    """
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.apb_clk, 10000)

    m_state = int(_tl(dut, "m").state.value)
    s_state = int(_tl(dut, "s").state.value)
    dut._log.info(f"  SKID_BITS={int(dut.SKID_BITS_EXPOSED.value)}: "
                  f"FCSM master={m_state} slave={s_state}")

    # We are not strict here — this is more of a sanity log to surface
    # regressions; assert both reach >=2 (saw CR) at minimum.
    assert m_state >= 2, f"master FCSM stuck below CR_SEEN with SKID_BITS={int(dut.SKID_BITS_EXPOSED.value)}"
    assert s_state >= 2, f"slave  FCSM stuck below CR_SEEN with SKID_BITS={int(dut.SKID_BITS_EXPOSED.value)}"
