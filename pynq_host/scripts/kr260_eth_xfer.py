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
IPC_MSG_VALID      = (1 << 0)
MBOX_RULE_VALUE    = (0x23 << 16) | (0x2F << 8) | 1   # 0x00232F01


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


def program_cam(enable):
    # CTRL armed last so a half-configured rule is never live.
    wr(WINDOW_BASE + CAM_BASE, 0x00000000)
    wr(WINDOW_BASE + CAM_RULE_0, RULE_0_VALUE)
    wr(WINDOW_BASE + CAM_CTRL, 1 if enable else 0)
    print("  CAM: RULE_0=0x%08X (match 0x%02X -> replace 0x%02X), global_enable=%d"
          % (RULE_0_VALUE, APERTURE_BYTE, REMOTE_BYTE, 1 if enable else 0))


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
        print("RESULT: PASS — the payload CROSSED THE LINK from die_a to die_b.")
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
    expect = _mbox_words(payload)
    valid = (ctrl & IPC_MSG_VALID) != 0
    data_ok = words == expect
    print("  slot0 data = [%s]" % " ".join("0x%08X" % w for w in words))
    print("  expect     = [%s]" % " ".join("0x%08X" % w for w in expect))
    print("  SLOT0_CTRL = 0x%08X  (MSG_VALID=%d, ACK=%d)"
          % (ctrl, ctrl & 1, (ctrl >> 1) & 1))
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
                             "mbox_send", "mbox_recv"),
                    help="sender=die_a CAM+write (SRAM); recv=die_b read local SRAM; "
                         "readback=die_a read over link; mbox_send=die_a mailbox "
                         "write (CAM 0x2F->0x23); mbox_recv=die_b read local "
                         "mailbox; link=status only.")
    ap.add_argument("--payload", default=hex(DEFAULT_PAYLOAD),
                    help="32-bit payload (default 0xC0FFEE01).")
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("ERROR: needs root for /dev/mem (sudo).", file=sys.stderr)
        return 4
    payload = int(args.payload, 0) & 0xFFFFFFFF

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
    return 4


if __name__ == "__main__":
    sys.exit(main())
