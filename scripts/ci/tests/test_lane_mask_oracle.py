#!/usr/bin/env python3
"""Red/green control for the lane-mask byte-exact oracle (false-green B3).

`cocotb/tidelink_top_pair_v2/test_v2_lane_mask_sweep.py::test_00_oracle_selftest`
exists to prove the suite's oracle can produce a FAILING verdict. Until
2026-08-26 it could not: it computed the byte-exact result and never read it,
and its all-zeros guard compared the EXPECTED packet (nonzero header) against
zero, so it was a compile-time False. On the all-zeros RX signature the suite's
own header names, test_00 passed.

The verdict now lives in a pure function. This harness drives that function
with invented specimens — no simulator, no DUT — and asserts each one is
caught. Run:

    python3 scripts/ci/tests/test_lane_mask_oracle.py
"""

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "cocotb" / "tidelink_top_pair_v2"))

from lane_mask_oracle import (  # noqa: E402
    INJECTIONS, inject_specimen, oracle_verdict,
)

# The real packet shape make_packet() produces for PAYLOAD_M2S. Note words[1]
# is genuinely 0x00000000, which is why a per-word "is it zero" check is not a
# sufficient all-zeros guard and the whole-vector check is used instead.
WORDS = [0x00240000, 0x00000000, 0xCAFE0001, 0xCAFE0002]

CASES = [
    # (label, got, words, must_be_caught, substring)
    ("byte-exact RX", list(WORDS), WORDS, False, ""),

    # THE B3 SPECIMEN: the signature the suite exists to catch, on which the
    # pre-fix test_00 passed.
    ("all-zeros RX", [0, 0, 0, 0], WORDS, True, "RX IS ALL ZEROS"),

    ("bit-inverted RX", [w ^ 0xFFFFFFFF for w in WORDS], WORDS, True,
     "bit-inverted expectation"),
    ("one word wrong", [0x00240000, 0, 0xCAFE0001, 0xDEADBEEF], WORDS, True,
     "NOT BYTE-EXACT"),
    ("word-shifted RX", [0x00000000, 0xCAFE0001, 0xCAFE0002, 0], WORDS, True,
     "NOT BYTE-EXACT"),
    ("short read", [0x00240000, 0, 0xCAFE0001], WORDS, True,
     "COULD-NOT-EVALUATE"),
    ("no read at all", None, WORDS, True, "COULD-NOT-EVALUATE"),

    # Instrument faults: an expectation that cannot discriminate.
    ("expected packet all zeros", [0, 0, 0, 0], [0, 0, 0, 0], True,
     "expected packet is itself all-zeros"),
    ("expected packet uniform", [7, 7, 7, 7], [7, 7, 7, 7], True,
     "every expected word is identical"),
]


def main():
    failures = 0
    for label, got, words, must_be_caught, want in CASES:
        problems = oracle_verdict(got, words)
        caught = bool(problems)
        ok = (caught == must_be_caught) and (
            not must_be_caught or any(want in p for p in problems))
        if ok:
            print("  PASS  %-26s -> %s" % (label, "RED" if caught else "GREEN"))
        else:
            failures += 1
            print("  FAIL  %-26s -> %s (wanted %s)"
                  % (label, "RED" if caught else "GREEN",
                     "RED" if must_be_caught else "GREEN"))
            for p in problems:
                print("        %s" % p)
            if must_be_caught and not any(want in p for p in problems):
                print("        expected text not found: %r" % want)

    # Every injection the suite offers must actually produce a red verdict,
    # or the end-to-end control hook would be decoration too.
    for kind in INJECTIONS:
        got = inject_specimen(kind, list(WORDS), WORDS)
        problems = oracle_verdict(got, WORDS)
        if problems:
            print("  PASS  injection %-16s -> RED" % kind)
        else:
            failures += 1
            print("  FAIL  injection %-16s -> GREEN (must be RED)" % kind)

    total = len(CASES) + len(INJECTIONS)
    if total < 10:
        print("COULD-NOT-EVALUATE: only %d cases" % total)
        return 2
    print("lane_mask_oracle self-test: %d/%d cases passed"
          % (total - failures, total))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
