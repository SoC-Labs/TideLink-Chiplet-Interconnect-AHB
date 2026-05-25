"""tdif-bisect-ll-rx — FRAMER vs DESERIALIZER bisect on slave's LL_RX.

Given the asymmetric repro (master cr_pkt_seen_rx=1, slave cr_pkt_seen_rx=0
forever after recal + LL swreset cycle in test_paired_recal_to_link_data
test_01), the L1+L2+L3 RTL fix stack is insufficient.

The test-suite agent showed in test_multi_recal_count_phase::test_01 that
the per-lane `count` register phase IS stable across recal — so the
byte alignment is fine. The bug is DOWNSTREAM of the GPIORx `count`
register: somewhere between the deserialised `phy_link_rx_rx_link_data`
output of the GPIO PHY and the FCSM's `cr_pkt_seen_rx` latch.

This file isolates the bug to exactly one of:

  * DESERIALIZER  — phy_link_rx_rx_link_data on slave never shows the CR
                    packet header bytes the master is sending (mux/byte-
                    window slips after the swreset pulse).
  * FRAMER        — phy_link_rx_rx_link_data DOES show the CR packet
                    header bytes on slave, but llrx never moves out of
                    `state==0` to assert `valid` / `is_short_pkt`.
  * FCSM/LATCH    — both llrx outputs look fine on slave but cr_pkt_seen_rx
                    never latches (FCSM gate problem or peer FCSM input
                    routing bug).

For each side we snapshot, per master_clk cycle, in the post-swreset window:

  * llrx.state                 (byte-align FSM state, 0=hunt 1=lock 2=err)
  * llrx.io_obs_is_short_pkt
  * llrx.io_obs_is_long_pkt
  * llrx.io_obs_valid           (LL_RX has a valid packet pulse)
  * llrx.auto_out_data_id       (DATA_ID byte of the packet header)
  * llrx.io_link_data           (raw 128-bit deserialised word from PHY)
  * wlink_tidelinktl.pkt_is_cr_pkt
  * wlink_tidelinktl.cr_pkt_seen_rx
  * Lane-0..7 byte slice of io_link_data at the same instant a CR header
    is asserted on master.

A CR packet on TideLink TL has data_id == 0x44 (swi_cr_id default).
For 8 active lanes the LL_RX header bytes drop into the 4 lowest-indexed
unmasked lanes (Wlink CSI-2 style: byte 0..3 are DI, WC[7:0], WC[15:8],
ECC); the rest of the 128-bit word holds the long-packet payload (CR is a
short packet, so the rest is don't-care).

If on master side we see io_obs_is_short_pkt high with data_id=0x44 at
cycle N, and on slave side at the corresponding cycle we DO NOT see
data_id=0x44 in io_link_data[7:0] (the first byte of the short-packet
header pattern), then DESERIALIZER is broken on the slave.

If we DO see 0x44 in slave's io_link_data byte 0 but is_short_pkt never
fires on slave, FRAMER is broken on the slave.

If is_short_pkt fires on the slave but cr_pkt_seen_rx never latches,
the bug is in the LATCH/GATING path between LL_RX and FC FCSM.
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave
from test_paired_recal_to_link_data import (
    recal_cycle, drop_training_and_swreset_ll,
)

SWI_CR_ID = 0x44
SWI_CRACK_ID = 0x45


def _wlink(dut, side):
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink


def _llrx(dut, side):
    return _wlink(dut, side).llrx


def _fcsm(dut, side):
    return _wlink(dut, side).tl2wl.wlink_tidelinktl


async def _trace_window(dut, cycles, label):
    """Walk N master_clks, snapshotting llrx + fcsm internals on BOTH sides.
    Returns aggregate dict per side."""
    m_llrx = _llrx(dut, "m")
    s_llrx = _llrx(dut, "s")
    m_fcsm = _fcsm(dut, "m")
    s_fcsm = _fcsm(dut, "s")

    def _init(side):
        return {"valid_pulses": 0, "is_short_pulses": 0, "is_long_pulses": 0,
                "cr_data_id_seen": 0, "any_data_id_seen": 0,
                "max_state": 0, "any_state1": False, "any_state2": False,
                # any-byte (search every byte of all 16) matches
                "cr_byte_any": 0, "crack_byte_any": 0,
                "cr_byte_lane0_b0": 0, "crack_byte_lane0_b0": 0,
                # ECC + decode internals
                "ecc_corrupted_pulses": 0, "ecc_corrected_pulses": 0,
                "corrected_ph_low_eq_0": 0, "corrected_ph_low_eq_cr": 0,
                "corrected_ph_low_eq_crack": 0,
                "corrected_ph_low_other": 0,
                "io_enable_pulses": 0, "demet_pulses": 0,
                # timing landmarks
                "first_cr_byte_any_cycle": None,
                "first_is_short_cycle": None,
                "first_pkt_is_cr_cycle": None,
                "first_cr_pkt_seen_cycle": None,
                # observed unique values
                "all_data_ids": set(),
                "all_ph_low_when_short": set(),
                # raw transcript head
                "link_data_low_samples": [],
                "ph_samples": [],
                # number of master cr_pkt_is_cr_pkt pulses in window
                "master_pkt_is_cr_pulses": 0}
    agg = {"m": _init("m"), "s": _init("s")}

    for c in range(cycles):
        await ClockCycles(dut.master_clk, 1)
        # Master CR pulse counter (visible regardless of side).
        try:
            m_pkt_is_cr_now = int(m_fcsm.io_obs_pkt_is_cr_pkt.value)
            agg["m"]["master_pkt_is_cr_pulses"] += m_pkt_is_cr_now
            agg["s"]["master_pkt_is_cr_pulses"] += m_pkt_is_cr_now
        except Exception:
            pass
        for side, llrx, fcsm in (("m", m_llrx, m_fcsm),
                                 ("s", s_llrx, s_fcsm)):
            try:
                state = int(llrx.state.value)
                is_short = int(llrx.io_obs_is_short_pkt.value)
                is_long = int(llrx.io_obs_is_long_pkt.value)
                valid = int(llrx.io_obs_valid.value)
                data_id = int(llrx.auto_out_data_id.value)
                link_data = int(llrx.io_link_data.value)
                pkt_is_cr = int(fcsm.io_obs_pkt_is_cr_pkt.value)
                cr_seen = int(fcsm.io_obs_cr_pkt_seen_rx.value)
                ecc_corrupted = int(llrx.ecc_check_corrupted.value)
                ecc_corrected = int(llrx.ecc_check_corrected.value)
                corrected_ph = int(llrx.ecc_check_corrected_ph.value)
                io_enable = int(llrx.io_enable.value)
                demet = int(llrx.enable_ff2_demet_io_out.value)
            except Exception:
                continue
            a = agg[side]
            a["max_state"] = max(a["max_state"], state)
            if state == 1: a["any_state1"] = True
            if state == 2: a["any_state2"] = True
            if valid: a["valid_pulses"] += 1
            if is_short: a["is_short_pulses"] += 1
            if is_long: a["is_long_pulses"] += 1
            if ecc_corrupted: a["ecc_corrupted_pulses"] += 1
            if ecc_corrected: a["ecc_corrected_pulses"] += 1
            if io_enable: a["io_enable_pulses"] += 1
            if demet: a["demet_pulses"] += 1
            ph_low = corrected_ph & 0xFF
            if ph_low == 0:
                a["corrected_ph_low_eq_0"] += 1
            elif ph_low == SWI_CR_ID:
                a["corrected_ph_low_eq_cr"] += 1
            elif ph_low == SWI_CRACK_ID:
                a["corrected_ph_low_eq_crack"] += 1
            else:
                a["corrected_ph_low_other"] += 1
            if valid:
                a["all_data_ids"].add(data_id)
                a["any_data_id_seen"] += 1
                if data_id == SWI_CR_ID:
                    a["cr_data_id_seen"] += 1
            if is_short:
                a["all_ph_low_when_short"].add(ph_low)
            if is_short and a["first_is_short_cycle"] is None:
                a["first_is_short_cycle"] = c
            if pkt_is_cr and a["first_pkt_is_cr_cycle"] is None:
                a["first_pkt_is_cr_cycle"] = c
            if cr_seen and a["first_cr_pkt_seen_cycle"] is None:
                a["first_cr_pkt_seen_cycle"] = c
            # SEARCH ALL 16 BYTES OF link_data for CR/CRACK byte. Each
            # lane provides 2 bytes (low + high) in its 16-bit slot; so
            # for 8 active lanes we have 16 bytes of header candidates.
            saw_cr_anywhere = False
            saw_crack_anywhere = False
            for b in range(16):
                byte_val = (link_data >> (8 * b)) & 0xFF
                if byte_val == SWI_CR_ID:
                    saw_cr_anywhere = True
                if byte_val == SWI_CRACK_ID:
                    saw_crack_anywhere = True
            if saw_cr_anywhere:
                a["cr_byte_any"] += 1
                if a["first_cr_byte_any_cycle"] is None:
                    a["first_cr_byte_any_cycle"] = c
            if saw_crack_anywhere:
                a["crack_byte_any"] += 1
            lane0_b0 = link_data & 0xFF
            if lane0_b0 == SWI_CR_ID:
                a["cr_byte_lane0_b0"] += 1
            if lane0_b0 == SWI_CRACK_ID:
                a["crack_byte_lane0_b0"] += 1
            # Save a few representative samples for later inspection.
            if c < 16 or c % 100 == 0:
                a["link_data_low_samples"].append((c, link_data & 0xFFFFFFFFFFFFFFFF))
                a["ph_samples"].append(
                    (c, corrected_ph, ecc_corrupted, ecc_corrected,
                     is_short, is_long, state))
    return agg


def _summarise(dut, label, agg):
    for side in ("m", "s"):
        a = agg[side]
        dut._log.info(
            f"  [{label}][{side}] "
            f"max_state={a['max_state']} st1={int(a['any_state1'])} "
            f"st2={int(a['any_state2'])}  "
            f"valid_pulses={a['valid_pulses']}  "
            f"is_short_pulses={a['is_short_pulses']}  "
            f"is_long_pulses={a['is_long_pulses']}")
        dut._log.info(
            f"  [{label}][{side}] io_enable_pulses={a['io_enable_pulses']} "
            f"demet_pulses={a['demet_pulses']} "
            f"ecc_corrupted={a['ecc_corrupted_pulses']} "
            f"ecc_corrected={a['ecc_corrected_pulses']}")
        dut._log.info(
            f"  [{label}][{side}] corrected_ph_low: =0:{a['corrected_ph_low_eq_0']} "
            f"=cr(0x44):{a['corrected_ph_low_eq_cr']} "
            f"=crack(0x45):{a['corrected_ph_low_eq_crack']} "
            f"other:{a['corrected_ph_low_other']}")
        dut._log.info(
            f"  [{label}][{side}] cr_data_id_seen={a['cr_data_id_seen']} "
            f"any_data_id_seen={a['any_data_id_seen']} "
            f"all_data_ids_seen={sorted(a['all_data_ids'])}")
        dut._log.info(
            f"  [{label}][{side}] link_data byte-search ANY of 16 bytes: "
            f"cr_byte_any={a['cr_byte_any']} crack_byte_any={a['crack_byte_any']} "
            f"(lane0_b0 only: cr={a['cr_byte_lane0_b0']} crack={a['crack_byte_lane0_b0']})")
        dut._log.info(
            f"  [{label}][{side}] "
            f"first_cr_byte_any_cyc={a['first_cr_byte_any_cycle']}  "
            f"first_is_short_cyc={a['first_is_short_cycle']}  "
            f"first_pkt_is_cr_cyc={a['first_pkt_is_cr_cycle']}  "
            f"first_cr_pkt_seen_cyc={a['first_cr_pkt_seen_cycle']}")
        dut._log.info(
            f"  [{label}][{side}] all_ph_low_when_short_fires={sorted(a['all_ph_low_when_short'])}")
    dut._log.info(
        f"  [{label}] reference master.pkt_is_cr_pkt pulses in window = "
        f"{agg['m']['master_pkt_is_cr_pulses']}")


def _verdict(dut, agg):
    """Apply the FRAMER vs DESERIALIZER vs LATCH bisect rules and log
    a single-line verdict for the report."""
    m, s = agg["m"], agg["s"]
    # Master must be the reference: master should see CR data_id and
    # latch cr_pkt_seen_rx. If master doesn't see it, the test is
    # invalid (slave never even sent CR).
    if m["first_cr_pkt_seen_cycle"] is None:
        dut._log.error("  VERDICT: INVALID — master never saw CR either; "
                       "this is symmetric failure, not the slave-only bug.")
        return "INVALID"

    # Slave didn't latch cr_pkt_seen_rx (the bug).
    if s["first_cr_pkt_seen_cycle"] is not None:
        dut._log.info("  VERDICT: PASS — slave also latched cr_pkt_seen_rx, "
                      "no bug repro.")
        return "PASS"

    # Slave didn't see CR data_id pulse on llrx output at all.
    if s["cr_data_id_seen"] == 0:
        # Did slave's link_data EVER carry the CR data_id byte ANYWHERE
        # in the 16-byte word? (Any-lane search — robust to byte-window
        # offset, ECC-correction lane permutations, etc.)
        if s["cr_byte_any"] == 0:
            dut._log.error("*" * 70)
            dut._log.error("  VERDICT: DESERIALIZER — slave's "
                           "phy_link_rx_rx_link_data NEVER carries 0x44 "
                           "(CR data_id) in ANY of the 16 byte positions "
                           "across the entire post-swreset window. The "
                           "master IS sending CR (master saw "
                           "cr_pkt_seen_rx). The slave's deserialised "
                           "128-bit word is corrupted or byte-window "
                           "mis-aligned — bug is in the WavD2DGpio Rx "
                           "path or the byte-window mux (despite "
                           "per-lane count being stable).")
            dut._log.error("*" * 70)
            return "DESERIALIZER"
        # link_data sees CR byte but llrx never decodes it.
        if s["is_short_pulses"] == 0 and s["valid_pulses"] == 0:
            dut._log.error("*" * 70)
            dut._log.error("  VERDICT: FRAMER (state stuck) — slave's "
                           f"link_data carries 0x44 ({s['cr_byte_any']} "
                           "samples in some lane byte position) but llrx "
                           "never asserts is_short_pkt and never asserts "
                           f"valid. byte-align FSM max_state={s['max_state']} "
                           "(must be 0=hunt if never moves to 1=lock). "
                           "The byte-window in WlinkRxLinkLayer is failing "
                           "to lock onto the CR packet after recal+swreset. "
                           f"ECC corrupted pulses={s['ecc_corrupted_pulses']} "
                           f"corrected pulses={s['ecc_corrected_pulses']}")
            dut._log.error("*" * 70)
            return "FRAMER_STATE_STUCK"
        dut._log.error("*" * 70)
        dut._log.error("  VERDICT: FRAMER (decode wrong) — slave's "
                       "link_data carries 0x44 AND is_short_pkt fires "
                       f"({s['is_short_pulses']} pulses), but the "
                       "decoded auto_out_data_id is never 0x44. ECC "
                       "correction or byte-window phase has placed CR "
                       "byte at wrong index — bug in lane-mux indexing.")
        dut._log.error("*" * 70)
        return "FRAMER_DECODE_WRONG"

    # data_id 0x44 DID appear at llrx output on slave.
    if s["first_pkt_is_cr_cycle"] is None:
        dut._log.error("*" * 70)
        dut._log.error("  VERDICT: FCSM/LATCH — slave's llrx decoded "
                       "data_id=0x44 with valid pulses, but pkt_is_cr_pkt "
                       "never asserts in the slave's FCSM. likely "
                       "swi_cr_id mismatch (swi_cr_id reset by swreset "
                       "to a different value than master) or sop gating "
                       "broken between llrx and FCSM.")
        dut._log.error("*" * 70)
        return "FCSM_DECODE_GATING"

    dut._log.error("*" * 70)
    dut._log.error("  VERDICT: LATCH — slave's pkt_is_cr_pkt asserts at "
                   f"cycle {s['first_pkt_is_cr_cycle']} but cr_pkt_seen_rx "
                   "never latches. Bug in the latch-enable or fcsm-internal "
                   "reset/gating path of the cr_pkt_seen_rx register.")
    dut._log.error("*" * 70)
    return "LATCH"


# -----------------------------------------------------------------------
# TEST 1 — main bisect. Replays the HW bringup and traces both sides
# during the post-swreset window. Prints the FRAMER/DESERIALIZER/LATCH
# verdict. Always passes; this is a diagnostic, not a gate.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_01_bisect_ll_rx_path(dut):
    """Trace slave's LL_RX internals while master is sending CR packets
    and emit a FRAMER / DESERIALIZER / LATCH verdict."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # Bring up to the same checkpoint as test_paired_recal_to_link_data.
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)
    # Skip the LL_CTRL pre-swreset noise so master has had time to start
    # streaming CR packets (master's FCSM advances to SEND_CREDITS2 by
    # ~5000 cycles in the repro).
    await ClockCycles(dut.master_clk, 200)

    # Trace 4000 master_clk cycles — long enough for master to send many
    # CR packets and to confirm slave never latches.
    agg = await _trace_window(dut, 4000, "post-swreset+200")
    _summarise(dut, "post-swreset+200", agg)
    verdict = _verdict(dut, agg)
    dut._log.info(f"  BISECT_VERDICT = {verdict}")


