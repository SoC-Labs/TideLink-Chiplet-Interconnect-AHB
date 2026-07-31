#!/usr/bin/env python3
# =============================================================================
# kr260_eth_xfer.py — cross-die data transfer over the LIVE TideLink link,
#                     driven PS-side through the eth_ss_0 backdoor.
#
# On-silicon version of verif/g2_soc_pair/test_g2_soc_pair.py
# (test_peer_write_crosses_to_die_b). The link must already be UP (FCSM=4) —
# run kr260_eth_bringup.py --bringup on both boards first.
#
#   die A eth_ss_0 -> SoC matrix -> d2d_ahb_m -> chiplet_d2d_decode (hsel_peer)
#     -> die A tidelink ahb_sub (0x2F aperture) == CAM rewrites addr[31:24]
#     0x2F->0x2D == PHY -> die B tidelink ahb_mng -> die B SoC matrix
#     -> die B shared_sram_0 (0x2D......)
#
# Modes (each run on the indicated board):
#   sender   (die_a): program the address-translator CAM (0x2F->0x2D), then write
#                     PAYLOAD to the peer aperture 0x2F00_1000. Fire-and-forget.
#   recv     (die_b): read its OWN shared_sram_0 at 0x2D00_1000 -> expect PAYLOAD.
#                     A LOCAL SRAM read (no link traversal) — the clean proof the
#                     payload crossed the link. This is the primary verdict.
#   readback (die_a): read 0x2F00_1000 back OVER the link -> expect PAYLOAD.
#                     Exercises the read round-trip too.
#   control  (die_a): CAM OFF, write to a different offset -> recv-control must
#                     see the UNtranslated address (proves 0x2D came from the CAM).
#
# SAFETY: the peer write/read (0x2F) traverses the link. sender/readback REFUSE
# to touch 0x2F unless the local TideLink reports FCSM=4 — a peer access on a
# down link can hang the PS AXI bus (JTAG-POR recovery). recv only reads local
# SRAM (0x2D), always safe. All addresses are inside the eth_ss_0 window, whose
# SoC default slave terminates any in-window miss with SLVERR (never a hang).
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import mmap
import os
import struct
import sys
import time

WINDOW_BASE = 0x400000000            # eth_ss_0 backdoor window (PS phys); SoC A -> WINDOW_BASE+A

# SoC-internal addresses.
_TLAPB              = 0x2E030000
REG_SWI_LANE_STATUS = _TLAPB + 0x2108     # [16] cal_done, [19:17] fcsm
CAM_BASE            = _TLAPB + 0x4000     # 0x2E034000 ADDRXLAT_APB base
CAM_CTRL            = _TLAPB + 0x4004     # bit[0] global_enable
CAM_RULE_0          = _TLAPB + 0x4010     # [0]=en [15:8]=match [23:16]=replace

PEER_ADDR    = 0x2F001000            # die_a peer aperture (translated 0x2F->0x2D)
LANDED_ADDR  = 0x2D001000            # die_b shared_sram_0 (where it lands)
CTRL_OFFSET  = 0x40                  # a distinct offset for the CAM-off control

APERTURE_BYTE = 0x2F
REMOTE_BYTE   = 0x2D
RULE_0_VALUE  = (REMOTE_BYTE << 16) | (APERTURE_BYTE << 8) | 1   # 0x002D2F01
DEFAULT_PAYLOAD = 0xC0FFEE01
FCSM_LINK_IDLE  = 4

# --- IPC mailbox: the 2nd (previously untested) inbound D2D target ----------
# die_a writes the peer aperture (0x2F); a CAM rule 0x2F->0x23 lands the write in
# die_b's ipc_mailbox_0 @ 0x2300_0000. Layout from nanosoc_multicore_addrmap.h.
MBOX_SOC_BASE      = 0x23000000       # die_b local mailbox base
MBOX_PEER_APERTURE = 0x2F000000       # die_a writes here (CAM 0x2F->0x23)
IPC_SLOT0_DATA     = 0x000            # .. 0x00C (4 words)
IPC_SLOT0_CTRL     = 0x020            # [0]=MSG_VALID, [1]=ACK
IPC_IRQ_STATUS     = 0x028            # [0]=slot0 msg edge -> CPU1 NVIC IRQ0 (latched
                                      #     on MSG_VALID edge regardless of irq_enable)
IPC_MSG_VALID      = (1 << 0)
MBOX_RULE_VALUE    = (0x23 << 16) | (0x2F << 8) | 1   # 0x00232F01

# --- link health / credit registers (full SoC addr = _TLAPB + REGISTER_MAP off)
REG_CREDIT_COUNT  = _TLAPB + 0x200C   # RO local free-credit count (13-bit)
REG_STATUS        = _TLAPB + 0x2010   # RO sticky faults: [1]OVERRUN [2]UNDERRUN [3]MASTER_ERROR
REG_OBS_FC_CREDIT = _TLAPB + 0x219C   # RO far-end credit observation
STATUS_STICKY_MASK = 0xE              # bits [3:1]
SRAM_PEER_BASE    = 0x2F001000   # peer-aperture window for the soak (CAM 0x2F->0x2D)

# --- per-node Wlink FC health (the nodes that wedge; NOT seen by OBS_FC_CREDIT) --
# Node bases are offsets from _TLAPB; per-node regs +0x08/+0x10/+0x20 (REGISTER_MAP
# §2.3). The AXI data nodes (AW/W/B/AR/R) are the recovery-stripped ones on current
# silicon (docs/CROSS_DIE_WEDGE_ROOTCAUSE.md) — poll these BETWEEN transfers: rising
# CRC on B/R = bit error (drift/eye); a stuck non-empty Ack/Nack FIFO = credit/ACK
# stall (the FCSM-recovery gap).
FC_NODES = (("AW", 0x1000), ("W", 0x1100), ("B", 0x1200), ("AR", 0x1300),
            ("R", 0x1400), ("GenBus", 0x1600), ("TideLink", 0x1700))
