#!/usr/bin/env python3
"""Control for the 0x21F8 witness decode, across every host tool that reads it.

THE GAP THIS CLOSES. rev2/integration added three bits to the packed witness
word in src/rtl/tidelink_top.sv:2178

    [12] sub_wr_hol_stuck_sticky   TL-042 head-of-line WRITE-age watchdog EXPIRED
    [13] xhb_dead_r                TL-044 XHB500 declared DEAD, bounded-error
                                   containment engaged
    [14] xhb_dead_perm_r           TL-044 containment latched PERMANENTLY

and, until 2026-09-11, `grep -rl 'sub_wr_hol\\|xhb_dead' pynq_host` returned
NOTHING. Two watchdogs and a permanent containment latch shipped with no host
tool able to say they had fired. A die running entirely inside TL-044
containment -- every transfer retired with a bounded AHB ERROR, by design --
read HEALTHY, because Region F only sees the FC nodes and the FC nodes are fine
while the XHB500 is parked. That asymmetry IS TL-044's premise, so Region F can
never be the instrument for it.

WHAT IS ASSERTED HERE, against synthetic register words, no board:
  1. every bit of the word decodes at the position the RTL packs it;
  2. the 0xB5 presence marker gates ALL of it -- absent marker gives None
     ("could not evaluate"), never 0 ("healthy");
  3. a set containment bit is a FAULT in health_snapshot's verdict even with a
     spotless Region F;
  4. an absent witness plane is COULD-NOT-EVALUATE, not HEALTHY;
  5. kr260_sysval.healthy() agrees with health_snapshot on the same words --
     the two must not disagree about what "healthy" means;
  6. a board script too old to report the bits is NOT healthy (missing key is
     "cannot tell", not 0).

Run: python3 scripts/ci/tests/test_obs_witness_decode.py
"""

import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "pynq_host" / "scripts"))

os.environ.setdefault("KR260_PASSWORD", "control-harness-not-a-real-password")

from health_snapshot import (  # noqa: E402
    EXIT_COULD_NOT_EVALUATE, EXIT_FAULT, EXIT_HEALTHY,
    WITNESS_MARKER_EXPECTED, decode, evaluate,
)
import kr260_sysval as SV  # noqa: E402

# The packed word, exactly as src/rtl/tidelink_top.sv:2178 builds it:
#   { 8'hB5, 9'h0, xhb_dead_perm_r, xhb_dead_r, sub_wr_hol_stuck_sticky,
#     ext_stall_err_q, xhb_stall_stuck_sticky, sub_err_sticky,
#     sub_wr_stuck_sticky, sub_wr_os_hwm, pipe_hprot_r[2], sub_wr_os_ctr,
#     xhb_sub_hreadyout_raw }
BITS = {"hreadyout": 0, "synth_b": 8, "wr_err": 9, "stall_stuck": 10,
        "ext_stall_err": 11, "wr_hol_stuck": 12, "xhb_dead": 13,
        "xhb_dead_perm": 14}


def word(marker=WITNESS_MARKER_EXPECTED, hreadyout=1, wr_os=0, hwm=0, **bits):
    v = ((marker & 0xFF) << 24) | ((hwm & 7) << 5) | ((wr_os & 7) << 1) \
        | (hreadyout & 1)
    for name, val in bits.items():
        v |= (val & 1) << BITS[name]
    return v


def swi(fcsm=4, cal=1):
    return ((fcsm & 7) << 17) | ((cal & 1) << 16) | (1 << 23) | (1 << 24)


def rf(marker=0xAD, healthy=1):
    return ((marker & 0xFF) << 24) | ((healthy & 1) << 23)


def obs_json(wt, regf_ok=True, drop=()):
    """What eth_sysval_board.py's `obs` mode emits for this witness word."""
    present = ((wt >> 24) & 0xFF) == WITNESS_MARKER_EXPECTED
    o = {"fcsm": 4, "cal": 1, "regf_present": regf_ok, "data_healthy": 1,
         "wedge_tgt": 0, "wedge_ini": 0,
         "witness_raw": "0x%08x" % wt, "witness_present": present}
    for name, pos in BITS.items():
        o[name] = (wt >> pos) & 1 if present else None
    for k in drop:
        o.pop(k, None)
    return o


LABELS = {EXIT_HEALTHY: "HEALTHY(0)", EXIT_FAULT: "FAULT(1)",
          EXIT_COULD_NOT_EVALUATE: "COULD-NOT-EVALUATE(2)"}


