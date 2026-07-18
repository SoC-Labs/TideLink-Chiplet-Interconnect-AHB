"""F14 · Scenario 3 — SINGLE-LANE DROPOUT (one lane forced 0/1/X/flip).

Injection: u_inj_s2m with lane_mask = ONE lane, mode in {stuck0, stuck1, stuckX,
flip}, held WHILE an s->m packet is in flight, then classified per lane:

  UNUSED             - packet still byte-exact under the fault  => that lane
                       carries no payload for this packet (masked / not load-
                       bearing; e.g. the negotiated 0xE4 data mask drops
                       lanes 0,1,3,4).
  DETECTED-DROPPED   - packet NOT committed (PKT_LEN==0, RX FIFO empty/stale)
                       => the corrupted word failed CRC and was dropped/NACKed.
  SILENT-CORRUPTION  - packet committed (PKT_LEN>0) but data WRONG => a corrupt
                       word passed as a valid packet with no error flag (the
                       CRITICAL finding).

test_01 sweeps all 8 lanes with FLIP to map the load-bearing lanes and their
detection behaviour. test_02..05 exercise stuck0/1/X/flip on a KNOWN load-
bearing lane (found by the sweep; default lane 2, which 0xE4 keeps active).

EXPECTED (from RTL): a corrupted 16-bit slice of a load-bearing lane makes the
Wlink LL CRC fail -> DETECTED-DROPPED and replay retry. stuckX is the X-
propagation / silent-corruption probe (an X sampled as a lucky-CRC 0/1 would be
SILENT-CORRUPTION; WlinkRxLinkLayer CRC over active lanes should catch it).
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, make_packet, APB_PKT_WORD_LEN,
)
from errinj_common import (
    inject_data, clear_all, link_healthy, classify_recovery,
    M_STUCK0, M_STUCK1, M_STUCKX, M_FLIP,
)

MODES = {"stuck0": M_STUCK0, "stuck1": M_STUCK1,
         "stuckX": M_STUCKX, "flip": M_FLIP}
ACTIVE_LANE = 2      # in the 0xE4 data mask (lanes 2,5,6,7)


async def _bringup_healthy(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "PRECONDITION: no CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, detail = await link_healthy(tb)
    assert ok, f"PRECONDITION: not healthy pre-injection ({detail})"
    return tb


async def _send_under_lane_fault(tb, dut, lane, mode, payload):
    """Send one s->m packet with lane `lane` corrupted the whole time, then
    read back + classify. Returns (klass, pkt_len, got, sent_words)."""
    words = make_packet(payload)
    inject_data(dut, "s2m", mode, lane_mask=(1 << lane))
    await tb.ahb_tx_write_packet("s", words)
    await ClockCycles(dut.hclk, 3000)
    pkt_len = await tb.apb("m").read(APB_PKT_WORD_LEN)
    got = [await tb.ahb_fifo_read_word("m", i * 4) for i in range(4)]
    clear_all(dut)
    await ClockCycles(dut.hclk, 1500)
    byte_exact = (got[0] == words[0] and got[2] == payload[0]
                  and got[3] == payload[1])
    if byte_exact:
        klass = "UNUSED"
    elif pkt_len == 0 and all(g == 0 for g in got):
        klass = "DETECTED-DROPPED(no commit)"
    elif pkt_len != 0:
        klass = "SILENT-CORRUPTION(committed wrong)"
    else:
        klass = "DETECTED-DROPPED(stale/empty)"
    return klass, pkt_len, got, words


@cocotb.test()
async def test_01_lane_sweep_flip(dut):
    """FLIP each lane 0..7 in turn; map load-bearing lanes + detection."""
    tb = await _bringup_healthy(dut)
    report = {}
    for lane in range(8):
        klass, plen, got, words = await _send_under_lane_fault(
            tb, dut, lane, M_FLIP, [0x5EED0000 | lane, 0xD00D0000 | lane])
        report[lane] = klass
        tb.log.info(f"  lane{lane} FLIP -> {klass} (PKT_LEN=0x{plen:x} "
                    f"got=[{', '.join(hex(w) for w in got)}])")
        # Recover the link between lanes if a fault wedged it.
        ok, _ = await link_healthy(tb)
        if not ok:
            await classify_recovery(tb, "s", "m")
    silent = [l for l, k in report.items() if k.startswith("SILENT")]
    active = [l for l, k in report.items() if not k.startswith("UNUSED")]
    tb.log.info(f"VERDICT[S3_lane_sweep_flip]: load-bearing lanes={active} "
                f"unused/masked={[l for l in range(8) if l not in active]} "
                f"SILENT-CORRUPTION lanes={silent} | per-lane={report}")

    # SILENT-CORRUPTION = the receiver ACCEPTED a packet whose bits were flipped
    # in flight, with no error signalled. That is the most serious outcome this
    # test can produce, and until 2026-07-18 it was only log.info'd -- so the
    # suite reported its own critical finding and exited green.
    #
    # It now fails by default. If it fails, read this before "fixing" the test:
    # CRC is DISABLED BY RESET DEFAULT in shipping silicon
    # (WlinkGenericFCSM.v:686 / _6.v:1167, `swi_disable_crc <= 1'h1`), so with the
    # POR configuration a flipped bit is UNDETECTABLE BY CONSTRUCTION and silent
    # corruption is the expected consequence, not a surprise. The right response
    # is a design decision (flip the reset default, or make CRC-on a mandatory,
    # gated bring-up step) -- not deleting this assertion.
    #
    # EI_ALLOW_SILENT_LANES records that debt EXPLICITLY when you need the suite
    # green while the decision is pending, e.g. EI_ALLOW_SILENT_LANES="2,5,6,7".
    # Set it deliberately, never to make a red go away quietly.
    import os
    _allow_raw = os.environ.get("EI_ALLOW_SILENT_LANES", "").strip()
    allowed = sorted(int(x) for x in _allow_raw.replace(",", " ").split()) if _allow_raw else []
    unexpected = [l for l in silent if l not in allowed]
    if allowed:
        tb.log.warning(f"EI_ALLOW_SILENT_LANES={allowed} -- silent corruption on "
                       f"these lanes is being TOLERATED by explicit opt-in. This is "
                       f"recorded technical debt, not a passing result.")
    assert not unexpected, (
        f"SILENT DATA CORRUPTION on lane(s) {unexpected}: a packet with in-flight "
        f"bit-flips was ACCEPTED with no error signalled. per-lane={report}. "
        f"Note CRC is off by reset default (swi_disable_crc=1) -- see the comment "
        f"above; if this is expected for the current configuration, record it via "
        f"EI_ALLOW_SILENT_LANES rather than removing this assertion.")


async def _run_mode_on_active(dut, name, mode):
    tb = await _bringup_healthy(dut)
    klass, plen, got, words = await _send_under_lane_fault(
        tb, dut, ACTIVE_LANE, mode, [0x1A2B0001, 0x3C4D0002])
    tb.log.info(f"  lane{ACTIVE_LANE} {name} -> {klass} (PKT_LEN=0x{plen:x} "
                f"got=[{', '.join(hex(w) for w in got)}])")
    verdict, detail = await classify_recovery(tb, "s", "m")
    tb.log.info(f"VERDICT[S3_lane{ACTIVE_LANE}_{name}]: {klass} | "
                f"recovery={verdict} | post health: {detail}")


@cocotb.test()
async def test_02_active_lane_stuck0(dut):
    await _run_mode_on_active(dut, "stuck0", M_STUCK0)


@cocotb.test()
async def test_03_active_lane_stuck1(dut):
    await _run_mode_on_active(dut, "stuck1", M_STUCK1)


@cocotb.test()
async def test_04_active_lane_stuckX(dut):
    await _run_mode_on_active(dut, "stuckX", M_STUCKX)


@cocotb.test()
async def test_05_active_lane_flip(dut):
    await _run_mode_on_active(dut, "flip", M_FLIP)
