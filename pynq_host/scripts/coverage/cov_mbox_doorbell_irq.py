#!/usr/bin/env python3
# =============================================================================
# cov_mbox_doorbell_irq.py — BOARD-SIDE tool: cross-die IPC mailbox doorbell as
#     the FIRST real interrupt-SOURCE proof on silicon (coverage backlog #1 + #8
#     source half). Runs ON a KR260 die via the eth_ss_0 backdoor (/dev/mem @
#     PS phys 0x4_0000_0000 + SoC_addr). Pair it with the host orchestrator
#     cov_mbox_irq_source.py (arms both dies, times out every access).
#
# WHY THIS EXISTS (the gap it closes):
#   The existing kr260_eth_xfer.py `mbox_recv` PASSES on data + MSG_VALID and only
#   *reports* IRQ_STATUS[0] as a diagnostic. Per the V-plan, NO interrupt has ever
#   been observed asserting on hardware — every current HW "IRQ" check is a data
#   proxy. This tool makes the IRQ SOURCE BIT a PASS REQUIREMENT: recv fails unless
#   ipc_mailbox_0.IRQ_STATUS[0] latched from the far-die MSG_VALID edge. That is the
#   first "an interrupt source actually latched on silicon" verdict (not a proxy).
#   It also proves the R/W1C clear path (the ISR's ack in test #3).
#
# THE MECHANISM (verified against ipc_mailbox_apb_regs.sv):
#   die_a peer-writes 0x2F.. ; CAM rule 0x2F->0x23 lands it in die_b ipc_mailbox_0
#   @ 0x2300_0000. IRQ_STATUS[0] is EDGE-SET on the RISING edge of slot0 MSG_VALID
#   (slot0_ctrl[0]) and latches REGARDLESS of irq_enable (irq_enable only gates the
#   NVIC output cpu1_irq). It persists until a W1C to 0x2300_0028. So a clean,
#   repeatable edge needs MSG_VALID de-asserted first (see `arm`).
#
# MODES (each on the indicated board):
#   arm   (die_b): LOCAL — de-assert slot0 MSG_VALID + W1C IRQ_STATUS so the next
#                  send is a genuine rising edge (no stale-latch ambiguity). No link
#                  traversal -> cannot wedge. Run this before every send.
#   send  (die_a): CAM 0x2F->0x23, peer-write 4 payload words, then a fresh
#                  MSG_VALID doorbell (ctrl 0->1). PEER WRITES ONLY (return via
#                  HREADY; no peer reads). REFUSES unless local FCSM=4.
#   recv  (die_b): LOCAL reads of the mailbox slot AND IRQ_STATUS[0]. PASS REQUIRES
#                  IRQ_STATUS[0]==1 AND the 4 words match. Local read == wedge-safe.
#   clear (die_b): LOCAL W1C test — write 1 to IRQ_STATUS[0], confirm it drops 1->0
#                  (the exact ack an ISR performs). Local write/read == wedge-safe.
#
# SAFETY: only `send` touches the peer window (0x2F) and it REFUSES on a down link
# (FCSM!=4) — a peer access on a down/wedged link can hang the PS AXI bus (JTAG-POR
# recovery). arm/recv/clear are die-local (0x23) and always safe. All addresses sit
# inside the eth_ss_0 window whose SoC default slave terminates a miss with SLVERR.
# NEVER pokes the bare-link 0x8403/0xA400/0x8000 map (those are undecoded -> hang).
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import mmap
import os
import struct
import sys

WINDOW_BASE = 0x400000000            # eth_ss_0 backdoor window (PS phys); SoC A -> WINDOW+A

# --- TideLink CONFIG plane (for the FCSM=4 gate on the sender) ---------------
_TLAPB              = 0x2E030000
REG_SWI_LANE_STATUS = _TLAPB + 0x2108     # [16] cal_done, [19:17] fcsm
CAM_BASE            = _TLAPB + 0x4000     # ADDRXLAT_APB base
CAM_CTRL            = _TLAPB + 0x4004     # bit[0] global_enable
CAM_RULE_0          = _TLAPB + 0x4010     # [0]=en [15:8]=match [23:16]=replace
FCSM_LINK_IDLE      = 4

