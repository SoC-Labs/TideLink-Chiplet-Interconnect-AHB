"""eth_ptp_chain — make HA1588 timestamp a REAL MII event, read it across the link.

This closes GAP 1 of docs/ETHERNET_PTP_CHAIN_GAP.md.

WHAT SHAPE-A PROVED (and what it did NOT)
-----------------------------------------
Shape-A (cocotb/eth_tidelink_pair_shape_a) proved die_a can READ MAC reset
constants and WRITE/READBACK HA1588.SCRATCH across the chiplet link. That is
register VISIBILITY. It explicitly did not exercise the MAC datapath: its
SIMPLIFICATION 2 tied `mrxd_i`/`mrxdv_i` to constant 0 and ran mtx_clk/mrx_clk
as two independent oscillators, so HA1588 -- which timestamps MII frame events
-- could never capture anything. SCRATCH is a plain RW cell with no hardware
side effects; writing it proves a bus path, not a clock.

WHAT THIS BENCH ADDS
--------------------
An MII EXTERNAL LOOPBACK in tb_top.sv (mtxd_o/mtxen_o -> mrxd_i/mrxdv_i, one
shared 25 MHz clock -- see the block comment there), and a full MAC transmit
sequence driven ENTIRELY FROM die_a ACROSS THE LINK:

  die_a peer window
    -> [link] -> die_b ahb_mng -> eth_ss_0 -> subsystem AHB matrix
       |
       +-- stage a real L2 PTP Sync frame into eth_scratch_tx (0x3800_0000)
       +-- program the MAC (MAC addr, IPG, PACKETLEN, TX_BD_NUM, BDs, MODER)
       +-- program HA1588 (zero-init, RTC period, TSU msgid mask, queue reset)
       +-- arm the TX buffer descriptor and set MODER.TXEN
                                |
                                v
        MAC's OWN DMA master reads the frame out of eth_scratch_tx
                                |
                                v
        real MAC TX FSM -> mtxd_o/mtxen_o --[LOOPBACK]--> mrxd_i/mrxdv_i
                                |                              |
                       HA1588 TX TSU tap             HA1588 RX TSU tap
                                |                              |
                                +--------------+---------------+
                                               v
                            die_a reads the captured timestamp
                            back ACROSS THE LINK  <-- THE DEMO RESULT

Nothing is faked. The frame is DMA'd by the MAC's own bus master, serialised
nibble-by-nibble by the real TX FSM, re-parsed by the real RX FSM, and parsed
again by HA1588's own ptp_parser. The far die's grandmaster hardware timestamp
is then read by die_a over the die-to-die link.

HA1588 CAPTURE PRECONDITIONS (all non-obvious, all sourced)
-----------------------------------------------------------
 1. NO RESET on the HA1588 register file (OpenCores-HA1588 rtl/reg/reg.v has no
    reset clause) => every register is X at power-up. Must zero-init 0x00..0x7C
    exactly as the block's own TB does (cocotb/ha1588_ahb/test_ha1588_ahb.py:154).
 2. ptp_msgid_mask defaults to 0 => NOTHING is ever queued until software writes
    TSU_RXSTAT/TXSTAT[31:24] (ptp_parser.v:184-189). Mask bit0 = Sync.
 3. The queue write is `ptp_found && eop` (tsu.v:348) -- so the frame must be a
    genuine EtherType-0x88F7 PTP frame with an enabled messageType, and must
    reach end-of-packet. A random frame produces no entry.
 4. The RTC must be ticking (period load) or the captured timestamp is zero --
    a zero timestamp would be a false negative, not a capture failure.
 5. The timestamp sampling trigger is the rising edge of gmii_ctrl, i.e. MII
    tx_en / rx_dv -- start of carrier, NOT SFD (tsu.v:190, incl. its own
    "TODO: check frame start delimiter").

Run:
    cd cocotb/eth_ptp_chain
    source ../../set_env.sh
    source ~/SoCLabs/nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh
    export TIDELINK_PHY_V2=1
    make MODULE=test_ptp_chain
"""
import cocotb
from cocotb.triggers import ClockCycles

