#!/usr/bin/env python3
"""Red/green control for kr260_sysval T6_endurance (false-green C4).

`pynq_host/scripts/kr260_sysval.py:220-223` ended T6 with

    rc, out = board(B, "verify %d 0x%08X" % (min(step, ENDUR_BEATS), base), 60)
    record("T6_endurance", "PASS", "%d beats, die_a alive, ..." % ENDUR_BEATS)

`rc` and `out` were dead at function end. The delivery check ran and its answer
was thrown away; PASS was recorded unconditionally. T6 could not report a
delivery failure at all — and it writes a JSON verdict artefact that other
people read as evidence.

T6's dependencies are now injectable, so this harness runs the whole function
against a FAKE board with no hardware, no ssh and no KR260, and asserts the
recorded verdict.

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

HEALTHY_OBS = {"fcsm": 4, "cal": 1, "regf_present": True, "data_healthy": 1,
               "wedge_tgt": 0, "wedge_ini": 0}


def run_t6(verify_rc, verify_out):
    """Drive t6_endurance with a fake board and return (verdict, detail, ret)."""
    recorded = []
    pors = []

    def fake_board(host, args, timeout=40):
        if args.startswith("write"):
            return 0, "WRITE ok"
        if args.startswith("verify"):
            return verify_rc, verify_out
        raise AssertionError("unexpected board call %r" % args)

    ret = SV.t6_endurance(
        base=0xC7C70000,
        board_fn=fake_board,
        obs_fn=lambda host: dict(HEALTHY_OBS),
        por_fn=lambda: pors.append(1),
        record_fn=lambda n, v, d: recorded.append((n, v, d)))

    assert len(recorded) == 1, "expected exactly one record(), got %r" % recorded
    name, verdict, detail = recorded[0]
    return verdict, detail, ret


N = int(os.environ["SYSVAL_ENDUR_BEATS"])

CASES = [
    # (label, verify rc, verify stdout, expected verdict, expected return)
    ("clean delivery",           0, "VERIFY %d/%d ok" % (N, N), "PASS", True),

    # THE C4 SPECIMEN: the board reports a real byte mismatch. Pre-fix this
    # was recorded as PASS.
    ("delivery mismatch",        0, "VERIFY %d/%d ok" % (N - 3, N), "FAIL", False),
    ("board printed nothing",    0, "", "FAIL", False),

    ("board timeout (rc=124)", 124, "", "FAIL", False),

    # rc=255 with no output is an ssh reset, not a data mismatch. Calling it
    # FAIL is the 2026-08-24 false-red that cost weeks.
    ("ssh reset (rc=255, no output)", 255, "", "INCONCLUSIVE", False),
    ("other rc, some output",       3, "boom", "INCONCLUSIVE", False),
]


def main():
    failures = 0
    for label, rc, out, want_verdict, want_ret in CASES:
        verdict, detail, ret = run_t6(rc, out)
        ok = (verdict == want_verdict) and (ret is want_ret)
        if ok:
            print("  PASS  %-32s -> %s" % (label, verdict))
        else:
            failures += 1
            print("  FAIL  %-32s -> %s / ret=%r (wanted %s / %r)"
                  % (label, verdict, ret, want_verdict, want_ret))
            print("        detail: %s" % detail)

    # The pure verdict helper must agree with what the function records.
    for rc, out, want in ((0, "VERIFY %d/%d" % (N, N), "PASS"),
                          (0, "VERIFY 1/%d" % N, "FAIL"),
                          (255, "", "INCONCLUSIVE"),
                          (124, "", "FAIL")):
        v, _d = SV.verify_verdict(rc, out, N)
        if v == want:
            print("  PASS  verify_verdict(rc=%-3d) -> %s" % (rc, v))
        else:
            failures += 1
            print("  FAIL  verify_verdict(rc=%-3d) -> %s (wanted %s)" % (rc, v, want))

    total = len(CASES) + 4
    if total < 8:
        print("COULD-NOT-EVALUATE: only %d cases" % total)
        return 2
    print("kr260_sysval T6 self-test: %d/%d cases passed" % (total - failures, total))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
