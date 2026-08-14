#!/usr/bin/env python3
# =============================================================================
# anchor_pair_gate.py — the ANCHOR-PAIR RETRY GATE predicate, in one place.
#
# WHAT THIS DECIDES
# -----------------
# After a concurrent two-die bring-up, look at the PAIR of autonomous re-anchor
# verdicts (EPOCH_STATUS 0x2140 bit0, one per die) and answer one question:
#
#     is this bring-up worth sending payload over, or should we re-roll it?
#
# THE MEASUREMENT IT IS BUILT ON (n=20, imp/hw_gate/overnight/, 2026-08-13)
# ------------------------------------------------------------------------
# Cross-die delivery on the baseline build was 17/20 byte-exact. The 3 failures
# were EXACTLY the runs where die_a re-anchored and die_b did not:
#
#     anchor die_a/die_b | runs | delivery
#     -------------------+------+-----------------
#     YES / YES          |   5  | all 16/16
#     NO  / NO           |   8  | all 16/16
#     NO  / YES          |   4  | all 16/16
#     YES / NO           |   3  | all  0/16   <-- the whole failure population
#
# So re-anchoring is NOT required for delivery, and asymmetry alone is not the
# fault — only that ONE direction is. `fcsm=4` was true in all 20 runs, so the
# pre-existing health check (FCSM==4 && cal_done) cannot see this at all.
#
# WHY THIS IS A RETRY CONDITION AND NOT A SILICON FIX
# ---------------------------------------------------
# Both bits are readable BEFORE any payload is sent, and a bring-up is a
# PRECONDITION of a measurement, not the measurement itself. Re-rolling it costs
# ~15 s and re-runs winscan = a fresh eye. So the cheap mitigation is: detect the
# YES/NO pair, throw the bring-up away, try again. No netlist change.
#
# WHAT THIS IS *NOT*
# ------------------
#   * NOT a proven mechanism. n=3 on the failing arm. Three-for-three is
#     suggestive, not settled.
#   * The campaign CANNOT separate predictor from symptom. The live hypothesis is
#     anchor-as-WITNESS: `reanchored=1` with an all-zero `lane_off` is
#     bit-identical on the datapath to `reanchored=0`, so the anchor bit may be
#     reporting a condition rather than causing one.
#   * Consequently every accept is provisional and every retry MUST be logged.
#     A "works ~100%" claim from this gate is only honest when it carries its
#     retry cost alongside it.
#
# WHY NOT SWI_LANE_STATUS — do not "improve" this by adding those bits
# --------------------------------------------------------------------
# Bits [29]/[25] of SWI_LANE_STATUS are `llrx_valid` / `is_short_pkt`: free-running
# Wlink RX packet-classification samples, not anchor state (and [29] is [25]
# delayed one clock — one observation, not two). Retrospectively, gating on the
# bring-up-time `0x27890000` sample would have flagged runs 06/17/18 — all three
# of which DELIVERED — and caught none of 09/15/19. See
# imp/hw_gate/status_decode/SWI_LANE_STATUS_DECODE_2026_08_14.md.
#
# USAGE
# -----
#   # decide from two bring-up logs (what the orchestrator calls):
#   anchor_pair_gate.py --log-a bu_a.log --log-b bu_b.log [--mode pair|both|off]
#     exit 0  = ACCEPT (proceed to payload)
#     exit 10 = REJECT (re-roll the bring-up)
#     exit 11 = UNKNOWN (logs unparseable — fail closed, treated as re-roll)
#
#   # decide from explicit bits (for tests / retrospective replay):
#   anchor_pair_gate.py --pair 1,0
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import re
import sys

# --- verdicts ---------------------------------------------------------------
ACCEPT = "ACCEPT"
REJECT = "REJECT"
UNKNOWN = "UNKNOWN"

RC = {ACCEPT: 0, REJECT: 10, UNKNOWN: 11}

# --- modes ------------------------------------------------------------------
#   pair : the anchor-pair gate. Reject ONLY die_a=YES & die_b=NO. This is the
#          measured predicate: it accepts the 17/20 that delivered and rejects
#          the 3/3 that did not.
#   both : the LEGACY accept test already in kr260_eth_bringup_pair.sh — require
#          both dies re-anchored. Strictly safe w.r.t. the n=20 evidence, but it
#          rejects 15/20 bring-ups that would have delivered perfectly well, so
#          at the measured p(both)=0.25 an 8-try budget still fails ~10% of the
#          time. Kept so the old behaviour is one env var away.
#   off  : no anchor gate at all (link-up only). Reproduces the 08-13 baseline
#          measurement conditions, where every lottery number was taken with
#          retry switched OFF. Use this and ONLY this when generating numbers
#          that must be comparable to that campaign.
MODES = ("pair", "both", "off")