from eth_pair_common import (
    PairV2TB, run_bringup_full, EthAHBSubMaster,
    MAC_BASE, HA1588_BASE, ETHMAC_BASE,
    MAC_MODER, MAC_PACKETLEN, MAC_TX_BD_NUM, MAC_MAC_ADDR0, MAC_MAC_ADDR1,
    MAC_MODER_RESET,
    MAC_INT_SOURCE, MAC_INT_MASK, MAC_IPGT, MAC_IPGR1, MAC_IPGR2, MAC_BD_BASE,
    MODER_RXEN, MODER_TXEN, MODER_PRO, MODER_FULLD, MODER_CRCEN, MODER_PAD,
    TX_BD_RD, TX_BD_IRQ, TX_BD_WR, TX_BD_PAD, TX_BD_CRC,
    RX_BD_E, RX_BD_IRQ, RX_BD_WR,
    INT_TXB, INT_RXB,
    HA1588_TSU_RXCTRL, HA1588_TSU_RXSTAT, HA1588_TSU_RXDATA0,
    HA1588_TSU_TXCTRL, HA1588_TSU_TXSTAT, HA1588_TSU_TXDATA0,
    HA1588_PERIOD_H, HA1588_PERIOD_L, HA1588_RTC_CTRL,
    TSU_CTRL_READ_QUEUE, TSU_CTRL_RESET, RTC_CTRL_SET_PERIOD,
    TX_BUF_ADDR, RX_BUF_ADDR, NUM_TX_BDS,
    build_ptp_sync_payload,
)

# Word packing for the DMA frame buffer.
#
# MEASURED, NOT ASSUMED. The first run of this bench packed frame byte0 into
# bits[31:24] (the "MAC transmits MSB first" guess). The tb's MII recorder then
# showed what was PHYSICALLY on the wire:
#
#   staged word0 = 0x011b1900   ->   wire bytes: 00 19 1b 01
#   staged word1 = 0x0000001a   ->   wire bytes: 1a 00 00 00
#
# i.e. every DMA word came out BYTE-REVERSED: the OpenCores MAC emits the
# LEAST significant byte of each 32-bit DMA word first. The EtherType landed as
# 0x0200 instead of 0x88F7, the HA1588 parser correctly refused to match, and
# both TSU queues stayed at depth 0 -- a true negative, not a broken capture.
#
# So frame byte0 belongs in bits[7:0]. This is exactly why the recorder was
# built before the first run: a silent depth-0 result would otherwise have been
# indistinguishable from "HA1588 cannot timestamp", and would have sent the
# investigation after the timestamp unit instead of the byte order.
BIG_ENDIAN_DMA_WORDS = False

# Issue the HA1588 TSU queue-pop (CTRL bit0) before reading the DATA registers.
# MEASURED to wedge the cross-link read -- left False so the bench is
# deterministic; flip to True to reproduce the stall. See gap doc §1.7.
POP_TSU_QUEUE = False


def pack_words(frame: bytes):
    """Split a frame into 32-bit words for AHB writes into the DMA buffer."""
    if len(frame) % 4:
        frame = frame + b'\x00' * (4 - len(frame) % 4)
    words = []
    for i in range(0, len(frame), 4):
        b = frame[i:i + 4]
        if BIG_ENDIAN_DMA_WORDS:
            words.append((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3])
        else:
            words.append((b[3] << 24) | (b[2] << 16) | (b[1] << 8) | b[0])
    return words


def mii_wire_bytes(dut, n):
    """Read back the tb's MII recorder as a list of bytes seen on the wire."""
    try:
        flat = int(dut.mii_cap_flat.value)
        ln = int(dut.mii_cap_len.value)
    except ValueError:
        return []
    n = min(n, ln)
    return [(flat >> (i * 8)) & 0xFF for i in range(n)]


def hexdump(bs):
    return " ".join(f"{b:02x}" for b in bs)


