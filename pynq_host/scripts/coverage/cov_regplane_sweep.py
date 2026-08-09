#!/usr/bin/env python3
# =============================================================================
# cov_regplane_sweep.py — FULL TideLink APB register-plane sweep on the
#   eth-chiplet, over the eth_ss_0 backdoor. RW round-trip / RO write-reject /
#   reset-&-ID match / W1P self-clear, region by region.
#
# The eth-chiplet has NEVER had its full TideLink register plane swept — only the
# PYNQ-Z2 hwtest/02,04,06 did, on a different platform and address base. This
# gate ports that coverage to the KR260 eth-chiplet, whose TLAPB config plane is
# at TLAPB+0x2000.. (SWI_LANE_STATUS reads at 0x2108, not 0x108), the per-node FC
# plane at TLAPB+0x1000.., and obs at TLAPB+0x219C.. . Authoritative map:
# hwtest/REG_INVENTORY.md (offsets there are the Z2 low offsets == eth offset
# minus 0x2000 for the R0..R8 config regions).
#
# Per register KIND:
#   rw   save -> write A5/5A/walking (masked to writable bits) -> read back ==
#        written -> RESTORE the original.  (round-trip)
#   ro   save -> write 0xFFFFFFFF then 0x0 -> assert the reg did NOT take the
#        written value (drift-robust RO check).  On a NATIVE APB probe the write
#        also raises pslverr; over the /dev/mem backdoor a rejected write is
#        absorbed by the AHB default slave (SLVERR) so read-back-unchanged is the
#        reliable signal.
#   id   read == an exact reset/ID constant (PHY_ALIGN_ID 0x5041_0100, VERSION
#        0x544C_0100, PERF_ID 0x5046_0100).
#   w1p  write the pulse bit -> read back the bit == 0 (self-clears).
#   mark RO + a fixed presence marker in the top bits (OBS 0xAD / WINSCAN 0xC5,
#        0x25 / FCEMIT 0xE1,0xE2).
#   skip present/non-faulting read only — write-once or link-disruptive regs we
#        must NOT poke (CTRL.LOCK, ROLE_CFG.role_lock, SWI_PHASE_OFFSET,
#        NEGO_TRAIN_CFG, SWI_TRAINING_MODE recal, the WO consume reg, dead ECCCNT).
#
# SAFETY (mandatory): the whole sweep stays inside the TLAPB config/obs/FC plane
# (combinational, bounded) — it NEVER touches AHB_TX (0x4400_0000 wedge aperture),
# the peer aperture, or the bare-link addresses 0x8403/0xA400/0x8000. Write-once
# bits (CTRL.LOCK, ROLE_CFG.role_lock) are never set — writes are masked to safe
# bits only, and every RW reg is restored. Link-disruptive writes (routing / PHY
# bit-slip+training / PTP) are OPT-IN (--include-routing/--include-phy/--include-ptp;
# default OFF -> those regs get the read-only `skip` treatment). FCSM=4 is required
# (cov_common gate); every board access is subprocess-timeout-wrapped; a hang is a
# wedge and JTAG-POR is staged.
#
# Self-shipping single file:
#   export KR260_PASSWORD=...
#   python3 cov_regplane_sweep.py                       # safe default sweep, die_a
#   python3 cov_regplane_sweep.py --die b
#   python3 cov_regplane_sweep.py --include-ptp         # add PTP RW round-trips
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import base64
import os
import sys

WINDOW = 0x400000000
TLAPB = 0x2E030000

