"""End-to-end JOIN: HA1588 RTC -> ha1588_servo -> PHC, through the REAL
ethernet_ss_ahb_phc subsystem AHB, plus a real MII PTP capture in the same sim.

This is the first functional (driven) simulation of ethernet_ss_ahb_phc. The two
halves of the grandmaster chain were each proven separately before:
  * capture (eth_ptp_chain): HA1588 timestamps a real MII PTP frame;
  * servo   (phc_ha1588_servo_loop): ha1588_servo disciplines the PHC — but
    there the RTC was a TB STUB and the PHC was a bare APB port.

Here BOTH run inside one subsystem: the PHC is programmed across the subsystem's
own AHB matrix + AHB->APB bridge (eth_ss_0 -> u_phc_0), and the servo reference
is the REAL running HA1588 RTC (u_ethmac_0.u_ha1588), not a stub.

RIGOUR: every positive test has a negative control. What this sim CANNOT prove:
  * it is a loopback, not an independent time source, so it cannot detect a
    common-mode offset shared by both MII directions;
  * ideal MII/AHB timing != silicon rate;
  * the RTL does NOT route the TSU MII timestamp into the servo — the servo
    tracks the HA1588 *RTC*. So "a timestamped MII event moves the PHC" is NOT
    what this hardware does; the honest claim is that the same HA1588 that
    timestamps real MII traffic also provides the RTC the servo disciplines the
    PHC to. See NOTE in test_03.
"""

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles, Timer, First
from cocotb.clock import Clock

# ── PHC-variant memory map (build_soc_phc/reports/ethernet_ss_ahb_phc_memory_map.txt)
ETHMAC_BASE = 0x1800_0000
HA1588_BASE = ETHMAC_BASE + 0x1000        # ethmac AHB->APB, paddr[15:12]==1
PHC_BASE    = 0x1A00_0000

# ── HA1588 registers (OpenCores-HA1588 reg.v; no reset => must zero-init) ────
HA_RTC_CTRL   = HA1588_BASE + 0x00
HA_SCRATCH    = HA1588_BASE + 0x04
HA_TIME_SEC_H = HA1588_BASE + 0x10
HA_TIME_SEC_L = HA1588_BASE + 0x14
HA_PERIOD_H   = HA1588_BASE + 0x20
HA_PERIOD_L   = HA1588_BASE + 0x24
HA_TSU_RXCTRL = HA1588_BASE + 0x40
HA_TSU_RXSTAT = HA1588_BASE + 0x44
HA_TSU_TXCTRL = HA1588_BASE + 0x60
HA_TSU_TXSTAT = HA1588_BASE + 0x64
HA_TSU_TXDATA0 = HA1588_BASE + 0x70

RTC_CTRL_GET_TIME   = 1 << 0
RTC_CTRL_SET_PERIOD = 1 << 2
RTC_CTRL_SET_TIME   = 1 << 3
TSU_CTRL_READ_QUEUE = 1 << 0
TSU_CTRL_RESET      = 1 << 1

# ── PHC registers (phc_apb_regs.sv) ─────────────────────────────────────────
PHC_CTRL            = PHC_BASE + 0x000     # [0]=EN [1]=SET_TIME(W1S) [2]=CAPTURE(W1S)
PHC_NS_INCR         = PHC_BASE + 0x008
PHC_SET_SECONDS_LO  = PHC_BASE + 0x010
PHC_SET_SECONDS_HI  = PHC_BASE + 0x014
PHC_SET_NANOSECONDS = PHC_BASE + 0x018
PHC_CAP_SECONDS_LO  = PHC_BASE + 0x020
PHC_CAP_SECONDS_HI  = PHC_BASE + 0x024
PHC_CAP_NANOSECONDS = PHC_BASE + 0x028
PHC_SERVO_CTRL      = PHC_BASE + 0x0A0     # [0]=SRC_SEL(1=ha1588) [1]=SERVO_EN
PHC_SYNC_INTERVAL   = PHC_BASE + 0x0A4
PHC_SERVO_STATUS    = PHC_BASE + 0x0A8     # [0]=LOCKED [1]=PHASE_STEP_ACTIVE

