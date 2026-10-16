#!/usr/bin/env python3
"""Run a CRC-matrix tier: one sim per case (shared compile per build), controls first.

  run_crc_matrix.py {quick|gate|nightly} [--jobs N] [--out DIR] [--only SUBSTR]

Builds (sim_build_cm_<build>[_w<k>]): zero | silicon (EPOCH_PROFILE=silicon, EPOCH_ANCHOR_EN=1) |
l9 (+define+SOCL_L9_ALWAYS = pre-TL-059 sideband RTL).  Every build dir is removed first and compiled
by the first case that needs it (a cached simv would test stale RTL: the gate-integrity rule).

Gate semantics:
  * controls (group control|mutant) run first.  Any control not ok => HARNESS_BROKEN: the matrix is
    NOT run and the tier fails (a matrix that cannot prove its instrument fires proves nothing).
  * a matrix case passes iff the sim ran to a cocotb verdict AND its [cm] RESULT class == CM_EXPECT.
    A sim without a verdict or without a RESULT line is ERROR (could-not-evaluate), never a pass.
  * exit 0 only if every case is ok.  Writes DIR/results.json and DIR/summary.txt.
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import crc_matrix_cases as CASES   # noqa: E402

BUILD_ARGS = {
    "zero": ["EPOCH_PROFILE=zero"],
    "silicon": ["EPOCH_PROFILE=silicon"],
    "l9": ["EPOCH_PROFILE=zero", "EXTRA_DEFINES=+define+SOCL_L9_ALWAYS"],
}
RESULT_RE = re.compile(r"\[cm\] RESULT (\{.*\})")


def run_case(case, worker, outdir, timeout):
    build = case["build"]
    sb = f"sim_build_cm_{build}_w{worker}"
    flist = os.path.join(HERE, f"tidelink_fpga_v2_fcsm_local_w{worker}.flist")
    log = os.path.join(outdir, case["name"] + ".log")
    env = dict(os.environ)
    env.update(case["env"])
    env["COCOTB_RESULTS_FILE"] = os.path.join(HERE, f"results_cm_{case['name']}.xml")
    cmd = ["make", f"SIM_BUILD={sb}", "MODULE=test_crc_matrix", f"LOCAL_FLIST={flist}"] + BUILD_ARGS[build]
    t0 = time.time()
    try:
        with open(log, "w") as f:
            rc = subprocess.run(cmd, cwd=HERE, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        rc = 124
    dt = time.time() - t0
    res = None
    verdict = False
    with open(log, errors="replace") as f:
        for line in f:
            m = RESULT_RE.search(line)
            if m:
                try:
                    res = json.loads(m.group(1))
                except ValueError:
                    pass
            if re.search(r"\*\*\s+TESTS=\d+ PASS=\d+ FAIL=\d+", line):
                verdict = True
    cls = (res or {}).get("cls", "ERROR")
    expect = (res or {}).get("expect", case["env"].get("CM_EXPECT", "EXACT"))
    ok = bool(res) and verdict and bool(res.get("ok")) and rc == 0
    note = ""
    if not verdict:
        note = "no cocotb verdict (build/sim died)"
    elif not res:
        note = "no [cm] RESULT line"
    elif not ok:
        note = (res.get("why") or "") + f" lost={res.get('lost')} dup={res.get('dup')} stray={res.get('stray')}"
    return dict(name=case["name"], group=case["group"], build=build, cls=cls, expect=expect, ok=ok,
                secs=round(dt, 1), rc=rc, note=note.strip(), rec=res, log=log)


def run_batch(cases, jobs, outdir, timeout, keep=()):
    """Fan `cases` over `jobs` workers.  Worker k owns sim_build_cm_<build>_w<k>, compiled by the first case
    that needs it; (build, worker) pairs in `keep` were compiled by an earlier phase and are reused."""
    if not cases:
        return []
    jobs = max(1, jobs)
    for b in {c["build"] for c in cases}:
        for w in range(jobs):
            if (b, w) not in keep:      # a cached simv would silently test stale RTL
                shutil.rmtree(os.path.join(HERE, f"sim_build_cm_{b}_w{w}"), ignore_errors=True)
    queue = list(cases)
    results = {}

    def worker_fn(w):
        out = []
        while True:
            try:
                c = queue.pop(0)
            except IndexError:
                return out
            r = run_case(c, w, outdir, timeout)
            print(f"[crc_matrix] {'ok  ' if r['ok'] else 'FAIL'} {r['name']:<46} {r['cls']:<6} (exp {r['expect']}) "
                  f"{r['secs']:>6.1f}s {r['note']}", flush=True)
            out.append((r, w))

    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        for fut in [ex.submit(worker_fn, w) for w in range(jobs)]:
            for r, w in fut.result():
                r["worker"] = w
                results[r["name"]] = r
    return [results[c["name"]] for c in cases]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tier", choices=sorted(CASES.TIERS))
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("CM_JOBS", "1")))
    ap.add_argument("--out", default=None)
    ap.add_argument("--only", default=None, help="substring filter on case name (debug)")
    ap.add_argument("--timeout", type=int, default=1500)
    a = ap.parse_args()
    outdir = a.out or os.path.join(HERE, "crc_matrix_out", a.tier)
    os.makedirs(outdir, exist_ok=True)
    cases = CASES.TIERS[a.tier]()
    if a.only:
        cases = [c for c in cases if a.only in c["name"]]
    ctl = [c for c in cases if c["group"] in ("control", "mutant")]
    mat = [c for c in cases if c["group"] == "matrix"]
    t0 = time.time()
    print(f"[crc_matrix] tier={a.tier} controls={len(ctl)} matrix={len(mat)} jobs={a.jobs} out={outdir}", flush=True)
    results = run_batch(ctl, a.jobs, outdir, a.timeout)
    broken = [r for r in results if not r["ok"]]
    if broken:
        print("[crc_matrix] HARNESS_BROKEN: control(s) failed -> matrix NOT run: " + ", ".join(r["name"] for r in broken),
              flush=True)
    else:
        print(f"[crc_matrix] controls ok ({len(ctl)}) -> matrix", flush=True)
        keep = {(r["build"], r["worker"]) for r in results}      # builds the control phase already compiled
        results += run_batch(mat, a.jobs, outdir, a.timeout, keep)
    # ------ summary
    total = time.time() - t0
    lines = []
    lines.append(f"CRC matrix tier={a.tier}  wall={total:.0f}s  jobs={a.jobs}")
    lines.append(f"{'case':<50} {'group':<8} {'build':<8} {'class':<6} {'expect':<10} {'secs':>6}  ok")
    for r in results:
        lines.append(f"{r['name']:<50} {r['group']:<8} {r['build']:<8} {r['cls']:<6} {r['expect']:<10} {r['secs']:>6}  "
                     f"{'ok' if r['ok'] else 'FAIL'} {r['note']}")
    ran = {r["name"] for r in results}
    for c in mat:
        if c["name"] not in ran:
            lines.append(f"{c['name']:<50} {'matrix':<8} {c['build']:<8} {'NOTRUN':<6}")
    nfail = sum(1 for r in results if not r["ok"]) + sum(1 for c in mat if c["name"] not in ran)
    by = {}
    for r in results:
        by[r["cls"]] = by.get(r["cls"], 0) + 1
    lines.append(f"classes: {by}   failing/not-run: {nfail}   "
                 f"{'HARNESS_BROKEN' if broken else ('PASS' if not nfail else 'FAIL')}")
    txt = "\n".join(lines)
    print(txt)
    with open(os.path.join(outdir, "summary.txt"), "w") as f:
        f.write(txt + "\n")
    with open(os.path.join(outdir, "results.json"), "w") as f:
        json.dump(results, f, indent=1, default=str)
    sys.exit(0 if not nfail and not broken else (2 if broken else 1))


if __name__ == "__main__":
    main()