# Register inventory (offset-from-TLAPB, name, kind, extra). extra:
#   rw   -> wmask (writable-bit mask)
#   id   -> expected constant
#   w1p  -> pulse-bit mask
#   mark -> (shift, mask, expected)
#   gate -> optional feature flag name that must be enabled to WRITE (else skip)
INVENTORY = [
    # --- Region 0: config/status (0x2000-0x201C) ---
    (0x2000, "PAIR_BASE_ADDR", "rw", {"wmask": 0xFFFFFFFF, "gate": "routing"}),
    (0x2004, "RELEASE_THRESHOLD", "rw", {"wmask": 0xFFFFFFFF}),
    (0x2008, "PACKET_WORD_LENGTH", "ro", {}),
    (0x200C, "CURRENT_CREDITS", "ro", {}),
    (0x2010, "STATUS", "ro", {}),
    (0x2014, "TIDELINK_VERSION", "id", {"expect": 0x544C0100}),
    (0x2018, "RELEASE_ACC", "ro", {}),
    (0x201C, "CTRL_FLUSH", "w1p", {"pulse": 0x2}),   # bit1 FLUSH; bit2 LOCK NEVER set
    # --- Region 1: incoming credits + PTP basic (0x2020-0x203C) ---
    (0x2028, "PAIR_CREDIT_COUNTER", "ro", {}),
    (0x202C, "PAIR_CREDIT_CONSUME", "skip", {"why": "WO consume — writing decrements credits"}),
    (0x2030, "PAIR_CREDIT_COUNTER_EN", "rw", {"wmask": 0x1}),
    (0x2034, "PTP_CTRL", "rw", {"wmask": 0x7, "gate": "ptp"}),
    (0x2038, "PTP_RX_PAYLOAD", "ro", {}),
    (0x203C, "PTP_STATUS", "ro", {}),
    # --- Region 2: PTP HW sync + servo (0x2040-0x205C) ---
    (0x2040, "HW_SYNC_CTRL", "rw", {"wmask": 0x5, "gate": "ptp"}),  # [0]en [2]force_en
    (0x2048, "HW_SYNC_STATUS", "ro", {}),
    (0x204C, "SERVO_KP", "rw", {"wmask": 0xFFFFFFFF, "gate": "ptp"}),
    # --- Region 3: servo status + TS mailbox (0x2060-0x207C) ---
    (0x2060, "SERVO_STATUS", "ro", {}),
    (0x2068, "TS_MAILBOX_0", "ro", {}),
    # --- Region 4: chiplet role (0x2080-0x209C) ---
    (0x2080, "ROLE_CFG", "skip", {"why": "role_lock W1S write-once (deploy_pair owns it)"}),
    (0x2084, "CHIPLET_CTRL_1", "ro", {}),   # read-only sanity (misc chiplet ctrl)
    # --- Region 5/6/7: perf (0x20A0-0x20FC) ---
    (0x20A0, "PERF_CTRL", "rw", {"wmask": 0x13}),    # [0]en [1]freeze [4]irq_en
    (0x20A4, "TX_ORIGIN_NS", "rw", {"wmask": 0x3FFFFFFF}),
    (0x20A8, "TX_ORIGIN_SEC", "rw", {"wmask": 0xFFFFFFFF}),
    (0x20C8, "TX_PKT_COUNT", "ro", {}),
    (0x20D0, "TX_WORD_COUNT", "ro", {}),
    (0x20E4, "CREDIT_STARVE", "ro", {}),
    (0x20F8, "PERF_CONG_STATE", "ro", {}),
    (0x20FC, "PERF_ID", "id", {"expect": 0x50460100}),
    # --- Region 8: chiplet extended PHY-align (0x2100-0x211C) ---
    (0x2100, "SWI_TRAINING_MODE", "skip", {"why": "recal (W1P) retrains the link"}),
    (0x2104, "SWI_BIT_SLIP_LO", "rw", {"wmask": 0xFFFFFF, "gate": "phy"}),
    (0x2108, "SWI_LANE_STATUS", "ro", {}),
    (0x210C, "NEGO_TRAIN_CFG", "skip", {"why": "autoneg handshake — handle with care"}),
    (0x2110, "NEGO_TRAIN_STATUS", "ro", {}),
    (0x2114, "ECC_COUNTERS", "skip", {"why": "DEAD ECCCNT (ties 0) + step is W1P"}),
    (0x2118, "SWI_PHASE_OFFSET", "skip", {"why": "latched at role_lock; write is inert/risky"}),
    (0x211C, "PHY_ALIGN_ID", "id", {"expect": 0x50410100}),
    # --- Observability plane (RO + presence markers) ---
    (0x219C, "OBS_FC_CREDIT", "ro", {}),
    (0x21E0, "OBS_AXI_NODES", "mark", {"shift": 24, "mask": 0xFF, "expect": 0xAD}),
    (0x21E4, "WINSCAN_STAT", "mark", {"shift": 24, "mask": 0xFF, "expect": 0xC5}),
    (0x21E8, "WINSCAN_EYE", "mark", {"shift": 26, "mask": 0x3F, "expect": 0x25}),
    (0x21EC, "FCEMIT_STAT", "mark", {"shift": 24, "mask": 0xFF, "expect": 0xE1}),
    (0x21F0, "FCEMIT_IDCNT", "mark", {"shift": 24, "mask": 0xFF, "expect": 0xE2}),
    (0x21F4, "AUTO_ANCHOR_OBS", "ro", {}),
    # --- per-node FC CRC (RO) — representative AXI node ---
    (0x1020, "FC_AW_CRC", "ro", {}),
    (0x1220, "FC_B_CRC", "ro", {}),
    (0x1420, "FC_R_CRC", "ro", {}),
]

