#!/usr/bin/env python3
# =============================================================================
# cov_mbox_irq_source.py — HOST gate (runs on the dev host, e.g. mapstone-dev):
#     the first cross-die INTERRUPT-SOURCE proof on the KR260 eth-chiplet pair.
#
# Orchestrates the board-side cov_mbox_doorbell_irq.py across both dies, reusing
# the wedge-safety layer in cov_common.py (timeout-wrapped ssh, FCSM=4 gate,
# env-only password, STAGED JTAG-POR). Sequence:
#
#     0. require BOTH dies FCSM=4 (else refuse — never drive a down link)
#     1. die_b  arm    (LOCAL) reset MSG_VALID + W1C IRQ_STATUS -> clean edge
#     2. die_a  send   peer-write payload + MSG_VALID doorbell (0x2F->0x23)
#     3. die_b  recv   (LOCAL) VERDICT: PASS requires IRQ_STATUS[0]==1 + 4 words
#     4. die_b  clear  (LOCAL) W1C the source bit (the ISR ack) -> 1->0
#
# WHY IT MATTERS: per the V-plan, no interrupt has EVER been observed asserting on
# this hardware — every "IRQ" check to date is a register-value proxy. Step 3 is
# the first PASS that is gated on an interrupt SOURCE actually latching on silicon
# (IRQ_STATUS[0], set on the far-die MSG_VALID rising edge, latches regardless of
# irq_enable). Delivery to an ISR still needs firmware (see cov_cross_die_isr_plan.md).
#
# WEDGE-SAFETY (mandatory, all inherited from cov_common):
#   * every board access is subprocess-timeout-wrapped; a timeout == a PS-bus WEDGE
#     (WedgeTimeout) -> abort + STAGED JTAG-POR (never `reboot`, never auto unless
#     COV_AUTO_POR=1).
#   * the ONLY peer traversal is step-2 die_a peer WRITES (reliable; return via
#     HREADY). The verdict (step 3/4) is die_b LOCAL reads -> the verifier cannot
#     wedge. No peer READ round-trip anywhere.
#   * refuses unless BOTH dies FCSM=4. Never touches bare-link 0x8403/0xA400/0x8000.
#
# This gate is CI-safe-ISH but marked ATTENDED: step 2 crosses the AXI data-node
# path that intermittently wedges (docs/CROSS_DIE_WEDGE_ROOTCAUSE.md). Run attended,
# one pair, ready to JTAG-POR from mapstone-dev.
#
# Env: KR260_PASSWORD (required), KR260_DIEA_IP/KR260_DIEB_IP (defaults in cov_common),
#      COV_AUTO_POR=1 to allow auto JTAG-POR on a wedge.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import os
import subprocess
import sys

import cov_common as cc

BOARD_TOOL = os.path.join(cc.HERE, "cov_mbox_doorbell_irq.py")
REMOTE_TOOL = "cov_mbox_doorbell_irq.py"          # lands in ~/<DEST_DIR>/
T_SEND = int(os.environ.get("COV_T_SEND", "45"))   # peer-write doorbell (attended)


