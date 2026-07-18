"""F14 · Scenario 5 — SYNC-WORD COLLISION (data word == SYNC pattern).

The GPIO-PHY SYNC / training word is
  TIDELINK_SYNC_WORD = 128'hF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00
(deps/tidelink-phy/rtl/tidelink_sync_word.svh:37; per-lane 16-bit slice low byte
0x00). The RX framer (WlinkRxLinkLayer.v:313-367) always compares assembled
words against SYNC_WORD (mask-aware) and, on a match, STRIPS the word and pulses
sync_resync — even though the beacon INSERTER is OFF in data mode.

EXPECTED (from RTL):
  * The framer authors argue a legitimate payload word can NEVER alias SYNC:
    the low byte 0x00 is an invalid Wlink length and the upper 120 bits are a
    fixed descending-nibble ramp the LL encoder never emits (:333-360). So
    sending payload words built from the SYNC slices must be delivered BYTE-
    EXACT (not stripped, not mis-framed).
  * FINDING if any SYNC-patterned payload word is dropped/altered -> the framer
    mis-frames on data (the historical mis-framing class).

We send several adversarial payloads and byte-check each.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, send_and_check
from errinj_common import link_healthy

# 32-bit adversarial payload words derived from the SYNC constant.
SYNC_SLICES = [
    0x1F001F00,   # two low SYNC lane-slices (low byte 0x00 = invalid length)
    0x3D2E1F00,   # low 32 bits of TIDELINK_SYNC_WORD
    0xF1E2D3C4,   # top 32 bits of TIDELINK_SYNC_WORD
    0x00000000,   # all-zero (the idle/strip substitute word)
]


async def _bringup_healthy(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "PRECONDITION: no CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, detail = await link_healthy(tb)
    assert ok, f"PRECONDITION: not healthy ({detail})"
    return tb


@cocotb.test()
async def test_01_sync_patterned_payload_m2s(dut):
    tb = await _bringup_healthy(dut)
    results = []
    for i in range(0, len(SYNC_SLICES), 2):
        pl = [SYNC_SLICES[i], SYNC_SLICES[i + 1]]
        ok, got = await send_and_check(tb, "m", "s", pl,
                                       ctx=f"sync-m2s#{i}", expect_pass=False)
        results.append((pl, ok, got))
    all_ok = all(r[1] for r in results)
    verdict = ("RECOVERS (framer robust: SYNC-patterned payloads delivered "
               "byte-exact, no strip/mis-frame)" if all_ok else
               "SILENT-CORRUPTION / mis-framing — a SYNC-patterned payload was "
               "dropped or altered")
    for pl, ok, got in results:
        tb.log.info(f"  sent={[hex(x) for x in pl]} ok={ok} "
                    f"got=[{', '.join(hex(w) for w in got)}]")
    tb.log.info(f"VERDICT[S5_sync_collision_m2s]: {verdict}")
    assert all_ok, "SYNC-patterned payload not delivered byte-exact (see log)"


@cocotb.test()
async def test_02_sync_patterned_payload_s2m(dut):
    tb = await _bringup_healthy(dut)
    ok, got = await send_and_check(tb, "s", "m", [0x3D2E1F00, 0x1F001F00],
                                   ctx="sync-s2m", expect_pass=False)
    tb.log.info(f"VERDICT[S5_sync_collision_s2m]: "
                f"{'RECOVERS (byte-exact)' if ok else 'SILENT-CORRUPTION'} "
                f"got=[{', '.join(hex(w) for w in got)}]")
    assert ok, "s2m SYNC-patterned payload not byte-exact"