RW_PATTERNS = (0xA5A5A5A5, 0x5A5A5A5A, 0xFFFFFFFF, 0x00000000)


# ============================================================================
# ON-BOARD AGENT (board-local /dev/mem; STDLIB ONLY). Prints per-reg RESULT lines.
# ============================================================================
def _onboard(args):
    import mmap
    import struct
    try:
        f = open("/dev/mem", "r+b", buffering=0)
        m = mmap.mmap(f.fileno(), 0x4000, mmap.MAP_SHARED,
                      mmap.PROT_READ | mmap.PROT_WRITE, offset=WINDOW + TLAPB)
    except (OSError, PermissionError) as e:
        print("ONBOARD_ERR mmap /dev/mem failed: %s" % e)
        return 3

    def rd(o):
        return struct.unpack("<I", m[o:o + 4])[0]

    def wr(o, v):
        m[o:o + 4] = struct.pack("<I", v & 0xFFFFFFFF)

    gates = {"routing": args.include_routing, "ptp": args.include_ptp, "phy": args.include_phy}
    npass = nfail = 0

    def emit(name, off, ok, detail):
        nonlocal npass, nfail
        if ok:
            npass += 1
        else:
            nfail += 1
        print("REG %-20s 0x%04X %-4s %s" % (name, off, "PASS" if ok else "FAIL", detail))

    for off, name, kind, ex in INVENTORY:
        gate = ex.get("gate")
        if kind == "rw" and gate and not gates.get(gate, False):
            print("REG %-20s 0x%04X SKIP writes gated behind --include-%s (read-only "
                  "sanity: 0x%08X)" % (name, off, gate, rd(off)))
            continue
        if kind == "skip":
            print("REG %-20s 0x%04X SKIP %s (read-only sanity: 0x%08X)"
                  % (name, off, ex.get("why", ""), rd(off)))
            continue
        try:
            if kind == "rw":
                wmask = ex["wmask"]
                orig = rd(off)
                bad = None
                for pat in RW_PATTERNS:
                    wr(off, pat & wmask)
                    got = rd(off) & wmask
                    if got != (pat & wmask):
                        bad = (pat, got)
                        break
                wr(off, orig)                       # RESTORE
                rb = rd(off)
                if bad is None and (rb & wmask) == (orig & wmask):
                    emit(name, off, True, "round-trip ok (wmask=0x%X restored 0x%08X)" % (wmask, orig))
                elif bad is not None:
                    emit(name, off, False, "wrote 0x%08X read 0x%08X (wmask=0x%X)" % (bad[0] & wmask, bad[1], wmask))
                else:
                    emit(name, off, False, "restore mismatch orig=0x%08X now=0x%08X" % (orig, rb))
            elif kind == "ro":
                orig = rd(off)
                wr(off, 0xFFFFFFFF)
                r1 = rd(off)
                wr(off, 0x00000000)
                r2 = rd(off)
                # RO holds if the forced 0xFFFFFFFF write did not stick.
                ok = not (r1 == 0xFFFFFFFF and orig != 0xFFFFFFFF)
                emit(name, off, ok, "RO reject (orig=0x%08X after wr0xF=0x%08X wr0=0x%08X)"
                     % (orig, r1, r2))
            elif kind == "id":
                v = rd(off)
                ok = v == ex["expect"]
                emit(name, off, ok, "id=0x%08X expect=0x%08X" % (v, ex["expect"]))
            elif kind == "w1p":
                pulse = ex["pulse"]
                wr(off, pulse)                      # only the safe pulse bit
                rb = rd(off)
                ok = (rb & pulse) == 0
                emit(name, off, ok, "W1P self-clear (wrote 0x%X read 0x%08X)" % (pulse, rb))
            elif kind == "mark":
                v = rd(off)
                got = (v >> ex["shift"]) & ex["mask"]
                ok = got == ex["expect"]
                emit(name, off, ok, "marker 0x%02X expect 0x%02X (raw 0x%08X)"
                     % (got, ex["expect"], v))
        except Exception as e:                      # never let one reg abort the sweep
            emit(name, off, False, "EXC %s" % e)

    print("SUMMARY pass=%d fail=%d" % (npass, nfail))
    m.close()
    f.close()
    return 0 if nfail == 0 else 1


