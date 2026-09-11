#!/usr/bin/env python3
"""Red/green control for kr260_sysval T6_endurance (false-green C4).

`pynq_host/scripts/kr260_sysval.py` ended T6 with

    board(B, "verify %d 0x%08X" % (min(step, ENDUR_BEATS), base), 60, marker="VERIFY")
    record("T6_endurance", "PASS", "%d beats, die_a alive, ..." % ENDUR_BEATS)

The Res was dropped on the floor. The delivery check ran and its answer was
thrown away; PASS was recorded unconditionally. T6 could not report a delivery
failure at all -- and it writes a JSON verdict artefact that other people read
as evidence.

HISTORY (this control has been deleted once already). 736607c fixed it against
the `rev2/fix-falsegreen` API (`verify_verdict(rc, out, n)`); merge 77db1c5 took
the `rev2/harness-repair` copy of kr260_sysval.py instead, the helper vanished,
and this file was deleted because it could no longer import what it tested. The
defect came back with it. Per docs/MERGE_RECONCILIATION_TODO.md step 3 this
version is written against the PRODUCTION classifier -- SV.classify / SV.Res --
so it exercises the real transport contract instead of a copy of it.

TWO INVARIANTS, both with cases below:
  * T6 MUST be able to report a delivery failure.
  * A dead ssh MUST NEVER be reported as a data mismatch.

THE rc=3 ROW, the one the reconciliation note said had to be decided rather
than guessed: the MARKER decides, not the exit code (see verify_verdict()).
  rc=3 + output + marker PRESENT -> FAIL         (it ran and disagreed)
  rc=3 + output + marker ABSENT  -> INCONCLUSIVE (no evidence it ran)
Both rows are cases here, so a future merge that silently picks one semantics
over the other goes red in this file rather than in silicon.

No ssh, no KR260, no /dev/mem: the whole of t6_endurance runs against a fake
board through its injected dependencies.

Run: python3 scripts/ci/tests/test_kr260_sysval_t6.py
"""

import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "pynq_host" / "scripts"))

# Keep the endurance loop to one chunk so the fake board is exercised once.
os.environ.setdefault("SYSVAL_ENDUR_BEATS", "256")
os.environ.setdefault("KR260_PASSWORD", "control-harness-not-a-real-password")

import kr260_sysval as SV  # noqa: E402

N = int(os.environ["SYSVAL_ENDUR_BEATS"])

HEALTHY_OBS = {"fcsm": 4, "cal": 1, "regf_present": True, "data_healthy": 1,
               "wedge_tgt": 0, "wedge_ini": 0}


def res(rc, out, err="", marker="VERIFY"):
    """Build a Res THROUGH THE PRODUCTION CLASSIFIER, so these specimens are
    classified by exactly the code the harness runs on hardware."""
    kind = SV.classify(rc, out, err, marker)
    return SV.Res(rc, out, err, kind, 1, 0, "fake@die_b", "verify %d 0x0" % N)


def run_t6(verify_res):
    """Drive the whole of t6_endurance with a fake board.

    Returns (verdict, detail, info, ret, n_pors)."""
    recorded = []
    pors = []

    def fake_board(host, args, timeout=40, marker=None):
        if args.startswith("write"):
            return res(0, "WRITE ok", marker="WRITE")
        if args.startswith("verify"):
            return verify_res
        raise AssertionError("unexpected board call %r" % args)

    def fake_obs(host):
        return dict(HEALTHY_OBS)
    fake_obs.last = None

    def fake_record(name, verdict, detail="", info=None):
        recorded.append((name, verdict, detail, info or {}))

    ret = SV.t6_endurance(base=0xC7C70000, board_fn=fake_board, obs_fn=fake_obs,
                          por_fn=lambda: pors.append(1), record_fn=fake_record)

    assert len(recorded) == 1, "expected exactly one record(), got %r" % recorded
    _name, verdict, detail, info = recorded[0]
    return verdict, detail, info, ret, len(pors)


TAG = "%d/%d" % (N, N)