PHC_CTRL_EN       = 1 << 0
PHC_CTRL_SET_TIME = 1 << 1
PHC_CTRL_CAPTURE  = 1 << 2
SERVO_SRC_HA1588  = 1 << 0
SERVO_EN          = 1 << 1

HCLK_NS = 20   # sys_hclk period; NS_INCR must match for real-time-ish PHC ticks

# ── OpenCores MAC + DMA buffers (PHC-variant map) ───────────────────────────
MAC_BASE      = ETHMAC_BASE + 0x0000
MAC_MODER     = MAC_BASE + 0x00
MAC_INT_MASK  = MAC_BASE + 0x08
MAC_IPGT      = MAC_BASE + 0x0C
MAC_IPGR1     = MAC_BASE + 0x10
MAC_IPGR2     = MAC_BASE + 0x14
MAC_PACKETLEN = MAC_BASE + 0x18
MAC_TX_BD_NUM = MAC_BASE + 0x20
MAC_MAC_ADDR0 = MAC_BASE + 0x40
MAC_MAC_ADDR1 = MAC_BASE + 0x44
MAC_BD_BASE   = MAC_BASE + 0x400
MAC_MODER_RESET = 0x0000_A000
MODER_RXEN, MODER_TXEN, MODER_PRO = 1 << 0, 1 << 1, 1 << 5
MODER_FULLD, MODER_CRCEN, MODER_PAD = 1 << 10, 1 << 13, 1 << 15
TX_BD_RD, TX_BD_IRQ, TX_BD_WR = 1 << 15, 1 << 14, 1 << 13
TX_BD_PAD, TX_BD_CRC = 1 << 12, 1 << 11
RX_BD_E, RX_BD_IRQ, RX_BD_WR = 1 << 15, 1 << 14, 1 << 13
INT_TXB, INT_RXB = 1 << 0, 1 << 2

TX_BUF_ADDR = 0x1400_0000     # eth_scratch_tx_0 (PHC-variant map)
RX_BUF_ADDR = 0x1000_0000     # eth_scratch_rx_0
NUM_TX_BDS  = 2
PTP_DST_MAC = b'\x01\x1B\x19\x00\x00\x00'
PTP_SRC_MAC = b'\x00\x1A\x2B\x3C\x4D\x5E'


def build_ptp_sync_payload(seq_id=0x42, msg_type=0x00):
    ethertype = b'\x88\xF7'
    h = bytearray(34)
    h[0] = msg_type & 0x0F
    h[1] = 0x02
    h[3] = 0x2C
    h[20:28] = b'\x00\x1A\x2B\xFF\xFE\x3C\x4D\x5E'
    h[28] = 0x00; h[29] = 0x01
    h[30] = (seq_id >> 8) & 0xFF; h[31] = seq_id & 0xFF
    frame = PTP_DST_MAC + PTP_SRC_MAC + ethertype + bytes(h)
    if len(frame) < 60:
        frame += b'\x00' * (60 - len(frame))
    return frame


def pack_words(frame):
    """OpenCores MAC DMA emits the LSB of each 32-bit word first (little-endian
    DMA words) — established byte-order in eth_ptp_chain (run 1 vs run 2)."""
    if len(frame) % 4:
        frame += b'\x00' * (4 - len(frame) % 4)
    return [(frame[i+3] << 24) | (frame[i+2] << 16) | (frame[i+1] << 8) | frame[i]
            for i in range(0, len(frame), 4)]


def mii_wire_bytes(dut, n):
    out = []
    length = int(dut.mii_cap_len.value)
    for i in range(min(n, length)):
        try:
            out.append(int(dut.mii_cap_mem[i].value) & 0xFF)
        except Exception:
            break
    return out


def hexdump(bs):
    return ' '.join(f'{b:02x}' for b in bs)


