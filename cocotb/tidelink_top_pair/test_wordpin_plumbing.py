# =============================================================================
# test_wordpin_plumbing.py — GATE 2c: word-window pin plumbing / no-dead-end
#
# Proves, on the PATCHED V1 build, that the V1-hoisted per-lane word-pin regs
# are LIVE and the value reaches the RX through the DEDICATED port path
# (controller -> u_wlink -> phy -> gpio -> gpiorx_N.io_word_pin):
#
#   PRIMARY (load-bearing on silicon): APB write 0x2148 (per-lane value) +
#   0x214C (per-lane enable) on the slave controller -> the enabled per-lane
#   nibble appears at gpiorx_N.io_word_pin, and DISABLED lanes stay at 4'h0
#   (OFF-by-default at the pin). This is the path the silicon A->B fix rides;
#   it does NOT depend on the APB readback.
#
# KNOWN V1 OBSERVABILITY GAP (documented, non-load-bearing): in the V1 build
# the APB *readback* of Region-10 (0x2140-0x217F) is owned by tidelink_eye_regs
# via eye_shim_sel in tidelink_top.sv. The `perlane_wp_sel` eye_shim EXCLUSION
# that lets 0x2148/0x214C fall through to the controller's region10_rdata exists
# ONLY inside `ifdef TIDELINK_PHY_V2`; the V1 `else` arm has no such exclusion.
# So a V1 read of 0x2148 returns whatever eye_regs holds at offset 0x08 (it
# happens to be a RW slot that echoes the written word) and 0x214C reads 0.
# The REGISTERS themselves latch correctly (peeked below) and reach the RX —
# only the read-back-for-confirmation is shadowed. A bring-up script that wants
# to CONFIRM the write in V1 must peek the reg / observe RX behaviour, not read
# 0x214C. (Fix, if read-back is wanted in V1: hoist `perlane_wp_sel` out of the
# V2 ifdef so eye_shim is excluded for these slots in V1 too.)
#
# Out of scope (documented in the PR): "word_pin rescues A->B" — not sim-showable
# (shared-clock model has no eye; word_pin only relocates an already-correct
# boundary). Efficacy is silicon-only.
#
# Joint work commissioned on behalf of SoC Labs, Arm Academic Access license.
# Contributors: David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import cocotb
from cocotb.triggers import ClockCycles

from test_tidelink_pair_doorbell import PairTB, APB_TIDELINK_BASE

# Region 10 per-lane word-pin regs (SoC 0x4403_2148 / _214C => APB 0x2148/0x214C).
APB_WORD_PIN_PERLANE     = APB_TIDELINK_BASE + 0x148   # 8 x 4-bit, lane L at [4L+3:4L]
APB_WORD_PIN_PERLANE_EN  = APB_TIDELINK_BASE + 0x14C   # 8-bit, lane L at bit L


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return None


