#!/usr/bin/env python3
# =============================================================================
# dashboard.py — fold OUT/iterations.jsonl (+ failures/*.json + markers) into a
#                human-readable OUT/DASHBOARD.txt, rewritten atomically.
#
# Read-only over the campaign artifacts; safe to run at any time (the driver runs
# it after every iteration). Never touches a board.
#
#   usage:  dashboard.py <OUT_DIR>
#
# Reports:
#   - beats-without-wedge (current streak + max)
#   - MTBF: beats-per-wedge and wall-hours-per-wedge
#   - re-convergence success rate (fraction of iters that reached fcsm=4)
#   - credit-recovery events
#   - mismatch count + first-bad address(es)
#   - coverage histograms: direction / soak-length bucket / role-swap count
#   - wedge-node taxonomy (which of AW/W/B/AR/R was CRC-hot / non-empty at wedge)
#   - a live current-iteration line (OUT/CURRENT)
#   - a PARKED / ALERT banner (OUT/ALERT_*.txt)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import glob
import json
import os
import sys
import time

AXI_NODES = ("AW", "W", "B", "AR", "R")
SOAK_BUCKETS = [(0, 500), (500, 2000), (2000, 8000), (8000, 20001)]


def load_iters(out_dir):
    path = os.path.join(out_dir, "iterations.jsonl")
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                pass  # tolerate a torn last line (append not yet flushed)
    return rows


def load_failures(out_dir):
    docs = []
    for p in sorted(glob.glob(os.path.join(out_dir, "failures", "*.json"))):
        try:
            with open(p) as f:
                docs.append(json.load(f))
        except Exception:
            pass
    return docs


def bar(count, total, width=24):
    if total <= 0:
        return ""
    n = int(round(width * count / total))
    return "#" * n + "." * (width - n)


def soak_bucket_label(lo, hi):
    return "%5d-%-5d" % (lo, hi - 1 if hi < 20001 else 20000)


