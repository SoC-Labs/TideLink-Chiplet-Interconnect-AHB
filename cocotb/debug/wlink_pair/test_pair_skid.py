"""Parameterised bit-skid reproduction test for the wlink_pair testbench.

Hypothesis under test
---------------------
On the Pynq-Z2 pair we observe a deterministic 3-bit serial-to-parallel
boundary misalignment in master's `WavD2DGpioRx` (BRINGUP_REPORT.md §6).
Master's LL_RX `byte0_reg` distribution exactly matches the seven FC
channels' `cr_id` bytes (0x08, 0x0c, 0x10, 0x14, 0x18, 0x40, 0x44)
right-shifted by 3 bits, and aliases into the four buckets
{0x01, 0x02, 0x03, 0x08} in the proportions {2, 2, 1, 2}.
`ecc_check_corrupted` is therefore expected to be high every cycle,
FCSM `state` stays at 1 (SEND_CREDITS1), `cr_pkt_seen_rx` never asserts.

The cocotb pair tests pass in sim because the testbench wires master TX to
slave RX with **zero delay** — the bit-clock and the data arrive aligned,
so the slave's deserialiser `count` indexes the correct bit-position.

This test inserts a parameterised bit-cell skid (see `pad_skid.sv`) between
TX and RX pads to recreate the FPGA experience in simulation.

How to run
----------
From `cocotb/wlink_pair/`:
    make MODULE=test_pair_skid SKID_BITS=0    # passthrough — should PASS
    make MODULE=test_pair_skid SKID_BITS=3    # FPGA repro — should FAIL
    make MODULE=test_pair_skid SKID_BITS=1    # arbitrary shift — should FAIL
    ...

The SKID_BITS value is forwarded into tb_top as the `TB_TOP_SKID_BITS`
preprocessor `+define+`, which sets the tb_top `SKID_BITS` parameter.
The `pad_skid` module is a per-lane shift register of depth SKID_BITS
on each of the eight pad data lines; pad_clk is forwarded unchanged.

Expected results
----------------
SKID_BITS=0 → bring-up converges:
    master.cr_pkt_seen_rx asserts within ~5000 cycles
    slave.cr_pkt_seen_rx  asserts within ~5000 cycles
    Both FCSM `state` reach >= 4
    ecc_check_corrupted is low after first few cycles

SKID_BITS=3 → bring-up STUCK (reproduces FPGA bug):
    cr_pkt_seen_rx never asserts on either side
    FCSM `state` stays at 1
    ecc_check_corrupted asserts every cycle
    byte0_reg distribution aliases into {0x01, 0x02, 0x03, 0x08}

SKID_BITS=1..7 (except 0) → bring-up STUCK, byte0_reg pattern depends on
shift amount.

Pointer to context
------------------
- BRINGUP_REPORT.md §6  (byte distribution analysis)
- BRINGUP_REPORT.md §8.1 (in-RTL bit-slip fix — to be validated against this test)
- BRINGUP_REPORT.md §8.4 (why swi_phase_offset cannot fix this)
- pad_skid.sv          (the bit-cell skid module wired into tb_top)
"""
import os
from collections import Counter

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_link_bringup import (
    setup, lock_master, lock_slave, snapshot,
)


def _skid_bits():
    """Read SKID_BITS from environment (forwarded by the Makefile)."""
    try:
        return int(os.environ.get("SKID_BITS", "0"))
    except ValueError:
        return 0