# (label, Res, expected verdict, expected return, expected info kind or None)
CASES = [
    ("clean delivery",
     res(0, "VERIFY %s ok" % TAG), "PASS", True, None),

    # THE C4 SPECIMEN. The board reports a real byte mismatch. Pre-fix: PASS.
    ("delivery mismatch (marker present)",
     res(0, "VERIFY %d/%d ok" % (N - 3, N)), "FAIL", False, SV.DATA_MISMATCH),

    # Ran, exited 0, printed nothing recognisable: no proof the verify body ran.
    ("board printed nothing",
     res(0, ""), "INCONCLUSIVE", False, SV.BOARD_ERROR),

    # rc=124 is the board taking the command and never coming back = a wedge.
    ("board timeout rc=124",
     res(124, ""), "FAIL", False, None),

    # rc=255 with no output is an ssh reset. Calling it a mismatch is the
    # 2026-08-24 false-red that cost weeks. INVARIANT 2.
    ("ssh reset rc=255, no output",
     res(255, "", "kex_exchange_identification: Connection reset by peer"),
     "INCONCLUSIVE", False, None),
    ("ssh reset rc=255, bare (no stderr signature)",
     res(255, ""), "INCONCLUSIVE", False, None),

    # THE rc=3 ROW, BOTH HALVES -- decided by the marker, not the exit code.
    ("rc=3, output, marker ABSENT -> INCONCLUSIVE",
     res(3, "Traceback (most recent call last): PermissionError /dev/mem"),
     "INCONCLUSIVE", False, SV.BOARD_ERROR),
    ("rc=3, output, marker PRESENT -> FAIL",
     res(3, "VERIFY %d/%d MISMATCH at 17" % (N - 1, N)),
     "FAIL", False, SV.DATA_MISMATCH),

    # A truncated/corrupted first line eats the marker: still no data verdict.
    ("sudo prompt ate the marker line",
     res(0, "[sudo] password for ubuntu: ERIFY %s ok" % TAG),
     "INCONCLUSIVE", False, SV.BOARD_ERROR),
]


def main():
    failures = 0

    for label, r, want_verdict, want_ret, want_kind in CASES:
        verdict, detail, info, ret, n_pors = run_t6(r)
        ok = (verdict == want_verdict) and (ret is want_ret)
        if want_kind is not None and info.get("kind") != want_kind:
            ok = False
        if ok:
            print("  PASS  %-46s -> %-12s kind=%s"
                  % (label, verdict, info.get("kind")))
        else:
            failures += 1
            print("  FAIL  %-46s -> %s / ret=%r / kind=%s "
                  "(wanted %s / %r / %s)"
                  % (label, verdict, ret, info.get("kind"),
                     want_verdict, want_ret, want_kind))
            print("        detail: %s" % detail)

    # INVARIANT 2, stated as its own assertion rather than inferred from a
    # verdict: no transport failure may ever be stamped DATA_MISMATCH.
    for label, r in (("rc=255 reset", res(255, "", "Connection reset by peer")),
                     ("rc=255 bare", res(255, ""))):
        _v, _d, info, _ret, _p = run_t6(r)
        if info.get("kind") == SV.DATA_MISMATCH:
            failures += 1
            print("  FAIL  %s recorded as DATA_MISMATCH — a dead ssh is not a "
                  "data verdict" % label)
        else:
            print("  PASS  %-46s -> never DATA_MISMATCH (kind=%s)"
                  % (label, info.get("kind")))

    # A mismatch must NOT power-cycle die_a: the link is alive and returning
    # wrong data, and a POR destroys the only state that could explain it.
    # A wedge must.
    _v, _d, _i, _r, pors_mismatch = run_t6(res(0, "VERIFY %d/%d ok" % (N - 3, N)))
    _v, _d, _i, _r, pors_wedge = run_t6(res(124, ""))
    if pors_mismatch == 0:
        print("  PASS  %-46s -> no POR" % "data mismatch")
    else:
        failures += 1
        print("  FAIL  data mismatch POR'd die_a (%d times); that destroys the "
              "evidence" % pors_mismatch)
    if pors_wedge == 1:
        print("  PASS  %-46s -> POR'd die_a" % "board wedge (rc=124)")
    else:
        failures += 1
        print("  FAIL  a wedge must POR die_a (got %d PORs)" % pors_wedge)

    # The helper must agree with what the function records, directly.
    for rc, out, want in ((0, "VERIFY %s" % TAG, "PASS"),
                          (0, "VERIFY 1/%d" % N, "FAIL"),
                          (255, "", "INCONCLUSIVE"),
                          (124, "", "FAIL"),
                          (3, "VERIFY 1/%d" % N, "FAIL"),
                          (3, "boom", "INCONCLUSIVE")):
        v, _d, _k = SV.verify_verdict(res(rc, out), N)
        if v == want:
            print("  PASS  verify_verdict(rc=%-3d out=%-18r) -> %s"
                  % (rc, out[:18], v))
        else:
            failures += 1
            print("  FAIL  verify_verdict(rc=%-3d out=%-18r) -> %s (wanted %s)"
                  % (rc, out[:18], v, want))

    total = len(CASES) + 2 + 2 + 6
    if total < 12:
        print("COULD-NOT-EVALUATE: only %d cases" % total)
        return 2
    print("kr260_sysval T6 self-test: %d/%d cases passed" % (total - failures, total))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