# ===========================================================================
# Minimal AHB-Lite single-transfer master on eth_ss_0 (clocked on sys_hclk).
# ===========================================================================
class AhbMaster:
    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.sys_hclk

    def _idle(self):
        d = self.dut
        d.eth_ss_0_htrans.value = 0
        d.eth_ss_0_hwrite.value = 0
        d.eth_ss_0_haddr.value = 0

    @staticmethod
    def _resolved(sig):
        try:
            return int(sig.value)
        except Exception:
            return None

    async def _xfer(self, addr, write, wdata=0, timeout=2000):
        d = self.dut
        await RisingEdge(self.clk)
        # ---- address phase ----
        d.eth_ss_0_haddr.value  = addr & 0xFFFF_FFFF
        d.eth_ss_0_htrans.value = 2       # NONSEQ
        d.eth_ss_0_hwrite.value = 1 if write else 0
        d.eth_ss_0_hsize.value  = 2       # word
        d.eth_ss_0_hburst.value = 0
        d.eth_ss_0_hprot.value  = 0
        # wait for the slave to accept the address (hready high on a posedge)
        for _ in range(timeout):
            await RisingEdge(self.clk)
            if self._resolved(d.eth_ss_0_hready) == 1:
                break
        else:
            raise TimeoutError(f"AHB {'WR' if write else 'RD'} 0x{addr:08x}: address phase never accepted")
        # ---- data phase ----
        self._idle()
        if write:
            d.eth_ss_0_hwdata.value = wdata & 0xFFFF_FFFF
        for _ in range(timeout):
            await RisingEdge(self.clk)
            if self._resolved(d.eth_ss_0_hready) == 1:
                resp = self._resolved(d.eth_ss_0_hresp)
                rdata = self._resolved(d.eth_ss_0_hrdata)
                if resp:
                    raise RuntimeError(f"AHB {'WR' if write else 'RD'} 0x{addr:08x}: HRESP=ERROR")
                return rdata
        raise TimeoutError(f"AHB {'WR' if write else 'RD'} 0x{addr:08x}: data phase never completed")

    async def write(self, addr, data):
        await self._xfer(addr, True, data)

    async def read(self, addr):
        return await self._xfer(addr, False)


# ===========================================================================
# Bring-up: clocks, reset, and a running/programmed HA1588 RTC.
# ===========================================================================
async def bringup(dut):
    m = AhbMaster(dut)
    m._idle()

    # release reset, wait for the PRMU-generated hresetn
    dut.sys_sysresetn.value = 0
    await Timer(200, unit="ns")
    dut.sys_sysresetn.value = 1
    # sys_hclk is a DUT output; wait until it and hresetn are alive
    for _ in range(20000):
        await RisingEdge(dut.sys_hclk)
        if AhbMaster._resolved(dut.sys_hresetn) == 1:
            break
    await ClockCycles(dut.sys_hclk, 50)
    dut._log.info("[phc] reset released; sys_hresetn high, hclk running")
    return m


async def program_ha1588_rtc(dut, m):
    """Zero-init HA1588 (reg.v has NO reset), start the RTC ticking."""
    for off in range(0x00, 0x80, 0x04):
        await m.write(HA1588_BASE + off, 0)
    # 8 ns nominal period, then PERIOD_LD pulse
    await m.write(HA_PERIOD_H, 0x0000_0008)
    await m.write(HA_PERIOD_L, 0x0000_0000)
    await m.write(HA_RTC_CTRL, RTC_CTRL_SET_PERIOD)
    await ClockCycles(dut.sys_hclk, 200)
    await m.write(HA_RTC_CTRL, 0)
    await ClockCycles(dut.sys_hclk, 500)
    # witness the RTC ticking via the top-level rtc_time export (instrument-first)
    ns0 = int(dut.rtc_time_ptp_ns.value)
    await ClockCycles(dut.sys_hclk, 2000)
    ns1 = int(dut.rtc_time_ptp_ns.value)
    sec = int(dut.rtc_time_ptp_sec.value)
    dut._log.info(f"[phc] HA1588 RTC witness: ns {ns0} -> {ns1} sec={sec} "
                  f"{'TICKING' if ns0 != ns1 else 'STOPPED'}")
    assert ns0 != ns1, "HA1588 RTC not ticking — servo reference is dead"


def phc_live(dut):
    return int(dut.u_dut.phc_seconds.value), int(dut.u_dut.phc_nanoseconds.value)


async def program_phc(dut, m, phc_sec):
    """Enable the PHC, seed a deliberate offset second value."""
    await m.write(PHC_NS_INCR, HCLK_NS)
    await m.write(PHC_SET_SECONDS_LO, phc_sec & 0xFFFF_FFFF)
    await m.write(PHC_SET_SECONDS_HI, (phc_sec >> 32) & 0xFFFF)
    await m.write(PHC_SET_NANOSECONDS, 0)
    await m.write(PHC_CTRL, PHC_CTRL_EN | PHC_CTRL_SET_TIME)
    await ClockCycles(dut.sys_hclk, 20)


