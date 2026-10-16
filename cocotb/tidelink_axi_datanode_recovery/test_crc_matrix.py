"""CRC-injection matrix (VERIFICATION.md 2.2/2.3): one parameterised case per sim, env-driven.

  CM_KIND    shot (default) | ctl_live | ctl_inert | ctl_readback | ctl_detect_sense | ctl_counts
             | ctl_ship_default
  CM_NODE    sb | AW | W | B | AR | R
  CM_DIR     ab | ba                    (AXI nodes: ab only -- the slave die's ahb_sub is tied off)
  CM_POS     first | second | mid | second_to_last | last
  CM_SIZE    S (4 packets) | L (16, 2 messages / 8 ops) | X (32 / 16 ops: past the replay window)
  CM_GAP     idle hclk between words (sb) / ops (AXI)
  CM_EXPECT  EXACT (default) | INERT | NOT_EXACT (mutant arms) | NOT_ERROR (liveness) | ANY
  CM_PROFILE zero | silicon (compile-time; recorded only)  CM_MUTANT '' | fixg_off (AXI mutant)
The matrix (gen_crc_matrix_cases.py) and runner (run_crc_matrix.py) own the cross product; this
module is the single test body, so every case uses the same classifier (crc_matrix_core.classify).
Each case needs its own sim (a second run_bringup_full does not re-POR cleanly).
"""
import os
import traceback

import cocotb
from cocotb.triggers import ClockCycles

import crc_matrix_core as C

E = os.environ.get


def _judge(cls, expect, d):
    if expect == "NOT_ERROR":
        return cls != "ERROR"
    return C.judge(cls, expect)


