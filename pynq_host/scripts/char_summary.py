#!/usr/bin/env python3
"""char_summary.py — render summary.md from a char_session.sh results dir.

Usage: char_summary.py <RUN_DIR>   (markdown on stdout)

Runs LOCALLY on the orchestration host (mapstone-dev) — never staged to a
board. Tolerates missing/partial files: a failed test leg simply drops out
of its table instead of killing the summary.
"""
import csv
import glob
import json
import os
import re
import sys


def load_json(path):
    """Last JSON object line in the file (tlchar prints one JSON line;
    earlier lines may be sudo/ssh noise)."""
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None
    try:
        return json.loads(text)        # whole-file JSON (meta.json is multi-line)
    except ValueError:
        pass
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    for ln in reversed(lines):
        if ln.startswith("{"):
            try:
                return json.loads(ln)
            except ValueError:
                continue
    return None


def fmt(v, nd=1):
    if isinstance(v, float):
        return ("%%.%df" % nd) % v
    return str(v)


def t4_section(d, out):
    t4 = load_json(os.path.join(d, "t4_ping.json"))
    if not t4:
        return
    out.append("## T4 — doorbell round-trip latency")
    out.append("")
    r = t4.get("rtt_us") or {}
    out.append("| n | gap_ms | lost | amplification | min us | p50 us | p90 us | p99 us | max us | mean us |")
    out.append("|---|---|---|---|---|---|---|---|---|---|")
    out.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
        r.get("n", "?"), t4.get("gap_ms", "?"), t4.get("lost", "?"),
        fmt(t4.get("amplification", "?"), 2),
        fmt(r.get("min", "?")), fmt(r.get("p50", "?")), fmt(r.get("p90", "?")),
        fmt(r.get("p99", "?")), fmt(r.get("max", "?")), fmt(r.get("mean", "?"))))
    resp = load_json(os.path.join(d, "t4_respond.json"))
    if resp:
        out.append("")
        out.append("Responder: echoed=%s drained_words=%s" % (
            resp.get("echoed", "?"), resp.get("drained_words", "?")))
    out.append("")


def t1_section(d, out):
    rows = []
    for f in glob.glob(os.path.join(d, "t1_stream_B*.json")):
        m = re.search(r"t1_stream_B(\d+)\.json$", f)
        if not m:
            continue
        b = int(m.group(1))
        s = load_json(f)
        if not s:
            continue
        drain = load_json(os.path.join(d, "t1_drain_B%d.json" % b)) or {}
        rows.append((b, s, drain))
    if not rows:
        return
    rows.sort()
    out.append("## T1 — M->S streaming throughput vs burst size")
    out.append("")
    out.append("| burst | pkts | words/s | payload words/s | payload MB/s | starve % | peer drained | end status |")
    out.append("|---|---|---|---|---|---|---|---|")
    for b, s, drain in rows:
        out.append("| %d | %s | %s | %s | %s | %s | %s | 0x%x |" % (
            b, s.get("pkts", "?"), fmt(s.get("words_per_s", "?")),
            fmt(s.get("payload_words_per_s", "?")),
            fmt(s.get("payload_MBps", "?"), 4), fmt(s.get("starve_pct", "?"), 2),
            drain.get("drained_words", "?"), s.get("end_status", 0)))
    out.append("")


def t5_csv_stats(path):
    """t_ns,pair_credits,released_acc -> (n, cmin, cmax, steps, mean_step)."""
    n = 0
    cmin = cmax = None
    prev = None
    steps = []
    try:
        with open(path) as f:
            for row in csv.DictReader(f):
                try:
                    c = int(row["pair_credits"])
                except (KeyError, TypeError, ValueError):
                    continue
                n += 1
                cmin = c if cmin is None else min(cmin, c)
                cmax = c if cmax is None else max(cmax, c)
                if prev is not None and c > prev:
                    steps.append(c - prev)
                prev = c
    except OSError:
        return None
    if n == 0:
        return None
    mean_step = (sum(steps) / float(len(steps))) if steps else 0.0
    return n, cmin, cmax, len(steps), mean_step


def t5_section(d, out):
    rows = []
    for f in glob.glob(os.path.join(d, "t5_credsample_th*.csv")):
        m = re.search(r"t5_credsample_th(\d+)\.csv$", f)
        if not m:
            continue
        th = int(m.group(1))
        st = t5_csv_stats(f)
        if not st:
            continue
        fill = load_json(os.path.join(d, "t5_fill_th%d.json" % th)) or {}
        drain = load_json(os.path.join(d, "t5_drain_th%d.json" % th)) or {}
        rows.append((th, st, fill, drain))
    if not rows:
        return
    rows.sort()
    out.append("## T5 — credit-return latency vs RELEASE_THRESHOLD")
    out.append("")
    out.append("(staircase shape: credit-release batches of ~threshold words; "
               "full step-lag distributions live in the per-threshold CSVs)")
    out.append("")
    out.append("| threshold | filled words | samples | pair_credits min | max | credit steps seen | mean step size | peer drained |")
    out.append("|---|---|---|---|---|---|---|---|")
    for th, (n, cmin, cmax, nsteps, mean_step), fill, drain in rows:
        out.append("| %d | %s | %d | %s | %s | %d | %.1f | %s |" % (
            th, fill.get("pushed_words", "?"), n, cmin, cmax, nsteps,
            mean_step, drain.get("drained_words", "?")))
    out.append("")


def t6b_section(d, out):
    idle = load_json(os.path.join(d, "t6b_apblat_idle.json"))
    strm = load_json(os.path.join(d, "t6b_apblat_stream.json"))
    if not idle and not strm:
        return
    out.append("## T6b — APB read latency, idle vs under stream")
    out.append("")
    out.append("| condition | n | min us | p50 us | p90 us | p99 us | max us | mean us |")
    out.append("|---|---|---|---|---|---|---|---|")
    for name, j in (("idle", idle), ("under stream", strm)):
        if not j:
            continue
        r = j.get("lat_us") or {}
        out.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            name, r.get("n", "?"), fmt(r.get("min", "?"), 2),
            fmt(r.get("p50", "?"), 2), fmt(r.get("p90", "?"), 2),
            fmt(r.get("p99", "?"), 2), fmt(r.get("max", "?"), 2),
            fmt(r.get("mean", "?"), 2)))
    bg = load_json(os.path.join(d, "t6b_stream_bg.json"))
    if bg:
        out.append("")
        out.append("Background load: burst=%s, %s words/s, starve %s%%" % (
            bg.get("burst", "?"), fmt(bg.get("words_per_s", "?")),
            fmt(bg.get("starve_pct", "?"), 2)))
    out.append("")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: char_summary.py <RUN_DIR>")
    d = sys.argv[1]
    out = ["# TideLink characterization session summary", ""]
    meta = load_json(os.path.join(d, "meta.json")) or {}
    if meta:
        out.append("| key | value |")
        out.append("|---|---|")
        for k in sorted(meta):
            out.append("| %s | %s |" % (k, meta[k]))
        out.append("")
    t4_section(d, out)
    t1_section(d, out)
    t5_section(d, out)
    t6b_section(d, out)
    fails = os.path.join(d, "test_failures.log")
    if os.path.exists(fails) and os.path.getsize(fails):
        out.append("## Test failures / recoveries")
        out.append("")
        out.append("```")
        with open(fails) as f:
            out.append(f.read().rstrip())
        out.append("```")
        out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