# ============================================================================
# DEV-HOST ORCHESTRATOR
# ============================================================================
def _ship_run(cc, ip, onboard_args, timeout, stage):
    b64 = base64.b64encode(open(os.path.abspath(__file__), "rb").read()).decode()
    fn = "/tmp/%s" % os.path.basename(__file__)
    remote = "echo %s | base64 -d > %s && python3 %s %s" % (b64, fn, fn, onboard_args)
    return cc.ssh_board(ip, remote, timeout, stage)


def _devhost(args):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import cov_common as cc

    ip = cc.DIE_A_IP if args.die == "a" else cc.DIE_B_IP
    cc.banner("TIDELINK APB REGISTER-PLANE SWEEP — die_%s (%s)" % (args.die, ip))
    cc.require_pair_fcsm4(cc.DIE_A_IP, cc.DIE_B_IP)

    ob = "--on-board"
    if args.include_routing:
        ob += " --include-routing"
    if args.include_ptp:
        ob += " --include-ptp"
    if args.include_phy:
        ob += " --include-phy"
    try:
        rc, out = _ship_run(cc, ip, ob, cc.T_STREAM, "regsweep")
    except cc.WedgeTimeout as e:
        print("  !! WEDGE: register sweep timed out (stage=%s) — a write hung the bus."
              % e.stage)
        cc.por_stage(ip, "regsweep wedge")
        print("RESULT: FAIL — sweep wedged (a masked config-plane write should never "
              "hang; investigate before re-running).")
        return 1
    print(out.rstrip())
    if "ONBOARD_ERR" in out:
        print("RESULT: FAIL — on-board agent error.")
        return 1
    ok = rc == 0 and "SUMMARY pass=" in out and " fail=0" in out
    print("RESULT: %s — %s" % ("PASS" if ok else "FAIL",
          "all swept registers behaved (RW round-trip / RO reject / id / W1P / marker)"
          if ok else "one or more registers misbehaved (see FAIL lines above)"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="TideLink APB register-plane sweep (eth-chiplet).")
    ap.add_argument("--on-board", action="store_true", help="internal: sweep agent.")
    ap.add_argument("--die", choices=("a", "b"), default="a")
    ap.add_argument("--include-routing", action="store_true",
                    help="also RW-round-trip PAIR_BASE_ADDR (restored; misroute risk).")
    ap.add_argument("--include-ptp", action="store_true",
                    help="also RW-round-trip PTP/servo regs (needs a PHC image).")
    ap.add_argument("--include-phy", action="store_true",
                    help="also RW-round-trip SWI_BIT_SLIP_LO (restored; lane-disturb risk).")
    args = ap.parse_args()
    if args.on_board:
        return _onboard(args)
    return _devhost(args)


if __name__ == "__main__":
    sys.exit(main())