async def _measure_with_histogram(dut, cycles, label):
    """Run for `cycles` master_clk ticks; return state info + byte0 histogram.

    Internal signals probed (all inside u_master / u_slave hierarchy):
      - u_<side>.u_wlink.tl2wl.wlink_tidelinktl.state          : FCSM state
      - u_<side>.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx : cr_pkt seen flag
      - u_<side>.u_wlink.wlink_link_layer_inst.rx.byte0_reg    : LL_RX byte 0
      - u_<side>.u_wlink.wlink_link_layer_inst.rx.byte1_reg    : LL_RX byte 1
      - u_<side>.u_wlink.wlink_link_layer_inst.rx.ecc_check_corrupted

    The cocotb HDL handle lookup is best-effort: not every hierarchy path
    exists on every Wlink config (Chisel-generated names drift), so each
    probe is wrapped in a getattr-chain helper.
    """
    def _resolve(root, dotted):
        cur = root
        for part in dotted.split("."):
            try:
                cur = getattr(cur, part)
            except AttributeError:
                return None
        return cur

    m_state = _resolve(dut, "u_master.u_wlink.tl2wl.wlink_tidelinktl.state")
    s_state = _resolve(dut, "u_slave.u_wlink.tl2wl.wlink_tidelinktl.state")
    m_cr    = _resolve(dut, "u_master.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx")
    s_cr    = _resolve(dut, "u_slave.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx")
    m_crack = _resolve(dut, "u_master.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx")
    s_crack = _resolve(dut, "u_slave.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx")

    # WlinkRxLinkLayer signals — the Wlink wrapper instance name varies by
    # config. The Chisel-generated Wlink.v instantiates it as `llrx`.
    rx_paths = [
        "u_master.u_wlink.llrx",
        "u_master.u_wlink.wlink_rxll",
        "u_master.u_wlink.wlink_link_layer_inst.rx",
    ]
    m_rx = None
    for p in rx_paths:
        m_rx = _resolve(dut, p)
        if m_rx is not None:
            break
    # Slave-side RX LL hierarchy
    rx_paths_s = [p.replace("u_master", "u_slave") for p in rx_paths]
    s_rx = None
    for p in rx_paths_s:
        s_rx = _resolve(dut, p)
        if s_rx is not None:
            break

    m_byte0 = getattr(m_rx, "byte0_reg", None) if m_rx is not None else None
    m_byte1 = getattr(m_rx, "byte1_reg", None) if m_rx is not None else None
    m_ecc   = getattr(m_rx, "ecc_check_corrupted", None) if m_rx is not None else None
    s_byte0 = getattr(s_rx, "byte0_reg", None) if s_rx is not None else None
    s_ecc   = getattr(s_rx, "ecc_check_corrupted", None) if s_rx is not None else None

    m_byte0_hist = Counter()
    s_byte0_hist = Counter()
    m_ecc_corrupt_count = 0
    s_ecc_corrupt_count = 0
    m_state_max = 0
    s_state_max = 0
    m_cr_latched = False
    s_cr_latched = False
    m_crack_latched = False
    s_crack_latched = False

    for _ in range(cycles):
        await ClockCycles(dut.master_clk, 1)
        try:
            if m_state is not None:
                m_state_max = max(m_state_max, int(m_state.value))
            if s_state is not None:
                s_state_max = max(s_state_max, int(s_state.value))
        except ValueError:
            pass
        try:
            if m_cr is not None and int(m_cr.value):    m_cr_latched = True
            if s_cr is not None and int(s_cr.value):    s_cr_latched = True
            if m_crack is not None and int(m_crack.value): m_crack_latched = True
            if s_crack is not None and int(s_crack.value): s_crack_latched = True
        except ValueError:
            pass
        try:
            if m_byte0 is not None:
                m_byte0_hist[int(m_byte0.value)] += 1
            if s_byte0 is not None:
                s_byte0_hist[int(s_byte0.value)] += 1
            if m_ecc is not None and int(m_ecc.value):
                m_ecc_corrupt_count += 1
            if s_ecc is not None and int(s_ecc.value):
                s_ecc_corrupt_count += 1
        except ValueError:
            pass

    dut._log.info(f"  [{label}] master state_max={m_state_max} cr_seen={m_cr_latched} "
                  f"crack_seen={m_crack_latched} ecc_corrupt={m_ecc_corrupt_count}/{cycles}")
    dut._log.info(f"  [{label}] slave  state_max={s_state_max} cr_seen={s_cr_latched} "
                  f"crack_seen={s_crack_latched} ecc_corrupt={s_ecc_corrupt_count}/{cycles}")

    def _fmt_hist(h, top=8):
        total = sum(h.values())
        if total == 0:
            return "(no samples)"
        items = h.most_common(top)
        return "  ".join(f"0x{k:02x}:{v} ({100.0*v/total:.1f}%)" for k, v in items)

    dut._log.info(f"  [{label}] master byte0_reg top: {_fmt_hist(m_byte0_hist)}")
    dut._log.info(f"  [{label}] slave  byte0_reg top: {_fmt_hist(s_byte0_hist)}")

    return {
        "m_state_max":   m_state_max,
        "s_state_max":   s_state_max,
        "m_cr":          m_cr_latched,
        "s_cr":          s_cr_latched,
        "m_crack":       m_crack_latched,
        "s_crack":       s_crack_latched,
        "m_ecc_corrupt": m_ecc_corrupt_count,
        "s_ecc_corrupt": s_ecc_corrupt_count,
        "m_byte0_hist":  m_byte0_hist,
        "s_byte0_hist":  s_byte0_hist,
        "cycles":        cycles,
    }


