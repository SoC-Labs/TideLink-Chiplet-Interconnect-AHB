"""V2 silicon data-bug reproduction: TRULY CONTIGUOUS back-to-back FC long packets.

Unlike test_v2_pair_b2b (which feeds via the slow AHB-TX port — per-write
handshake overhead spaces the resulting FC long packets at the link), this test
INJECTS the FC app->link words directly at the tl_fc_a2l interface of the
sender's tidelink_top (tb_top force/release harness), holding tl_fc_a2l_valid
high and presenting a new 48-bit FC word every cycle tl_fc_a2l_ready is high.
Each accepted a2l word becomes one Wlink long packet (data_id=0xa1,
word_count=7 — WlinkGenericFCSM_6.v:632-640); filling the a2l replay FIFO faster
than the FCSM drains forces BACK-TO-BACK long packets with NO inter-packet idle.

Probes (sender + receiver, every cycle):
  TX contiguity : sender u_wlink.lltx_io_ll_tx_valid  (gaps => not contiguous)
  RX framer     : receiver u_wlink.llrx .state .auto_out_valid .auto_out_word_count
                  .auto_out_data_id .io_in_error_state
  CRC           : receiver FCSM .crc_errors  (WlinkGenericFCSM_6.v:374)
  FCSM state    : receiver FCSM .state (4=LINK_IDLE,5=TX,6,7=SEND_NACK)
  FC decode     : receiver u_fc_adapter .rx_addr_offset .fc_rx_fifo_addr
  Commit        : receiver fifo_ctrl .write_target_addr_r .write_complete

Both disable_crc arms are run (forced on the receiver FCSM):
  disable_crc=1 (today's default) — silicon: "no commit, addr wrong" arm
  disable_crc=0                   — silicon: "+ crc_errors saturates" arm

Run:  make EPOCH_PROFILE=zero MODULE=test_v2_fc_contiguous
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, APB_PKT_WORD_LEN, APB_PAIR_CREDIT_COUNTER,
)

PKT_FIFO_DATA = 0


def fc_word(addr_offset, payload):
    return ((PKT_FIFO_DATA & 0x3) << 46) | ((addr_offset & 0x3FFF) << 32) | (payload & 0xFFFFFFFF)


def make_fc_packet(length, dest_addr, payloads):
    """v33-style 4-word packet -> FC words at byte offsets 0,4,8,0xC.
    off0=header (length in [31:20]); off4=dest_addr; off8/0xC=payload."""
    hdr_payload = (length & 0xFFF) << 20
    words = [fc_word(0x0, hdr_payload), fc_word(0x4, dest_addr)]
    off = 0x8
    for p in payloads:
        words.append(fc_word(off, p))
        off += 4
    return words


def fcsm(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def wlink(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink


def fc_adapter(tb, side):
    return tb.top(side).u_fc_adapter


def fifo_ctrl(tb, side):
    return tb.top(side).u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return -1


def _get(obj, name):
    return getattr(obj, name, None)


async def inject_a2l_contiguous(tb, side, fc_words):
    """Drive the tb_top contiguous-a2l injector (force/release of tl_fc_a2l)."""
    dut = tb.dut
    pfx = "m" if side == "m" else "s"
    inj_word = getattr(dut, f"{pfx}_inj_word")
    inj_len = getattr(dut, f"{pfx}_inj_len")
    inj_go = getattr(dut, f"{pfx}_inj_go")
    inj_idx = getattr(dut, f"{pfx}_inj_idx")
    assert len(fc_words) <= 64, "INJ_MAX is 64"
    for k, w in enumerate(fc_words):
        inj_word[k].value = w
    inj_len.value = len(fc_words)
    await RisingEdge(dut.hclk)
    inj_go.value = 1
    for _ in range(2000):
        await RisingEdge(dut.hclk)
        if _i(inj_idx) >= len(fc_words):
            break
    await ClockCycles(dut.hclk, 4)
    inj_go.value = 0
    await RisingEdge(dut.hclk)


async def probe_tx_contiguity(tb, src, cycles):
    """Measure the sender lltx valid stream: longest contiguous run and the
    set of gap lengths between asserted-valid runs. A back-to-back stream of
    4 long packets (word_count=7 -> ~7 link words each) should show one long
    contiguous valid run (or runs separated by 0-cycle gaps)."""
    dut = tb.dut
    w = wlink(tb, src)
    vsig = _get(w, "lltx_io_ll_tx_valid")
    if vsig is None:
        return None
    total_valid = 0
    max_run = 0
    run = 0
    gaps = []
    gap = 0
    in_run = False
    for _ in range(cycles):
        await RisingEdge(dut.hclk)
        v = _i(vsig)
        if v == 1:
            total_valid += 1
            run += 1
            max_run = max(max_run, run)
            if not in_run and gap > 0:
                gaps.append(gap)
            in_run = True
            gap = 0
        else:
            if in_run:
                run = 0
            in_run = False
            gap += 1
    return {"total_valid": total_valid, "max_run": max_run,
            "gaps_between_runs": gaps[:20]}


async def probe_rx(tb, dst, cycles, label):
    """Sample receiver framing/commit signals each cycle."""
    dut = tb.dut
    f = fcsm(tb, dst)
    fa = fc_adapter(tb, dst)
    fc = fifo_ctrl(tb, dst)
    w = wlink(tb, dst)
    crc_sig = _get(f, "crc_errors")
    st_sig = _get(f, "state")
    ao_sig = _get(fa, "rx_addr_offset")
    fv_sig = _get(fa, "fc_rx_fifo_valid")
    fad_sig = _get(fa, "fc_rx_fifo_addr")
    wt_sig = _get(fc, "write_target_addr_r")
    wc_sig = _get(fc, "write_complete")
    # llrx framer probes
    llstate_sig = _get(w, "llrx").state if _get(w, "llrx") is not None else None
    llwc_sig = _get(_get(w, "llrx"), "word_count") if _get(w, "llrx") is not None else None
    llval_sig = _get(_get(w, "llrx"), "auto_out_valid") if _get(w, "llrx") is not None else None
    llerr_sig = _get(_get(w, "llrx"), "io_in_error_state") if _get(w, "llrx") is not None else None
    lldid_sig = _get(_get(w, "llrx"), "auto_out_data_id") if _get(w, "llrx") is not None else None

    max_crc = 0
    fcsm_states = set()
    fifo_addrs = set()
    addr_offsets = set()
    write_target_seen = set()
    write_complete_count = 0
    ll_states = set()
    ll_wcounts = set()
    ll_valid_count = 0
    ll_err_count = 0
    ll_dids = set()
    for _ in range(cycles):
        await RisingEdge(dut.hclk)
        if crc_sig is not None:
            ce = _i(crc_sig)
            if ce > max_crc:
                max_crc = ce
        if st_sig is not None:
            fcsm_states.add(_i(st_sig))
        if ao_sig is not None:
            addr_offsets.add(_i(ao_sig))
        if fv_sig is not None and _i(fv_sig) == 1 and fad_sig is not None:
            fifo_addrs.add(_i(fad_sig))
        if wt_sig is not None:
            write_target_seen.add(_i(wt_sig))
        if wc_sig is not None and _i(wc_sig) == 1:
            write_complete_count += 1
        if llstate_sig is not None:
            ll_states.add(_i(llstate_sig))
        if llwc_sig is not None:
            ll_wcounts.add(_i(llwc_sig))
        if llval_sig is not None and _i(llval_sig) == 1:
            ll_valid_count += 1
            if lldid_sig is not None:
                ll_dids.add(_i(lldid_sig))
        if llerr_sig is not None and _i(llerr_sig) == 1:
            ll_err_count += 1
    tb.log.info(
        f"  [{label}] RX probe {cycles}cy: max_crc_errors={max_crc} "
        f"fcsm_states={sorted(fcsm_states)} "
        f"llrx_states={sorted(ll_states)} llrx_word_counts={sorted(ll_wcounts)} "
        f"llrx_valid_cy={ll_valid_count} llrx_data_ids={[hex(d) for d in sorted(ll_dids)]} "
        f"llrx_error_cy={ll_err_count} "
        f"fc_rx_fifo_addrs={sorted(fifo_addrs)} "
        f"rx_addr_offsets={sorted(a for a in addr_offsets if a>=0)} "
        f"write_target_addrs={sorted(w_ for w_ in write_target_seen if w_>=0)} "
        f"write_complete_pulses={write_complete_count}")
    return {"max_crc": max_crc, "fcsm_states": sorted(fcsm_states),
            "fifo_addrs": sorted(fifo_addrs),
            "write_complete": write_complete_count,
            "llrx_error_cy": ll_err_count,
            "llrx_word_counts": sorted(ll_wcounts)}


def set_disable_crc(tb, side, val):
    try:
        fcsm(tb, side).out_prepend_swi_disable_crc.value = val
        tb.log.info(f"  set disable_crc[{side}]={val}")
    except Exception as e:
        tb.log.warning(f"could not set disable_crc on {side}: {e}")


async def _run(tb, src, dst, n_packets, ctx, disable_crc):
    # Force the receiver's disable_crc to the requested arm.
    set_disable_crc(tb, dst, disable_crc)
    await ClockCycles(tb.dut.hclk, 5)
    # N back-to-back v33-style 4-word packets with UNIQUE dest addresses so they
    # do NOT overwrite each other in the dst FIFO (dest_addr in word1).
    fc_words = []
    base = 0xC0DE0000
    for k in range(n_packets):
        fc_words += make_fc_packet(length=2, dest_addr=(0x100 * (k + 1)),
                                   payloads=[base + (k << 8) + 0x11,
                                             base + (k << 8) + 0x22])
    tb.log.info(f"  [{ctx}] inject {len(fc_words)} contiguous FC a2l words "
                f"({n_packets} long-packet bursts) {src}->{dst} disable_crc={disable_crc}")
    probe = cocotb.start_soon(probe_rx(tb, dst, cycles=4000, label=ctx))
    txprobe = cocotb.start_soon(probe_tx_contiguity(tb, src, cycles=600))
    await inject_a2l_contiguous(tb, src, fc_words)
    tx = await txprobe
    res = await probe
    got = [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(4)]
    pkt_len = await tb.apb(dst).read(APB_PKT_WORD_LEN)
    pcc = await tb.apb(dst).read(APB_PAIR_CREDIT_COUNTER)
    tb.log.info(f"  [{ctx}] TX contiguity: {tx}")
    tb.log.info(f"  [{ctx}] RESULT {src}->{dst} disable_crc={disable_crc}: "
                f"PKT_LEN=0x{pkt_len:x} pcc={pcc} "
                f"rx_fifo=[{', '.join(f'0x{w:08x}' for w in got)}] "
                f"max_crc_errors={res['max_crc']} fcsm_states={res['fcsm_states']} "
                f"write_complete_pulses={res['write_complete']} "
                f"llrx_error_cy={res['llrx_error_cy']}")
    crc_sat = res['max_crc'] >= 0x4000
    committed = res['write_complete'] > 0
    tb.log.info(f"  [{ctx}] >>> REPRO crc_saturates={crc_sat} committed={committed} "
                f"(silicon bug = crc_saturates AND NOT committed)")
    return res, got, pkt_len


@cocotb.test()
async def test_contiguous_m2s_crc_off(dut):
    """disable_crc=1 (today's default): does contiguous injection still commit?"""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await _run(tb, "m", "s", n_packets=4, ctx="m2s-contig-crcOFF", disable_crc=1)


@cocotb.test()
async def test_contiguous_m2s_crc_on(dut):
    """disable_crc=0: does contiguous injection saturate CRC + block commit?"""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await _run(tb, "m", "s", n_packets=4, ctx="m2s-contig-crcON", disable_crc=0)


@cocotb.test()
async def test_contiguous_s2m_crc_on(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await _run(tb, "s", "m", n_packets=4, ctx="s2m-contig-crcON", disable_crc=0)


@cocotb.test()
async def test_contiguous_s2m_crc_off(dut):
    """Silicon claim: NO commit EVEN with disable_crc=1. Under the silicon
    epoch profile + anchor OFF, does S->M still fail to enqueue with CRC off?"""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await _run(tb, "s", "m", n_packets=4, ctx="s2m-contig-crcOFF", disable_crc=1)
