"""Post-recal LINK_DATA advance test — pin-points the recal-induced bug.

THE BISECT
----------
Two new finding pairs from 2026-05-25 testing on main RTL:

  (a) test_link_idle_advance_with_payload      → 3/3 PASS (no recal flow)
      Full LINK_DATA bidirectional loop works when you skip the recal_cycle.

  (b) test_paired_recal_to_link_data           → 1/2 FAIL (with recal flow)
      Same loop FAILS after recal_cycle because master never latches
      cr_pkt_seen_rx.

The difference is the recal_cycle (slot0=0x3 → wait → slot0=0x1 → wait).
This test goes further: it does the recal_cycle, then forces the app-side
a2l valid (like test_link_idle_advance_with_payload). If the FCSM advance
4 → 5 STILL works under app-pressure, the recal didn't break the data
path — only the credit handshake (cr_pkt_seen_rx never latched on master).
If FCSM advance ALSO fails, the recal broke the whole link.

This is the test that splits the failure into "credit-bookkeeping bug"
vs "data-path bug".

PASS criterion
--------------
test_01: After recal_cycle + forced app packet, master FCSM should reach
         LINK_DATA. Whether or not this passes splits the bug class.
test_02: Same as test_01 but slave-side data observation. Splits the
         second leg.

Both tests are diagnostic-quality: they log loudly which leg failed.

Invocation
----------
  rm -rf sim_build ../phy_align/sim_build
  make MODULE=test_post_recal_link_data_advance
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave
from test_paired_recal_to_link_data import (
    recal_cycle, drop_training_and_swreset_ll,
    FCSM_LINK_DATA, FCSM_LINK_IDLE, STATE_NAME,
)
from test_link_idle_advance_with_payload import (
    _force_app_packet, _release_app_packet, _wlink, _fcsm,
)


# -----------------------------------------------------------------------
# TEST 1 — KEY TEST: after recal_cycle, does forcing the app a2l valid
# advance the master FCSM to LINK_DATA? If yes, the bug is purely in
# credit handshake bookkeeping (cr_pkt_seen_rx asymmetry); if no, the
# data path itself is broken.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_01_master_advance_to_link_data_after_recal(dut):
    """Replay HW bringup (with recal_cycle) then force master's app a2l
    valid HIGH. Probe whether master FCSM advances 4->5."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # Replay the HW bringup sequence (this is the path that triggers the bug
    # in test_paired_recal_to_link_data on main).
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)

    # Let FCSMs converge to wherever they'll wedge.
    m = _fcsm(dut, "m")
    s = _fcsm(dut, "s")
    await ClockCycles(dut.master_clk, 1000)

    pre_m = int(m.state.value); pre_s = int(s.state.value)
    pre_m_cr = int(m.cr_pkt_seen_rx.value); pre_s_cr = int(s.cr_pkt_seen_rx.value)
    dut._log.info(
        f"  post-recal pre-force: m.state={pre_m}({STATE_NAME.get(pre_m,'?')}) "
        f"s.state={pre_s}({STATE_NAME.get(pre_s,'?')}) "
        f"m.cr={pre_m_cr} s.cr={pre_s_cr}")

    # Force the master's app interface to present a valid packet.
    _force_app_packet(_wlink(dut, "m"), 0xCAFEBABEDEAD)

    reached_data = False
    cycles_to_data = -1
    for c in range(4000):
        await ClockCycles(dut.master_clk, 1)
        if int(m.state.value) >= FCSM_LINK_DATA:
            reached_data = True
            cycles_to_data = c
            break

    final_m = int(m.state.value); final_s = int(s.state.value)
    final_m_cr = int(m.cr_pkt_seen_rx.value); final_s_cr = int(s.cr_pkt_seen_rx.value)
    dut._log.info(
        f"  post-force: m.state={final_m}({STATE_NAME.get(final_m,'?')}) "
        f"s.state={final_s}({STATE_NAME.get(final_s,'?')}) "
        f"m.cr={final_m_cr} s.cr={final_s_cr} "
        f"reached_LINK_DATA={reached_data} cycles_to_data={cycles_to_data}")

    _release_app_packet(_wlink(dut, "m"))

    # Diagnostic logging only — the assert is targeted to surface the SPLIT.
    if reached_data:
        dut._log.info(
            "  SPLIT FINDING (data-path GOOD): master FCSM advances to "
            "LINK_DATA even after recal_cycle. The recal bug is purely a "
            "credit-handshake bookkeeping issue (cr_pkt_seen_rx asymmetry); "
            "the LINK_DATA gate and the application data path are not "
            "affected by the recal_cycle.")
    else:
        dut._log.error(
            "  SPLIT FINDING (data-path BROKEN): master FCSM CANNOT advance "
            "to LINK_DATA after recal_cycle. The recal_cycle broke not just "
            "credit bookkeeping but the LINK_IDLE→LINK_DATA gate itself.")

    assert reached_data, (
        f"master FCSM did not reach LINK_DATA after recal_cycle even with "
        f"forced app a2l valid (final state={final_m}, cr_pkt_seen_rx="
        f"{final_m_cr}). The recal_cycle broke the LINK_IDLE→LINK_DATA gate")


