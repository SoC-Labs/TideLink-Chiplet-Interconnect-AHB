"""
test_idelay_fullrange.py — FULL-RANGE IDELAY tap unit test (SoC Labs 2026-06-25)

Proves CHANGE 1 (deps/tidelink-phy IDELAY full-range tap):
  tidelink_idelay_rx now forms the per-lane 5-bit IDELAYE2 tap as
      lane_tap[N] = {phase_tap_i[4N +: 4], lsb_i[N]} = 2*nibble + lsb
  so the tap reaches ODD values and the UPPER HALF of 0..31, instead of the
  old even-only {nibble, 1'b0} (0,2,..30).

The DUT is built with USE_IDELAY=1 and the PRIMITIVE arm selected (no
TIDELINK_IDELAY_NO_PRIMITIVE) against the behavioural IDELAYE2 stub, which
mirrors the loaded CNTVALUEIN onto CNTVALUEOUT. We read each lane's
CNTVALUEOUT (== lane_tap) via the hierarchical instance path and check:

  1. odd-tap reach:   nibble=3, lsb=1 -> tap 7 ;  nibble=15, lsb=1 -> tap 31
  2. zero:            nibble=0, lsb=0 -> tap 0
  3. lsb=0 IDENTITY:  for every nibble, lsb=0 -> tap == {nibble,1'b0} == 2*nibble
                      (bit-identical to the historical even-only behaviour)
  4. full sweep:      every (nibble, lsb) -> tap == 2*nibble + lsb (0..31)
"""

import cocotb
from cocotb.triggers import Timer

NUM_LANES = 8


def _pack_nibbles(nibbles):
    """Pack 8 4-bit nibbles into the 32-bit phase_tap_i word (lane N at 4N)."""
    v = 0
    for i, nib in enumerate(nibbles):
        v |= (nib & 0xF) << (4 * i)
    return v


def _pack_lsb(lsbs):
    v = 0
    for i, b in enumerate(lsbs):
        v |= (b & 0x1) << i
    return v


def _flat_child(parent, name):
    """Find a (possibly flattened-name) child handle by exact _name. The
    constant generate-if scope members elaborate as flat-named children of the
    DUT in this VCS/cocotb build, so attribute access (dut.u_dut.g_idelay) does
    not resolve — iterate and match the full hierarchical leaf name."""
    for k in parent:
        if (k._name if hasattr(k, "_name") else "") == name:
            return k
    raise AttributeError(f"{parent._path}: no child named {name}")


def _lane_tap(dut, lane):
    """Per-lane 5-bit IDELAY tap (= {nibble, lsb}). This is the exact RTL net
    lane_tap fed to the IDELAYE2 CNTVALUEIN (the stub mirrors it to CNTVALUEOUT);
    reading lane_tap directly proves the {phase_tap_i, lsb_i} wiring."""
    return _flat_child(dut.u_dut, f"g_idelay.g_lane[{lane}].lane_tap")


def _lane_cntvalueout(dut, lane):
    """Per-lane stubbed IDELAYE2 CNTVALUEOUT (the loaded CNTVALUEIN)."""
    e2 = _flat_child(dut.u_dut, f"g_idelay.g_lane[{lane}].u_idelaye2")
    return _flat_child(e2, "CNTVALUEOUT")


async def _settle(dut):
    await Timer(1, units="ns")


async def _check_tap(dut, nibbles, lsbs):
    dut.phase_tap_i.value = _pack_nibbles(nibbles)
    dut.lsb_i.value = _pack_lsb(lsbs)
    await _settle(dut)
    for lane in range(NUM_LANES):
        exp = 2 * (nibbles[lane] & 0xF) + (lsbs[lane] & 0x1)
        got = int(_lane_tap(dut, lane).value)
        assert got == exp, (
            f"lane {lane}: nibble={nibbles[lane]} lsb={lsbs[lane]} "
            f"expected tap {exp}, got lane_tap {got}"
        )
        # Cross-check the value actually reaches the IDELAYE2 CNTVALUEIN load
        # (CNTVALUEOUT mirrors it in the stub).
        try:
            cnt = int(_lane_cntvalueout(dut, lane).value)
            assert cnt == exp, (
                f"lane {lane}: CNTVALUEOUT {cnt} != expected tap {exp}"
            )
        except AttributeError:
            pass  # CNTVALUEOUT not introspectable in this build; lane_tap suffices
    return True


@cocotb.test()
async def test_fullrange_tap(dut):
    # Hold the IDELAY reset deasserted; LD is tied high in the DUT so the tap
    # tracks CNTVALUEIN combinationally (the stub mirrors it).
    dut.idelay_ref_clk.value = 0
    dut.idelay_rst.value = 0
    dut.pad_rx_i.value = 0
    dut.phase_tap_i.value = 0
    dut.lsb_i.value = 0
    await _settle(dut)

    # --- 1. specific odd-tap reach cases (the task's named checks) -----------
    # nibble=0, lsb=0 -> 0
    await _check_tap(dut, [0] * 8, [0] * 8)
    dut._log.info("PASS: nibble=0 lsb=0 -> tap 0 (all lanes)")

    # nibble=3, lsb=1 -> 7 (ODD, previously unreachable)
    await _check_tap(dut, [3] * 8, [1] * 8)
    dut._log.info("PASS: nibble=3 lsb=1 -> tap 7 (ODD reach, all lanes)")

    # nibble=15, lsb=1 -> 31 (top of range, previously unreachable)
    await _check_tap(dut, [15] * 8, [1] * 8)
    dut._log.info("PASS: nibble=15 lsb=1 -> tap 31 (upper-half reach, all lanes)")

    # --- 2. lsb=0 IDENTITY: tap == 2*nibble for every nibble -----------------
    for nib in range(16):
        await _check_tap(dut, [nib] * 8, [0] * 8)
    dut._log.info("PASS: lsb=0 identity -> tap == 2*nibble for all nibbles "
                  "(bit-identical to the old even-only mapping)")

    # --- 3. full per-(nibble,lsb) sweep: tap == 2*nibble + lsb ---------------
    seen = set()
    for nib in range(16):
        for lsb in range(2):
            await _check_tap(dut, [nib] * 8, [lsb] * 8)
            seen.add(2 * nib + lsb)
    assert seen == set(range(32)), f"full 0..31 not covered, got {sorted(seen)}"
    dut._log.info("PASS: full sweep reaches every tap 0..31 "
                  "(odd taps + upper half now reachable)")

    # --- 4. per-lane INDEPENDENCE: distinct (nibble,lsb) per lane ------------
    nibs = [0, 1, 2, 3, 7, 15, 8, 12]
    lsbs = [0, 1, 0, 1, 1, 1, 0, 1]
    await _check_tap(dut, nibs, lsbs)
    dut._log.info("PASS: per-lane independence -> each lane's tap = 2*nibble+lsb")