# --- IPC mailbox: the 2nd inbound D2D target (CAM 0x2F->0x23) ----------------
# Offsets from ipc_mailbox_apb_regs.sv (reg_addr = off>>2):
#   0x000..0x00C slot0 data (4 words)        reg 0..3
#   0x020 slot0_ctrl  [0]MSG_VALID [1]MSG_ACK(self-clearing)   reg 8
#   0x028 IRQ_STATUS  [0]slot0_msg-edge [1]slot0_ack [2]slot1_msg [3]slot1_ack  reg 10  R/W1C
#   0x02C IRQ_ENABLE  (masks IRQ_STATUS -> cpu0/cpu1_irq; source still latches)  reg 11
MBOX_SOC_BASE      = 0x23000000       # die_b local mailbox base (PS 0x4_2300_0000)
MBOX_PEER_APERTURE = 0x2F000000       # die_a writes here (CAM 0x2F->0x23)
IPC_SLOT0_DATA     = 0x000            # .. 0x00C (4 words)
IPC_SLOT0_CTRL     = 0x020            # [0]=MSG_VALID [1]=ACK
IPC_IRQ_STATUS     = 0x028            # [0]=slot0 msg edge -> CPU1 NVIC IRQ0
IPC_IRQ_ENABLE     = 0x02C
IPC_MSG_VALID      = 1 << 0
IPC_MSG_ACK        = 1 << 1
IRQ_SLOT0_MSG      = 1 << 0
MBOX_RULE_VALUE    = (0x23 << 16) | (0x2F << 8) | 1   # 0x00232F01
DEFAULT_PAYLOAD    = 0xC0FFEE01
NWORDS             = 4


# --- /dev/mem access (page-granular, matches kr260_eth_xfer.py) --------------
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


def _mbox_words(payload):
    return [(payload + i) & 0xFFFFFFFF for i in range(NWORDS)]


def _require_link():
    st = rd(WINDOW_BASE + REG_SWI_LANE_STATUS)
    fcsm, cal = (st >> 17) & 7, (st >> 16) & 1
    up = fcsm == FCSM_LINK_IDLE and cal == 1
    print("  link SWI_LANE_STATUS=0x%08X fcsm=%d cal=%d -> %s"
          % (st, fcsm, cal, "UP" if up else "DOWN"))
    if not up:
        print("ABORT: link not FCSM=4. Bring it up on BOTH boards first "
              "(bringup_pair_release.sh). Refusing to peer-write a down link "
              "(wedge risk).", file=sys.stderr)
        raise SystemExit(2)


# --- arm (die_b, LOCAL): guarantee a clean rising edge for the next send -----
def do_arm():
    print("=== MBOX ARM (die_b, LOCAL): reset MSG_VALID + W1C IRQ_STATUS ===")
    # De-assert MSG_VALID so die_a's next 0->1 is a genuine rising edge; then W1C
    # the whole IRQ_STATUS so recv can prove the latch is FRESH, not stale.
    wr(WINDOW_BASE + MBOX_SOC_BASE + IPC_SLOT0_CTRL, 0)
    wr(WINDOW_BASE + MBOX_SOC_BASE + IPC_IRQ_STATUS, 0xF)   # W1C bits[3:0]
    ctrl = rd(WINDOW_BASE + MBOX_SOC_BASE + IPC_SLOT0_CTRL)
    irqst = rd(WINDOW_BASE + MBOX_SOC_BASE + IPC_IRQ_STATUS)
    ok = (ctrl & IPC_MSG_VALID) == 0 and (irqst & IRQ_SLOT0_MSG) == 0
    print("  SLOT0_CTRL=0x%08X (MSG_VALID=%d)  IRQ_STATUS=0x%08X (slot0_msg=%d)"
          % (ctrl, ctrl & 1, irqst, irqst & 1))
    print("RESULT: %s — %s" % ("PASS" if ok else "FAIL",
          "edge detector reset; safe to send" if ok else
          "MSG_VALID/IRQ_STATUS did not clear (slot locked? re-read)"))
    return 0 if ok else 1


# --- send (die_a): peer-write payload + a fresh MSG_VALID doorbell ------------
def do_send(payload):
    print("=== MBOX SEND (die_a): CAM 0x2F->0x23 + payload + MSG_VALID doorbell ===")
    _require_link()
    # CAM rule 0x2F -> 0x23 (mailbox), CTRL armed last so a half-rule is never live.
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
    # Guarantee a RISING edge from the sender side too: de-assert then assert. If
    # die_b ran `arm` first (recommended), this is a definitively fresh edge.
    wr(WINDOW_BASE + MBOX_PEER_APERTURE + IPC_SLOT0_CTRL, 0)
    wr(WINDOW_BASE + MBOX_PEER_APERTURE + IPC_SLOT0_CTRL, IPC_MSG_VALID)
    print("  SLOT0_CTRL <- 0 then MSG_VALID (peer 0x2F00_0020 -> die_b 0x2300_0020)")
    print("  doorbell issued (peer writes only, returned via HREADY — no bus hang).")
    print("Now run: recv on die_b (PASS requires IRQ_STATUS[0]==1 + the 4 words).")
    return 0