def push_tool(ip, timeout=30):
    """scp the board-side tool into ~/<DEST_DIR>/ (deploy may not stage coverage/).
    A push hang is a network/host problem (not a bus wedge) -> hard error."""
    pw = cc.password()
    dest = "%s@%s:%s/" % (cc.KR260_USER, ip, cc.DEST_DIR)
    cmd = ["sshpass", "-p", pw, "scp",
           "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15",
           BOARD_TOOL, dest]
    try:
        p = subprocess.run(cmd, timeout=timeout, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
    except subprocess.TimeoutExpired:
        sys.exit("ERROR: scp to %s timed out — board unreachable (this is not a bus "
                 "wedge; check the network / power)." % ip)
    if p.returncode != 0:
        sys.exit("ERROR: scp of %s to %s failed:\n%s" % (REMOTE_TOOL, ip, p.stdout))


def step(ip, label, mode, payload, timeout):
    """Run one board-side mode; print its output; return (rc, output). A hang is a
    WEDGE -> STAGE recovery and re-raise so the caller aborts cleanly."""
    print("-- [%s] %s --" % (label, mode))
    args = "%s --mode %s --payload %s" % (REMOTE_TOOL, mode, payload)
    try:
        rc, out = cc.board_python(ip, args, timeout, "mbox_" + mode)
    except cc.WedgeTimeout as w:
        print("  !! WEDGE: %s hung past %ds during '%s'." % (ip, timeout, mode))
        cc.por_stage(ip, reason="mbox_%s wedge" % mode)
        raise
    for line in out.splitlines():
        print("   " + line)
    return rc, out


def run(payload):
    cc.banner(" cov_mbox_irq_source — cross-die interrupt-SOURCE proof (mailbox 0x2F->0x23)")
    print("  die_a(initiator)=%s  die_b(target)=%s  payload=%s"
          % (cc.DIE_A_IP, cc.DIE_B_IP, payload))
    print("  ATTENDED: step 2 crosses the AXI data plane (wedge-prone). Ready to "
          "JTAG-POR from mapstone-dev.")

    # 0. FCSM=4 gate (RO, wedge-safe). Refuses on a down/half link.
    cc.require_pair_fcsm4(cc.DIE_A_IP, cc.DIE_B_IP)

    # stage the board-side tool onto both dies.
    push_tool(cc.DIE_A_IP)
    push_tool(cc.DIE_B_IP)

    try:
        # 1. arm die_b so the doorbell is a genuine rising edge (clean-room latch).
        step(cc.DIE_B_IP, "die_b", "arm", payload, cc.T_POKE)
        # 2. die_a fires the doorbell (peer writes only).
        rc_s, _ = step(cc.DIE_A_IP, "die_a", "send", payload, T_SEND)
        if rc_s != 0:
            print("  send returned rc=%d (link refused? see above) — aborting." % rc_s)
            return 2
        # 3. VERDICT from die_b LOCAL read: the IRQ source must have latched.
        rc_r, out_r = step(cc.DIE_B_IP, "die_b", "recv", payload, cc.T_VERIFY)
        source_latched = "RESULT: PASS" in out_r
        # 4. W1C clear (the ISR ack) — proves the clear path too.
        rc_c, out_c = step(cc.DIE_B_IP, "die_b", "clear", payload, cc.T_VERIFY)
        clear_ok = "RESULT: PASS" in out_c
    except cc.WedgeTimeout:
        print("=" * 78)
        print(" SUMMARY: WEDGED mid-test — verdict UNKNOWN. Recover (JTAG-POR) + "
              "re-bring-up before retrying.")
        print("=" * 78)
        return 3

    print("=" * 78)
    print(" SUMMARY: interrupt-SOURCE latched = %s ; W1C clear = %s"
          % ("YES" if source_latched else "NO", "YES" if clear_ok else "NO"))
    if source_latched and clear_ok:
        print("  PASS — first cross-die interrupt SOURCE proven on silicon (set on the "
              "far-die MSG_VALID edge, cleared by W1C). ISR DELIVERY still needs "
              "firmware: cov_cross_die_isr_plan.md.")
    else:
        print("  FAIL — see the die_b recv/clear output above. If data crossed but the "
              "source did not latch, suspect a stale MSG_VALID (arm ran?) or a silicon "
              "edge-detect gap.")
    print("=" * 78)
    return 0 if (source_latched and clear_ok) else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--payload", default="0xC0FFEE01",
                    help="32-bit base payload (word i = payload+i). Default 0xC0FFEE01.")
    args = ap.parse_args()
    if not os.environ.get("KR260_PASSWORD"):
        sys.exit("ERROR: export KR260_PASSWORD before running (never hardcoded).")
    return run(args.payload)


if __name__ == "__main__":
    sys.exit(main())
