#!/usr/bin/env python3
"""Fail loudly when `urg` SILENTLY DISCARDED coverage databases during a merge.

WHY THIS EXISTS (2026-08-26)
    The first merged coverage database this project ever had reported
    src/rtl/tidelink_addr_translator.sv as its WORST-covered shipping file:
    35.29% line, 20.00% branch.  Run on its own, the bench that targets that
    file -- cocotb/tidelink_addr_translator, 34 tests, all passing, present in
    the merge input list -- puts the SAME file at 100.00% line / 80.00% branch.

    urg had thrown its data away.  When two coverage databases come from
    designs whose top-level module has the same NAME but a different SHAPE --
    and in this repository essentially every bench's top level is called
    `tb_top` -- urg keeps ONE design for that name and, for every other
    database, prints

        Warning-[UCAPI-INSTANCEMISMATCH] Instance Data Mismatch
          ... is not the same as in base design.
          Coverage data of this instance won't be merged.

    and drops it.  The 2026-08-26 whole-corpus merge printed 1326 of these.
    The merged report is therefore an UNDER-report of unknown size, and every
    "no test executes this" claim drawn from it is only as strong as whichever
    design happened to win the `tb_top` name.

    Reversing the -dir order reverses which data survives.  That is the tell:
    a measurement whose answer depends on argument order is not a measurement.

WHAT THIS DOES NOT DO
    It does not fix the merge.  Fixing it means either giving each bench a
    distinct top-level module name, or merging per-design and reporting per
    design instead of pretending one number spans them.  This script exists so
    that the number is never QUIETLY believed again: the failure is now loud,
    named, and counted, and the list of discarded databases is an artifact.

Usage:
    coverage_merge_integrity.py --log imp/coverage/urg_merge.log \
                                [--out imp/coverage_report/merge_dropped.txt] \
                                [--allow-drops]
Exit status:
    0  no database was discarded (or --allow-drops given)
    1  urg discarded coverage data
    2  the log could not be read
"""
import argparse
import os
import re
import sys
from collections import defaultdict

# urg emits one of these per (database, instance, metric) it refuses to merge.
DROP_TAGS = (
    "UCAPI-INSTANCEMISMATCH",
    "UCAPI-INSTANCE-SHAPEMISMATCH",
    "UCAPI-MISSINGINST",
)

_INST_RE = re.compile(r"for instance '([^']+)'")
_DIR_RE = re.compile(r"directory\s+'([^']+)'")
_TESTFILE_RE = re.compile(r"test file\s+'([^']+)'")


def scan(path):
    """Return {database: {instance: count}} for every discarded record."""
    with open(path, "r", errors="replace") as fh:
        text = fh.read()

    dropped = defaultdict(lambda: defaultdict(int))
    total = 0
    # Each warning is a short block; split on the tag and read the block that
    # follows it.  urg wraps lines, so join the block before matching.
    for tag in DROP_TAGS:
        for chunk in text.split("Warning-[%s]" % tag)[1:]:
            block = " ".join(chunk.split("\n")[:10])
            inst = _INST_RE.search(block)
            db = _DIR_RE.search(block) or _TESTFILE_RE.search(block)
            dropped[db.group(1) if db else "<unknown database>"][
                inst.group(1) if inst else "<unknown instance>"
            ] += 1
            total += 1
    return dropped, total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True, help="urg merge log")
    ap.add_argument("--out", help="write the discarded-database list here")
    ap.add_argument("--allow-drops", action="store_true",
                    help="report but do not fail (for a knowingly-mixed merge)")
    args = ap.parse_args()

    if not os.path.exists(args.log):
        print("[merge-integrity] ERROR: no urg log at %s" % args.log)
        return 2

    dropped, total = scan(args.log)

    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "w") as fh:
            fh.write("# Coverage databases whose data urg DISCARDED during the merge.\n")
            fh.write("# Any 'no test executes this' claim over this merge is an\n")
            fh.write("# UNDER-report by at least the coverage these databases carried.\n")
            fh.write("# records: %d\n\n" % total)
            for db in sorted(dropped):
                fh.write("%s\n" % db)
                for inst, n in sorted(dropped[db].items()):
                    fh.write("    %-40s %d records\n" % (inst, n))
        print("[merge-integrity] wrote %s" % args.out)

    if total == 0:
        print("[merge-integrity] PASS — urg merged every database "
              "(no UCAPI-*MISMATCH / MISSINGINST records)")
        return 0

    print("[merge-integrity] ==================================================")
    print("[merge-integrity] urg DISCARDED coverage data: %d records, "
          "%d databases" % (total, len(dropped)))
    for db in sorted(dropped)[:12]:
        print("[merge-integrity]   %s" % db)
    if len(dropped) > 12:
        print("[merge-integrity]   ... and %d more" % (len(dropped) - 12))
    print("[merge-integrity]")
    print("[merge-integrity] The merged report is an UNDER-report of unknown")
    print("[merge-integrity] size.  Do not publish an 'unexercised RTL' list")
    print("[merge-integrity] from it without re-checking each finding against")
    print("[merge-integrity] the PER-DATABASE reports:")
    print("[merge-integrity]     for v in imp/coverage/*.vdb; do \\")
    print("[merge-integrity]       urg -full64 -dir $v -metric fsm \\")
    print("[merge-integrity]           -format text -report /tmp/r/$(basename $v); done")
    print("[merge-integrity] Root cause: benches share the top-level module name")
    print("[merge-integrity] 'tb_top' with different shapes, so urg keeps one")
    print("[merge-integrity] design for that name and drops the rest.  Reversing")
    print("[merge-integrity] the -dir order reverses which data survives.")
    print("[merge-integrity] ==================================================")
    return 0 if args.allow_drops else 1


if __name__ == "__main__":
    sys.exit(main())