def classify(a_reanchored, b_reanchored, a_linkup=True, b_linkup=True,
             mode="pair"):
    """Return (verdict, reason). Inputs may be 0, 1 or None (=unknown).

    Fail-closed: any unknown input yields UNKNOWN, never ACCEPT. An unreadable
    bring-up log means we do not know the pair state, and "we do not know" must
    never be spelled the same way as "we checked and it is good".
    """
    if mode not in MODES:
        raise ValueError("mode %r not in %r" % (mode, MODES))

    # Link-up is a precondition for every mode, including `off`: a die that never
    # reached FCSM=4 has no anchor verdict to interpret.
    if a_linkup is None or b_linkup is None:
        return UNKNOWN, "link-up verdict missing for one or both dies"
    if not a_linkup or not b_linkup:
        return REJECT, ("no LINK UP (die_a=%s die_b=%s) — bring-up lottery miss"
                        % (_yn(a_linkup), _yn(b_linkup)))

    if mode == "off":
        return ACCEPT, "anchor gate DISABLED (mode=off) — link-up only"

    if a_reanchored is None or b_reanchored is None:
        return UNKNOWN, ("anchor verdict missing (die_a=%s die_b=%s)"
                         % (_yn(a_reanchored), _yn(b_reanchored)))

    pair = "%s/%s" % (_yn(a_reanchored), _yn(b_reanchored))

    if mode == "both":
        if a_reanchored and b_reanchored:
            return ACCEPT, "anchor pair %s (mode=both: both re-anchored)" % pair
        return REJECT, "anchor pair %s (mode=both requires YES/YES)" % pair

    # mode == "pair" — the measured predicate.
    if a_reanchored and not b_reanchored:
        return REJECT, ("anchor pair %s — die_a re-anchored, die_b did NOT. "
                        "This is the only pair that failed delivery in the n=20 "
                        "campaign (3/3 at 0/16). Re-roll the bring-up." % pair)
    return ACCEPT, ("anchor pair %s — not the YES/NO reject pair "
                    "(delivered 17/17 in the n=20 campaign)" % pair)


def _yn(v):
    return "?" if v is None else ("YES" if v else "NO")


# --- log parsing ------------------------------------------------------------
# The bring-up recipe (kr260_eth_bringup.py) emits exactly one of these RESULT
# lines per run, plus — since 8d71ee2 — the full EPOCH_STATUS word.
_RE_REANCHORED = re.compile(r"^RESULT: RE-ANCHORED", re.M)
_RE_NOT_REANCH = re.compile(r"^RESULT: LINK UP but NOT RE-ANCHORED", re.M)
_RE_LINKUP = re.compile(r"^RESULT: LINK UP", re.M)
_RE_NOTCONV = re.compile(r"^RESULT: NOT converged", re.M)
# "    EPOCH_STATUS = 0x00000001 (reanchored=1 sr_span_meas=0)"   [post-8d71ee2]
_RE_EPOCH = re.compile(
    r"EPOCH_STATUS\s*=\s*(0x[0-9a-fA-F]+)\s*\(reanchored=(\d)\s+sr_span_meas=(\d+)\)")


def parse_bringup_log(text):
    """Extract one die's bring-up verdict from its log text.

    Returns a dict: linkup, reanchored (0/1/None), epoch_raw, sr_span_meas,
    and `anomaly` (str or None) if the RESULT line and the EPOCH_STATUS word
    disagree — which would mean the log is not self-consistent and the caller
    should not trust either.

    Takes the LAST occurrence of each marker, so a log that accumulated several
    attempts resolves to the most recent one.
    """
    out = {"linkup": None, "reanchored": None, "epoch_raw": None,
           "sr_span_meas": None, "anomaly": None}

    reanch_hits = list(_RE_REANCHORED.finditer(text))
    notreanch_hits = list(_RE_NOT_REANCH.finditer(text))
    linkup_hits = list(_RE_LINKUP.finditer(text))
    notconv_hits = list(_RE_NOTCONV.finditer(text))

    # Latest of the terminal verdicts wins.
    terminal = []
    if reanch_hits:
        terminal.append((reanch_hits[-1].start(), "reanchored"))
    if notreanch_hits:
        terminal.append((notreanch_hits[-1].start(), "linkup_no_anchor"))
    if notconv_hits:
        terminal.append((notconv_hits[-1].start(), "not_converged"))
    if not terminal:
        # No terminal verdict at all: crashed, timed out, or truncated.
        if linkup_hits:
            out["linkup"] = True
        return out
    terminal.sort()
    _, kind = terminal[-1]
    if kind == "reanchored":
        out["linkup"], out["reanchored"] = True, 1
    elif kind == "linkup_no_anchor":
        out["linkup"], out["reanchored"] = True, 0
    else:
        out["linkup"], out["reanchored"] = False, None

    ep = list(_RE_EPOCH.finditer(text))
    if ep:
        m = ep[-1]
        out["epoch_raw"] = int(m.group(1), 16)
        out["sr_span_meas"] = int(m.group(3))
        word_rea = int(m.group(2))
        if out["reanchored"] is not None and word_rea != out["reanchored"]:
            out["anomaly"] = (
                "RESULT line says reanchored=%d but EPOCH_STATUS word says %d"
                % (out["reanchored"], word_rea))
    return out


