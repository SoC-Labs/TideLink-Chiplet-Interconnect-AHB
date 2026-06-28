"""V2 (TIDELINK_PHY_V2) paired-die DOORBELL / IRQ cross gate.

The doorbell channel (unchanged by V2 — V2 only swaps the GPIO PHY; the
doorbell/returner/FC-sideband RTL is the shared TideLink datapath):

    APB write DOORBELL 0x2014 on side A
      -> tidelink_apb_regs.doorbell_trigger
      -> tidelink_returner channel 1 (AHB master)
      -> FC sideband packet across the link (PKT_SIDEBAND)
      -> side B FC adapter RX writes peer DOORBELL_RESPONSE_ADDR (0x2024)
      -> side B doorbell_response_acc += credit_count_data   (R-clear)
      -> side B doorbell_irq = (doorbell_response_acc != 0)

This is the SAME FC-sideband path the slave->master credit-return uses, i.e.
the path the V1 "Bug A" (S->M sideband never crosses the master RX) used to
break. The V1 pair env therefore split the doorbell into two tests:
  test_05_doorbell_master_to_slave  (M->S — the known-good direction)
  test_06_doorbell_slave_to_master  (S->M — the historically broken one)

RE-EVALUATION ON V2: the V2 stack delivers application packets BOTH ways in
this very sim env (test_v2_pair_data test_02 M->S + test_03 S->M both PASS),
so the V1 S->M sideband asymmetry is NOT present on V2. This suite asserts the
doorbell crosses in BOTH directions, mirroring the data-path symmetry. Each
test rings the doorbell on one die and checks the PEER's DOORBELL_RESPONSE_ACC
(0x2024) goes non-zero and the peer's doorbell_irq asserts, with FC a2l/l2a
pulse counts logged for localisation.

DOORBELL_RESPONSE_ACC is W-add / R-clear (tidelink_apb_regs.sv): the first
read of it CLEARS the accumulator. So the proven pattern is: clear-first (one
read), ring exactly one doorbell, then a single read returns one increment.

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_doorbell
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full,
    APB_TIDELINK_BASE, OFF_DOORBELL, OFF_DOORBELL_RESP_ACC,
)

APB_DOORBELL          = APB_TIDELINK_BASE + OFF_DOORBELL        # 0x2014
APB_DOORBELL_RESP_ACC = APB_TIDELINK_BASE + OFF_DOORBELL_RESP_ACC  # 0x2024


# ---------------------------------------------------------------------------
# FC-adapter sideband localisation probes (mirror the V1 pair env's watcher;
# the V2 pair common harness doesn't carry them, so keep them local here).
#   <side>.tl_fc_a2l_valid -> this side SUBMITTED a word to its Wlink TX
#   <side>.tl_fc_l2a_valid -> this side RECEIVED a word from its Wlink RX
# ---------------------------------------------------------------------------
def _fc(tb, side):
    return tb.top(side).u_fc_adapter


def _fc_bit(tb, side, name):
    try:
        return int(getattr(_fc(tb, side), name).value)
    except (AttributeError, ValueError):
        return -1


def _irq(tb, side):
    sig = tb.dut.m_doorbell_irq if side == "m" else tb.dut.s_doorbell_irq
    try:
        return int(sig.value)
    except ValueError:
        return -1


async def watch_fc_pulses(tb, n_cycles, label):
    """Count cycles each side's FC a2l/l2a valid is high over n_cycles, and
    whether the peer's doorbell_irq asserted at any point."""
    c = dict(m_a2l=0, m_l2a=0, s_a2l=0, s_l2a=0, m_irq=0, s_irq=0)
    for _ in range(n_cycles):
        await RisingEdge(tb.dut.hclk)
        if _fc_bit(tb, "m", "tl_fc_a2l_valid") == 1: c["m_a2l"] += 1
        if _fc_bit(tb, "m", "tl_fc_l2a_valid") == 1: c["m_l2a"] += 1
        if _fc_bit(tb, "s", "tl_fc_a2l_valid") == 1: c["s_a2l"] += 1
        if _fc_bit(tb, "s", "tl_fc_l2a_valid") == 1: c["s_l2a"] += 1
        if _irq(tb, "m") == 1: c["m_irq"] += 1
        if _irq(tb, "s") == 1: c["s_irq"] += 1
    tb.log.info(
        f"  [{label}] FC valid-cycle counts over {n_cycles} cy: "
        f"M(a2l={c['m_a2l']},l2a={c['m_l2a']},irq={c['m_irq']})  "
        f"S(a2l={c['s_a2l']},l2a={c['s_l2a']},irq={c['s_irq']})")
    return c