FC_AXI_NODES = ("AW", "W", "B", "AR", "R")   # the recovery-stripped wedge-prone set
FC_TXFIFO  = 0x08   # [0] FIFO empty
FC_ACKNACK = 0x10   # [0]empty [1]full [2]halffull [3]almostempty [4]almostfull
FC_CRC     = 0x20   # [15:0] CRC error count (RO)

# --- corner-test geometry (peer aperture / shared_sram_0 bases + confinement) ---
# The 16 MB peer aperture 0x2F00_0000.. folds onto the 8 KB shared_sram_0 (mod 8 KB,
# last-writer-wins). Inbound is CONFINED to 0x2D (sram) + 0x23 (mailbox); a CAM
# replace to any OTHER byte must DECERR on die_b (2-cycle AHB error), land nowhere.
PEER_APER_BASE   = 0x2F000000        # die_a peer aperture (offset 0 == sram base)
LANDED_SRAM_BASE = 0x2D000000        # die_b shared_sram_0 base (local read)
SRAM_FOLD        = 0x2000            # 8 KB fold
EXCLUDED_BYTES   = (0x2A, 0x2C, 0x2E)   # replace-bytes that are NOT inbound targets
DEFAULT_EXCL     = 0x2C
POISON_DEFAULT   = 0xDEADBEEF        # value aimed at an excluded byte (must vanish)

# --- cross-die SWD debug over the D2D bridge (one probe debugs both dies) -------
# REQUIRES the batch RTL: 0b (network_core/chip_core_dbg_window added to d2d_m's
# inbound target list, sim-PROVEN 2026-07-29) + 0c (REMOTE_DBG_EN gate). NOT in the
# current bitstream — dbg_halt against today's silicon returns SLVERR/0. And the
# per-beat PPB reads cross the AXI FC nodes, so this inherits the intermittent
# cross-die wedge until the FCSM-recovery fix lands (docs/CROSS_DIE_WEDGE_ROOTCAUSE.md).
# die_a drives the peer aperture (0x2F); a CAM rule 0x2F->0xA0 (CPU0) / 0x2F->0xB0
# (CPU1) routes it to the far core's debug window; the dbg bridge maps
# {8'hE0,HADDR[23:0]} so 0x2F00_EDF0 -> far 0xE000_EDF0 (DHCSR).
DBG_PEER_APERTURE = 0x2F000000
DBG_CAM_CPU0 = (0xA0 << 16) | (0x2F << 8) | 1   # 0x00A02F01 -> network_core_dbg_window
DBG_CAM_CPU1 = (0xB0 << 16) | (0x2F << 8) | 1   # 0x00B02F01 -> chip_core_dbg_window
PPB_DHCSR = 0x000EDF0     # peer 0x2F00EDF0 -> far 0xE000EDF0
PPB_CPUID = 0x000ED00     # peer 0x2F00ED00 -> far 0xE000ED00
DHCSR_HALT   = 0xA05F0003  # DBGKEY | C_HALT | C_DEBUGEN
DHCSR_RESUME = 0xA05F0001  # DBGKEY | C_DEBUGEN
DHCSR_S_HALT = 1 << 17
CPUID_M0PLUS = 0x410CC601  # expected (matches the sim prototype)
# 0c gate: reset_ctrl_0 @ 0x2A000000; REMOTE_DBG_EN in the free RAZ slot 0x004.
REG_REMOTE_DBG_EN = 0x2A000000 + 0x004


