#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - shared PASS/FAIL/COULD-NOT-EVALUATE verdict for the
# PYNQ host test scripts.
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
"""One place that turns a (passed, failed) tally into a process exit code.

FALSE-GREEN C11. `pynq_host/test_loopback_pair.py` and
`pynq_host/test_single_instance.py` computed a `failed` counter, printed it,
and then ended. Neither contained a single `exit`/`sys.exit` call, so both
always exited 0: every caller, wrapper and CI step that checked `$?` read a
board with failing hardware checks as a pass. `test_td_artifact.py:208` had the
correct pattern (`sys.exit(1 if FAIL else 0)`) all along.

Three verdicts, because collapsing the third into PASS is the bug class:

    0  PASS                  at least one check ran and none failed
    1  FAIL                  one or more checks failed
    2  COULD-NOT-EVALUATE    zero checks ran -- the script reached the end
                             without exercising anything (import bailed, the
                             rig was absent, an early branch skipped the body).
                             A test that ran nothing has not passed.
"""

import sys

EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_COULD_NOT_EVALUATE = 2


def verdict(passed, failed):
    """Pure: (passed, failed) -> exit code. No printing, no exiting."""
    if failed:
        return EXIT_FAIL
    if passed <= 0:
        return EXIT_COULD_NOT_EVALUATE
    return EXIT_PASS


def summarise_and_exit(passed, failed, name="", out=print, exit_fn=sys.exit):
    """Print the tally, then exit with the code `verdict()` gives.

    `out` and `exit_fn` are injectable so the control test can drive this
    without terminating its own process.
    """
    rc = verdict(passed, failed)
    label = {
        EXIT_PASS: "PASS",
        EXIT_FAIL: "FAIL",
        EXIT_COULD_NOT_EVALUATE: "COULD-NOT-EVALUATE",
    }[rc]
    out("\n" + "=" * 60)
    out("Results%s: %d passed, %d failed" % (" [%s]" % name if name else "",
                                             passed, failed))
    if rc == EXIT_COULD_NOT_EVALUATE:
        out("NO CHECKS RAN — this is NOT a pass. Exiting %d." % rc)
    out("VERDICT: %s (exit %d)" % (label, rc))
    out("=" * 60)
    return exit_fn(rc)