# ===========================================================================
# Tests
# ===========================================================================
@cocotb.test()
async def test_01_bringup_and_regs(dut):
    """Subsystem elaborates AND runs: reach HA1588 + PHC registers over eth_ss_0."""
    # All clocks (sys_fclk, rtc_clk, mtx_clk) are generated inside tb_top.sv.
    m = await bringup(dut)

    # PHC read-back of a seeded time proves the eth_ss_0 -> interconnect ->
    # AHB->APB -> phc_0 path is live (this is the register-visibility floor).
    await m.write(PHC_NS_INCR, HCLK_NS)
    await m.write(PHC_SET_SECONDS_LO, 0x1234)
    await m.write(PHC_CTRL, PHC_CTRL_EN | PHC_CTRL_SET_TIME)
    await ClockCycles(dut.sys_hclk, 10)
    await m.write(PHC_CTRL, PHC_CTRL_CAPTURE)          # snapshot live time
    await ClockCycles(dut.sys_hclk, 5)
    cap = await m.read(PHC_CAP_SECONDS_LO)
    dut._log.info(f"[phc] PHC seeded 0x1234, captured seconds = 0x{cap:x}")
    assert cap == 0x1234, f"PHC not reachable/seedable over eth_ss_0: got 0x{cap:x}"
    dut._log.info("PASS: PHC + HA1588 reachable through the subsystem AHB")


@cocotb.test()
async def test_02_servo_disciplines_phc(dut):
    """THE JOIN: the servo steps the PHC off a deliberate offset onto the REAL
    running HA1588 RTC, all through the subsystem AHB. PHC starts at 100 s; the
    HA1588 RTC free-runs near 0 s, so a correct servo drives PHC 100 -> ~0."""
    m = await bringup(dut)
    await program_ha1588_rtc(dut, m)
    await program_phc(dut, m, phc_sec=100)

    s0, n0 = phc_live(dut)
    rtc_s = int(dut.rtc_time_ptp_sec.value)
    dut._log.info(f"[phc] before servo: PHC={s0}.{n0:09d}  RTC≈{rtc_s} s")
    assert s0 == 100, f"PHC should start at the seeded 100 s, got {s0}"
    assert rtc_s < 5, f"RTC drifted unexpectedly far ({rtc_s} s) — offset no longer clean"

    # small sync interval so the servo fires promptly
    await m.write(PHC_SYNC_INTERVAL, 10_000)
    await m.write(PHC_SERVO_CTRL, SERVO_SRC_HA1588 | SERVO_EN)

    # watch the servo actually act (top-level witness nets)
    saw_capture = saw_set_time = False
    for _ in range(200_000):
        await RisingEdge(dut.sys_hclk)
        if AhbMaster._resolved(dut.u_dut.ha1588_hw_capture) == 1:
            saw_capture = True
        if AhbMaster._resolved(dut.u_dut.ha1588_hw_set_time) == 1:
            saw_set_time = True
            break
    assert saw_capture, "servo never requested a PHC capture (sync_fire never asserted)"
    assert saw_set_time, "servo never issued a set-time — PHC not disciplined"

    await ClockCycles(dut.sys_hclk, 50)
    s1, n1 = phc_live(dut)
    rtc_s2 = int(dut.rtc_time_ptp_sec.value)
    dut._log.info(f"[phc] after servo: PHC {s0} s -> {s1} s  (HA1588 RTC ≈ {rtc_s2} s)")
    assert s1 <= 2, (f"PHC did not converge onto the HA1588 RTC: {s0} s -> {s1} s "
                     f"(RTC ≈ {rtc_s2} s)")
    dut._log.info("PASS: servo disciplined the PHC onto the real running HA1588 RTC")