@cocotb.test()
async def test_wordpin_reaches_rx(dut):
    """GATE 2c PRIMARY: APB-written per-lane word-pin reaches gpiorx_N.io_word_pin
    on the slave RX; the enable-gate holds disabled lanes at OFF (4'h0)."""
    tb = PairTB(dut)
    await tb.reset()
    ctrl = dut.u_slave.u_chiplet_controller

    # Distinct nibble per lane so a swap/stuck mis-wire is visible:
    #   lane0=0x1 lane1=0x2 ... lane7=0x8  -> packed 0x87654321
    val_word = 0x8765_4321
    # Enable only EVEN lanes (0,2,4,6) -> 0b0101_0101 = 0x55. ODD lanes stay OFF.
    en_byte  = 0x55

    await tb.s_apb.write(APB_WORD_PIN_PERLANE,    val_word)
    await tb.s_apb.write(APB_WORD_PIN_PERLANE_EN, en_byte)
    await ClockCycles(tb.s_apb._clk, 12)   # APB-domain regs -> PHY effective_word_pin

    # Sanity: the controller regs latched the write (proves the V1 region10_write
    # hoist made the write LAND, even though the read-back is eye_regs-shadowed).
    reg_val = _i(ctrl.swi_word_pin_perlane_r)
    reg_en  = _i(ctrl.swi_word_pin_perlane_en_r)
    tb.log.info(f"[2c] controller regs: perlane_r=0x{reg_val:08x} perlane_en_r=0x{reg_en:02x}")
    assert reg_val == val_word, (
        f"per-lane word-pin VALUE reg did not latch the V1 APB write: "
        f"wrote 0x{val_word:08x}, reg=0x{reg_val:08x} (region10_write hoist failed)")
    assert reg_en == en_byte, (
        f"per-lane word-pin ENABLE reg did not latch the V1 APB write: "
        f"wrote 0x{en_byte:02x}, reg=0x{reg_en:02x}")

    # PRIMARY: the value reaches gpiorx_N.io_word_pin through the dedicated
    # port chain, enable-gated per lane.
    gpio = ctrl.u_wlink.phy.gpio
    expect_val = [(val_word >> (4 * n)) & 0xF for n in range(8)]
    enabled    = [(en_byte >> n) & 1 for n in range(8)]
    seen, mism = [], []
    for n in range(8):
        wp = _i(getattr(gpio, f"gpiorx_{n}").io_word_pin)
        seen.append(wp)
        want = expect_val[n] if enabled[n] else 0x0   # disabled -> OFF (0)
        tag = "EN " if enabled[n] else "off"
        tb.log.info(f"[2c] lane{n} {tag}: io_word_pin=0x{wp:x}  expect=0x{want:x}")
        if wp != want:
            mism.append((n, wp, want, bool(enabled[n])))

    assert not mism, (
        "word-pin did NOT reach gpiorx.io_word_pin correctly "
        "(controller->u_wlink->phy->gpio->gpiorx chain broken or mis-packed): "
        + "; ".join(f"lane{n}: saw 0x{s:x} want 0x{w:x} (en={e})"
                    for n, s, w, e in mism)
        + f". full seen={[hex(x) for x in seen]}")

    # Belt-and-braces: ENABLED even lanes carry their nibble (value path proven,
    # not coincidental all-zero); DISABLED odd lanes are 0 (enable-gate OFF-by-
    # default at the pin -> the B->A safety guarantee at the RX input).
    assert seen[0] == 0x1 and seen[2] == 0x3 and seen[4] == 0x5 and seen[6] == 0x7, \
        f"enabled even lanes wrong: {[hex(x) for x in seen]}"
    assert seen[1] == 0x0 and seen[3] == 0x0 and seen[5] == 0x0 and seen[7] == 0x0, \
        f"disabled odd lanes not OFF: {[hex(x) for x in seen]}"

    tb.log.info("[2c] PASS: per-lane word-pin reaches gpiorx.io_word_pin in V1 "
                "(dedicated port path); enable-gate OFF-by-default confirmed.")


@cocotb.test()
async def test_wordpin_default_off_at_rx(dut):
    """OFF-by-default: with NO APB writes, every lane's io_word_pin is 4'h0
    (legacy framing) — the reset/default safety state on the proven B->A dir."""
    tb = PairTB(dut)
    await tb.reset()
    await ClockCycles(tb.s_apb._clk, 12)
    gpio_s = dut.u_slave.u_chiplet_controller.u_wlink.phy.gpio
    gpio_m = dut.u_master.u_chiplet_controller.u_wlink.phy.gpio
    bad = []
    for side, gpio in (("slave", gpio_s), ("master", gpio_m)):
        for n in range(8):
            wp = _i(getattr(gpio, f"gpiorx_{n}").io_word_pin)
            if wp != 0:
                bad.append((side, n, wp))
    assert not bad, ("default word_pin not 0 (OFF-by-default broken): "
                     + ", ".join(f"{s} lane{n}=0x{w:x}" for s, n, w in bad))
    tb.log.info("[2c] PASS: default io_word_pin=0 on all 16 lanes (both dies) "
                "-> legacy framing == proven B->A path.")