# -----------------------------------------------------------------------
# TEST 2 — focused link_data snapshot. Dumps a window of the slave's
# raw link_data when master's pkt_is_cr_pkt is asserting, so a human
# can inspect whether the CR header bytes are present on the slave.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_02_snapshot_slave_link_data_at_master_cr(dut):
    """When master's pkt_is_cr_pkt asserts, immediately sample the
    slave's llrx.io_link_data and report the lower 32 bits + lane-0
    byte. This is the 'photograph the wire' test: if these bytes don't
    show 0x44 around the master-side CR pulse, the slave's wire/
    deserialiser is broken.

    Note that the master→slave path has a ~1 cycle apb_clk-domain
    crossing latency from the master TX serialiser to the slave RX
    deserialiser. The slave's link_data should carry CR bytes within
    a small window around the master pkt_is_cr_pkt assertion."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)
    await ClockCycles(dut.master_clk, 200)

    m_fcsm = _fcsm(dut, "m")
    s_llrx = _llrx(dut, "s")
    m_llrx = _llrx(dut, "m")

    snapshots = []
    for c in range(4000):
        await ClockCycles(dut.master_clk, 1)
        try:
            m_pkt_is_cr = int(m_fcsm.io_obs_pkt_is_cr_pkt.value)
        except Exception:
            continue
        if m_pkt_is_cr:
            try:
                s_link_low = int(s_llrx.io_link_data.value) & 0xFFFFFFFFFFFFFFFF
                m_link_low = int(m_llrx.io_link_data.value) & 0xFFFFFFFFFFFFFFFF
                s_state = int(s_llrx.state.value)
                s_is_short = int(s_llrx.io_obs_is_short_pkt.value)
            except Exception:
                continue
            snapshots.append((c, m_link_low, s_link_low, s_state, s_is_short))
            if len(snapshots) >= 8:
                break

    dut._log.info(f"  Captured {len(snapshots)} snapshots of slave link_data "
                  "at instants when master.pkt_is_cr_pkt=1.")
    for (c, m_low, s_low, s_state, s_is_short) in snapshots:
        dut._log.info(
            f"    cyc={c:4d}  m.link_data[63:0]=0x{m_low:016x}  "
            f"s.link_data[63:0]=0x{s_low:016x}  "
            f"s.state={s_state}  s.is_short={s_is_short}")
        # Decode lane-0 byte (bits[7:0]) and lane-1 byte (bits[23:16])
        # of the slave's link_data. CR header should have data_id=0x44
        # in lane-0 byte-0 when active_lanes=8.
        m_lane0_b0 = m_low & 0xFF
        s_lane0_b0 = s_low & 0xFF
        s_lane1_b0 = (s_low >> 16) & 0xFF
        dut._log.info(
            f"      m.lane0.b0=0x{m_lane0_b0:02x}  "
            f"s.lane0.b0=0x{s_lane0_b0:02x}  "
            f"s.lane1.b0=0x{s_lane1_b0:02x}  (cr_id=0x{SWI_CR_ID:02x})")

    if not snapshots:
        dut._log.warning(
            "  No master.pkt_is_cr_pkt assertions found in 4000 cycles — "
            "either master isn't sending CR (test broken) or sample "
            "phase missed the pulse (single-cycle).")
    else:
        # Per-lane byte dump from FULL 128-bit link_data (search all 16 bytes).
        # This is the lab-grade dump — for each snapshot, show every byte
        # of slave link_data so we can see WHERE the CR byte goes (if it's
        # in the word at all but at a different lane index).
        dut._log.info("  Full lane-by-lane byte dump of slave link_data "
                      "at master.pkt_is_cr_pkt=1 instants:")
        hit_any_lane = 0
        s_llrx_full = s_llrx
        # Re-sample full 128-bit at remembered cycles is tricky — instead,
        # re-walk and re-capture full 128-bit for these snapshot cycles.
        # We just dump what we have now plus the full samples below.
        for (c, m_low, s_low, s_state, s_is_short) in snapshots:
            bytes_str = " ".join(
                f"b{b}=0x{((s_low >> (8*b)) & 0xFF):02x}"
                for b in range(8))
            dut._log.info(
                f"    cyc={c:4d}  s.link_data[63:0]={s_low:016x}  state={s_state} "
                f"is_short={s_is_short}  {bytes_str}")
            # Search byte 0..7 (lower 64 bits).
            for byte_idx in range(8):
                if ((s_low >> (8*byte_idx)) & 0xFF) == SWI_CR_ID:
                    hit_any_lane += 1
                    break
        dut._log.info(
            f"  slave's link_data shows 0x{SWI_CR_ID:02x} (cr_id) in "
            f"some byte of the low 64 bits in {hit_any_lane}/{len(snapshots)} "
            f"of the master-CR snapshots.")
        if hit_any_lane == 0:
            dut._log.error(
                "  VERDICT (link_data snapshot): DESERIALIZER — slave's "
                "deserialised link_data NEVER carries the CR data_id byte "
                "in any of the low 8 lanes, even when master is sending CR. "
                "The byte-window phase is wrong on the slave side.")
        else:
            dut._log.info(
                "  Slave's link_data DOES carry the CR byte but is being "
                "rejected downstream (FRAMER or FCSM/LATCH).")


# -----------------------------------------------------------------------
# TEST 3 — capture the moment slave's `state` transitions 0→1, dump
# the `corrected_ph[7:0]` (= the PH byte that decided the transition)
# and the link_data lane bytes at that instant. Goal: prove the slave
# enters the long-packet branch on a byte the master never classifies
# as long. The L4 fix candidate is to **invalidate the long-packet
# branch entry until byte_count has filled (i.e. wait for a valid
# header pulse)**.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_03b_slave_state_0_to_1_trigger(dut):
    """Walk the post-swreset window cycle-by-cycle and capture the
    EXACT cycle slave's state transitions from 0 to 1 (the entry to
    the phantom long-packet branch). Dump corrected_ph (24-bit) and
    the four byte_index muxes at that cycle and at +/-2 cycles. If
    the PH byte is one of the master's data_ids (e.g. 0x08, 0x0C),
    something is shifting the byte alignment such that the slave
    extracts byte at wrong offset."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    s_llrx = _llrx(dut, "s")
    state_history = []
    transition_cycle = None
    transition_window = []

    # Start tracing BEFORE the recal so we can catch the 0->1
    # transition wherever it happens during the bringup sequence.
    # We perform recal_cycle and drop_training in inline form here
    # while continuing to sample every cycle.
    # First pass: idle cycles before recal (~50)
    async def _sample_and_record(cycles_remaining_log):
        nonlocal transition_cycle, transition_window
        for _ in range(cycles_remaining_log):
            await ClockCycles(dut.master_clk, 1)
            try:
                state = int(s_llrx.state.value)
                ph = int(s_llrx.ecc_check_corrected_ph.value)
                ph_in = int(s_llrx.ecc_check_ph_in.value)
                corrupted = int(s_llrx.ecc_check_corrupted.value)
                is_short = int(s_llrx.io_obs_is_short_pkt.value)
                is_long = int(s_llrx.io_obs_is_long_pkt.value)
                link_data = int(s_llrx.io_link_data.value)
                demet = int(s_llrx.enable_ff2_demet_io_out.value)
            except Exception:
                continue
            c = len(state_history)
            state_history.append((c, state, ph, ph_in, corrupted, is_short,
                                  is_long, link_data & 0xFFFFFFFFFFFFFFFF, demet))
            if len(state_history) >= 2:
                prev = state_history[-2]
                if prev[1] == 0 and state == 1 and transition_cycle is None:
                    transition_cycle = c
                    start = max(0, len(state_history) - 4)
                    end = min(len(state_history), start + 7)
                    transition_window = state_history[start:end]

    # 50 cycles of pre-bringup
    await _sample_and_record(50)
    # set_slot0 = 0x3 (train+recal hold)
    from test_paired_recal_to_link_data import set_slot0, R8_SLOT0_TRAIN_RECAL
    from test_link_bringup import ctrl_write, apb_write
    await ctrl_write(dut, 'm', R8_SLOT0_TRAIN_RECAL, 0x3)
    await ctrl_write(dut, 's', R8_SLOT0_TRAIN_RECAL, 0x3)
    await _sample_and_record(200)
    # set_slot0 = 0x1 (recal falls)
    await ctrl_write(dut, 'm', R8_SLOT0_TRAIN_RECAL, 0x1)
    await ctrl_write(dut, 's', R8_SLOT0_TRAIN_RECAL, 0x1)
    await _sample_and_record(200)
    # set_slot0 = 0x0 (drop training)
    await ctrl_write(dut, 'm', R8_SLOT0_TRAIN_RECAL, 0x0)
    await ctrl_write(dut, 's', R8_SLOT0_TRAIN_RECAL, 0x0)
    await _sample_and_record(50)
    # LL swreset on
    WL_LE = 0x0208
    await apb_write(dut, 'm', WL_LE, 0x27f08)
    await apb_write(dut, 's', WL_LE, 0x27f08)
    await _sample_and_record(50)
    await apb_write(dut, 'm', WL_LE, 0x27f00)
    await apb_write(dut, 's', WL_LE, 0x27f00)
    await _sample_and_record(50)
    await apb_write(dut, 'm', WL_LE, 0x27f07)
    await apb_write(dut, 's', WL_LE, 0x27f07)
    await _sample_and_record(500)

    # Tail observation 2000 cycles.
    await _sample_and_record(2000)

    # ANALYSIS: confirm swreset behaviour. Check state at end of trace,
    # and report whether state==1 persists across the swreset apb_writes.
    final_state = state_history[-1][1] if state_history else "?"
    # Find a long-duration state==1 streak
    streaks = []
    cur_state = None
    cur_start = 0
    for (c, st, *_) in state_history:
        if st != cur_state:
            if cur_state is not None:
                streaks.append((cur_state, cur_start, c - 1))
            cur_state = st
            cur_start = c
    if cur_state is not None:
        streaks.append((cur_state, cur_start, state_history[-1][0]))
    dut._log.info(
        f"  Final slave state at end of trace = {final_state}. "
        f"Total streaks={len(streaks)}, longest state==1 streak: "
        f"{max((b - a for (st, a, b) in streaks if st == 1), default=0)} cycles. "
        f"(Trace is {len(state_history)} cycles total.)")
    # Print first 6 streaks to show timing.
    for (st, a, b) in streaks[:8]:
        dut._log.info(f"    state={st}  cycles [{a},{b}]  len={b-a+1}")

    if transition_cycle is None:
        dut._log.info(
            f"  Slave state never transitioned 0->1 in trace "
            f"({len(state_history)} cycles sampled); "
            f"max_state was {max(s[1] for s in state_history) if state_history else '?'}, "
            f"first state value was {state_history[0][1] if state_history else '?'}")
    else:
        dut._log.info(
            f"  Slave state 0->1 transition at sample-cycle {transition_cycle}. "
            "Window dump (3 cycles before, transition row, 3 after):")
        for (c, st, ph, ph_in, corr, isS, isL, ld, dm) in transition_window:
            dut._log.info(
                f"    cyc={c:4d}  state={st}  ph=0x{ph:06x} "
                f"ph_in=0x{ph_in:06x} corrupted={corr} "
                f"is_short={isS} is_long={isL}  "
                f"ph[7:0]=0x{(ph & 0xFF):02x}  link_data[31:0]=0x{(ld & 0xFFFFFFFF):08x}  "
                f"demet={dm}")
        if len(transition_window) >= 4:
            mid_ph = transition_window[3][2]
            dut._log.info(
                f"  Decision byte: corrected_ph[7:0]=0x{(mid_ph & 0xFF):02x} "
                "(at the transition row) — compare to "
                "swi_short_packet_max=0x7F. ph[7:0] > 0x7F means slave's "
                "PH byte > short_packet_max -> wrong long-packet branch.")


