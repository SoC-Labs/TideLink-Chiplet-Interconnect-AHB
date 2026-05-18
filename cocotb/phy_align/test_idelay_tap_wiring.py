"""
test_idelay_tap_wiring — pins the §9 IDELAYE2 RX delay element wiring.

SoC Labs §9 structural fix (2026-05-18). The per-lane IDELAYE2 RX delay
element (src/rtl/tidelink_idelay_rx.sv, instantiated as u_idelay_rx inside
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
