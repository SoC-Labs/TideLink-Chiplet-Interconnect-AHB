"""
test_idelay_tap_wiring — pins the §9 IDELAYE2 RX delay element wiring.

SoC Labs §9 structural fix (2026-05-18). The per-lane IDELAYE2 RX delay
element (fpga/rtl/tidelink_idelay_rx.sv, instantiated as u_idelay_rx inside
axi_chiplet_controller) is driven by the SAME per-lane phase value the
calibrator already feeds into the Wlink deserialiser
(swi_phase_offset_w[31:0], lane N nibble at [4N+3:4N]). This converts the
calibrator's "phase" from a deserialiser bit-SELECT only into a real,
characterised clk-to-data delay at the IOB — the structural fix for the
build-to-build slave-RX-lock nondeterminism.

cocotb cannot test FPGA routing skew or the Xilinx IDELAYE2 silicon
behaviour (the wlink_pair TB elaborates the controller with USE_IDELAY=0,
the bit-exact passthrough — there is NO unisim primitive in sim). What it
CAN and MUST pin, so a future RTL refactor that breaks the calibrator→tap
path is caught:

  1. The IDELAY wrapper instance EXISTS in the controller hierarchy
     (u_idelay_rx) — proves it was actually instantiated, not dropped.
  2. Its tap source `phase_tap_i` is byte-identical to `swi_phase_offset_w`
     — i.e. the IDELAY tap is driven by the EXACT bus the Wlink
     `.swi_phase_offset_in` consumes (the calibrator OR Region-8 override).
     This is the load-bearing wiring: tap == what the calibrator drives.
  3. With USE_IDELAY=0 (the sim default — and bit-exact requirement),
     `pad_rx_o` == `pad_rx_i` (the Wlink still sees the raw pads, so every
     existing pair/align test stays valid).

Invocation (from cocotb/phy_align/):
    rm -rf sim_build ../wlink_pair/sim_build && make MODULE=test_idelay_tap_wiring

(The pair simv does NOT auto-rebuild on submodule RTL edits — clean first.)
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, ctrl_write, ctrl_read
from test_autocal_integrated import _chiplet_path

# Region 8 slot 6 = SWI_PHASE_OFFSET (ctrl_reg_addr {1, 3'h6} = 0b1110).
R8_SWI_PHASE_OFFSET = 0b1110


def _idelay(dut, side):
    """The tidelink_idelay_rx instance inside the chiplet controller."""
    return _chiplet_path(dut, side).u_idelay_rx


def _phase_bus(dut, side):
    """swi_phase_offset_w — the bus the Wlink .swi_phase_offset_in sees."""
    return int(_chiplet_path(dut, side).swi_phase_offset_w.value)


@cocotb.test()
async def test_idelay_instance_present(dut):
    """The IDELAY wrapper must actually be in the controller hierarchy on
    BOTH sides. If a refactor drops the instance, getattr raises and this
    fails loudly (rather than silently reverting to the un-delayed PHY)."""
    await setup(dut)
    for side in ("m", "s"):
        inst = _idelay(dut, side)
        assert inst is not None, f"{side}: u_idelay_rx missing from controller"
        # The load-bearing ports must exist (name-pins the contract).
        _ = inst.phase_tap_i
        _ = inst.pad_rx_i
        _ = inst.pad_rx_o
    dut._log.info(
        "u_idelay_rx present on both sides with phase_tap_i / pad_rx_i / "
        "pad_rx_o — IDELAY wrapper instantiated in the controller"
    )


@cocotb.test()
async def test_idelay_tap_tracks_calibrator_phase(dut):
    """The IDELAY tap source MUST equal swi_phase_offset_w (the exact bus
    the Wlink deserialiser's .swi_phase_offset_in consumes). Drive a
    distinct per-lane phase via Region 8 and assert
    u_idelay_rx.phase_tap_i == swi_phase_offset_w cycle-for-cycle."""
    await setup(dut)
    dut.m_apb_debug_unlock.value = 1
    await ClockCycles(dut.apb_clk, 4)
    await ctrl_write(dut, "m", 0, 0x02)            # role-lock master
    await ClockCycles(dut.apb_clk, 8)

    # Distinct per-lane nibbles (same unfakeable pattern as the §9.7 test).
    per_lane = [1, 0, 3, 0, 5, 0, 7, 0]
    packed = 0
    for ln, nib in enumerate(per_lane):
        packed |= (nib & 0xF) << (4 * ln)
    await ctrl_write(dut, "m", R8_SWI_PHASE_OFFSET, packed)
    await ClockCycles(dut.apb_clk, 8)

    rb = await ctrl_read(dut, "m", R8_SWI_PHASE_OFFSET)
    assert rb == packed, (
        f"Region 8 SWI_PHASE_OFFSET read 0x{rb:08x}, wrote 0x{packed:08x}"
    )

    bus = _phase_bus(dut, "m")
    tap = int(_idelay(dut, "m").phase_tap_i.value)
    dut._log.info(
        f"swi_phase_offset_w=0x{bus:08x}  u_idelay_rx.phase_tap_i=0x{tap:08x}"
    )
    assert tap == bus, (
        f"IDELAY tap source 0x{tap:08x} != swi_phase_offset_w 0x{bus:08x} "
        f"— the calibrator→IDELAY tap wiring is BROKEN: the IDELAY would "
        f"delay by a different value than the calibrator drives into the "
        f"deserialiser, defeating the structural fix."
    )
    assert tap == packed, (
        f"IDELAY tap 0x{tap:08x} != driven per-lane phase 0x{packed:08x} "
        f"(calibrator idle here so swi_phase_offset_w == Region-8 override)"
    )
    dut._log.info(
        "OK: u_idelay_rx.phase_tap_i is byte-identical to the "
        "swi_phase_offset_w bus the Wlink .swi_phase_offset_in consumes — "
        "the IDELAY tap is driven by exactly what the calibrator drives."
    )


@cocotb.test()
async def test_idelay_passthrough_bit_exact(dut):
    """USE_IDELAY=0 (the sim default + the bit-exact requirement): the
    delayed output must equal the raw pad input combinationally, so the
    Wlink still sees the unmodified pads and every existing pair/align
    test remains valid. Sample pad_rx_i vs pad_rx_o over live traffic."""
    await setup(dut)
    # Let the pads settle out of X (POR / link bring-up) before sampling —
    # the passthrough is structural (an `assign), so comparing the raw
    # LogicArrays (X-tolerant, NOT int()) is the right bit-exact check:
    # for `assign pad_rx_o = pad_rx_i`, pad_rx_o tracks pad_rx_i value-for-
    # value INCLUDING x/z. Any divergence means an inserted delay/logic.
    await ClockCycles(dut.master_clk, 200)
    mismatches = 0
    checked = 0
    for _ in range(64):
        await ClockCycles(dut.master_clk, 1)
        for side in ("m", "s"):
            inst = _idelay(dut, side)
            # .binstr compares 0/1/x/z literally — exactly what a pure
            # combinational passthrough must satisfy.
            pi = inst.pad_rx_i.value.binstr
            po = inst.pad_rx_o.value.binstr
            checked += 1
            if pi != po:
                mismatches += 1
                dut._log.error(
                    f"{side}: pad_rx_i={pi} != pad_rx_o={po}"
                )
    assert mismatches == 0, (
        f"USE_IDELAY=0 passthrough NOT bit-exact: {mismatches}/{checked} "
        f"pad_rx_i != pad_rx_o samples. The Wlink would see a different RX "
        f"bus than the raw pads — breaks every pair/align test's premise."
    )
    dut._log.info(
        f"OK: USE_IDELAY=0 passthrough bit-exact over {checked} live "
        f"samples (pad_rx_o binstr == pad_rx_i binstr) — Wlink sees the "
        f"raw pads, every existing pair/align test premise preserved"
    )


def _pack_per_lane(per_lane):
    """Pack 8 per-lane nibbles into the 32-bit swi_phase_offset word
    (lane N at [4N+3:4N]) — identical packing to the §9.7 wiring test."""
    packed = 0
    for ln, nib in enumerate(per_lane):
        packed |= (nib & 0xF) << (4 * ln)
    return packed


@cocotb.test()
async def test_idelay_passthrough_phase_invariant(dut):
    """Audit-rec D1 — passthrough is INDEPENDENT of phase_tap_i.

    Commit 1b2e87e made USE_IDELAY the SOLE gate of the IDELAYE2 path.
    With USE_IDELAY=0 (the sim/ASIC default + the bit-exact requirement)
    the module MUST be a pure `assign pad_rx_o = pad_rx_i` that does NOT
    observe phase_tap_i AT ALL. test_idelay_passthrough_bit_exact only
    samples bit-exactness at the calibrator-idle phase — it would NOT
    catch a refactor that let phase_tap_i leak into pad_rx_o in the
    g_passthru branch (the load-bearing invariant of 1b2e87e).

    This test drives a DISTINCT non-zero per-lane phase via the Region-8
    SWI_PHASE_OFFSET override, proves pad_rx_o==pad_rx_i under it, then
    CHANGES the phase to a clearly-different pattern MID-STREAM and proves
    (a) still bit-exact, and (b) for every input value seen under BOTH
    patterns the output is byte-identical — i.e. ZERO perturbation
    attributable to the phase change. A phase leak in g_passthru
    (e.g. `pad_rx_o = pad_rx_i ^ {NUM_LANES{|phase_tap_i}}`) fails (b)
    (and almost always (a)) the instant the second pattern is written.

    The Region-8 SWI_PHASE_OFFSET override is a PER-SIDE register: a write
    via ctrl_write(dut, "m", ...) drives ONLY the master's
    swi_phase_offset_w (== master u_idelay_rx.phase_tap_i). The slave's
    calibrator stays idle so its bus holds 0 — a "phase change" never
    occurs there, so the load-bearing invariance proof is MASTER-side
    (where phase_tap_i genuinely transitions A->B). The slave side is
    still held to bit-exact passthrough as a corroborating check (its
    phase is constant 0, so any pad_rx_o!=pad_rx_i there is also a bug).
    This mirrors the existing tests in this file, which likewise drive
    Region-8 on "m" only and read the master phase bus."""
    await setup(dut)
    dut.m_apb_debug_unlock.value = 1
    await ClockCycles(dut.apb_clk, 4)
    await ctrl_write(dut, "m", 0, 0x02)            # role-lock master
    await ClockCycles(dut.apb_clk, 8)

    # Two clearly-different non-zero per-lane phase patterns. Pattern A is
    # the odd-lane nibble style already used in this file; pattern B is its
    # near-complement so EVERY lane's phase nibble changes between writes —
    # any phase_tap_i dependence in g_passthru perturbs every lane.
    phase_a = [1, 0, 3, 0, 5, 0, 7, 0]
    phase_b = [15, 14, 13, 12, 11, 10, 9, 8]
    packed_a = _pack_per_lane(phase_a)
    packed_b = _pack_per_lane(phase_b)

    # --- Phase pattern A: drive on the master, verify it landed --------
    await ctrl_write(dut, "m", R8_SWI_PHASE_OFFSET, packed_a)
    await ClockCycles(dut.apb_clk, 8)
    rb_a = await ctrl_read(dut, "m", R8_SWI_PHASE_OFFSET)
    assert rb_a == packed_a, (
        f"Region 8 SWI_PHASE_OFFSET read 0x{rb_a:08x}, wrote phase A "
        f"0x{packed_a:08x} — override path did not take, test premise void"
    )
    bus_a = _phase_bus(dut, "m")
    assert bus_a == packed_a, (
        f"m: swi_phase_offset_w=0x{bus_a:08x} != phase A 0x{packed_a:08x} "
        f"(calibrator idle, the Region-8 override must own the master bus "
        f"that feeds master u_idelay_rx.phase_tap_i)"
    )
    tap_a = int(_idelay(dut, "m").phase_tap_i.value)
    assert tap_a == packed_a, (
        f"m: u_idelay_rx.phase_tap_i=0x{tap_a:08x} != phase A "
        f"0x{packed_a:08x} — the IDELAY tap is not seeing phase A; the "
        f"invariance check below would not be exercising a phase change"
    )
    dut._log.info(
        f"phase A 0x{packed_a:08x} driven onto master swi_phase_offset_w "
        f"== master u_idelay_rx.phase_tap_i (slave calibrator idle, slave "
        f"bus held 0 — invariance proof is master-side where phase moves)"
    )

    # Settle out of POR/bring-up X, then sample under phase A. Record, per
    # side, the observed pad_rx_i binstr -> pad_rx_o binstr mapping. Under a
    # correct passthrough this is always the identity; we KEEP it so the
    # phase-B pass can prove the SAME inputs still map the SAME way.
    await ClockCycles(dut.master_clk, 200)
    seen_a = {"m": {}, "s": {}}
    mismatches_a = 0
    checked_a = 0
    for _ in range(64):
        await ClockCycles(dut.master_clk, 1)
        for side in ("m", "s"):
            inst = _idelay(dut, side)
            pi = inst.pad_rx_i.value.binstr
            po = inst.pad_rx_o.value.binstr
            checked_a += 1
            if pi != po:
                mismatches_a += 1
                dut._log.error(
                    f"phase A {side}: pad_rx_i={pi} != pad_rx_o={po}"
                )
            # Last write wins; a clean passthrough is deterministic in
            # pad_rx_i, so any prior entry for this key must already match.
            seen_a[side][pi] = po
    assert mismatches_a == 0, (
        f"phase A: USE_IDELAY=0 passthrough NOT bit-exact: "
        f"{mismatches_a}/{checked_a} pad_rx_i != pad_rx_o samples"
    )
    dut._log.info(
        f"OK phase A: passthrough bit-exact over {checked_a} samples; "
        f"recorded {len(seen_a['m'])} (m) / {len(seen_a['s'])} (s) "
        f"distinct pad_rx_i->pad_rx_o entries for the invariance check"
    )

    # --- Phase pattern B: re-write Region-8 WHILE traffic flows ---------
    await ctrl_write(dut, "m", R8_SWI_PHASE_OFFSET, packed_b)
    await ClockCycles(dut.apb_clk, 8)
    rb_b = await ctrl_read(dut, "m", R8_SWI_PHASE_OFFSET)
    assert rb_b == packed_b, (
        f"Region 8 SWI_PHASE_OFFSET read 0x{rb_b:08x}, wrote phase B "
        f"0x{packed_b:08x} — mid-stream phase change did not take"
    )
    bus_b = _phase_bus(dut, "m")
    assert bus_b == packed_b, (
        f"m: swi_phase_offset_w=0x{bus_b:08x} != phase B 0x{packed_b:08x} "
        f"— the mid-stream phase change did not reach the master bus"
    )
    tap_b = int(_idelay(dut, "m").phase_tap_i.value)
    assert tap_b == packed_b and tap_b != tap_a, (
        f"m: u_idelay_rx.phase_tap_i=0x{tap_b:08x} (was 0x{tap_a:08x}); "
        f"expected phase B 0x{packed_b:08x} and DIFFERENT from phase A — "
        f"phase_tap_i did NOT actually change, the invariance check below "
        f"would be vacuous (it must exercise a real phase transition)"
    )
    dut._log.info(
        f"master phase_tap_i changed MID-STREAM A->B: 0x{tap_a:08x} -> "
        f"0x{tap_b:08x} (every lane's nibble differs); sampling under "
        f"phase B — master proves invariance, slave corroborates passthru"
    )

    mismatches_b = 0
    perturbed = 0
    checked_b = 0
    repeated = {"m": 0, "s": 0}
    for _ in range(64):
        await ClockCycles(dut.master_clk, 1)
        for side in ("m", "s"):
            inst = _idelay(dut, side)
            pi = inst.pad_rx_i.value.binstr
            po = inst.pad_rx_o.value.binstr
            checked_b += 1
            # (a) still a bit-exact passthrough under the new phase.
            if pi != po:
                mismatches_b += 1
                dut._log.error(
                    f"phase B {side}: pad_rx_i={pi} != pad_rx_o={po}"
                )
            # (b) zero perturbation attributable to the phase change: an
            # input value also seen under phase A must produce the IDENTICAL
            # output now. If phase_tap_i leaked into pad_rx_o, the SAME
            # pad_rx_i would map to a DIFFERENT pad_rx_o under phase B.
            if pi in seen_a[side]:
                repeated[side] += 1
                if seen_a[side][pi] != po:
                    perturbed += 1
                    dut._log.error(
                        f"phase B {side}: pad_rx_i={pi} -> pad_rx_o={po} "
                        f"but under phase A the SAME input -> "
                        f"{seen_a[side][pi]} — pad_rx_o is phase-DEPENDENT, "
                        f"g_passthru leaks phase_tap_i (defeats 1b2e87e)"
                    )
    assert mismatches_b == 0, (
        f"phase B: USE_IDELAY=0 passthrough NOT bit-exact: "
        f"{mismatches_b}/{checked_b} pad_rx_i != pad_rx_o samples — the "
        f"mid-stream phase change perturbed the passthrough datapath"
    )
    assert perturbed == 0, (
        f"phase B: {perturbed} repeated-input samples produced a DIFFERENT "
        f"pad_rx_o than under phase A for the SAME pad_rx_i — the "
        f"USE_IDELAY=0 g_passthru branch is NOT independent of "
        f"phase_tap_i. 1b2e87e's sole-gate invariant (phase has ZERO "
        f"effect when USE_IDELAY=0) is BROKEN."
    )
    # The MASTER is the side whose phase_tap_i actually transitioned A->B;
    # the invariance proof is only non-vacuous if the SAME pad_rx_i value
    # was observed before AND after that transition there.
    assert repeated["m"] > 0, (
        f"no pad_rx_i value recurred on the MASTER across the phase-A and "
        f"phase-B windows (m repeated={repeated['m']}) — the phase-"
        f"invariance assertion never actually fired on the side whose "
        f"phase_tap_i changed; the live link did not replay a comparable "
        f"RX value across the mid-stream phase change"
    )
    dut._log.info(
        f"OK: USE_IDELAY=0 passthrough is PHASE-INVARIANT — over a "
        f"mid-stream MASTER phase change (0x{packed_a:08x} -> "
        f"0x{packed_b:08x}) pad_rx_o stayed bit-exact ({checked_b} "
        f"samples, both sides) AND every one of {repeated['m']} master "
        f"(+{repeated['s']} slave) repeated pad_rx_i values mapped to the "
        f"IDENTICAL pad_rx_o as before — zero perturbation attributable "
        f"to phase_tap_i. Closes audit-rec D1; defends 1b2e87e's "
        f"sole-gate invariant (phase_tap_i has NO effect, USE_IDELAY=0)."
    )