def fold(out_dir):
    rows = load_iters(out_dir)
    fails = load_failures(out_dir)
    L = []
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    L.append("=" * 74)
    L.append(" KR260 eth-chiplet WEEKEND SOAK — dashboard   (%s)" % now)
    L.append(" out: %s" % out_dir)
    L.append("=" * 74)

    # --- PARKED / ALERT banner ----------------------------------------------
    alerts = sorted(glob.glob(os.path.join(out_dir, "ALERT_*.txt")))
    if alerts:
        L.append("")
        L.append("  " + "!" * 68)
        for a in alerts:
            first = ""
            try:
                with open(a) as f:
                    first = f.readline().strip()
            except Exception:
                pass
            L.append("  !! %s" % (first or os.path.basename(a)))
        if len(alerts) >= 2:
            L.append("  !! BOTH BOARDS PARKED — campaign has aborted. Bench attention "
                     "required.")
        L.append("  " + "!" * 68)

    total = len(rows)
    verdicts = {}
    for r in rows:
        verdicts[r.get("verdict", "?")] = verdicts.get(r.get("verdict", "?"), 0) + 1
    n_wedge = verdicts.get("WEDGE", 0)
    n_mismatch = verdicts.get("MISMATCH", 0)
    n_noconv = verdicts.get("NOCONVERGE", 0)
    n_pass = verdicts.get("PASS", 0)

    # --- beats-without-wedge (streaks) + totals -----------------------------
    total_beats = 0
    cur_streak = 0
    max_streak = 0
    total_wall_s = 0.0
    credit_recov = 0
    for r in rows:
        b = int(r.get("beats_done", 0) or 0)
        total_beats += b
        total_wall_s += float(r.get("wall_s", 0) or 0)
        if (r.get("credit") or {}).get("recovered"):
            credit_recov += 1
        if r.get("verdict") == "WEDGE":
            cur_streak += b            # beats accrued up to the wedge still count
            max_streak = max(max_streak, cur_streak)
            cur_streak = 0             # reset after the wedge
        else:
            cur_streak += b
            max_streak = max(max_streak, cur_streak)

    L.append("")
    L.append(" SUMMARY")
    L.append("   iterations   : %d   (PASS %d / MISMATCH %d / WEDGE %d / NOCONVERGE %d)"
             % (total, n_pass, n_mismatch, n_wedge, n_noconv))
    L.append("   total beats  : %d   (wall %.2f h)" % (total_beats, total_wall_s / 3600.0))
    L.append("   beats-w/o-wedge : current %d   max %d" % (cur_streak, max_streak))

    # --- MTBF ----------------------------------------------------------------
    if n_wedge > 0:
        L.append("   MTBF         : %.0f beats/wedge   %.2f wall-h/wedge"
                 % (total_beats / n_wedge, (total_wall_s / 3600.0) / n_wedge))
    else:
        L.append("   MTBF         : no wedge yet  (%d beats clean)" % total_beats)

    # --- re-convergence success rate ----------------------------------------
    if total > 0:
        conv = total - n_noconv
        L.append("   re-converge  : %d/%d bring-ups reached fcsm=4  (%.1f%%)"
                 % (conv, total, 100.0 * conv / total))
    L.append("   credit-recovery events : %d" % credit_recov)

    # --- mismatch detail -----------------------------------------------------
    if n_mismatch:
        L.append("")
        L.append(" MISMATCHES (%d)" % n_mismatch)
        for r in rows:
            if r.get("verdict") == "MISMATCH":
                mm = r.get("mismatch") or {}
                L.append("   seed %-7s first-bad addr=%s got=%s exp=%s"
                         % (r.get("seed"), mm.get("addr", "?"),
                            mm.get("got", "?"), mm.get("exp", "?")))

    # --- coverage histograms -------------------------------------------------
    L.append("")
    L.append(" COVERAGE")
    dirc = {"fwd": 0, "rev": 0}
    workc = {}
    swap_n = 0
    sbuck = {i: 0 for i in range(len(SOAK_BUCKETS))}
    for r in rows:
        dirc[r.get("direction", "fwd")] = dirc.get(r.get("direction", "fwd"), 0) + 1
        workc[r.get("workload", "?")] = workc.get(r.get("workload", "?"), 0) + 1
        if r.get("role_swap"):
            swap_n += 1
        sl = int(r.get("soak_len", 0) or 0)
        for i, (lo, hi) in enumerate(SOAK_BUCKETS):
            if lo <= sl < hi:
                sbuck[i] += 1
                break
    L.append("   direction : fwd %3d [%s]" % (dirc.get("fwd", 0), bar(dirc.get("fwd", 0), total)))
    L.append("               rev %3d [%s]" % (dirc.get("rev", 0), bar(dirc.get("rev", 0), total)))
    L.append("   workload  : " + "  ".join("%s=%d" % (k, v) for k, v in sorted(workc.items())))
    L.append("   role-swap : %d/%d iters" % (swap_n, total))
    L.append("   soak-len buckets (beats):")
    for i, (lo, hi) in enumerate(SOAK_BUCKETS):
        L.append("       %s : %3d [%s]" % (soak_bucket_label(lo, hi), sbuck[i],
                                           bar(sbuck[i], total)))

    # --- wedge-node taxonomy -------------------------------------------------
    L.append("")
    L.append(" WEDGE-NODE TAXONOMY  (AXI data nodes AW/W/B/AR/R; see CROSS_DIE_WEDGE_ROOTCAUSE.md)")
    crc_tally = {n: 0 for n in AXI_NODES}
    ne_tally = {n: 0 for n in AXI_NODES}
    sticky_tally = {n: 0 for n in AXI_NODES}
    stage_tally = {}
    class_tally = {}
    if not fails:
        L.append("   (no wedge failure files captured)")
    else:
        for d in fails:
            tax = d.get("taxonomy") or {}
            for n in tax.get("crc_hot", []) or []:
                if n in crc_tally:
                    crc_tally[n] += 1
            for n in tax.get("nonempty", []) or []:
                if n in ne_tally:
                    ne_tally[n] += 1
            for n in tax.get("wedge_nodes", []) or []:
                if n in sticky_tally:
                    sticky_tally[n] += 1
            st = ((d.get("wedge") or {}).get("stage")) or tax.get("stage") or "?"
            stage_tally[st] = stage_tally.get(st, 0) + 1
            cls = tax.get("class") or (d.get("wedge") or {}).get("class") or "?"
            class_tally[cls] = class_tally.get(cls, 0) + 1
        L.append("   node          : " + "  ".join("%-3s" % n for n in AXI_NODES))
        L.append("   RegionF-sticky: " + "  ".join("%-3d" % sticky_tally[n] for n in AXI_NODES))
        L.append("   CRC-hot       : " + "  ".join("%-3d" % crc_tally[n] for n in AXI_NODES))
        L.append("   non-empty AckN: " + "  ".join("%-3d" % ne_tally[n] for n in AXI_NODES))
        L.append("   wedge class   : " + "  ".join("%s=%d" % (k, v)
                                                   for k, v in sorted(class_tally.items())))
        L.append("   wedge stage   : " + "  ".join("%s=%d" % (k, v)
                                                   for k, v in sorted(stage_tally.items())))
        L.append("   failure files : %d  (OUT/failures/*.json — each has repro + snapshots)"
                 % len(fails))

    # --- live current-iteration line ----------------------------------------
    L.append("")
    cur = os.path.join(out_dir, "CURRENT")
    if os.path.exists(cur):
        try:
            with open(cur) as f:
                L.append(" CURRENT : " + f.read().strip())
        except Exception:
            L.append(" CURRENT : (unreadable)")
    else:
        L.append(" CURRENT : (none — driver idle or finished)")

    L.append("=" * 74)
    return "\n".join(L) + "\n"


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: dashboard.py <OUT_DIR>\n")
        return 2
    out_dir = sys.argv[1]
    text = fold(out_dir)
    dst = os.path.join(out_dir, "DASHBOARD.txt")
    tmp = dst + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, dst)                                        # atomic rewrite
    if len(sys.argv) > 2 and sys.argv[2] == "--print":
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