# -----------------------------------------------------------------------
# TEST 2 — slave-side: after recal_cycle + master force, does the slave
# observe a data packet? Splits the data-direction independently.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_02_slave_observes_data_after_recal(dut):
    """After recal_cycle + master app force, does the slave's LL_RX
    decode a data packet?"""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)
    await ClockCycles(dut.master_clk, 1000)

    _force_app_packet(_wlink(dut, "m"), 0x11223344AABB)

    m = _fcsm(dut, "m"); s = _fcsm(dut, "s")
    # Wait for master to potentially transition; doesn't matter if it does.
    for _ in range(4000):
        await ClockCycles(dut.master_clk, 1)
        if int(m.state.value) >= FCSM_LINK_DATA:
            break

    slave_saw_data = False
    for c in range(8000):
        await ClockCycles(dut.master_clk, 1)
        try:
            if int(s.pkt_is_data_pkt.value):
                slave_saw_data = True
                break
        except Exception:
            try:
                if int(s.auto_rx_in_valid.value) and \
                   int(s.auto_rx_in_sop.value):
                    slave_saw_data = True
                    break
            except Exception:
                pass

    dut._log.info(
        f"  slave_saw_data={slave_saw_data}  s.state={int(s.state.value)} "
        f"m.state={int(m.state.value)}")
    _release_app_packet(_wlink(dut, "m"))

    if slave_saw_data:
        dut._log.info(
            "  SPLIT FINDING: slave observes data packet after recal_cycle. "
            "The m→s data path holds across recal; the recal-induced bug is "
            "specifically in the credit handshake direction (cr_pkt_seen_rx "
            "on the master) — NOT in the data forwarding path.")
    else:
        dut._log.error(
            "  SPLIT FINDING: slave NEVER observes data packet after "
            "recal_cycle. The m→s data path itself is corrupted by the "
            "recal — likely a byte-align / serializer-reset issue on the TX "
            "side that does not self-recover.")

    assert slave_saw_data, (
        f"slave LL_RX never decoded a data packet from the master after "
        f"recal_cycle. m→s data path corrupted by the recal_cycle")


# -----------------------------------------------------------------------
# TEST 3 — Reverse direction: drive slave→master after recal. Does the
# master observe slave's data packet? This is the polarity-flipped half
# of the bug — the user's report says option (c) eliminates the slave
# fail but leaves a master fail in 6/12 fuzz scenarios. This is the
# targeted repro for that.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_03_master_observes_data_after_recal_reverse(dut):
    """After recal_cycle + slave app force, does the master's LL_RX
    decode a data packet?

    This is the diagnostic for the polarity-flipped master-side fail
    that option (c) leaves in 6/12 fuzz scenarios."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)
    await ClockCycles(dut.master_clk, 1000)

    _force_app_packet(_wlink(dut, "s"), 0xAABBCCDDEEFF)

    m = _fcsm(dut, "m"); s = _fcsm(dut, "s")
    for _ in range(4000):
        await ClockCycles(dut.master_clk, 1)
        if int(s.state.value) >= FCSM_LINK_DATA:
            break

    master_saw_data = False
    for _ in range(8000):
        await ClockCycles(dut.master_clk, 1)
        try:
            if int(m.pkt_is_data_pkt.value):
                master_saw_data = True
                break
        except Exception:
            try:
                if int(m.auto_rx_in_valid.value) and \
                   int(m.auto_rx_in_sop.value):
                    master_saw_data = True
                    break
            except Exception:
                pass

    dut._log.info(
        f"  master_saw_data={master_saw_data}  m.state={int(m.state.value)} "
        f"s.state={int(s.state.value)}")
    _release_app_packet(_wlink(dut, "s"))

    assert master_saw_data, (
        f"master LL_RX never decoded a data packet from the slave after "
        f"recal_cycle. This is the polarity-flipped slave→master half of "
        f"the recal-induced bug")
