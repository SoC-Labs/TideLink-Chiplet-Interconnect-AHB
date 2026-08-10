#!/usr/bin/env python3
# =============================================================================
# cov_injector_liveness.py — CRC-FREE PROOF THAT ERR_INJECT (0x003C) IS LIVE.
#
# P3-T1 (build spec 2026-08-08, corrections C1 + CC-1). The un-vacuum-er for the
# whole error-injection family: without it, cov_errinject_sweep can "PASS" and
# every DECERR-with-injection leg is NON-PROBATIVE, because a NO-OP injector
# trivially satisfies "die_a alive + die_b byte-exact".
#
# WHY NOT CRC-RISE (the trap this gate avoids, C1):
#   AXI-data FCSM nodes default disable_crc=1 (WlinkGenericFCSM*.v:713), so an RX
#   CRC counter does NOT rise even with a LIVE injector. do_errinject reads
#   fc_crc_of on the injecting die => structurally can never observe the flip.
#
# THE CRC-FREE METHOD (C1):
#   arm ERR_INJECT on die_a for the W data node (id 0x81) with byte>0 (a DATA
#   byte — byte0 is data_id/word_count, ECC-corrected + CRC-off => invisible),
#   fire ONE peer write, and read the landed word from die_b LOCAL SRAM.
#     die_b MISMATCH (corrupted)  => the corruptor is LIVE            => PASS
#     die_b BYTE-EXACT (no change)=> the corruptor is a NO-OP         => VACUOUS
#                                    (declare cov_errinject_sweep + all
#                                     injection-propagation legs non-probative)
#
# RIGOUR (all verdicts die_b-LOCAL, so the verifier can never wedge):
#   Phase 0  control : clean write+verify (injector disarmed) — proves the path
#                      delivers byte-exact, so a Phase-1 mismatch is attributable
#                      to the injector and nothing else.
#   Phase 1  inject  : arm W/0x81/byte>0, fire ONE peer write, die_b LOCAL verify.
#   Phase 2  control': clean write+verify again — confirms the one-shot injector
#                      self-cleared and the path still delivers.
#
# WEDGE-SAFETY: exactly ONE beat on a recovery-stripped AXI node (MED-HIGH);
#   verdict is a die_b-LOCAL read (verifier can't wedge); refuses unless BOTH
#   dies FCSM=4; single-shot; every ssh timeout-wrapped (a timeout == WEDGE);
#   JTAG-POR staged on any wedge. Attended.
#
# Run ON mapstone-dev (never on the boards):
#   export KR260_PASSWORD=...          # or let it derive from the bring-up default
#   python3 cov_injector_liveness.py                 # W/0x81 byte1 bit0
#   python3 cov_injector_liveness.py --byte 2 --bit 3
#   COV_AUTO_POR=1 python3 cov_injector_liveness.py  # auto-recover on a wedge
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cov_common as cc

W_ID = 0x81                       # W data node data_id (initiator TX; provoke w/ a write)


# --- password: derive from the bring-up default, mask it, NEVER echo it -------
def _derive_pw():
    v = os.environ.get("KR260_PASSWORD")
    if v:
        return v
    sh = os.path.join(cc.SCRIPTS_DIR, "kr260_eth_bringup_pair.sh")
    try:
        with open(sh) as f:
            for ln in f:
                if "KR260_PASSWORD:-" in ln:
                    return ln.split("KR260_PASSWORD:-", 1)[1].split("}", 1)[0]
    except OSError:
        pass
    return ""


_PW = _derive_pw()
if _PW and not os.environ.get("KR260_PASSWORD"):
    os.environ["KR260_PASSWORD"] = _PW      # so cov_common.password() resolves it


def _mask(s):
    s = str(s)
    return s.replace(_PW, "***") if _PW else s


def _lastline(s):
    s = _mask(s).strip()
    return s.splitlines()[-1] if s else ""


# --- one clean write (die_a) -> die_b LOCAL verify ---------------------------
def write_verify(base, n, stage):
    """Returns (ok, wedged, got, exp, text).
       ok True  => die_b byte-exact; ok False => MISMATCH; ok None => write error.
       wedged True => an access timed out (== PS-bus WEDGE)."""
    try:
        rc, out = cc.board_python(cc.DIE_A_IP, "%s write %d 0x%08X"
                                  % (cc.SOAK_FWD, n, base), cc.T_STREAM, stage + "_w")
    except cc.WedgeTimeout as e:
        return None, True, None, None, "WEDGE on write (stage=%s)" % e.stage
    if rc != 0 or "WROTE" not in out:
        return None, False, None, None, "write failed rc=%d: %s" % (rc, _lastline(out))
    try:
        rvc, rout = cc.board_python(cc.DIE_B_IP, "%s verify %d 0x%08X"
                                    % (cc.SOAK_FWD, n, base), cc.T_VERIFY, stage + "_v")
    except cc.WedgeTimeout as e:
        return None, True, None, None, "WEDGE on die_b verify (stage=%s)" % e.stage
    ll = _lastline(rout)
    got = exp = None
    if "got0x" in ll:
        try:
            got = int(ll.split("got0x")[1].split()[0], 16)
            exp = int(ll.split("exp0x")[1].split()[0], 16)
        except (ValueError, IndexError):
            pass
    return (rvc == 0), False, got, exp, ll