# -----------------------------------------------------------------------
# TEST 4 — TX-side reference. Dumps what the master's *TX-side* link_data
# is sending on the wire (lltx.io_link_data). The slave should be
# receiving these exact bytes (mod skid and phy align). If the master's
# TX shows CR header bytes at byte 0 of its 128-bit word but the slave's
# RX *aggregate* never carries 0x44 in any lane byte, the bug is on the
# wire (the deserialiser/byte-window) — not in the framer.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_04_master_tx_vs_slave_rx_bytes(dut):
    """Cross-check master-side TX bytes (what the wire IS carrying) with
    slave-side RX bytes (what the slave actually sees). If the slave's
    aggregate cr_byte_any count is much less than the master's TX-side
    short-packet cr-byte emission rate, the slave's deserialiser is
    dropping/scrambling bytes."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)
    await ClockCycles(dut.master_clk, 200)

    m_lltx = _wlink(dut, "m").lltx
    s_llrx = _llrx(dut, "s")

    # We need lltx.io_link_data. The TX serialiser drives this onto the
    # phy_link_tx pins; the slave receives the mirrored pattern (modulo
    # any pad skid).
    m_tx_cr_byte_any = 0
    s_rx_cr_byte_any = 0
    m_tx_crack_byte_any = 0
    s_rx_crack_byte_any = 0
    samples = []
    for c in range(4000):
        await ClockCycles(dut.master_clk, 1)
        try:
            m_tx_link = int(m_lltx.io_link_data.value)
            s_rx_link = int(s_llrx.io_link_data.value)
        except Exception:
            continue
        tx_has_cr = False
        tx_has_crack = False
        rx_has_cr = False
        rx_has_crack = False
        for b in range(16):
            if ((m_tx_link >> (8*b)) & 0xFF) == SWI_CR_ID:
                tx_has_cr = True
            if ((m_tx_link >> (8*b)) & 0xFF) == SWI_CRACK_ID:
                tx_has_crack = True
            if ((s_rx_link >> (8*b)) & 0xFF) == SWI_CR_ID:
                rx_has_cr = True
            if ((s_rx_link >> (8*b)) & 0xFF) == SWI_CRACK_ID:
                rx_has_crack = True
        if tx_has_cr: m_tx_cr_byte_any += 1
        if tx_has_crack: m_tx_crack_byte_any += 1
        if rx_has_cr: s_rx_cr_byte_any += 1
        if rx_has_crack: s_rx_crack_byte_any += 1
        # capture a few aligned samples
        if c < 20 or (c % 500 == 0):
            samples.append((c, m_tx_link & 0xFFFFFFFFFFFFFFFF,
                            s_rx_link & 0xFFFFFFFFFFFFFFFF))

    dut._log.info(
        f"  master_TX.io_link_data: cr_byte_any={m_tx_cr_byte_any} "
        f"crack_byte_any={m_tx_crack_byte_any} / 4000 master_clks")
    dut._log.info(
        f"  slave_RX.io_link_data:  cr_byte_any={s_rx_cr_byte_any} "
        f"crack_byte_any={s_rx_crack_byte_any} / 4000 master_clks")
    dut._log.info(
        "  Selected raw samples (cyc, m_TX[63:0], s_RX[63:0]):")
    for (c, mt, sr) in samples:
        dut._log.info(f"    cyc={c:4d}  m_TX=0x{mt:016x}  s_RX=0x{sr:016x}")