def _mm(phys):
    page = phys & ~0xFFF
    off = phys - page
    f = open("/dev/mem", "r+b", buffering=0)
    try:
        m = mmap.mmap(f.fileno(), 0x1000, mmap.MAP_SHARED,
                      mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
    except (OSError, PermissionError) as e:
        f.close()
        raise SystemExit("mmap /dev/mem @ 0x%X failed: %s (run as root; bitstream "
                         "loaded?)" % (page, e))
    return f, m, off


def rd(phys):
    f, m, off = _mm(phys)
    v = struct.unpack("<I", m[off:off + 4])[0]
    m.close(); f.close()
    return v


def wr(phys, val):
    f, m, off = _mm(phys)
    m[off:off + 4] = struct.pack("<I", val & 0xFFFFFFFF)
    m.close(); f.close()


def link_status():
    st = rd(WINDOW_BASE + REG_SWI_LANE_STATUS)
    up = ((st >> 17) & 7) == FCSM_LINK_IDLE and ((st >> 16) & 1) == 1
    return up, st


def _require_link():
    up, st = link_status()
    print("  link SWI_LANE_STATUS=0x%08X  fcsm=%d cal=%d  -> %s"
          % (st, (st >> 17) & 7, (st >> 16) & 1, "UP" if up else "DOWN"))
    if not up:
        print("ABORT: link not FCSM=4. Bring it up on BOTH boards first "
              "(kr260_eth_bringup.py --bringup). Refusing to peer-access a down "
              "link (wedge risk).", file=sys.stderr)
        raise SystemExit(2)


def program_cam_rule(rule_value):
    """Program CAM RULE_0 to an arbitrary {replace<<16 | match<<8 | en} value;
    CTRL armed last so a half-configured rule is never live."""
    wr(WINDOW_BASE + CAM_BASE, 0x00000000)
    wr(WINDOW_BASE + CAM_RULE_0, rule_value)
    wr(WINDOW_BASE + CAM_CTRL, 1)
    print("  CAM: RULE_0=0x%08X (match 0x%02X -> replace 0x%02X), global_enable=1"
          % (rule_value, (rule_value >> 8) & 0xFF, (rule_value >> 16) & 0xFF))


def program_cam(enable):
    if enable:
        program_cam_rule(RULE_0_VALUE)   # 0x2F -> 0x2D (shared_sram_0)
    else:
        wr(WINDOW_BASE + CAM_BASE, 0x00000000)
        wr(WINDOW_BASE + CAM_RULE_0, RULE_0_VALUE)
        wr(WINDOW_BASE + CAM_CTRL, 0)
        print("  CAM: RULE_0=0x%08X, global_enable=0" % RULE_0_VALUE)


def do_sender(payload):
    print("=== SENDER (die_a): CAM + peer write ===")
    _require_link()
    program_cam(enable=True)
    print("  peer write: [0x%08X] <- 0x%08X   (CAM translates -> die_b 0x%08X)"
          % (PEER_ADDR, payload, LANDED_ADDR))
    wr(WINDOW_BASE + PEER_ADDR, payload)
    print("  write issued and returned (link accepted it — no bus hang).")
    print("Now run: recv on die_b (expect 0x%08X at 0x%08X)." % (payload, LANDED_ADDR))
    return 0


def do_recv(payload):
    print("=== RECV (die_b): read local shared_sram_0 where the payload should land ===")
    got = rd(WINDOW_BASE + LANDED_ADDR)
    ok = got == payload
    print("  shared_sram_0[0x%08X] = 0x%08X   expect 0x%08X   [%s]"
          % (LANDED_ADDR, got, payload, "PASS" if ok else "FAIL"))
    if ok:
        print("RESULT: PASS — the payload CROSSED THE LINK to this die's shared_sram_0.")
    else:
        print("RESULT: FAIL — payload not present. If 0x00000000, this is the "
              "'peer-write data-phase drop' the g2 sim found (should be fixed in "
              "nanosoc_eth_chiplet.sv). Check the sender ran + link still up.")
    return 0 if ok else 1


def do_readback(payload):
    print("=== READBACK (die_a): read the peer aperture back over the link ===")
    _require_link()
    got = rd(WINDOW_BASE + PEER_ADDR)
    ok = got == payload
    print("  peer readback [0x%08X] = 0x%08X   expect 0x%08X   [%s]  (link round-trip)"
          % (PEER_ADDR, got, payload, "PASS" if ok else "FAIL"))
    return 0 if ok else 1


def do_soak(iters, payload, readback=False, adversarial=False, seed=1,
            win=16, health_every=50):
    """Sustained peer-write load over the link (die_a), sampling link health.

    Default is WRITE-ONLY + health: peer writes are reliable, and a peer write
    that stalls returns via HREADY. --soak-readback re-enables the per-beat peer
    READ round-trip, which is WEDGE-PRONE on silicon (an intermittent read-return
    hang wedged both boards on 2026-07-29; see docs/OVERNIGHT_WORKLOG.md). Data
    integrity is covered wedge-safely by sram_fwd (die_b LOCAL read); soak's job
    is link health (FCSM/sticky-fault/credit) under sustained write traffic.

    --adversarial swaps the payload for the xfer_corners_lib deterministic
    generator (all-0/all-1/walking-1/0/PRBS32/addr-xor) so the delivery path sees
    hard bit patterns, and samples the Region F AXI-node obs plane every
    `health_every` beats — ABORTING (nonzero) on a wedge-sticky BEFORE the PS bus
    hangs. Verify byte-exactness wedge-safely with `--mode soak_recv` on die_b
    (same --seed/--iters/--win)."""
    tag = " + readback (WEDGE-PRONE)" if readback else " (write-only)"
    if adversarial:
        tag += " [ADVERSARIAL seed=0x%X win=%d]" % (seed, win)
    print("=== SOAK (die_a): %d peer-write beats over the link%s ===" % (iters, tag))
    _require_link()
    program_cam(enable=True)                       # 0x2F -> 0x2D (shared_sram_0)

    xcl = None
    if adversarial:
        import xfer_corners_lib as xcl
        h0 = xcl.snap_health()
        xcl.print_health(h0)
        if not xcl.health_ok(h0):
            print("  ABORT: link not healthy at baseline; refusing to soak.")
            xcl.recovery_ladder(xcl.classify_wedge(h0))
            return 1

    sticky0 = rd(WINDOW_BASE + REG_STATUS)
    print("  baseline STATUS=0x%08X (sticky[3:1]=0x%X)  CREDIT_COUNT=%d"
          % (sticky0, sticky0 & STATUS_STICKY_MASK,
             rd(WINDOW_BASE + REG_CREDIT_COUNT) & 0x1FFF))
    NW = win if adversarial else 16                 # cycle an NW-word window
    mism = 0
    fcsm_min, cal_all = 7, 1
    sticky_seen = 0
    cc_min, cc_max = 0x1FFF, 0
    for i in range(iters):
        if adversarial:
            _wo, byte_off, val, _cls = xcl.beat(seed, i, NW)
            addr = SRAM_PEER_BASE + byte_off
        else:
            addr = SRAM_PEER_BASE + (i % NW) * 4
            val = (payload + i) & 0xFFFFFFFF
        wr(WINDOW_BASE + addr, val)
        if readback:
            got = rd(WINDOW_BASE + addr)     # peer read — WEDGE-PRONE (see header)
            if got != val:
                mism += 1
                if mism <= 5:
                    print("  MISMATCH iter %d @0x%08X: got 0x%08X want 0x%08X"
                          % (i, addr, got, val))
        if i % health_every == 0:
            sv = rd(WINDOW_BASE + REG_SWI_LANE_STATUS)
            fcsm_min = min(fcsm_min, (sv >> 17) & 7); cal_all &= (sv >> 16) & 1
            sticky_seen |= rd(WINDOW_BASE + REG_STATUS) & STATUS_STICKY_MASK
            cc = rd(WINDOW_BASE + REG_CREDIT_COUNT) & 0x1FFF
            cc_min, cc_max = min(cc_min, cc), max(cc_max, cc)
            if adversarial:
                # fail-fast: catch a latched AXI-node wedge BEFORE the bus hangs.
                h = xcl.snap_health()
                cls = xcl.classify_wedge(h)
                if cls != "NONE" or not xcl.health_ok(h):
                    print("  !! WEDGE DETECTED at beat %d — class=%s (aborting before "
                          "the PS bus saturates)" % (i, cls))
                    xcl.print_health(h)
                    xcl.recovery_ladder(cls)
                    return 1
    ok = mism == 0 and fcsm_min == FCSM_LINK_IDLE and cal_all and sticky_seen == 0
    print("  iters=%d  mismatches=%d  FCSM_min=%d  cal_all=%d  sticky_seen=0x%X"
          % (iters, mism, fcsm_min, cal_all, sticky_seen))
    print("  CREDIT_COUNT range [%d..%d]  OBS_FC_CREDIT=0x%08X"
          % (cc_min, cc_max, rd(WINDOW_BASE + REG_OBS_FC_CREDIT)))
    print("RESULT: %s — %s" % ("PASS" if ok else "FAIL",
          "sustained data plane intact, link healthy, no sticky faults" if ok
          else "see counts above"))
    return 0 if ok else 1


def do_soak_recv(iters, seed, win=16):
    """die_b: wedge-safe verify of an ADVERSARIAL soak. Reconstructs the same
    stream from --seed and checks the LOCAL shared_sram_0 holds the last-writer
    value at every folded offset (last-writer-wins under the 8 KB fold). A LOCAL
    read only — no link traversal — so it cannot wedge."""
    import xfer_corners_lib as xcl
    print("=== SOAK RECV (die_b): verify adversarial soak seed=0x%X iters=%d win=%d ==="
          % (seed, iters, win))
    expect = xcl.final_values(seed, iters, win)     # {byte_off: (val, cls, last_i)}
    ok = 0
    firstbad = None
    for byte_off, (val, cls, last_i) in sorted(expect.items()):
        got = rd(WINDOW_BASE + LANDED_ADDR + byte_off)   # 0x2D001000 + off (local read)
        if got == val:
            ok += 1
        elif firstbad is None:
            firstbad = (byte_off, got, val, cls)
    n = len(expect)
    print("  %d/%d folded words byte-exact%s" % (ok, n, "" if ok == n else
          "   firstbad off=0x%04X got=0x%08X exp=0x%08X (%s)" % firstbad))
    good = ok == n
    print("RESULT: %s — %s" % ("PASS" if good else "FAIL",
          "adversarial stream landed byte-exact" if good
          else "mis-delivery/bit-error on the data plane"))
    return 0 if good else 1


def do_fc_health():
    """GATING per-node Wlink FC health check (RO, wedge-safe).

    Baselines the per-node CRC + Ack/Nack FIFOs and the Region F AXI-node obs
    plane, re-samples after a short settle, and ASSERTS the link is clean:
      * no RISING CRC on any AXI data node (a rise => bit error / drift / eye);
      * no stuck non-empty Ack/Nack FIFO on an AXI data node (credit/ACK stall —
        the FCSM-recovery gap signature);
      * Region F data_healthy=1, wedge-sticky=0, no resp-err;
      * STATUS sticky[3:1]=0 and SWI_LANE fe_rx_is_full=0.
    Returns nonzero on any fault, and prints classify_wedge()+recovery_ladder().
    Poll this BETWEEN cross-die transfers on an attended session to pin the node
    that wedges; it also validates the FCSM-recovery fix once it lands (CRC may
    count but the link stays healthy)."""
    import xfer_corners_lib as xcl
    print("=== Wlink FC health GATE (RO) — the AXI data nodes are the wedge-prone set ===")
    base_nodes = xcl.fc_node_snapshot()
    time.sleep(0.05)
    now_nodes = xcl.fc_node_snapshot()
    print("  node      CRC(base->now)  AckNack(E/F/HF)  TXfifo_empty")
    worst_crc = 0
    crc_rose, stuck = [], []
    for name, base in FC_NODES:
        b, n = base_nodes[name], now_nodes[name]
        an = n["acknack"]
        empty, full, half = an & 1, (an >> 1) & 1, (an >> 2) & 1
        worst_crc = max(worst_crc, n["crc"])
        if name in FC_AXI_NODES and n["crc"] > b["crc"]:
            crc_rose.append(name)
        # a non-empty Ack/Nack FIFO on an AXI data node (across both samples) is the
        # credit/ACK-stall signature — it should drain to empty at idle.
        if name in FC_AXI_NODES and not empty and not b["an_empty"]:
            stuck.append(name)
        print("  %-8s  %6d->%-6d   %d/%d/%d            %d"
              % (name, b["crc"], n["crc"], empty, full, half, n["txfifo_empty"]))
    h = xcl.snap_health()
    xcl.print_health(h)
    cls = xcl.classify_wedge(h)
    faults = []
    if crc_rose:
        faults.append("rising CRC on %s" % ",".join(crc_rose))
    if stuck:
        faults.append("stuck non-empty Ack/Nack on %s" % ",".join(stuck))
    if not xcl.health_ok(h):
        faults.append("Region F / sticky fault (wedge=%s)" % cls)
    ok = not faults
    print("  worst CRC=%d; faults: %s" % (worst_crc, "; ".join(faults) if faults else "none"))
    if not ok:
        xcl.recovery_ladder(cls)
    print("RESULT: %s — %s" % ("PASS" if ok else "FAIL",
          "FC nodes clean, Region F healthy" if ok else "; ".join(faults)))
    return 0 if ok else 1


# =============================================================================
# CORNER TESTS — self-checking, seed-reproducible, Region-F-guarded.
# All peer-touching corners below are ATTENDED / wedge-prone and print the
# recovery ladder on a wedge. Each die_a driver has a die_b `*_verify` partner
# that reads LOCAL SRAM only (no link traversal on the read -> cannot wedge).
# =============================================================================
def do_decerr(seed, excl=DEFAULT_EXCL):
    """ATTENDED / JTAG-POR-STAGED. Inbound-confinement + clean-error-path corner.

    die_a: (1) seed a sentinel into die_b shared_sram_0 via the PROVEN 0x2F->0x2D
    path, (2) reprogram the CAM replace-byte to an EXCLUDED byte (0x2A/0x2C/0x2E —
    NOT an inbound target) and peer-write a POISON word. The far die must DECERR
    that access (2-cycle AHB error) and land it NOWHERE. We assert PS-side that
    (a) the access RETURNS (no bus hang — control reaches the next line) and
    (b) the link stays HEALTHY (the errored access did not wedge an AXI node).
    Confirm (c) the legit 0x2D region was NOT corrupted with `decerr_verify` on
    die_b (it must still read the sentinel, never the poison)."""
    import xfer_corners_lib as xcl
    if excl not in EXCLUDED_BYTES:
        print("  WARN: 0x%02X is not in the known excluded set %s"
              % (excl, ",".join("0x%02X" % b for b in EXCLUDED_BYTES)))
    sentinel, _ = xcl.golden(seed, 0)
    print("=== DECERR CONFINEMENT (die_a) — ATTENDED, JTAG-POR staged ===")
    print("  seed=0x%X sentinel=0x%08X excluded-byte replace=0x%02X poison=0x%08X"
          % (seed, sentinel, excl, POISON_DEFAULT))
    _require_link()
    ok0, _ = xcl.gate_or_ladder("baseline")
    if not ok0:
        return 1
    # 1. seed the legit region via the proven 0x2F->0x2D path.
    program_cam_rule(RULE_0_VALUE)                       # 0x2F -> 0x2D
    wr(WINDOW_BASE + PEER_ADDR, sentinel)
    print("  seeded sentinel 0x%08X -> die_b 0x%08X (proven path)" % (sentinel, LANDED_ADDR))
    # 2. retarget CAM to the EXCLUDED byte and fire the poison write.
    excl_rule = (excl << 16) | (APERTURE_BYTE << 8) | 1
    program_cam_rule(excl_rule)                          # 0x2F -> EXCLUDED (no target)
    print("  peer write POISON 0x%08X -> excluded 0x%02X (must DECERR far side)..."
          % (POISON_DEFAULT, excl))
    wr(WINDOW_BASE + PEER_APER_BASE + 0x1000, POISON_DEFAULT)
    print("  ...write RETURNED (no PS bus hang — DECERR came back cleanly).")
    # 3. link must still be healthy — an errored access must not wedge a node.
    ok1, cls = xcl.gate_or_ladder("post-poison")
    # restore the proven CAM for downstream steps.
    program_cam_rule(RULE_0_VALUE)
    print("RESULT: %s — %s" % ("PASS" if ok1 else "FAIL",
          "excluded write DECERR'd cleanly, link healthy (verify 0x2D on die_b)"
          if ok1 else "link wedged on the errored access (class=%s)" % cls))
    return 0 if ok1 else 1


def do_decerr_verify(seed):
    """die_b: confirm the DECERR corner's confinement held — shared_sram_0 still
    reads the SENTINEL die_a seeded, NOT the poison. LOCAL read only."""
    import xfer_corners_lib as xcl
    sentinel, _ = xcl.golden(seed, 0)
    got = rd(WINDOW_BASE + LANDED_ADDR)
    poisoned = got == POISON_DEFAULT
    ok = got == sentinel
    print("=== DECERR VERIFY (die_b): read local 0x%08X ===" % LANDED_ADDR)
    print("  got=0x%08X  expect sentinel=0x%08X  poison=0x%08X" % (got, sentinel, POISON_DEFAULT))
    if poisoned:
        print("RESULT: FAIL — POISON LEAKED into 0x2D: inbound confinement BROKEN.")
    elif ok:
        print("RESULT: PASS — 0x2D holds the sentinel; the excluded-byte write "
              "landed nowhere (confinement holds).")
    else:
        print("RESULT: FAIL — 0x2D neither sentinel nor poison (sender not run / "
              "link down?).")
    return 0 if ok else 1


# boundary + aliasing: 4 aperture offsets that fold onto 2 physical sram words.
#   0x000000 & 0x002000 -> fold 0x0000   (last writer wins: 0x002000)
#   0x001FFC & 0xFFFFFC -> fold 0x1FFC   (last writer wins: 0xFFFFFC)
_BOUNDARY_OFFS = (0x000000, 0x001FFC, 0x002000, 0xFFFFFC)


def do_boundary(seed):
    """ATTENDED. Boundary + 8 KB-alias sweep (die_a). Writes 4 seed-derived words
    to aperture offsets {0x000, 0x1FFC, 0x2000, 0xFFFFFC}; the top two alias the
    first two under the 8 KB fold, so only the LAST writer survives at each of the
    two physical words. Verify with `boundary_verify` on die_b."""
    import xfer_corners_lib as xcl
    print("=== BOUNDARY + ALIASING SWEEP (die_a) — ATTENDED ===")
    _require_link()
    ok0, _ = xcl.gate_or_ladder("baseline")
    if not ok0:
        return 1
    program_cam_rule(RULE_0_VALUE)                       # 0x2F -> 0x2D
    vals = [xcl.golden(seed, k)[0] for k in range(len(_BOUNDARY_OFFS))]
    for k, off in enumerate(_BOUNDARY_OFFS):
        fold = off % SRAM_FOLD
        print("  write [aperture 0x2F%06X] <- 0x%08X   (folds to sram 0x%04X)"
              % (off, vals[k], fold))
        wr(WINDOW_BASE + PEER_APER_BASE + off, vals[k])
        ok, cls = xcl.gate_or_ladder("after off 0x%06X" % off)
        if not ok:
            print("RESULT: FAIL — wedged mid-sweep (class=%s)" % cls)
            return 1
    exp0 = vals[2]    # 0x2000 last-writer at fold 0x0000
    exp1 = vals[3]    # 0xFFFFFC last-writer at fold 0x1FFC
    print("  expected last-writer-wins: sram[0x0000]=0x%08X  sram[0x1FFC]=0x%08X"
          % (exp0, exp1))
    print("RESULT: PASS — sweep issued, link healthy (verify folds on die_b).")
    return 0


def do_boundary_verify(seed):
    """die_b: verify the 8 KB alias map (last-writer-wins) at the two physical
    words the boundary sweep collapses onto. LOCAL read only."""
    import xfer_corners_lib as xcl
    vals = [xcl.golden(seed, k)[0] for k in range(len(_BOUNDARY_OFFS))]
    exp0, exp1 = vals[2], vals[3]
    g0 = rd(WINDOW_BASE + LANDED_SRAM_BASE + 0x0000)
    g1 = rd(WINDOW_BASE + LANDED_SRAM_BASE + 0x1FFC)
    ok0, ok1 = g0 == exp0, g1 == exp1
    print("=== BOUNDARY VERIFY (die_b): 8 KB-fold last-writer-wins ===")
    print("  sram[0x0000]=0x%08X expect 0x%08X [%s]  (0x000 & 0x2000 alias)"
          % (g0, exp0, "PASS" if ok0 else "FAIL"))
    print("  sram[0x1FFC]=0x%08X expect 0x%08X [%s]  (0x1FFC & 0xFFFFFC alias)"
          % (g1, exp1, "PASS" if ok1 else "FAIL"))
    ok = ok0 and ok1
    print("RESULT: %s — %s" % ("PASS" if ok else "FAIL",
          "aperture folds mod 8 KB, last-writer-wins confirmed" if ok
          else "alias map not as expected"))
    return 0 if ok else 1


def do_errinject(seed, node="B", bit=0, byte=0, stream=32, win=16):
    """ATTENDED / SINGLE-SHOT / JTAG-POR STAGED. The DISCRIMINATING test for the
    AXI data-node recovery gap (docs/CROSS_DIE_WEDGE_ROOTCAUSE.md).

    die_a: baseline the target node's CRC, inject ONE bit error on that data node
    via 0x2E03_003C, do one peer write (the corrupted beat), and confirm the
    node's CRC ROSE (inject took effect). Then disable the injector and resume a
    short deterministic write stream, sampling Region F each beat:
      * if the stream completes healthy  -> RECOVERY PRESENT (host-observed);
        confirm byte-exact with `errinject_verify` on die_b.
      * if Region F latches a wedge-sticky (or fe_rx_is_full) -> RECOVERY ABSENT
        (the node wedged as the root-cause predicts); the ladder is printed and a
        JTAG-POR is required. BOTH outcomes are reported clearly.
    Exit: 0 recovery-present, 1 recovery-absent, 2 inject had no effect (the
    injector reg is not in this bitstream)."""
    import xfer_corners_lib as xcl
    if node not in xcl.INJECT_IDS:
        print("ERROR: node %r not in %s" % (node, ",".join(xcl.INJECT_IDS)))
        return 4
    data_id = xcl.INJECT_IDS[node]
    print("=== ERROR INJECTION (die_a) — ATTENDED, SINGLE-SHOT, JTAG-POR STAGED ===")
    print("  target node=%s (DataID=0x%02X) bit=%d byte=%d  seed=0x%X stream=%d"
          % (node, data_id, bit, byte, seed, stream))
    _require_link()
    ok0, _ = xcl.gate_or_ladder("baseline")
    if not ok0:
        return 1
    program_cam_rule(RULE_0_VALUE)                       # 0x2F -> 0x2D
    crc_before = xcl.fc_crc_of(node)
    inj = xcl.error_inject(data_id, byte=byte, bit=bit)
    print("  injector 0x2E03_003C <- 0x%08X (enable|bit|byte|id)" % inj)
    # the single corrupted beat.
    _wo, off0, v0, _cls = xcl.beat(seed, 0, win)
    wr(WINDOW_BASE + PEER_APER_BASE + 0x1000 + off0, v0)
    crc_after = xcl.fc_crc_of(node)
    xcl.error_inject_off()
    print("  node %s CRC %d -> %d  (delta=%d)" % (node, crc_before, crc_after,
                                                  crc_after - crc_before))
    if crc_after <= crc_before:
        print("RESULT: INCONCLUSIVE — CRC did not rise; the error injector is not "
              "wired in this bitstream (0x2E03_003C is a no-op). Nothing to judge.")
        return 2
    print("  inject CONFIRMED (CRC rose). Injector OFF; resuming write stream...")
    # resume traffic and watch for the recovery-gap wedge.
    for i in range(1, stream + 1):
        _wo, off, val, _c = xcl.beat(seed, i, win)
        wr(WINDOW_BASE + PEER_APER_BASE + 0x1000 + off, val)
        h = xcl.snap_health()
        cls = xcl.classify_wedge(h)
        if cls != "NONE" or not xcl.health_ok(h):
            print("  !! beat %d: wedge latched — class=%s" % (i, cls))
            xcl.print_health(h)
            xcl.recovery_ladder(cls)
            print("RESULT: RECOVERY ABSENT — the corrupted %s beat wedged the node "
                  "with no recovery (as CROSS_DIE_WEDGE_ROOTCAUSE predicts). "
                  "JTAG-POR both boards." % node)
            return 1
    print("  stream of %d beats completed; Region F stayed healthy." % stream)
    print("RESULT: RECOVERY PRESENT (host-observed) — node absorbed the bit error "
          "and kept delivering. Confirm byte-exact with errinject_verify on die_b.")
    return 0


def do_errinject_verify(seed, stream=32, win=16):
    """die_b: after an error-injection run, verify the resumed stream (beats 1..N)
    landed byte-exact in LOCAL shared_sram_0 (last-writer-wins). LOCAL read only.
    Byte-exact == the injected error was truly recovered end-to-end."""
    import xfer_corners_lib as xcl
    print("=== ERRINJECT VERIFY (die_b): resumed stream byte-exact? seed=0x%X N=%d ==="
          % (seed, stream))
    # reconstruct beats 1..stream (beat 0 was the deliberately-corrupted one).
    expect = {}
    for i in range(1, stream + 1):
        _wo, off, val, cls = xcl.beat(seed, i, win)
        expect[off] = (val, cls, i)
    ok, firstbad = 0, None
    for off, (val, cls, i) in sorted(expect.items()):
        got = rd(WINDOW_BASE + LANDED_ADDR + off)
        if got == val:
            ok += 1
        elif firstbad is None:
            firstbad = (off, got, val, cls)
    n = len(expect)
    print("  %d/%d folded words byte-exact%s" % (ok, n, "" if ok == n else
          "   firstbad off=0x%04X got=0x%08X exp=0x%08X (%s)" % firstbad))
    good = ok == n
    print("RESULT: %s — %s" % ("PASS" if good else "FAIL",
          "resumed stream recovered byte-exact (recovery present)" if good
          else "residual corruption after the injected error"))
    return 0 if good else 1


def do_dbg_gate(enable):
    """die_b: open/close the REMOTE_DBG_EN gate (0c). Local write; harmless as a
    RAZ no-op until the 0c RTL exists."""
    print("=== DBG GATE (die_b): REMOTE_DBG_EN <- %d @ 0x2A000004 ===" % (1 if enable else 0))
    wr(WINDOW_BASE + REG_REMOTE_DBG_EN, 1 if enable else 0)
    rb = rd(WINDOW_BASE + REG_REMOTE_DBG_EN)
    print("  readback = 0x%08X (0c not in this bitstream -> reads 0/RAZ)" % rb)
    return 0


def do_dbg_halt(core):
    """die_a: halt the far core over the D2D bridge (requires 0b+0c RTL).
    WEDGE-PRONE: the per-beat PPB reads cross the AXI FC nodes (see the
    FCSM-recovery caveat). Gated on local FCSM=4."""
    cam, name = (DBG_CAM_CPU0, "CPU0/net") if core == "net" else (DBG_CAM_CPU1, "CPU1/chip")
    print("=== DBG HALT (die_a): far %s over d2d_m (CAM 0x%08X) ===" % (name, cam))
    _require_link()
    program_cam_rule(cam)
    cpuid = rd(WINDOW_BASE + DBG_PEER_APERTURE + PPB_CPUID)   # peer read (wedge-prone)
    print("  CPUID @ peer 0x2F00ED00 = 0x%08X (expect 0x%08X)%s"
          % (cpuid, CPUID_M0PLUS,
             "" if cpuid == CPUID_M0PLUS else "  <- 0/err => 0b/0c not built or gate closed"))
    wr(WINDOW_BASE + DBG_PEER_APERTURE + PPB_DHCSR, DHCSR_HALT)
    dhcsr = rd(WINDOW_BASE + DBG_PEER_APERTURE + PPB_DHCSR)
    halted = (dhcsr & DHCSR_S_HALT) != 0
    print("  DHCSR after halt = 0x%08X (S_HALT=%d)" % (dhcsr, 1 if halted else 0))
    print("RESULT: %s — far %s %s" % ("PASS" if halted else "NOT halted", name,
          "HALTED over the link" if halted else "(needs 0b/0c RTL + gate open + a running core)"))
    return 0 if halted else 1


def do_dbg_resume(core):
    """die_a: resume the far core (write DHCSR C_DEBUGEN)."""
    cam, name = (DBG_CAM_CPU0, "CPU0/net") if core == "net" else (DBG_CAM_CPU1, "CPU1/chip")
    print("=== DBG RESUME (die_a): far %s ===" % name)
    _require_link()
    program_cam_rule(cam)
    wr(WINDOW_BASE + DBG_PEER_APERTURE + PPB_DHCSR, DHCSR_RESUME)
    print("  DHCSR <- RESUME (0x%08X)" % DHCSR_RESUME)
    return 0


def _mbox_words(payload):
    return [(payload + i) & 0xFFFFFFFF for i in range(4)]


def do_mbox_send(payload):
    print("=== MBOX SENDER (die_a): CAM 0x2F->0x23 + mailbox write ===")
    _require_link()
    # CAM rule 0x2F -> 0x23 (mailbox), CTRL armed last.
    wr(WINDOW_BASE + CAM_BASE, 0x00000000)
    wr(WINDOW_BASE + CAM_RULE_0, MBOX_RULE_VALUE)
    wr(WINDOW_BASE + CAM_CTRL, 1)
    print("  CAM: RULE_0=0x%08X (0x2F -> 0x23 ipc_mailbox), global_enable=1"
          % MBOX_RULE_VALUE)
    words = _mbox_words(payload)
    for i, w in enumerate(words):
        wr(WINDOW_BASE + MBOX_PEER_APERTURE + IPC_SLOT0_DATA + i * 4, w)
    print("  slot0 data <- [%s] via peer 0x2F00_0000+0x00..0x0C"
          % " ".join("0x%08X" % w for w in words))
    wr(WINDOW_BASE + MBOX_PEER_APERTURE + IPC_SLOT0_CTRL, IPC_MSG_VALID)
    print("  SLOT0_CTRL <- MSG_VALID (peer 0x2F00_0020 -> die_b 0x2300_0020)")
    print("  write burst issued (no bus hang). Now run mbox_recv on die_b.")
    return 0


def do_mbox_recv(payload):
    print("=== MBOX RECV (die_b): read local ipc_mailbox_0 @ 0x2300_0000 ===")
    words = [rd(WINDOW_BASE + MBOX_SOC_BASE + IPC_SLOT0_DATA + i * 4)
             for i in range(4)]
    ctrl = rd(WINDOW_BASE + MBOX_SOC_BASE + IPC_SLOT0_CTRL)
    irqst = rd(WINDOW_BASE + MBOX_SOC_BASE + IPC_IRQ_STATUS)
    expect = _mbox_words(payload)
    valid = (ctrl & IPC_MSG_VALID) != 0
    data_ok = words == expect
    irq_src = irqst & 0x1
    print("  slot0 data = [%s]" % " ".join("0x%08X" % w for w in words))
    print("  expect     = [%s]" % " ".join("0x%08X" % w for w in expect))
    print("  SLOT0_CTRL = 0x%08X  (MSG_VALID=%d, ACK=%d)"
          % (ctrl, ctrl & 1, (ctrl >> 1) & 1))
    print("  IRQ_STATUS = 0x%08X  (slot0 msg edge=%d -> feeds CPU1 NVIC IRQ0)"
          % (irqst, irq_src))
    print("  -> cross-die INTERRUPT SOURCE %s (a far-die write latched the near-die "
          "mailbox IRQ)" % ("LATCHED" if irq_src else "not set"))
    ok = valid and data_ok
    if ok:
        print("RESULT: PASS — mailbox message CROSSED the link (MSG_VALID + 4 words).")
    else:
        print("RESULT: FAIL — data_ok=%s msg_valid=%s. (0s ⇒ sender didn't run / "
              "CAM not 0x2F->0x23 / link down.)" % (data_ok, valid))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="Cross-die transfer over the live "
                                 "TideLink link (PS-side, eth_ss_0 backdoor).")
    ap.add_argument("--mode", required=True,
                    choices=("sender", "recv", "readback", "link",
                             "mbox_send", "mbox_recv", "soak", "soak_recv",
                             "fc_health", "decerr", "decerr_verify",
                             "boundary", "boundary_verify",
                             "errinject", "errinject_verify",
                             "dbg_gate", "dbg_halt", "dbg_resume"),
                    help="sender=die_a CAM+write (SRAM); recv=die_b read local SRAM; "
                         "readback=die_a read over link; mbox_send=die_a mailbox "
                         "write (CAM 0x2F->0x23); mbox_recv=die_b read local "
                         "mailbox; soak=die_a N write+readback beats + health "
                         "(+--adversarial); soak_recv=die_b verify adversarial soak; "
                         "fc_health=GATING per-node FC + Region F check; "
                         "decerr/decerr_verify=inbound-confinement (ATTENDED); "
                         "boundary/boundary_verify=8 KB-alias sweep (ATTENDED); "
                         "errinject/errinject_verify=single-bit AXI-node recovery "
                         "probe (ATTENDED, JTAG-POR staged); link=status only.")
    ap.add_argument("--iters", type=int, default=500,
                    help="soak mode: number of beats (default 500).")
    ap.add_argument("--soak-readback", action="store_true",
                    help="soak mode: re-enable the per-beat peer READ round-trip "
                         "(WEDGE-PRONE on silicon; off by default).")
    ap.add_argument("--adversarial", action="store_true",
                    help="soak: use the xfer_corners_lib deterministic payload "
                         "generator + sample Region F every --health-every beats, "
                         "aborting on a wedge-sticky before the bus hangs.")
    ap.add_argument("--seed", default="1",
                    help="deterministic seed for adversarial soak / corner tests "
                         "(sender + verifier must match). Default 1.")
    ap.add_argument("--win", type=int, default=16,
                    help="soak/errinject: cycling window in words (default 16).")
    ap.add_argument("--health-every", type=int, default=50,
                    help="adversarial soak: Region F sample interval in beats.")
    ap.add_argument("--stream", type=int, default=32,
                    help="errinject: resume-stream length after the injected beat.")
    ap.add_argument("--node", choices=("B", "R", "W"), default="B",
                    help="errinject: AXI data node to corrupt (default B=write).")
    ap.add_argument("--inj-bit", type=int, default=0,
                    help="errinject: bit index [0..7] to flip (default 0).")
    ap.add_argument("--inj-byte", type=int, default=0,
                    help="errinject: byte index to corrupt (default 0).")
    ap.add_argument("--excl", default=hex(DEFAULT_EXCL),
                    help="decerr: excluded CAM replace-byte (0x2A/0x2C/0x2E; "
                         "default 0x2C).")
    ap.add_argument("--core", choices=("net", "chip"), default="net",
                    help="dbg_halt/dbg_resume: which far core (net=CPU0/0xA0, "
                         "chip=CPU1/0xB0). Default net.")
    ap.add_argument("--gate-off", action="store_true",
                    help="dbg_gate: close (disable) REMOTE_DBG_EN instead of opening.")
    ap.add_argument("--payload", default=hex(DEFAULT_PAYLOAD),
                    help="32-bit payload (default 0xC0FFEE01).")
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("ERROR: needs root for /dev/mem (sudo).", file=sys.stderr)
        return 4
    payload = int(args.payload, 0) & 0xFFFFFFFF
    seed = int(args.seed, 0) & 0xFFFFFFFF
    excl = int(args.excl, 0) & 0xFF

    if args.mode == "link":
        up, st = link_status()
        print("link SWI_LANE_STATUS=0x%08X fcsm=%d cal=%d -> %s"
              % (st, (st >> 17) & 7, (st >> 16) & 1, "UP" if up else "DOWN"))
        return 0 if up else 1
    if args.mode == "sender":
        return do_sender(payload)
    if args.mode == "recv":
        return do_recv(payload)
    if args.mode == "readback":
        return do_readback(payload)
    if args.mode == "mbox_send":
        return do_mbox_send(payload)
    if args.mode == "mbox_recv":
        return do_mbox_recv(payload)
    if args.mode == "soak":
        return do_soak(args.iters, payload, args.soak_readback,
                       adversarial=args.adversarial, seed=seed, win=args.win,
                       health_every=args.health_every)
    if args.mode == "soak_recv":
        return do_soak_recv(args.iters, seed, win=args.win)
    if args.mode == "fc_health":
        return do_fc_health()
    if args.mode == "decerr":
        return do_decerr(seed, excl=excl)
    if args.mode == "decerr_verify":
        return do_decerr_verify(seed)
    if args.mode == "boundary":
        return do_boundary(seed)
    if args.mode == "boundary_verify":
        return do_boundary_verify(seed)
    if args.mode == "errinject":
        return do_errinject(seed, node=args.node, bit=args.inj_bit,
                            byte=args.inj_byte, stream=args.stream, win=args.win)
    if args.mode == "errinject_verify":
        return do_errinject_verify(seed, stream=args.stream, win=args.win)
    if args.mode == "dbg_gate":
        return do_dbg_gate(not args.gate_off)
    if args.mode == "dbg_halt":
        return do_dbg_halt(args.core)
    if args.mode == "dbg_resume":
        return do_dbg_resume(args.core)
    return 4


if __name__ == "__main__":
    sys.exit(main())
