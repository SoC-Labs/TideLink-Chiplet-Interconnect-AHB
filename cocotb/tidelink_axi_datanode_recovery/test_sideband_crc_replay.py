"""Sideband FC node (DataID 0xA1, WlinkGenericFCSM_6) CRC-detected packet: is it REPLAYED?

KR260 finding (a652c73e, 2026-10-14): die_a arms LINK_ERROR_INJECTION (APB 0x23C)
= 0x010005A1 (enable, bit0, byte5, DataID 0xA1) and sends ONE sideband packet via the
onchip ahb_tx path.  die_b's sideband CRC counter (node 0x1700 +0x20) goes 0->1
(detected) but the packet is never delivered; a fresh clean packet afterwards is.
On AXI data nodes (0x80-0x84) the same single-bit shot is detected AND replayed.

This test drives the identical sequence in sim through the real APB register
(0x23C, edge-armed: write 0, then write the armed value), the same ahb_tx 4-word
packet rev2hw.Path.send writes ([len<<20, 0, tag, ~tag]), and drains the receiver
FIFO like Path.collect.  Assertions: RX CRC counter +1 AND exactly one exact packet.

Tests (each needs its own sim -- run with TESTCASE=):
  test_sideband_clean_control   no injection: packet delivered exactly once, CRC +0
  test_sideband_crc_replay      the finding (sideband 0xA1, byte 5)
  test_axi_w_crc_replay_control positive control: W (0x81) byte 5 via a peer write
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, run_bringup_full
from test_axi_datanode_gaps import (AHBSubMaster, _force_axi_crc, _slave_bram_peek,
                                    _wlink, _arm_injector, _release_all,
                                    APER_BASE, OFF_INJECT, OFF_SANITY, D_INJECT, D_SANITY)

SB_ID = 0xA1
N6 = 0x1700
CRCCNT = 0x20
APB_ERRINJ = 0x023C
APB_REL, APB_CREDIT, APB_RXST, APB_RXCTL, APB_PAIR_EN = 0x2004, 0x200C, 0x2010, 0x201C, 0x2030
BYTE = int(os.environ.get("SB_BYTE", "5"))
BIT = int(os.environ.get("SB_BIT", "0"))


def _s(h, n):
    try:    return int(getattr(h, n).value)
    except Exception: return None


class Mon:
    """Per-hclk latch of the interesting FCSM_6 / watchdog / NACK wires on both dies."""
    SIGS = ("state", "crc_corrupt", "valid_rx_pkt_crc_err", "send_nack_req",
            "pkt_is_nack_pkt", "socl_l7_wdog_force_clear", "socl_l7_real_crc_seen",
            "crc_errors", "socl_l7_reached_link_data", "isNotExpPacket", "crcCorruptSeen",
            # replay-path observability (root-cause evidence)
            "ack_seen_before", "a2l_fc_replay_link_revert", "a2l_fc_replay_link_revert_addr",
            "a2l_fc_replay_link_cur_addr", "a2l_fc_replay_link_valid", "a2l_fc_replay_link_empty",
            "a2l_fc_replay_link_advance", "fe_rx_ptr", "ne_rx_ptr", "isNackPacket", "isAckPacket",
            "isExpPacket", "send_ack_req", "last_good_pkt", "last_good_pkt_from_rx", "sop",
            # RX pktnum tracker (L9b forward re-anchor / L9c backward re-ACK)
            "exp_pkt_num", "ll_rx_pktnum", "socl_l9b_reanchor_now", "socl_l9c_backward",
            "socl_l9b_hold", "l2a_fc_replay_app_valid", "exp_pkt_not_seen", "pkt_is_data_pkt")

    def __init__(self, tb):
        self.tb = tb; self.run = False
        self.ev = []            # (t, side, signal, value) on change
        self.max_wdog = {"m": 0, "s": 0}
        self.state7 = {"m": 0, "s": 0}

    async def _loop(self):
        last = {}
        t = 0
        while self.run:
            await RisingEdge(self.tb.dut.hclk); t += 1
            for side in ("m", "s"):
                fc = self.tb.fcsm(side)
                for n in self.SIGS:
                    v = _s(fc, n)
                    if v is None: continue
                    if last.get((side, n)) != v:
                        self.ev.append((t, side, n, v)); last[(side, n)] = v
                w = _s(fc, "socl_l7_wdog_cnt") or 0
                self.max_wdog[side] = max(self.max_wdog[side], w)
                if _s(fc, "state") == 7: self.state7[side] += 1

    def start(self):
        self.run = True; self.task = cocotb.start_soon(self._loop())

    def stop(self):
        self.run = False

    def count(self, side, name, val=1):
        return sum(1 for (_, s, n, v) in self.ev if s == side and n == name and v == val)

    def dump(self, log):
        for e in self.ev:
            log.info(f"  MON t={e[0]:6d} {e[1]} {e[2]}={e[3]}")


async def _bringup(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    return tb


async def _sb_setup(tb):
    """rev2hw.Path.setup for a2b (tx=m, rx=s)."""
    await tb.apb("s").write(APB_REL, 0)
    await tb.apb("m").write(APB_PAIR_EN, 1)
    await tb.apb("s").write(APB_RXCTL, 0x2)
    await ClockCycles(tb.dut.hclk, 50)


async def _sb_send(tb, tag, length=2):
    t0 = 0
    while (await tb.apb("s").read(APB_CREDIT)) < length + 2:
        await ClockCycles(tb.dut.hclk, 20); t0 += 1
        assert t0 < 500, "no receiver credit"
    words = [(length & 0xFFF) << 20, 0, tag & 0xFFFFFFFF, (~tag) & 0xFFFFFFFF]
    await tb.ahb_tx_write_packet("m", words)
    return words


async def _sb_collect(tb, wait_cycles=60000, settle=3000):
    """Wait for a packet (RXST bit4), settle for replay duplicates, drain all."""
    apb = tb.apb("s"); pk = []
    for _ in range(wait_cycles // 100):
        if (await apb.read(APB_RXST) >> 4) & 1: break
        await ClockCycles(tb.dut.hclk, 100)
    await ClockCycles(tb.dut.hclk, settle)
    while (await apb.read(APB_RXST) >> 4) & 1 and len(pk) < 8:
        hdr = await tb.ahb_fifo_read_word("s", 0)
        total = min(((hdr >> 20) & 0xFFF) + 2, 64)
        pk.append([hdr] + [await tb.ahb_fifo_read_word("s", i * 4) for i in range(1, total)])
    return pk


def _exact(pk, tag):
    return len(pk) == 1 and len(pk[0]) >= 4 and pk[0][2] == tag and pk[0][3] == (~tag) & 0xFFFFFFFF


async def _arm_apb(tb, did, byte, bit):
    """rev2hw.arm: write 0, then the armed value (0->1 edge in the TX link clock)."""
    apb = tb.apb("m")
    await apb.write(APB_ERRINJ, 0)
    await ClockCycles(tb.dut.hclk, 400)
    assert await apb.read(APB_ERRINJ) == 0, "0x23C does not read 0"
    val = (1 << 24) | ((bit & 7) << 16) | ((byte & 0xFF) << 8) | (did & 0xFF)
    await apb.write(APB_ERRINJ, val)
    await ClockCycles(tb.dut.hclk, 400)
    rb = await apb.read(APB_ERRINJ)
    assert rb == val, f"0x23C readback 0x{rb:08x} != 0x{val:08x}"
    return val


async def _disarm_apb(tb):
    await tb.apb("m").write(APB_ERRINJ, 0)
    await ClockCycles(tb.dut.hclk, 400)


async def _crc(tb):
    return (await tb.apb("s").read(N6 + CRCCNT)) & 0xFFFF


async def _sideband_shot(dut, inject):
    tb = await _bringup(dut)
    await _sb_setup(tb)
    if os.environ.get("SB_FORCE_NO_L9B") == "1":
        # DIAGNOSTIC CONTROL ONLY (not a fix): disable the RX forward re-anchor on the receiver.
        tb.fcsm("s").socl_l9b_reanchor_now.value = Force(0)
        tb.log.info("[sb] CONTROL: socl_l9b_reanchor_now forced 0 on die s")
    # sanity: a clean packet first (instrument check)
    tag0 = 0x5C000001
    await _sb_send(tb, tag0)
    pk0 = await _sb_collect(tb)
    assert _exact(pk0, tag0), f"PRECONDITION: clean sideband packet not delivered exactly once: {pk0}"
    c0 = await _crc(tb)
    mon = Mon(tb); mon.start()
    tag = 0x5C000105
    if inject:
        await _arm_apb(tb, SB_ID, BYTE, BIT)
    await _sb_send(tb, tag)
    pk = await _sb_collect(tb)
    if inject: await _disarm_apb(tb)
    c1 = await _crc(tb)
    mon.stop(); await ClockCycles(dut.hclk, 2)
    mon.dump(tb.log)
    exact = _exact(pk, tag)
    tb.log.info(f"[sb] inject={inject} byte={BYTE} bit={BIT} crc {c0}->{c1} packets={len(pk)} "
                f"exact={exact} data={[[hex(w) for w in p] for p in pk]}")
    tb.log.info(f"[sb] RX(s) state7_cycles={mon.state7['s']} send_nack_req_rises={mon.count('s','send_nack_req')} "
                f"crc_corrupt_rises={mon.count('s','crc_corrupt')} wdog_force_clear_rises={mon.count('s','socl_l7_wdog_force_clear')} "
                f"wdog_max={mon.max_wdog['s']} real_crc_seen_final={_s(tb.fcsm('s'),'socl_l7_real_crc_seen')} "
                f"| TX(m) nack_rx_rises={mon.count('m','pkt_is_nack_pkt')}")
    # fresh clean packet afterwards
    tag2 = tag ^ 0x00F00000
    await _sb_send(tb, tag2)
    pk2 = await _sb_collect(tb)
    tb.log.info(f"[sb] fresh clean packet after shot: exact={_exact(pk2, tag2)}")
    return dict(c0=c0, c1=c1, exact=exact, npk=len(pk), fresh=_exact(pk2, tag2), mon=mon)


@cocotb.test()
async def test_sideband_clean_control(dut):
    r = await _sideband_shot(dut, inject=False)
    assert r["c1"] - r["c0"] == 0 and r["exact"], r


@cocotb.test()
async def test_sideband_crc_replay(dut):
    r = await _sideband_shot(dut, inject=True)
    assert (r["c1"] - r["c0"]) & 0xFFFF == 1, f"shot not detected (CRC counter {r['c0']}->{r['c1']}): vacuous"
    assert r["npk"] == 1 and r["exact"], (
        f"detected sideband CRC error was NOT replayed exactly once: packets={r['npk']} exact={r['exact']}")


@cocotb.test()
async def test_axi_w_crc_replay_control(dut):
    """Positive control: same APB-armed single-bit shot on W (0x81, byte 5) of a peer write."""
    tb = await _bringup(dut)
    master = AHBSubMaster(dut)
    _force_axi_crc(tb, True)
    await master.write(APER_BASE + OFF_SANITY, D_SANITY)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, OFF_SANITY) == D_SANITY, "clean sanity write failed"
    fcw = tb.top("s").u_chiplet_controller.u_wlink.axi2wl.wlink_axiwFC
    c0 = _s(fcw, "crc_errors") or 0
    mon_n = {"state7": 0}
    async def mon():
        for _ in range(60000):
            await RisingEdge(dut.hclk)
            if _s(fcw, "state") == 7: mon_n["state7"] += 1
    m = cocotb.start_soon(mon())
    await _arm_apb(tb, 0x81, BYTE, BIT)
    await master.write(APER_BASE + OFF_INJECT, D_INJECT, timeout=80000)
    await ClockCycles(dut.hclk, 3000)
    await _disarm_apb(tb)
    m.kill()
    c1 = _s(fcw, "crc_errors") or 0
    got = _slave_bram_peek(dut, OFF_INJECT)
    dut._log.info(f"[w] crc_errors {c0}->{c1} state7_cycles={mon_n['state7']} mem=0x{got:08x} (sent 0x{D_INJECT:08x})")
    _release_all(tb)
    assert c1 > c0, "W shot not detected: vacuous"
    assert got == D_INJECT, "W shot detected but data not exact after replay"