def main():
    failures = 0

    def check(label, got, want):
        nonlocal failures
        if got == want:
            print("  PASS  %-56s -> %r" % (label, got))
        else:
            failures += 1
            print("  FAIL  %-56s -> %r (wanted %r)" % (label, got, want))

    # (1) bit positions, one at a time, so a transposed pair cannot hide.
    for name, pos in sorted(BITS.items(), key=lambda kv: kv[1]):
        d = decode(swi(), 0, 4096, 0, rf(), word(**{name: 1}))
        check("0x21F8[%2d] decodes as %s" % (pos, name), d[name], 1)
        others = [k for k in BITS if k != name]
        kw = {"hreadyout": 0}
        kw[name] = 1
        d0 = decode(swi(), 0, 4096, 0, rf(), word(**kw))
        bleed = [k for k in others if d0[k]]
        check("0x21F8[%2d] %s does not bleed into another field" % (pos, name),
              bleed, [])

    # multi-field word: hwm and wr_os are 3-bit and sit under the sticky bits.
    d = decode(swi(), 0, 4096, 0, rf(),
               word(wr_os=5, hwm=7, xhb_dead=1, xhb_dead_perm=1, wr_hol_stuck=1))
    check("wr_os=5 alongside the containment bits", d["wr_os"], 5)
    check("wr_hwm=7 alongside the containment bits", d["wr_hwm"], 7)
    check("xhb_dead / perm / wr_hol together",
          (d["xhb_dead"], d["xhb_dead_perm"], d["wr_hol_stuck"]), (1, 1, 1))

    # (2) the marker gates everything. ABSENT must be None, never 0.
    d = decode(swi(), 0, 4096, 0, rf(), word(marker=0x00, xhb_dead=1))
    check("marker absent -> wt_present False", d["wt_present"], False)
    for name in BITS:
        check("marker absent -> %s is None, not 0" % name, d[name], None)
    d = decode(swi(), 0, 4096, 0, rf(), word(marker=0x5A))
    check("wrong marker (0x5A) -> wt_present False", d["wt_present"], False)

    # (3)/(4) the verdict. Region F is spotless in every one of these.
    for label, w, want in (
            ("quiet witness", word(), EXIT_HEALTHY),
            ("xhb_dead=1", word(xhb_dead=1), EXIT_FAULT),
            ("xhb_dead_perm=1", word(xhb_dead_perm=1), EXIT_FAULT),
            ("wr_hol_stuck=1", word(wr_hol_stuck=1), EXIT_FAULT),
            ("stall_stuck=1", word(stall_stuck=1), EXIT_FAULT),
            ("synth_b=1", word(synth_b=1), EXIT_FAULT),
            ("wr_err=1", word(wr_err=1), EXIT_FAULT),
            ("ext_stall_err=1", word(ext_stall_err=1), EXIT_FAULT),
            ("marker absent", word(marker=0x00), EXIT_COULD_NOT_EVALUATE)):
        rc, _lbl, _r = evaluate(decode(swi(), 0, 4096, 0, rf(), w))
        check("verdict, clean Region F + %s" % label, LABELS[rc], LABELS[want])

    # the explicit opt-out works, and does not read as HEALTHY to a grepper.
    rc, lbl, _r = evaluate(decode(swi(), 0, 4096, 0, rf(), word(marker=0x00)),
                           allow_missing_witness=True)
    check("--allow-missing-witness -> exit 0", rc, EXIT_HEALTHY)
    check("--allow-missing-witness label does not contain HEALTHY",
          "HEALTHY" in lbl, False)
    # ... and must not launder a real containment fault.
    rc, _lbl, _r = evaluate(decode(swi(), 0, 4096, 0, rf(), word(xhb_dead=1)),
                            allow_missing_witness=True)
    check("--allow-missing-witness still FAULTs on xhb_dead=1",
          LABELS[rc], LABELS[EXIT_FAULT])

    # (5) kr260_sysval.healthy() must agree with health_snapshot.
    for label, w, want in (("quiet witness", word(), True),
                           ("xhb_dead=1", word(xhb_dead=1), False),
                           ("xhb_dead_perm=1", word(xhb_dead_perm=1), False),
                           ("wr_hol_stuck=1", word(wr_hol_stuck=1), False),
                           ("marker absent", word(marker=0x00), False)):
        check("kr260_sysval.healthy(), %s" % label,
              SV.healthy(obs_json(w)), want)

    # (6) a board script too old to report the bits is NOT healthy.
    stale = obs_json(word(), drop=("xhb_dead", "xhb_dead_perm", "wr_hol_stuck"))
    check("stale board script (keys missing) -> not healthy",
          SV.healthy(stale), False)
    reasons = SV.witness_faults(stale)
    check("... and says WHY (names the stale board script)",
          any("stale" in r for r in reasons), True)
    check("witness_faults() names TL-044 when xhb_dead is set",
          any("TL-044" in r for r in SV.witness_faults(obs_json(word(xhb_dead=1)))),
          True)
    check("witness_faults() is empty on a quiet, present plane",
          SV.witness_faults(obs_json(word())), [])

    total = 2 * len(BITS) + 3 + 2 + len(BITS) + 9 + 3 + 5 + 4
    print("obs witness decode self-test: %d checks, %d failed" % (total, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