@cocotb.test()
async def test_03_negative_control_servo_disabled(dut):
    """Negative control: with the servo DISABLED the PHC must NOT be corrected —
    it must hold its 100 s offset. Without this, test_02 is not attributable."""
    m = await bringup(dut)
    await program_ha1588_rtc(dut, m)
    await program_phc(dut, m, phc_sec=100)

    await m.write(PHC_SYNC_INTERVAL, 10_000)
    await m.write(PHC_SERVO_CTRL, SERVO_SRC_HA1588)   # SRC set, EN clear

    for _ in range(200_000):
        await RisingEdge(dut.sys_hclk)
        assert AhbMaster._resolved(dut.u_dut.ha1588_hw_capture) != 1, \
            "servo captured while disabled"
        assert AhbMaster._resolved(dut.u_dut.ha1588_hw_set_time) != 1, \
            "servo set-time while disabled"

    s1, _ = phc_live(dut)
    dut._log.info(f"[phc] servo disabled: PHC held at {s1} s (seeded 100)")
    assert s1 == 100, f"PHC moved to {s1} s with servo disabled — test_02 not attributable"
    dut._log.info("PASS: no servo activity while disabled; test_02 is attributable")


async def arm_tsu(dut, m):
    """Arm both TSU queues for messageType 0x00 (Sync) and reset them empty."""
    await m.write(HA_TSU_RXSTAT, 0x01 << 24)
    await m.write(HA_TSU_RXCTRL, TSU_CTRL_RESET)
    await ClockCycles(dut.sys_hclk, 300)
    await m.write(HA_TSU_RXCTRL, 0)
    await m.write(HA_TSU_TXSTAT, 0x01 << 24)
    await m.write(HA_TSU_TXCTRL, TSU_CTRL_RESET)
    await ClockCycles(dut.sys_hclk, 300)
    await m.write(HA_TSU_TXCTRL, 0)
    await ClockCycles(dut.sys_hclk, 200)