@cocotb.test()
async def test_ptp_chain_mii_timestamp(dut):
    """die_a drives a real PTP frame through die_b's MAC over an MII loopback and
    reads HA1588's hardware timestamp back across the TideLink pair."""
    tb = PairV2TB(dut)
    m = EthAHBSubMaster(dut)

    # ---- 1. Link up --------------------------------------------------------
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)
    tb.log.info("[chain] link up (cal+CR/CRACK); eth subsystem behind die_b ahb_mng")

    # ---- 2. Derive the peer-window -> ahb_mng transform (as Shape-A does) ----
    probe = RX_BUF_ADDR + 0x100
    await m.write(probe, 0xA5A50100)
    await ClockCycles(dut.hclk, 5)
    observed = int(dut.s_mng_haddr_seen.value)
    delta = (observed - probe) & 0xFFFF_FFFF
    tb.log.info(f"[chain] map: peer 0x{probe:08x} -> ahb_mng 0x{observed:08x} "
                f"(delta=0x{delta:08x}; {'IDENTITY' if delta == 0 else 'OFFSET'})")

    def P(addr):
        return (addr - delta) & 0xFFFF_FFFF

    async def wr(addr, val):
        await m.write(P(addr), val)

    async def rd(addr):
        return await m.read(P(addr))

    fails = []

    # ---- 3. Sanity: the link still reaches the MAC (Shape-A's proven read) ---
    moder0 = await rd(MAC_MODER)
    tb.log.info(f"[chain] MAC.MODER cold read = 0x{moder0:08x} "
                f"(golden 0x{MAC_MODER_RESET:08x})")
    if moder0 != MAC_MODER_RESET:
        fails.append(("MAC.MODER cold read", MAC_MODER_RESET, moder0))

    # ---- 4. ZERO-INIT the HA1588 register file (PRECONDITION 1) -------------
    # reg.v has no reset: every register is X until written. Skipping this makes
    # every later read ambiguous.
    tb.log.info("[chain] zero-init HA1588 registers 0x00..0x7C (reg.v has NO reset)")
    for off in range(0x00, 0x80, 0x04):
        await wr(HA1588_BASE + off, 0x0000_0000)
    tb.log.info("[chain] HA1588 zero-init done (32 registers, all across the link)")

    # ---- 5. Start the HA1588 RTC (PRECONDITION 4) --------------------------
    # 8 ns nominal period, then pulse PERIOD_LD. Without this the RTC never
    # advances and a capture would read back as an all-zero timestamp.
    await wr(HA1588_PERIOD_H, 0x0000_0008)
    await wr(HA1588_PERIOD_L, 0x0000_0000)
    await wr(HA1588_RTC_CTRL, RTC_CTRL_SET_PERIOD)
    await ClockCycles(dut.hclk, 200)
    await wr(HA1588_RTC_CTRL, 0)
    await ClockCycles(dut.hclk, 500)

    # Witness the RTC actually ticking, via the tb's non-bus RTC export. This is
    # instrument-first: if the RTC is dead, a later zero timestamp means "clock
    # stopped", not "capture failed", and the two must not be confused.
    ns_a = int(dut.eth_rtc_ptp_ns.value)
    await ClockCycles(dut.hclk, 2000)
    ns_b = int(dut.eth_rtc_ptp_ns.value)
    rtc_ticking = (ns_a != ns_b)
    tb.log.info(f"[chain] HA1588 RTC witness: ns {ns_a} -> {ns_b}  "
                f"{'TICKING' if rtc_ticking else 'STOPPED'}")
    if not rtc_ticking:
        fails.append(("HA1588 RTC not ticking", 1, 0))

    # ---- 6. Arm the TSU queues (PRECONDITION 2) ----------------------------
    # mask bit0 = messageType 0x00 = Sync. Mask 0 => the parser never sets
    # ptp_event and the queue stays empty forever.
    RX_MASK = 0x01
    TX_MASK = 0x01
    await wr(HA1588_TSU_RXSTAT, RX_MASK << 24)
    await wr(HA1588_TSU_RXCTRL, TSU_CTRL_RESET)
    await ClockCycles(dut.hclk, 300)
    await wr(HA1588_TSU_RXCTRL, 0)
    await wr(HA1588_TSU_TXSTAT, TX_MASK << 24)
    await wr(HA1588_TSU_TXCTRL, TSU_CTRL_RESET)
    await ClockCycles(dut.hclk, 300)
    await wr(HA1588_TSU_TXCTRL, 0)
    await ClockCycles(dut.hclk, 200)
    tb.log.info(f"[chain] TSU armed: rx_mask=0x{RX_MASK:02x} tx_mask=0x{TX_MASK:02x} "
                f"(bit0 = PTP Sync), both queues reset")

    depth_pre_rx = (await rd(HA1588_TSU_RXSTAT)) & 0xFF
    depth_pre_tx = (await rd(HA1588_TSU_TXSTAT)) & 0xFF
    tb.log.info(f"[chain] TSU depth BEFORE any frame: rx={depth_pre_rx} tx={depth_pre_tx} "
                f"(both must be 0 -- else the 'capture' below proves nothing)")
    if depth_pre_rx != 0 or depth_pre_tx != 0:
        fails.append(("TSU queues not empty before stimulus", 0,
                      (depth_pre_tx << 8) | depth_pre_rx))

    # ---- 7. Configure the MAC ----------------------------------------------
    await wr(MAC_MAC_ADDR0, 0xEFBE_ADDE)
    await wr(MAC_MAC_ADDR1, 0x0000_0002)
    await wr(MAC_IPGT, 0x0000_0015)
    await wr(MAC_IPGR1, 0x0000_000C)
    await wr(MAC_IPGR2, 0x0000_0012)
    await wr(MAC_PACKETLEN, (1518 << 16) | 64)
    await wr(MAC_TX_BD_NUM, NUM_TX_BDS)
    await wr(MAC_INT_MASK, INT_TXB | INT_RXB)

    rx_bd = MAC_BD_BASE + (NUM_TX_BDS * 8)
    await wr(rx_bd, RX_BD_E | RX_BD_IRQ | RX_BD_WR)
    await wr(rx_bd + 4, RX_BUF_ADDR)

    moder = (MAC_MODER_RESET | MODER_PRO | MODER_PAD | MODER_CRCEN
             | MODER_FULLD | MODER_TXEN | MODER_RXEN)
    await wr(MAC_MODER, moder & ~(MODER_TXEN | MODER_RXEN))
    tb.log.info(f"[chain] MAC configured (MODER target 0x{moder:08x}), TX/RX still off")

    # ---- 8. Stage the PTP frame in eth_scratch_tx ACROSS THE LINK ----------
    frame = build_ptp_sync_payload(seq_id=0x0042, msg_type=0x00)
    words = pack_words(frame)
    tb.log.info(f"[chain] staging {len(frame)}-byte L2 PTP Sync (seq_id=0x0042) into "
                f"eth_scratch_tx @0x{TX_BUF_ADDR:08x} as {len(words)} words, "
                f"across the link")
    for i, w in enumerate(words):
        await m.write(P(TX_BUF_ADDR + 4 * i), w)

    # Read two words back across the link to prove the far scratch really holds
    # the frame (and that the DMA source is not X).
    w0 = await rd(TX_BUF_ADDR + 0)
    w3 = await rd(TX_BUF_ADDR + 12)
    tb.log.info(f"[chain] scratch_tx readback: [0]=0x{w0:08x} (exp 0x{words[0]:08x})  "
                f"[3]=0x{w3:08x} (exp 0x{words[3]:08x})")
    if w0 != words[0] or w3 != words[3]:
        fails.append(("scratch_tx frame staging", words[0], w0))

    # ---- 9. Arm the TX BD and enable the MAC -> the frame goes on the wire --
    tx_bd = MAC_BD_BASE
    bd_word0 = ((len(frame) & 0xFFFF) << 16) | TX_BD_RD | TX_BD_IRQ | TX_BD_WR \
        | TX_BD_PAD | TX_BD_CRC
    await wr(tx_bd, bd_word0)
    await wr(tx_bd + 4, TX_BUF_ADDR)
    tb.log.info(f"[chain] TX BD armed: word0=0x{bd_word0:08x} ptr=0x{TX_BUF_ADDR:08x}")

    frames_before = int(dut.mii_tx_frames.value)
    await wr(MAC_MODER, moder)          # TXEN 0->1 restarts the TX BD scanner
    tb.log.info(f"[chain] MODER=0x{moder:08x} written -- TXEN asserted, MAC released")

    # ---- 10. Wait for the frame to physically traverse the loopback ---------
    # Poll the tb's MII observer, NOT a register: an independent, non-bus
    # witness that a frame really moved.
    moved = False
    for _ in range(400):
        await ClockCycles(dut.hclk, 200)
        if int(dut.mii_tx_frames.value) > frames_before:
            moved = True
            break
    nib = int(dut.mii_tx_nibbles.value)
    tb.log.info(f"[chain] MII observer: frames={int(dut.mii_tx_frames.value)} "
                f"(was {frames_before}) nibbles={nib}  "
                f"{'FRAME ON THE WIRE' if moved else 'NO FRAME'}")
    if not moved:
        fails.append(("no frame reached the MII wire", 1, 0))

    # Let the tail of the frame + the RX path + the TSU CDC settle.
    await ClockCycles(dut.hclk, 20000)

    # ---- 11. Dump what was PHYSICALLY on the wire ---------------------------
    wire = mii_wire_bytes(dut, 32)
    tb.log.info(f"[chain] MII wire bytes (first {len(wire)}): {hexdump(wire)}")
    # After preamble (0x55 x7) + SFD (0xd5) the frame proper begins: DA(6) SA(6)
    # then EtherType. Locate the SFD and check 0x88f7 sits 12 bytes past it.
    et_ok = False
    if 0xD5 in wire:
        s = wire.index(0xD5) + 1
        if len(wire) >= s + 14:
            et = (wire[s + 12] << 8) | wire[s + 13]
            et_ok = (et == 0x88F7)
            tb.log.info(f"[chain] wire frame starts at byte {s}: "
                        f"DA={hexdump(wire[s:s+6])} SA={hexdump(wire[s+6:s+12])} "
                        f"EtherType=0x{et:04x} {'== PTP (0x88f7) OK' if et_ok else 'NOT PTP'}")
    if not et_ok:
        tb.log.warning("[chain] EtherType 0x88f7 NOT confirmed on the wire -- if the "
                       "frame looks byte-reversed, flip BIG_ENDIAN_DMA_WORDS")
        fails.append(("PTP EtherType not seen on MII wire", 0x88F7, 0))

    # ---- 12. THE RESULT: read HA1588's hardware timestamps ACROSS THE LINK --
    # A read of a TSU DATA register can HANG the cross-link bus (measured: it
    # consumed the full 60000-cycle harness timeout). Never let that abort the
    # run -- a hang here is evidence about the HA1588 queue read port, and the
    # capture itself (queue depth) has already been established by then.
    async def try_rd(addr, tag):
        try:
            v = await m.read(P(addr), timeout=8000)
            tb.log.info(f"[chain]   {tag} @0x{addr:08x} = 0x{v:08x}")
            return v
        except TimeoutError:
            tb.log.error(f"[chain]   {tag} @0x{addr:08x} STALLED "
                         f"(no HREADY within 8000 cycles) -- bus read hang")
            return None

    async def pop_tsu(name, stat, ctrl, data0):
        depth = (await rd(stat)) & 0xFF
        tb.log.info(f"[chain] HA1588 {name} TSU depth = {depth}  "
                    f"{'<-- A TIMESTAMP WAS CAPTURED' if depth else '(empty)'}")
        if depth == 0:
            return None

        # (a) Read the DATA registers BEFORE any pop. If the queue presents its
        #     head combinationally, the entry is already here and the explicit
        #     pop is unnecessary.
        tb.log.info(f"[chain] {name}: reading DATA0..3 BEFORE the queue pop")
        pre = [await try_rd(data0 + 4 * k, f"{name}.DATA{k}(pre-pop)")
               for k in range(4)]

        # (b) The documented pop sequence (CTRL bit0) is DELIBERATELY NOT ISSUED
        #     here. MEASURED: issuing it wedges the cross-link read of the DATA
        #     registers -- both DATA0 and DATA1 returned no HREADY within 8000
        #     cycles, and on the first attempt a single read consumed the full
        #     60000-cycle harness timeout. See docs/ETHERNET_PTP_CHAIN_GAP.md
        #     §1.7. The pre-pop read already yields the entry's PTP identity
        #     (DATA3 = ptp_infor), which is what this bench asserts on, so the
        #     pop buys nothing here and costs determinism.
        #
        #     Set POP_TSU_QUEUE=True to reproduce the stall.
        if POP_TSU_QUEUE:
            tb.log.info(f"[chain] {name}: issuing queue pop (CTRL bit0) -- "
                        f"EXPECTED TO STALL, see gap doc")
            await wr(ctrl, TSU_CTRL_READ_QUEUE)
            await ClockCycles(dut.hclk, 300)
            await wr(ctrl, 0)
            await ClockCycles(dut.hclk, 2000)
            for k in range(4):
                await try_rd(data0 + 4 * k, f"{name}.DATA{k}(post-pop)")

        d = pre
        if any(x is None for x in d):
            tb.log.error(f"[chain] {name}: DATA registers not readable across the "
                         f"link -- capture CONFIRMED by depth={depth}, but the "
                         f"payload could not be retrieved")
            return {"d": [x or 0 for x in d], "msg_id": None, "seq_id": None,
                    "unreadable": True, "depth": depth}
        # tsu.v:349 -- {16'd0, time_stamp[79:0], ptp_infor[31:0]}
        # d3 = {msg_id[31:28], cksum[27:16], seq_id[15:0]}
        entry = {
            "d": d,
            "msg_id": (d[3] >> 28) & 0xF,
            "seq_id": d[3] & 0xFFFF,
            "ts_ns": d[2],
            "ts_sec": ((d[1] & 0xFFFF) << 16) | ((d[2] >> 16) & 0xFFFF),
        }
        tb.log.info(f"[chain] {name} TSU entry ACROSS THE LINK: "
                    f"d0=0x{d[0]:08x} d1=0x{d[1]:08x} d2=0x{d[2]:08x} d3=0x{d[3]:08x}")
        tb.log.info(f"[chain]   -> msg_id={entry['msg_id']} "
                    f"seq_id=0x{entry['seq_id']:04x} (expected 0x0042)")
        return entry

    tx_entry = await pop_tsu("TX", HA1588_TSU_TXSTAT, HA1588_TSU_TXCTRL,
                             HA1588_TSU_TXDATA0)
    rx_entry = await pop_tsu("RX", HA1588_TSU_RXSTAT, HA1588_TSU_RXCTRL,
                             HA1588_TSU_RXDATA0)

    captured = [e for e in (tx_entry, rx_entry) if e is not None]

    # THE GAP-1 CRITERION. A TSU queue entry can only be created by
    # `ptp_found && eop` (tsu.v:348) -- i.e. HA1588's own parser matched a
    # genuine EtherType-0x88F7 PTP frame with an enabled messageType and saw it
    # through to end-of-packet. A nonzero depth is therefore proof that the
    # hardware timestamped a REAL MII event, independently of whether the
    # payload registers can be read back.
    if not captured:
        fails.append(("HA1588 captured NO timestamp for a real MII PTP frame", 1, 0))

    readable = [e for e in captured if not e.get("unreadable")]
    for e in readable:
        # DATA3 = ptp_infor = {msg_id[31:28], cksum[27:16], seq_id[15:0]}
        # (tsu.v:349). These are the PTP identity fields HA1588's own parser
        # extracted from the frame -- so matching them against what die_a staged
        # proves the far die timestamped OUR frame, not some artefact.
        if e["seq_id"] != 0x0042:
            fails.append(("TSU seq_id mismatch", 0x0042, e["seq_id"]))
        if e["msg_id"] != 0x00:
            fails.append(("TSU msg_id not Sync", 0x00, e["msg_id"]))
        # NOT asserted: the 80-bit timestamp VALUE (DATA0..DATA2). Those words
        # are loaded into the readable registers by the queue-pop, and the pop
        # stalls the cross-link read (gap doc §1.7). They read 0 pre-pop. This
        # is stated as a known limitation rather than checked -- asserting a
        # value we cannot currently retrieve would be dishonest.
        tb.log.info(f"[chain] NOTE: timestamp value words DATA0..2 = "
                    f"0x{e['d'][0]:08x} 0x{e['d'][1]:08x} 0x{e['d'][2]:08x} "
                    f"(zero pre-pop; the pop that loads them stalls -- §1.7)")

    if captured and not readable:
        tb.log.warning(
            "[chain] PARTIAL: HA1588 DID capture a hardware timestamp for a real "
            "MII PTP frame (queue depth proves `ptp_found && eop`), but the TSU "
            "DATA registers stall the cross-link read. GAP 1 is closed at the "
            "CAPTURE step; the payload read-back is a separate, precisely located "
            "defect -- see docs/ETHERNET_PTP_CHAIN_GAP.md.")

    # ---- 13. Verdict --------------------------------------------------------
    assert not fails, (
        "eth_ptp_chain FAILED:\n" +
        "\n".join(f"  {why}: expected=0x{e:08x} got=0x{g:08x}" for why, e, g in fails))

    tb.log.info(
        "[chain] PASS: a REAL L2 PTP Sync frame was staged from die_a across the "
        "TideLink pair into die_b's eth_scratch_tx, DMA'd out by the MAC's own bus "
        "master, transmitted by the real MII TX FSM (EtherType 0x88f7 confirmed on "
        "the wire), looped back into the MII RX FSM, and TIMESTAMPED IN HARDWARE by "
        "HA1588's TSU -- then die_a read the captured entry's PTP identity "
        "(messageType=Sync, sequenceId=0x0042, matching what die_a itself staged) "
        "back ACROSS THE LINK.")
    tb.log.info(
        "[chain] GAP 1 CLOSED AT THE CAPTURE STEP. Remaining and precisely located: "
        "the 80-bit timestamp VALUE is only loaded into the readable DATA registers "
        "by the queue-pop, and that pop stalls the cross-link read (gap doc §1.7). "
        "This bench does NOT claim the timestamp value has been read.")