def parse_bringup_file(path):
    try:
        with open(path, "r", errors="replace") as f:
            return parse_bringup_log(f.read())
    except OSError as e:
        return {"linkup": None, "reanchored": None, "epoch_raw": None,
                "sr_span_meas": None, "anomaly": "unreadable: %s" % e}


def gate_from_logs(path_a, path_b, mode="pair"):
    """Full decision from two bring-up log files. Returns (verdict, reason, a, b)."""
    a = parse_bringup_file(path_a)
    b = parse_bringup_file(path_b)
    if a["anomaly"] or b["anomaly"]:
        return (UNKNOWN,
                "log unreadable or self-inconsistent (die_a: %s | die_b: %s)"
                % (a["anomaly"] or "ok", b["anomaly"] or "ok"), a, b)
    v, why = classify(a["reanchored"], b["reanchored"],
                      a["linkup"], b["linkup"], mode=mode)
    return v, why, a, b


def _span(d):
    return "-" if d["sr_span_meas"] is None else str(d["sr_span_meas"])


def main():
    ap = argparse.ArgumentParser(
        description="Anchor-pair retry gate: decide whether a two-die bring-up "
                    "is worth sending payload over.")
    ap.add_argument("--log-a", help="die_a bring-up log")
    ap.add_argument("--log-b", help="die_b bring-up log")
    ap.add_argument("--pair", help="explicit 'a,b' re-anchor bits, e.g. 1,0 "
                                   "(bypasses log parsing; for tests/replay)")
    ap.add_argument("--mode", choices=MODES, default="pair",
                    help="pair (default, the measured gate) | both (legacy "
                         "require-YES/YES) | off (link-up only, baseline-"
                         "comparable)")
    ap.add_argument("--quiet", action="store_true",
                    help="print only the one-line verdict")
    args = ap.parse_args()

    if args.pair:
        try:
            sa, sb = args.pair.split(",")
            a_r, b_r = int(sa), int(sb)
        except ValueError:
            print("ERROR: --pair wants 'a,b' with a,b in {0,1}", file=sys.stderr)
            return 2
        v, why = classify(a_r, b_r, True, True, mode=args.mode)
        print("ANCHOR_GATE mode=%s verdict=%s pair=%s/%s :: %s"
              % (args.mode, v, _yn(a_r), _yn(b_r), why))
        return RC[v]

    if not (args.log_a and args.log_b):
        print("ERROR: need --log-a and --log-b (or --pair)", file=sys.stderr)
        return 2

    v, why, a, b = gate_from_logs(args.log_a, args.log_b, mode=args.mode)
    if not args.quiet:
        print("  die_a: linkup=%s reanchored=%s epoch=%s sr_span_meas=%s"
              % (_yn(a["linkup"]), _yn(a["reanchored"]),
                 "-" if a["epoch_raw"] is None else "0x%08x" % a["epoch_raw"],
                 _span(a)))
        print("  die_b: linkup=%s reanchored=%s epoch=%s sr_span_meas=%s"
              % (_yn(b["linkup"]), _yn(b["reanchored"]),
                 "-" if b["epoch_raw"] is None else "0x%08x" % b["epoch_raw"],
                 _span(b)))
    print("ANCHOR_GATE mode=%s verdict=%s pair=%s/%s :: %s"
          % (args.mode, v, _yn(a["reanchored"]), _yn(b["reanchored"]), why))
    return RC[v]


if __name__ == "__main__":
    sys.exit(main())