@cocotb.test()
async def test_pair_skid(dut):
    """Run the standard bring-up sequence and assert based on SKID_BITS.

    SKID_BITS = 0   → expect bring-up to succeed (no skid = current sim behaviour)
    SKID_BITS != 0  → expect bring-up to FAIL (ECC corrupted, FCSM stuck at 1)

    The test asserts on these expectations so cocotb's pass/fail reflects
    the predicted FPGA-vs-sim divergence at each skid amount.
    """
    skid = _skid_bits()
    dut._log.info("=" * 70)
    dut._log.info(f"  test_pair_skid: SKID_BITS = {skid}")
    dut._log.info("=" * 70)

    # Sanity: confirm the testbench picked up the same SKID_BITS we expect.
    try:
        tb_skid = int(dut.SKID_BITS_EXPOSED.value)
        dut._log.info(f"  tb_top.SKID_BITS_EXPOSED = {tb_skid}")
        assert tb_skid == skid, (
            f"Makefile SKID_BITS={skid} but tb_top reports {tb_skid}. "
            "Recompile is needed: `make sim_build_clean` then re-run."
        )
    except AttributeError:
        dut._log.warning("  SKID_BITS_EXPOSED not visible; relying on env var only")

    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # Run for ~5000 cycles — same horizon the assertive bring-up tests use.
    res = await _measure_with_histogram(dut, cycles=5000, label=f"skid={skid}")

    # Final register snapshot for forensic logs.
    await snapshot(dut, 'm', f'skid={skid} final')
    await snapshot(dut, 's', f'skid={skid} final')

    if skid == 0:
        # Passthrough — bring-up must work like the existing tests.
        assert res["m_cr"], (
            f"SKID_BITS=0 (passthrough) but master cr_pkt_seen_rx never asserted "
            f"— existing pair-bringup behaviour is broken."
        )
        assert res["s_cr"], (
            f"SKID_BITS=0 (passthrough) but slave cr_pkt_seen_rx never asserted."
        )
        assert res["m_state_max"] >= 4, (
            f"SKID_BITS=0 master FCSM stuck at state={res['m_state_max']}"
        )
        assert res["s_state_max"] >= 4, (
            f"SKID_BITS=0 slave FCSM stuck at state={res['s_state_max']}"
        )
        dut._log.info("  RESULT: SKID_BITS=0 bring-up SUCCEEDED — passthrough works")
    else:
        # Misaligned — must reproduce the FPGA failure mode.
        # Primary symptom: cr_pkt_seen_rx never asserts on either side.
        assert not res["m_cr"], (
            f"SKID_BITS={skid} but master cr_pkt_seen_rx still asserted — "
            f"link-layer is still finding cr_pkts despite the bit shift. "
            f"That would contradict the 3-bit-shift hypothesis."
        )
        assert not res["s_cr"], (
            f"SKID_BITS={skid} but slave cr_pkt_seen_rx still asserted."
        )
        # Secondary symptom: FCSM stuck at state == 1 (SEND_CREDITS1).
        assert res["m_state_max"] <= 1, (
            f"SKID_BITS={skid} but master FCSM advanced to state={res['m_state_max']}"
        )
        assert res["s_state_max"] <= 1, (
            f"SKID_BITS={skid} but slave FCSM advanced to state={res['s_state_max']}"
        )
        dut._log.info(
            f"  RESULT: SKID_BITS={skid} reproduces FPGA failure mode "
            f"(cr_pkt_seen_rx=0, FCSM<=1, ecc_corrupt={res['m_ecc_corrupt']}/{res['cycles']})"
        )
