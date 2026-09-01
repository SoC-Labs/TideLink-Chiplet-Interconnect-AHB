#!/usr/bin/env python3
"""Red/green control for health_snapshot.py's verdict (false-green C3).

`pynq_host/scripts/health_snapshot.py:31-32` computed

    ok = (fcsm == 4 and cal and sticky == 0 and not fe_full
          and (not present or (healthy_bit and tgt_ws == 0 and ini_ws == 0)))

`not present` — the Region-F 0xAD marker being ABSENT, i.e. "the AXI-node obs
plane could not be read at all" — made the whole Region-F term TRUE, so the
script printed HEALTHY and exited 0 while half its verdict was unreadable. Its
own header promised "Exit 0 if healthy, 1 if a fault bit is set (CI-usable)".
The fail-closed form was already in a sibling in the same directory,
kr260_recover_gate.py:110-111.

This harness drives the (now pure) verdict with invented register words. No
/dev/mem, no board.

Run: python3 scripts/ci/tests/test_health_snapshot.py
"""

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "pynq_host" / "scripts"))

from health_snapshot import (  # noqa: E402
    EXIT_COULD_NOT_EVALUATE, EXIT_FAULT, EXIT_HEALTHY, decode, evaluate,
)


def swi(fcsm=4, cal=1, fe_full=0, cr=1, crack=1):
    return ((fcsm & 7) << 17) | ((cal & 1) << 16) | ((cr & 1) << 23) \
        | ((crack & 1) << 24) | ((fe_full & 1) << 31)


def rf(marker=0xAD, healthy=1, tgt_ws=0, ini_ws=0):
    return ((marker & 0xFF) << 24) | ((healthy & 1) << 23) \
        | ((tgt_ws & 0x1F) << 15 if False else 0) \
        | ((tgt_ws & 0x1F) << 10) | ((ini_ws & 0x1F) << 15)


CASES = [
    # (label, swi, status, regf, allow_missing, expected exit)
    ("all good, Region-F present+healthy",
     swi(), 0x0, rf(), False, EXIT_HEALTHY),

    # THE C3 SPECIMEN: everything else clean, Region-F marker ABSENT.
    # Pre-fix this exited 0 announcing HEALTHY.
    ("Region-F marker absent -> COULD-NOT-EVALUATE",
     swi(), 0x0, rf(marker=0x00), False, EXIT_COULD_NOT_EVALUATE),
    ("Region-F marker wrong value -> COULD-NOT-EVALUATE",
     swi(), 0x0, rf(marker=0x5A), False, EXIT_COULD_NOT_EVALUATE),

    # ... and the explicit opt-out still works, but only when asked for.
    ("Region-F absent + --allow-missing-regionf -> exit 0",
     swi(), 0x0, rf(marker=0x00), True, EXIT_HEALTHY),

    # Real faults must still be FAULT, not COULD-NOT-EVALUATE.
    ("data_healthy=0", swi(), 0x0, rf(healthy=0), False, EXIT_FAULT),
    ("tgt wedge-sticky", swi(), 0x0, rf(tgt_ws=0x3), False, EXIT_FAULT),
    ("ini wedge-sticky", swi(), 0x0, rf(ini_ws=0x1), False, EXIT_FAULT),
    ("fcsm != 4", swi(fcsm=7), 0x0, rf(), False, EXIT_FAULT),
    ("cal_done = 0", swi(cal=0), 0x0, rf(), False, EXIT_FAULT),
    ("STATUS sticky set", swi(), 0x4, rf(), False, EXIT_FAULT),
    ("fe_rx_full = 1", swi(fe_full=1), 0x0, rf(), False, EXIT_FAULT),

    # A fault elsewhere is decisive even when Region-F is unreadable: FAULT
    # outranks COULD-NOT-EVALUATE.
    ("fcsm bad AND Region-F absent -> FAULT",
     swi(fcsm=0), 0x0, rf(marker=0x00), False, EXIT_FAULT),
    # ... and --allow-missing-regionf must not launder a real fault.
    ("fcsm bad AND Region-F absent AND --allow -> still FAULT",
     swi(fcsm=0), 0x0, rf(marker=0x00), True, EXIT_FAULT),
]

LABELS = {EXIT_HEALTHY: "HEALTHY(0)", EXIT_FAULT: "FAULT(1)",
          EXIT_COULD_NOT_EVALUATE: "COULD-NOT-EVALUATE(2)"}


def main():
    failures = 0
    for label, s, st, r, allow, want in CASES:
        d = decode(s, st, 4096, 0, r)
        rc, verdict_label, reasons = evaluate(d, allow_missing_regionf=allow)
        if rc == want:
            print("  PASS  %-52s -> %s" % (label, LABELS[rc]))
        else:
            failures += 1
            print("  FAIL  %-52s -> %s (wanted %s)"
                  % (label, LABELS[rc], LABELS[want]))
            print("        verdict=%r reasons=%r" % (verdict_label, reasons))

    # The opt-out label must NOT contain the string consumers grep for.
    d = decode(swi(), 0x0, 4096, 0, rf(marker=0x00))
    _rc, lbl, _r = evaluate(d, allow_missing_regionf=True)
    if "HEALTHY" in lbl:
        failures += 1
        print("  FAIL  --allow-missing-regionf label %r contains 'HEALTHY'; "
              "consumers match `\"RESULT: HEALTHY\" in out`" % lbl)
    else:
        print("  PASS  --allow-missing-regionf label (%r) does not read as HEALTHY"
              % lbl)

    total = len(CASES) + 1
    if total < 10:
        print("COULD-NOT-EVALUATE: only %d cases" % total)
        return 2
    print("health_snapshot self-test: %d/%d cases passed" % (total - failures, total))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
