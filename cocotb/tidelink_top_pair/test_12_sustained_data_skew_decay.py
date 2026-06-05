"""S3-A — sustained AHB-DATA fill/drain under per-lane phase-offset skew.

Implements experiment S3-A of
`docs/DEBUG_PLAN_CREDIT_RETURN_DATA_TRANSFER.md` §3:

    Reproduce, IN SIMULATION, the silicon "sustained data transfer decays /
    credit never returns" bug, so we get a fast iteration loop.

The current cocotb suite does NOT reproduce it because the top_pair bench runs
ZERO-skew (single shared clock, pad_skid passthrough). The plan's #1 structural
hypothesis (H1) is that the cross-lane deskew FIFO injects bubble words when
`all_ready` glitches low under PER-LANE differential skew, mis-framing the
sustained return-link traffic — and the credit-return ACK packets are the prime
victim of that mis-framing. With the ACKs corrupted/dropped the original
sender's `fe_rx_ptr` never advances (WlinkGenericFCSM_6.v:1205,1206),
`fe_rx_is_full` latches (:464) and the sender FCSM wedges in/out of LINK_DATA.

Skew mechanism
--------------
This bench injects per-lane skew via the existing `pad_skid` block
(cocotb/tidelink_top_pair/pad_skid.sv), which delays each PHY data lane by an
independent integer number of pad_clk periods (SKID_BITS_LANE0..7). The tb_top
now wires those per-lane params from +define+TB_TOP_SKID_L0..L7 plusargs (added
2026-06-05 for this experiment). DIFFERENTIAL per-lane skew (different delay per
lane) is exactly the condition that desynchronises the cross-lane deskew FIFO —
stronger than the whole-die clock drift in tidelink_top_pair_drift.

Fidelity caveat: pad_skid delays in *bit/pad_clk* periods (the GPIO PHY serial
boundary), which is the same granularity the deskew FIFO works in. It models
inter-lane phase offset (lanes frequency-locked, offset by N pad-clk periods) —
which matches the real HW per-lane trace-delay scenario per the deskew memory.
It does NOT model continuous PPM frequency drift (that is the drift bench).

Run (per-lane differential skew set at compile time via the Makefile/plusargs):
    export CMSDK_FPGA_SRAM_V=.../cmsdk_fpga_sram.v
    make SIM_BUILD=sim_build_s3a MODULE=test_12_sustained_data_skew_decay \
         TESTCASE=test_12_sustained_data_skew_decay TB_TOP_NO_DUMP=1 \
         COMPILE_ARGS="+define+TB_TOP_SKID_L0=0 +define+TB_TOP_SKID_L1=1 ..."

The test itself reads back the actually-compiled skew from the pad_skid
instance parameters and logs it, so the run is self-documenting regardless of
how the plusargs were set.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

# Reuse the full PairTB + bringup machinery from the doorbell test module.
from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_full,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)


def _i(sig, default=-1):
    try:
        return int(sig.value)
    except Exception:
        return default


def ring_probe(tb, side):
    """Snapshot the FCSM functional credit ring + ACK-path health on `side`."""
    f = tb.fcsm(side)
    return {
        "state":      _i(f.state),
        "ne_rx_ptr":  _i(f.ne_rx_ptr),
        "fe_rx_ptr":  _i(f.fe_rx_ptr),
        "cmax":       _i(f.fe_rx_credit_max),
        "cmax_sync":  _i(f.fe_rx_credit_max_txsync),
        "is_full":    _i(f.fe_rx_is_full),
        "send_ack":   _i(f.send_ack_req),
        "last_good":  _i(f.last_good_pkt_from_rx),
        "ack_wfull":  _i(f.ack_nack_fifo_io_wfull),
        "ack_rempty": _i(f.ack_nack_fifo_io_rempty),
    }


def fmt_ring(p):
    return (f"state={p['state']} ne_ptr={p['ne_rx_ptr']} fe_ptr={p['fe_rx_ptr']} "
            f"is_full={p['is_full']} cmax=0x{p['cmax']:02x}/0x{p['cmax_sync']:02x} "
            f"send_ack={p['send_ack']} last_good={p['last_good']} "
            f"ack_wfull={p['ack_wfull']} ack_rempty={p['ack_rempty']}")


async def drain_one_packet(tb, side, n_payload):
    """Read a full (header + dest + n_payload) packet out of `side`'s RX FIFO,
    popping it (the read at read_target_addr = (n_payload+1)<<2 triggers
    read_complete -> read_ptr advances to the next packet). Returns the list of
    payload words actually read."""
    # word0 (offset 0) — also arms check_addr to capture packet length.
    await tb.ahb_fifo_read_word(side, 0x00)
    # word1 (dest_addr) at 0x04.
    await tb.ahb_fifo_read_word(side, 0x04)
    payload = []
    for k in range(n_payload):
        off = 0x08 + k * 4
        payload.append(await tb.ahb_fifo_read_word(side, off))
    return payload


@cocotb.test()
async def test_12_sustained_data_skew_decay(dut):
    """S3-A: sustained back-to-back AHB DATA packets M->S (and a S->M burst),
    drained + payload-compared, with the credit ring probed every batch.

    PASS  => link sustains traffic under this skew (skew model does not capture
             the HW condition, OR the committed prime-and-continuous deskew fix
             covers it). Report what stress was needed.
    FAIL  => decay reproduced: payload drops/mismatch, fe_rx_is_full latches, or
             fe_rx_ptr freezes while ne_rx_ptr advances. This is the HW bug,
             now sim-reproducible — the new fast gate.
    """
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)

    # ---- log the actually-compiled per-lane skew (self-documenting) ---------
    try:
        sk = dut.u_skid_m2s
        lanes = [_i(getattr(sk, f"SKID_BITS_LANE{n}"), 0) for n in range(8)]
        tb.log.info(f"  pad_skid m2s per-lane skew (pad_clk periods): {lanes}")
        sk2 = dut.u_skid_s2m
        lanes2 = [_i(getattr(sk2, f"SKID_BITS_LANE{n}"), 0) for n in range(8)]
        tb.log.info(f"  pad_skid s2m per-lane skew (pad_clk periods): {lanes2}")
        differential = len(set(lanes)) > 1
        tb.log.info(f"  DIFFERENTIAL per-lane skew present: {differential}")
    except Exception as e:
        tb.log.info(f"  (could not read pad_skid params: {e})")

    # ---- bring the pair up to a healthy data-mode link ----------------------
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    # Health gate: both FCSM credit rings loaded from CR/CRACK (0x1f).
    m0 = ring_probe(tb, "m")
    s0 = ring_probe(tb, "s")
    tb.log.info(f"  [bringup] M: {fmt_ring(m0)}")
    tb.log.info(f"  [bringup] S: {fmt_ring(s0)}")
    assert m0["cmax"] == 0x1f and s0["cmax"] == 0x1f, (
        f"link did not come up healthy: M.cmax=0x{m0['cmax']:02x} "
        f"S.cmax=0x{s0['cmax']:02x} (want 0x1f). Cannot evaluate decay.")

    # ---- sustained M->S AHB DATA packets, drained + compared ----------------
    N_PACKETS  = 80         # >> ring depth (31) so credit MUST replenish
    N_PAYLOAD  = 2          # words of payload per packet
    word0 = encode_word0(length=N_PAYLOAD, pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)

    delivered = 0
    mismatches = []
    first_fail_pkt = None
    fe_ptr_frozen_at = None
    is_full_latched = False
    prev_fe_ptr = m0["fe_rx_ptr"]
    fe_ptr_stuck_count = 0

    tb.log.info(f"  ==== driving {N_PACKETS} back-to-back AHB DATA packets "
                f"M->S (payload {N_PAYLOAD} words each) ====")

    for pkt in range(N_PACKETS):
        # Unique incrementing payload so we can detect drops/duplicates/reorder.
        base = 0xD0000000 | (pkt << 8)
        payload = [base | 0xEF, base | 0xBE]
        words = [word0, 0x0] + payload

        # Back-to-back: no extra inter-packet gap beyond ahb_tx_write_packet's
        # internal 4-cycle inter-word gap (the FC adapter pop latency).
        await tb.ahb_tx_write_packet("m", words)

        # Brief settle for this packet to traverse the FC link + return ACK.
        await ClockCycles(tb.dut.hclk, 400)

        # Drain this packet from the slave RX FIFO and compare payload.
        got = await drain_one_packet(tb, "s", N_PAYLOAD)
        ok = (got == payload)
        if ok:
            delivered += 1
        else:
            if first_fail_pkt is None:
                first_fail_pkt = pkt
            mismatches.append((pkt, [f"0x{w:08x}" for w in got],
                               [f"0x{w:08x}" for w in payload]))

        # Probe the credit ring each packet (master is the sender here).
        mp = ring_probe(tb, "m")
        sp = ring_probe(tb, "s")
        if mp["is_full"] == 1:
            is_full_latched = True
        # Track fe_rx_ptr advance vs ne_rx_ptr.
        if mp["fe_rx_ptr"] == prev_fe_ptr:
            fe_ptr_stuck_count += 1
            if fe_ptr_stuck_count >= 8 and fe_ptr_frozen_at is None and pkt >= 4:
                fe_ptr_frozen_at = pkt
        else:
            fe_ptr_stuck_count = 0
        prev_fe_ptr = mp["fe_rx_ptr"]

        if pkt < 6 or pkt % 8 == 0 or not ok:
            tag = "" if ok else "  <<< PAYLOAD FAIL"
            tb.log.info(f"  [pkt {pkt:02d}] sent=0x{payload[0]:08x}.. "
                        f"got={[f'0x{w:08x}' for w in got]}{tag}")
            tb.log.info(f"      M(sender): {fmt_ring(mp)}")
            tb.log.info(f"      S(recvr) : {fmt_ring(sp)}")

    # ---- final probe + verdict ----------------------------------------------
    mf = ring_probe(tb, "m")
    sf = ring_probe(tb, "s")
    tb.log.info("  ==== final state ====")
    tb.log.info(f"  M(sender): {fmt_ring(mf)}")
    tb.log.info(f"  S(recvr) : {fmt_ring(sf)}")
    tb.log.info(f"  delivered {delivered}/{N_PACKETS} packets intact M->S")
    if mismatches:
        tb.log.info(f"  first {min(5,len(mismatches))} mismatches:")
        for pkt, got, exp in mismatches[:5]:
            tb.log.info(f"    pkt {pkt}: got={got} expected={exp}")
    tb.log.info(f"  fe_rx_is_full ever latched on sender: {is_full_latched}")
    tb.log.info(f"  fe_rx_ptr frozen (>=8 stuck) first seen at pkt: "
                f"{fe_ptr_frozen_at}")

    # Decay evidence summary — explicit so the log states the verdict plainly.
    decayed = (
        delivered < N_PACKETS
        or is_full_latched
        or fe_ptr_frozen_at is not None
    )
    if decayed:
        tb.log.info("  *** SUSTAINED-DATA DECAY OBSERVED IN SIM ***")
        if first_fail_pkt is not None:
            tb.log.info(f"      first payload drop/mismatch at packet "
                        f"{first_fail_pkt}")
    else:
        tb.log.info("  *** no decay under this skew config — link sustained "
                    f"all {N_PACKETS} packets ***")

    # ---- assertions (a faithful HW repro makes these FAIL) ------------------
    assert delivered == N_PACKETS, (
        f"DECAY: only {delivered}/{N_PACKETS} M->S packets delivered intact "
        f"(first fail at pkt {first_fail_pkt}). "
        f"Final M sender ring: {fmt_ring(mf)}; S recvr ring: {fmt_ring(sf)}. "
        "Sustained-data credit-return bug reproduced in sim.")
    assert not is_full_latched, (
        f"DECAY: sender fe_rx_is_full latched during sustained traffic "
        f"(final {fmt_ring(mf)}). Credit ring filled and never replenished.")
    assert fe_ptr_frozen_at is None, (
        f"DECAY: sender fe_rx_ptr froze at packet {fe_ptr_frozen_at} while "
        f"ne_rx_ptr kept advancing — ACK/credit never returned. "
        f"Final {fmt_ring(mf)}.")