@cocotb.test()
async def test_04_real_mii_ptp_capture(dut):
    """Gap 1 IN THE PHC SUBSYSTEM: a REAL L2 PTP Sync frame is DMA'd out of
    eth_scratch_tx by the MAC's own master, put on the MII wire by the real TX
    FSM, looped back, and TIMESTAMPED by HA1588 — proving the capture half runs
    in the SAME sim binary as the servo join (tests 02/03).

    Instrument-first: the tb records the bytes physically on the MII wire, so a
    depth=0 can be distinguished from a wrong-byte-order frame (the true-negative
    that cost eth_ptp_chain a debug round)."""
    m = await bringup(dut)
    await program_ha1588_rtc(dut, m)
    await arm_tsu(dut, m)

    dpre_rx = (await m.read(HA_TSU_RXSTAT)) & 0xFF
    dpre_tx = (await m.read(HA_TSU_TXSTAT)) & 0xFF
    dut._log.info(f"[phc] TSU depth BEFORE frame: rx={dpre_rx} tx={dpre_tx}")
    assert dpre_rx == 0 and dpre_tx == 0, "TSU not empty before stimulus — capture would prove nothing"

    # ---- configure the MAC ----
    await m.write(MAC_MAC_ADDR0, 0xEFBE_ADDE)
    await m.write(MAC_MAC_ADDR1, 0x0000_0002)
    await m.write(MAC_IPGT, 0x15)
    await m.write(MAC_IPGR1, 0x0C)
    await m.write(MAC_IPGR2, 0x12)
    await m.write(MAC_PACKETLEN, (1518 << 16) | 64)
    await m.write(MAC_TX_BD_NUM, NUM_TX_BDS)
    await m.write(MAC_INT_MASK, INT_TXB | INT_RXB)
    rx_bd = MAC_BD_BASE + NUM_TX_BDS * 8
    await m.write(rx_bd, RX_BD_E | RX_BD_IRQ | RX_BD_WR)
    await m.write(rx_bd + 4, RX_BUF_ADDR)
    moder = (MAC_MODER_RESET | MODER_PRO | MODER_PAD | MODER_CRCEN
             | MODER_FULLD | MODER_TXEN | MODER_RXEN)
    await m.write(MAC_MODER, moder & ~(MODER_TXEN | MODER_RXEN))

    # ---- stage the PTP frame into eth_scratch_tx ----
    frame = build_ptp_sync_payload(seq_id=0x0042, msg_type=0x00)
    words = pack_words(frame)
    for i, w in enumerate(words):
        await m.write(TX_BUF_ADDR + 4 * i, w)
    w0 = await m.read(TX_BUF_ADDR + 0)
    assert w0 == words[0], f"scratch_tx staging failed: got 0x{w0:08x} exp 0x{words[0]:08x}"

    # ---- arm the TX BD and release the MAC ----
    tx_bd = MAC_BD_BASE
    bd0 = ((len(frame) & 0xFFFF) << 16) | TX_BD_RD | TX_BD_IRQ | TX_BD_WR | TX_BD_PAD | TX_BD_CRC
    await m.write(tx_bd, bd0)
    await m.write(tx_bd + 4, TX_BUF_ADDR)
    frames_before = int(dut.mii_frames.value)
    await m.write(MAC_MODER, moder)     # TXEN 0->1 starts the BD scanner

    moved = False
    for _ in range(400):
        await ClockCycles(dut.sys_hclk, 200)
        if int(dut.mii_frames.value) > frames_before:
            moved = True
            break
    assert moved, "no frame reached the MII wire"
    await ClockCycles(dut.sys_hclk, 20000)   # let RX FSM + TSU CDC settle

    wire = mii_wire_bytes(dut, 32)
    dut._log.info(f"[phc] MII wire bytes: {hexdump(wire)}")
    et_ok = False
    if 0xD5 in wire:
        s = wire.index(0xD5) + 1
        if len(wire) >= s + 14:
            et = (wire[s + 12] << 8) | wire[s + 13]
            et_ok = (et == 0x88F7)
            dut._log.info(f"[phc] wire frame @byte{s}: DA={hexdump(wire[s:s+6])} "
                          f"EtherType=0x{et:04x} {'== PTP OK' if et_ok else 'NOT PTP'}")
    assert et_ok, "PTP EtherType 0x88f7 not confirmed on the MII wire"

    depth_tx = (await m.read(HA_TSU_TXSTAT)) & 0xFF
    depth_rx = (await m.read(HA_TSU_RXSTAT)) & 0xFF
    d3 = await m.read(HA_TSU_TXDATA0 + 0x0C)      # DATA3 = {msg_id, cksum, seq_id}
    seq = d3 & 0xFFFF
    msg_id = (d3 >> 28) & 0xF
    dut._log.info(f"[phc] HA1588 TSU depth tx={depth_tx} rx={depth_rx}; "
                  f"TX.DATA3=0x{d3:08x} -> msg_id={msg_id} seq_id=0x{seq:04x}")
    assert depth_tx >= 1, "HA1588 TX TSU did not capture the frame"
    assert depth_rx >= 1, "HA1588 RX TSU did not capture (the stronger, RX-FSM-only proof)"
    assert seq == 0x0042, f"captured seq_id 0x{seq:04x} != staged 0x0042 — not our frame"
    dut._log.info("PASS: real MII PTP frame timestamped by HA1588 in the SAME sim as the servo join")