def main():
    ap = argparse.ArgumentParser(
        description="CRC-free proof that ERR_INJECT (0x003C) is a real corruptor.")
    ap.add_argument("--byte", type=int, default=1,
                    help="ERR_INJECT byte index (MUST be >0 — a DATA byte; byte0 "
                         "is ECC-corrected + CRC-off => invisible). Default 1.")
    ap.add_argument("--bit", type=int, default=0, help="bit within the byte [0..7]. Default 0.")
    ap.add_argument("--base", default="0x1B1B0000",
                    help="deterministic payload base written to the peer aperture.")
    args = ap.parse_args()

    byte, bit = args.byte, args.bit
    base = int(args.base, 0) & 0xFFFFFFFF

    cc.banner("INJECTOR LIVENESS (CRC-FREE, C1/CC-1) — W node id 0x%02X byte=%d bit=%d"
              % (W_ID, byte, bit))
    if not _PW:
        print("ERROR: no board password (KR260_PASSWORD unset and bring-up default "
              "not found).")
        print("RESULT: INJECTOR_LIVENESS INCONCLUSIVE (no password)")
        return 2
    if byte <= 0:
        print("ERROR: --byte must be >0. A byte0 flip is header (data_id/word_count): "
              "ECC-corrected at RX and CRC is off => structurally invisible (C1).")
        print("RESULT: INJECTOR_LIVENESS INCONCLUSIVE (byte0 requested; need a data byte)")
        return 2

    # 0. refuse unless BOTH dies FCSM=4 (primary wedge guard).
    try:
        cc.require_pair_fcsm4(cc.DIE_A_IP, cc.DIE_B_IP)
    except SystemExit:
        print("RESULT: INJECTOR_LIVENESS INCONCLUSIVE (link not FCSM=4 both dies)")
        return 2

    # 1. Phase 0 — control: prove the clean path delivers byte-exact (injector off).
    cc.inject_off(cc.DIE_A_IP)                       # ensure disarmed
    ok0, wed0, _, _, t0 = write_verify(base ^ 0x00010000, 1, "control_pre")
    print("  control(pre)  : %s" % t0)
    if wed0:
        cc.por_stage(cc.DIE_A_IP, "injector-liveness control wedge")
        print("RESULT: INJECTOR_LIVENESS WEDGE (control write/verify wedged before test)")
        return 1
    if ok0 is not True:
        print("  clean path is NOT byte-exact — a later mismatch could not be "
              "attributed to the injector.")
        print("RESULT: INJECTOR_LIVENESS INCONCLUSIVE (clean delivery path unproven)")
        return 2

    # 2. Phase 1 — arm the one-shot W injector, fire ONE peer write, verify die_b.
    print("-- arm ERR_INJECT die_a: id=0x%02X byte=%d bit=%d, then ONE peer write --"
          % (W_ID, byte, bit))
    cc.inject(cc.DIE_A_IP, W_ID, byte, bit)
    oki, wedi, got, exp, ti = write_verify(base, 1, "inject")
    cc.inject_off(cc.DIE_A_IP)                       # self-clears, but be explicit
    print("  injected      : %s" % ti)
    if wedi:
        cc.por_stage(cc.DIE_A_IP, "injector-liveness injected-beat wedge")
        print("RESULT: INJECTOR_LIVENESS WEDGE (injected beat wedged die_a)")
        return 1

    # 3. Phase 2 — control': confirm the one-shot self-cleared and path still delivers.
    ok2, wed2, _, _, t2 = write_verify(base ^ 0x00020000, 1, "control_post")
    print("  control(post) : %s" % (t2 if not wed2 else "WEDGE (post-control)"))

    print("-" * 66)
    if oki is False:
        # die_b LOCAL read of the injected word MISMATCHED at a data byte => LIVE.
        print("  die_b LOCAL read of the injected word MISMATCHED at byte>0:")
        if got is not None and exp is not None:
            print("    got=0x%08X  expected=0x%08X  flip-delta=0x%08X"
                  % (got, exp, got ^ exp))
        print("  => the ERR_INJECT (0x003C) corruptor is LIVE in this bitstream.")
        if ok2 is not True:
            print("  NOTE: post-control was not byte-exact — the path may carry residual "
                  "degradation after the injected beat (report-only).")
        print("RESULT: INJECTOR_LIVENESS PASS (injector LIVE — cov_errinject_sweep is PROBATIVE)")
        return 0
    if oki is True:
        # die_b byte-exact under an armed injector => the injector did nothing.
        print("  die_b LOCAL read of the injected word was BYTE-EXACT (no corruption)")
        print("  under an armed W/0x%02X injector." % W_ID)
        print("  => ERR_INJECT is a NO-OP on the W data node in this bitstream.")
        print("  => VACUOUS: cov_errinject_sweep + ALL injection-propagation legs are")
        print("     NON-PROBATIVE — a no-op injector trivially satisfies "
              "'die_a alive + die_b byte-exact'. Stop that branch.")
        print("RESULT: INJECTOR_LIVENESS VACUOUS (injector no-op — cov_errinject_sweep NON-PROBATIVE)")
        return 1
    # write error on the injected beat (rc!=0, not a timeout) — indeterminate.
    print("RESULT: INJECTOR_LIVENESS INCONCLUSIVE (injected write did not complete cleanly)")
    return 2


if __name__ == "__main__":
    sys.exit(main())