# --- recv (die_b, LOCAL): PASS *requires* the IRQ source bit -----------------
def do_recv(payload):
    print("=== MBOX RECV (die_b, LOCAL): mailbox slot + IRQ_STATUS[0] (source) ===")
    words = [rd(WINDOW_BASE + MBOX_SOC_BASE + IPC_SLOT0_DATA + i * 4)
             for i in range(NWORDS)]
    ctrl = rd(WINDOW_BASE + MBOX_SOC_BASE + IPC_SLOT0_CTRL)
    irqst = rd(WINDOW_BASE + MBOX_SOC_BASE + IPC_IRQ_STATUS)
    expect = _mbox_words(payload)
    valid = (ctrl & IPC_MSG_VALID) != 0
    data_ok = words == expect
    irq_src = (irqst & IRQ_SLOT0_MSG) != 0
    print("  slot0 data = [%s]" % " ".join("0x%08X" % w for w in words))
    print("  expect     = [%s]" % " ".join("0x%08X" % w for w in expect))
    print("  SLOT0_CTRL = 0x%08X  (MSG_VALID=%d ACK=%d)" % (ctrl, ctrl & 1, (ctrl >> 1) & 1))
    print("  IRQ_STATUS = 0x%08X  (slot0_msg=%d -> feeds CPU1 NVIC IRQ0)" % (irqst, irqst & 1))
    # THE verdict: the interrupt SOURCE must have latched. Data alone is the old
    # (proxy) test; here the latched edge is mandatory.
    ok = irq_src and data_ok
    if ok:
        print("RESULT: PASS — cross-die INTERRUPT SOURCE LATCHED on silicon "
              "(IRQ_STATUS[0]=1 from the far-die MSG_VALID edge) AND payload matched. "
              "First real interrupt-source proof (not a data proxy).")
    elif data_ok and not irq_src:
        print("RESULT: FAIL — data crossed but the IRQ SOURCE did NOT latch. Most "
              "likely a STALE MSG_VALID (no rising edge): run `--mode arm` on die_b "
              "BEFORE the send. If arm ran and it still reads 0, the edge-detect is "
              "broken on silicon (a real finding).")
    else:
        print("RESULT: FAIL — data_ok=%s irq_src=%s msg_valid=%s. (All-0 => sender "
              "didn't run / CAM not 0x2F->0x23 / link down.)" % (data_ok, irq_src, valid))
    return 0 if ok else 1


# --- clear (die_b, LOCAL): the R/W1C clear an ISR would perform --------------
def do_clear():
    print("=== MBOX CLEAR (die_b, LOCAL): R/W1C of IRQ_STATUS[0] (ISR ack path) ===")
    before = rd(WINDOW_BASE + MBOX_SOC_BASE + IPC_IRQ_STATUS)
    print("  IRQ_STATUS before = 0x%08X (slot0_msg=%d)" % (before, before & 1))
    if not (before & IRQ_SLOT0_MSG):
        print("  NOTE: slot0_msg already 0 — nothing latched to clear. Run send+recv "
              "first so there is a source bit to W1C.")
    wr(WINDOW_BASE + MBOX_SOC_BASE + IPC_IRQ_STATUS, IRQ_SLOT0_MSG)   # W1C bit0
    after = rd(WINDOW_BASE + MBOX_SOC_BASE + IPC_IRQ_STATUS)
    cleared = (before & IRQ_SLOT0_MSG) and not (after & IRQ_SLOT0_MSG)
    print("  IRQ_STATUS after  = 0x%08X (slot0_msg=%d)" % (after, after & 1))
    print("RESULT: %s — %s" % ("PASS" if cleared else "FAIL",
          "W1C dropped the source 1->0 (silicon honours the ISR ack)" if cleared else
          "source did not clear (was it set? W1C broken?)"))
    return 0 if cleared else 1


def main():
    ap = argparse.ArgumentParser(
        description="Cross-die IPC mailbox doorbell as an interrupt-SOURCE proof "
                    "(PS-side eth_ss_0 backdoor). arm/recv/clear=die_b LOCAL "
                    "(wedge-safe); send=die_a peer-write (FCSM=4-gated).")
    ap.add_argument("--mode", required=True,
                    choices=("arm", "send", "recv", "clear"),
                    help="arm=die_b reset edge (run before send); send=die_a "
                         "payload+doorbell; recv=die_b verdict (IRQ source REQUIRED); "
                         "clear=die_b W1C of the source bit.")
    ap.add_argument("--payload", default=hex(DEFAULT_PAYLOAD),
                    help="32-bit base payload (word i = payload+i). Default 0xC0FFEE01.")
    args = ap.parse_args()
    if os.geteuid() != 0:
        print("ERROR: needs root for /dev/mem (sudo).", file=sys.stderr)
        return 4
    payload = int(args.payload, 0) & 0xFFFFFFFF
    return {"arm": do_arm, "send": lambda: do_send(payload),
            "recv": lambda: do_recv(payload), "clear": do_clear}[args.mode]()


if __name__ == "__main__":
    sys.exit(main())