async def ring_and_check(tb, src, dst, ctx):
    """Clear-first the dst accumulator, ring exactly one doorbell on src,
    then verify the dst DOORBELL_RESPONSE_ACC went non-zero and dst
    doorbell_irq asserted. Returns (acc_after, counts)."""
    src_apb = tb.apb(src)
    dst_apb = tb.apb(dst)

    # CLEAR the dst read-to-clear accumulator first (drains any bring-up
    # residual — e.g. the reset-doorbell channel-2 traffic), then settle.
    cleared = await dst_apb.read(APB_DOORBELL_RESP_ACC)
    await ClockCycles(tb.dut.hclk, 50)
    drained = await dst_apb.read(APB_DOORBELL_RESP_ACC)
    await ClockCycles(tb.dut.hclk, 50)
    tb.log.info(f"  [{ctx}] {dst} DOORBELL_RESP_ACC pre-clear={cleared} "
                f"post-clear={drained}")

    # Ring exactly ONE doorbell on src.
    await src_apb.write(APB_DOORBELL, 1)
    counts = await watch_fc_pulses(tb, 3000, f"{ctx} after {src} doorbell ring")

    # A single read returns the accumulated increment.
    acc_after = await dst_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(f"  [{ctx}] {dst} DOORBELL_RESP_ACC after 1 ring = {acc_after} "
                f"(dst doorbell_irq cycles={counts[dst + '_irq']})")
    return acc_after, counts


@cocotb.test()
async def test_01_doorbell_master_to_slave(dut):
    """Ring DOORBELL on master -> slave DOORBELL_RESPONSE_ACC increments and
    slave doorbell_irq asserts. (V1's known-good direction.)"""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    acc, counts = await ring_and_check(tb, "m", "s", "m2s")
    assert acc != 0, (
        f"DOORBELL master->slave did not cross: slave DOORBELL_RESP_ACC=0 "
        f"after one ring. FC pulses M(a2l={counts['m_a2l']},l2a={counts['m_l2a']}) "
        f"S(a2l={counts['s_a2l']},l2a={counts['s_l2a']}).")
    assert counts["s_irq"] > 0, (
        f"slave doorbell_irq never asserted though RESP_ACC={acc}")


@cocotb.test()
async def test_02_doorbell_slave_to_master(dut):
    """Ring DOORBELL on slave -> master DOORBELL_RESPONSE_ACC increments and
    master doorbell_irq asserts.

    This is the V1 "Bug A" direction (S->M FC sideband). It is asserted as a
    HARD PASS here because the V2 stack delivers the S->M datapath in this same
    env (test_v2_pair_data.test_03 PASS) — i.e. the master-RX sideband
    asymmetry is gone on V2. If this ever regresses, the FC-pulse log localises
    it: s_a2l>0 with m_l2a==0 reproduces the exact V1 master-RX-never-decodes
    signature."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    acc, counts = await ring_and_check(tb, "s", "m", "s2m")
    assert acc != 0, (
        f"DOORBELL slave->master did not cross: master DOORBELL_RESP_ACC=0 "
        f"after one ring. FC pulses M(a2l={counts['m_a2l']},l2a={counts['m_l2a']}) "
        f"S(a2l={counts['s_a2l']},l2a={counts['s_l2a']}). "
        f"If s_a2l>0 but m_l2a==0, the S->M sideband does not cross the master "
        f"RX — a regression of the V1 'Bug A' the V2 stack had fixed.")
    assert counts["m_irq"] > 0, (
        f"master doorbell_irq never asserted though RESP_ACC={acc}")


@cocotb.test()
async def test_03_doorbell_bidirectional(dut):
    """Both directions in one bring-up: ring M->S, verify, then ring S->M,
    verify. Proves the doorbell channel is fully bilateral on V2 within a
    single linked session (the IRQ + R-clear accumulator behave independently
    per die)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    acc_m2s, c_m2s = await ring_and_check(tb, "m", "s", "bidir-m2s")
    assert acc_m2s != 0, (
        f"bidir M->S doorbell did not cross (slave RESP_ACC=0). "
        f"FC M(a2l={c_m2s['m_a2l']},l2a={c_m2s['m_l2a']}) "
        f"S(a2l={c_m2s['s_a2l']},l2a={c_m2s['s_l2a']}).")

    await ClockCycles(dut.hclk, 500)

    acc_s2m, c_s2m = await ring_and_check(tb, "s", "m", "bidir-s2m")
    assert acc_s2m != 0, (
        f"bidir S->M doorbell did not cross (master RESP_ACC=0). "
        f"FC M(a2l={c_s2m['m_a2l']},l2a={c_s2m['m_l2a']}) "
        f"S(a2l={c_s2m['s_a2l']},l2a={c_s2m['s_l2a']}).")

    tb.log.info(f"  [bidir] M->S slave RESP_ACC={acc_m2s}  "
                f"S->M master RESP_ACC={acc_s2m}  BOTH crossed")