@cocotb.test()
async def test_05_tsu_pop_localisation(dut):
    """Localise the eth_ptp_chain TSU queue-pop WEDGE. There, popping the queue
    (CTRL bit0) to load the 80-bit timestamp VALUE hung the CROSS-LINK read.
    This bench reaches the SAME HA1588 register path but WITHOUT the TideLink
    link — a direct AHB master on eth_ss_0. If the pop + DATA reads complete
    here, the wedge is LINK-specific (TideLink return path), not the HA1588
    AHB->WB bridge. That is the negative control the cross-link bench could not
    run."""
    m = await bringup(dut)
    await program_ha1588_rtc(dut, m)
    await arm_tsu(dut, m)

    # capture one frame -> exactly one TX queue entry
    await m.write(MAC_MAC_ADDR0, 0xEFBE_ADDE)
    await m.write(MAC_MAC_ADDR1, 0x0000_0002)
    await m.write(MAC_IPGT, 0x15); await m.write(MAC_IPGR1, 0x0C); await m.write(MAC_IPGR2, 0x12)
    await m.write(MAC_PACKETLEN, (1518 << 16) | 64)
    await m.write(MAC_TX_BD_NUM, NUM_TX_BDS)
    await m.write(MAC_INT_MASK, INT_TXB | INT_RXB)
    moder = (MAC_MODER_RESET | MODER_PRO | MODER_PAD | MODER_CRCEN
             | MODER_FULLD | MODER_TXEN | MODER_RXEN)
    await m.write(MAC_MODER, moder & ~(MODER_TXEN | MODER_RXEN))
    frame = build_ptp_sync_payload(seq_id=0x0055, msg_type=0x00)
    for i, w in enumerate(pack_words(frame)):
        await m.write(TX_BUF_ADDR + 4 * i, w)
    tx_bd = MAC_BD_BASE
    await m.write(tx_bd, ((len(frame) & 0xFFFF) << 16) | TX_BD_RD | TX_BD_IRQ | TX_BD_WR | TX_BD_PAD | TX_BD_CRC)
    await m.write(tx_bd + 4, TX_BUF_ADDR)
    await m.write(MAC_MODER, moder)
    await ClockCycles(dut.sys_hclk, 30000)

    depth = (await m.read(HA_TSU_TXSTAT)) & 0xFF
    dut._log.info(f"[phc] TX depth={depth}")
    assert depth >= 1, "no TX entry captured"

    # ---- FINDING 1: the queue entry is readable PRE-pop (no pop needed) --------
    # ptp_queue is first-word-fall-through (q = mem[rd_bin], ptp_queue.v:80), so
    # the head entry is continuously presented. DATA3 = ptp_infor (tsu.v:349) and
    # reads the real captured seq_id WITHOUT any pop. DATA0..2 are the 80-bit
    # timestamp {sec[47:0], ns[31:0]} — here ~0 because the TSU's rtc_timer was
    # near zero at the capture instant (a TRUE value, not "unloaded": that is why
    # eth_ptp_chain also saw 0 pre-pop). So the pop is not needed to read a value.
    d0 = await m.read(HA_TSU_TXDATA0 + 0x00)
    d1 = await m.read(HA_TSU_TXDATA0 + 0x04)
    d2 = await m.read(HA_TSU_TXDATA0 + 0x08)
    d3 = await m.read(HA_TSU_TXDATA0 + 0x0C)   # ptp_infor (seq_id etc.)
    dut._log.info(f"[phc] pre-pop DATA0..3 = 0x{d0:08x} 0x{d1:08x} 0x{d2:08x} 0x{d3:08x} "
                  f"(DATA3=ptp_infor -> seq_id 0x{d3 & 0xFFFF:04x})")
    assert (d3 & 0xFFFF) == 0x0055, (
        f"pre-pop ptp_infor seq_id 0x{d3 & 0xFFFF:04x} != staged 0x0055 — the head "
        f"entry is NOT readable without a pop")

    # ---- FINDING 2: the pop COMPLETES over a direct master (no bus hang) --------
    # eth_ptp_chain saw these post-pop reads never return HREADY ACROSS THE LINK.
    # Over a direct AHB master they complete => the wedge is LINK-specific
    # (TideLink return path on write-CTRL-then-read), NOT the HA1588 AHB->WB
    # bridge. (Post-pop the words are EXPECTED X: depth was 1, so the pop advances
    # rd_bin into never-written FIFO memory, mem[1] — the empty-queue X-init class,
    # same family as the tidelink empty-RX-FIFO issue. Read the value BEFORE
    # popping; never read after popping the last entry.)
    await m.write(HA_TSU_TXCTRL, TSU_CTRL_READ_QUEUE)
    await ClockCycles(dut.sys_hclk, 50)
    hung = False
    post = []
    for k in range(4):
        try:
            post.append(await m.read(HA_TSU_TXDATA0 + 4 * k))
        except TimeoutError:
            hung = True
            dut._log.error(f"[phc] DATA{k} STALLED over the direct master too")
            break
    await m.write(HA_TSU_TXCTRL, 0)
    dut._log.info("[phc] post-pop DATA0..3 = " +
                  ' '.join('X' if v is None else f'0x{v:08x}' for v in post) +
                  " (X expected: single entry consumed -> empty-FIFO read)")
    assert not hung, ("pop wedged over a DIRECT master too — the HA1588 bridge IS "
                      "the culprit (contradicts the link-specific hypothesis)")
    dut._log.info("PASS: timestamp VALUE readable pre-pop; pop completes over a "
                  "direct master => the eth_ptp_chain wedge is LINK-specific, and "
                  "the pop is unnecessary (and empties a depth-1 queue to X)")