async def _case(dut):
    kind = E("CM_KIND", "shot")
    node = E("CM_NODE", "sb")
    direction = E("CM_DIR", "ab")
    size, pos, gap = E("CM_SIZE", "L"), E("CM_POS", "first"), int(E("CM_GAP", "4"))
    byte, bit = int(E("CM_BYTE", "5")), int(E("CM_BIT", "0"))
    expect = E("CM_EXPECT", "INERT" if kind == "ctl_inert" else "EXACT")
    name = E("CM_NAME", f"{kind}_{node}_{direction}_{pos}_{size}_g{gap}")
    ad = C.make_adapter(dut, node, direction)

    if kind == "ctl_readback":
        # C-REG-HOLD: the injector holding register at 0x23C must read back what was written, on both
        # dies, and a write of 0 must read 0 (the 0x003C-alias class: a write to an unmapped address is
        # silently dropped and the readback of an untouched register reads 0).
        await ad.setup()
        bad = []
        for side in ("m", "s"):
            apb = ad.tb.apb(side)
            for w in (C.errinj_word(0xA1, 5, 0), C.errinj_word(0x81, 11, 7), C.errinj_word(0x84, 0, 3)):
                await apb.write(C.APB_ERRINJ, w)
                await ClockCycles(dut.hclk, 50)
                rb = await apb.read(C.APB_ERRINJ)
                if rb != w:
                    bad.append((side, hex(w), hex(rb)))
            await apb.write(C.APB_ERRINJ, 0)
            await ClockCycles(dut.hclk, 50)
            if await apb.read(C.APB_ERRINJ) != 0:
                bad.append((side, "0", "nonzero"))
        cls = "ERROR" if bad else "EXACT"
        rec = C.emit(dut, name, cls, dict(node="reg", bad=bad), cls == "EXACT", "EXACT")
        assert not bad, f"0x23C readback mismatch {bad}"
        return rec

    if kind == "ctl_ship_default":
        # Confirms the SHIPPING disable_crc reset value per node (SM_CONTROL bit16) straight after
        # bring-up: FCSM_6 (sideband) = 0 (CRC checked); FCSM 0-4 (AXI) = 1 (CRC NOT checked) in the FPGA
        # flist (local overrides).  ASIC flist uses the deps copies (reset 0): CM_EXPECT_AXI_DEFAULT=0.
        await ad.setup()
        exp_axi = int(E("CM_EXPECT_AXI_DEFAULT", "1"))
        bad = []
        table = {}
        for (side, base), v in ad.defaults.items():
            want = 0 if base == C.NODE["sb"]["base"] else exp_axi
            table[f"{side}:0x{base:04x}"] = v
            if v != want:
                bad.append((side, hex(base), v, want))
        cls = "ERROR" if bad else "EXACT"
        rec = C.emit(dut, name, cls, dict(node="all", disable_crc_reset=table, bad=bad), cls == "EXACT", "EXACT")
        assert not bad, f"shipping disable_crc default changed: {bad}"
        return rec

    crc_on = kind != "ctl_detect_sense"
    await ad.setup(crc_on=crc_on)

    if kind == "ctl_counts":
        # C-COUNT-EXPECT: shots fired == CRC counter increments over a multi-shot run.
        tot_f = tot_c = 0
        n = await C.census(ad, size)
        worst = "EXACT"
        for p in ("first", "mid", "last"):
            cls, d, _ = await C.run_shot(ad, size=size, pos=p, gap=gap, byte=byte, bit=bit, census_n=n)
            tot_f += d["fired"]; tot_c += d["crc_delta"]
            dut._log.info(f"[cm] counts shot {p}: {cls} fired={d['fired']} crc+{d['crc_delta']}")
            if cls == "ERROR":
                worst = "ERROR"
        ok = worst != "ERROR" and tot_f == tot_c == 3
        rec = C.emit(dut, name, "EXACT" if ok else "ERROR", dict(node=node, total_fired=tot_f, total_crc=tot_c),
                     ok, "EXACT")
        assert ok, f"shots {tot_f} != counter increments {tot_c} (or a shot ERRORed)"
        return rec

    if kind == "ctl_live":
        cls, d, _ = await C.run_shot(ad, size=size, pos="first", gap=gap, byte=byte, bit=bit, real_injector=True)
        ok = cls != "ERROR"                 # liveness only: fired==1 and the counter moved +1
        rec = C.emit(dut, name, cls, d, ok, "NOT_ERROR")
        assert ok, f"injector not live: {d}"
        return rec

    if kind == "ctl_inert":
        wrong = int(E("CM_WRONG_DID", "0x83" if node == "sb" else "0xA1"), 16)
        cls, d, _ = await C.run_shot(ad, size=size, pos="first", gap=gap, byte=byte, bit=bit,
                                     real_injector=True, did=wrong, expect_fired=0)
        d["armed_did"] = wrong
        ok = cls == "INERT"
        rec = C.emit(dut, name, cls, d, ok, "INERT")
        assert ok, f"wrong-DataID arm not inert: {cls} {d}"
        return rec

    if kind == "ctl_detect_sense":
        cls, d, _ = await C.run_shot(ad, size=size, pos=pos, gap=gap, byte=byte, bit=bit,
                                     expect_fired=1, expect_crc=0)
        ok = cls in ("STRAY", "LOST")       # corrupted word silently delivered, counter +0: CRC-on matters
        rec = C.emit(dut, name, cls, d, ok, "NOT_EXACT")
        assert ok, f"CRC-off arm did not show silent corruption (vacuous?): {cls} {d}"
        return rec

    cls, d, _ = await C.run_shot(ad, size=size, pos=pos, gap=gap, byte=byte, bit=bit)
    ok = _judge(cls, expect, d)
    rec = C.emit(dut, name, cls, d, ok, expect)
    assert ok, f"{name}: {cls} (expected {expect}) {d}"
    return rec


@cocotb.test()
async def test_crc_case(dut):
    try:
        await _case(dut)
    except AssertionError:
        raise
    except Exception as e:           # a harness exception is ERROR, never a pass
        dut._log.error("[cm] RESULT " + '{"case": "%s", "cls": "ERROR", "ok": false, "why": "%s"}'
                       % (E("CM_NAME", "?"), repr(e).replace('"', "'")[:300]))
        traceback.print_exc()
        raise
