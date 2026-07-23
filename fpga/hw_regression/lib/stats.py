#!/usr/bin/env python3
"""stats.py -- pure-python binomial statistics for the TideLink HW soak layer.

Factored out of ``fpga/hw_regression/allchan_recipe_soak.sh`` (the certified
"N=40 Clopper-Pearson" harness) so every feature soak (L3) computes CIs the same
way, plus a baseline-regression check for the L4 report. **No third-party deps**
(no scipy/numpy) -- the boards run a bare python3.

Public API
----------
    cp_interval(successes, trials, confidence=0.95) -> (lo, hi)
        Exact Clopper-Pearson TWO-SIDED interval (the interval the soak reports).
    trials_needed(target_rate, confidence=0.95) -> int
        Minimum N of an ALL-SUCCESS run whose lower confidence bound clears
        target_rate. One-sided sizing rule (see note below).
    regression_check(current, baseline, confidence=0.95, drop_pts=10.0) -> dict
        Flag a statistically significant / materially large drop vs a baseline.

Two conventions live here on purpose, and it matters:

* ``cp_interval`` is the *two-sided* 95% CI, matching ``clopper_pearson()`` in
  ``allchan_recipe_soak.sh`` (``betainv(0.025,...)`` / ``betainv(0.975,...)``).
  e.g. cp_interval(39, 39) lower bound is ~0.9097 -- the "39/39 -> 91%" number
  the verification plan (§3) quotes.

* ``trials_needed`` is the classic *one-sided* all-success sample-size rule
  ``n = ceil( ln(1-confidence) / ln(target_rate) )``. This is what makes
  ``trials_needed(0.95, 0.95) == 59`` (the plan's target). A two-sided lower
  bound would demand ~72; the plan sizes with the one-sided rule and reports the
  two-sided interval, so we keep both and document the difference rather than
  paper over it.
"""

import math
import sys


# --------------------------------------------------------------------------
# Regularized incomplete beta (Numerical-Recipes betacf/betai) + bisection
# inverse. Direct port of allchan_recipe_soak.sh's embedded python so the two
# agree bit-for-bit.
# --------------------------------------------------------------------------
def _betacf(a, b, x):
    MAXIT, EPS, FPMIN = 200, 3e-16, 1e-300
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < FPMIN:
        d = FPMIN
    d = 1.0 / d
    h = d
    for m in range(1, MAXIT + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        d = FPMIN if abs(d) < FPMIN else d
        c = 1.0 + aa / c
        c = FPMIN if abs(c) < FPMIN else c
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        d = FPMIN if abs(d) < FPMIN else d
        c = 1.0 + aa / c
        c = FPMIN if abs(c) < FPMIN else c
        d = 1.0 / d
        de = d * c
        h *= de
        if abs(de - 1.0) < EPS:
            break
    return h


def _betai(a, b, x):
    """Regularized incomplete beta I_x(a, b)."""
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    lbeta = math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
    bt = math.exp(lbeta + a * math.log(x) + b * math.log(1.0 - x))
    if x < (a + 1.0) / (a + b + 2.0):
        return bt * _betacf(a, b, x) / a
    return 1.0 - bt * _betacf(b, a, 1.0 - x) / b


def _betainv(p, a, b):
    """Bisection inverse of I_x(a, b) = p."""
    lo, hi = 0.0, 1.0
    for _ in range(100):
        mid = (lo + hi) / 2.0
        if _betai(a, b, mid) < p:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2.0


# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------
def cp_interval(successes, trials, confidence=0.95):
    """Exact Clopper-Pearson two-sided interval, returned as (lo, hi) fractions.

    >>> lo, hi = cp_interval(39, 39)
    >>> round(lo, 4)
    0.9097
    >>> hi
    1.0
    >>> lo, hi = cp_interval(0, 10)
    >>> lo
    0.0
    >>> round(hi, 4)
    0.3085
    >>> lo, hi = cp_interval(8, 8)      # KR260 recovery gate G3 (N>=8 smoke)
    >>> round(lo, 4)
    0.6306
    """
    k, n = int(successes), int(trials)
    if n <= 0:
        raise ValueError("trials must be > 0")
    if k < 0 or k > n:
        raise ValueError("successes must be in [0, trials]")
    alpha = 1.0 - confidence
    lo = 0.0 if k == 0 else _betainv(alpha / 2.0, k, n - k + 1)
    hi = 1.0 if k == n else _betainv(1.0 - alpha / 2.0, k + 1, n - k)
    return (lo, hi)


def trials_needed(target_rate, confidence=0.95):
    """Min N of an all-success run whose one-sided lower bound clears target_rate.

    Closed form: n = ceil( ln(1-confidence) / ln(target_rate) ) -- the standard
    "observe n/n, be C-confident the true rate >= target" sizing rule.

    >>> trials_needed(0.95, 0.95)
    59
    >>> trials_needed(0.90, 0.95)
    29
    >>> trials_needed(0.99, 0.95)
    299
    """
    if not (0.0 < target_rate < 1.0):
        raise ValueError("target_rate must be in (0, 1)")
    if not (0.0 < confidence < 1.0):
        raise ValueError("confidence must be in (0, 1)")
    n = math.log(1.0 - confidence) / math.log(target_rate)
    return int(math.ceil(n))


def regression_check(current, baseline, confidence=0.95, drop_pts=10.0):
    """Flag a significant / materially-large drop of ``current`` vs ``baseline``.

    ``current`` and ``baseline`` are (successes, trials) tuples. A regression is
    flagged when EITHER:
      * ``significant`` -- the current and baseline CIs do not overlap in the
        drop direction (current CI-upper < baseline CI-lower): the two runs are
        statistically distinguishable and current is worse, OR
      * ``lower_dropped`` -- the current CI-lower fell >= ``drop_pts`` percentage
        points below the baseline CI-lower (the plan's "CI-lower drop >= 10 pts
        even if still above threshold" rule, §3).

    Returns a dict with the numbers so the L4 report can cite them.

    >>> r = regression_check((40, 40), (40, 40))   # identical -> clean
    >>> r['regressed']
    False
    >>> r = regression_check((20, 40), (39, 40))   # 50% vs 97.5% -> regression
    >>> r['regressed']
    True
    >>> r['significant']
    True
    >>> r = regression_check((38, 40), (40, 40))   # small dip, still overlaps
    >>> r['significant']
    False
    """
    cs, cn = int(current[0]), int(current[1])
    bs, bn = int(baseline[0]), int(baseline[1])
    c_lo, c_hi = cp_interval(cs, cn, confidence)
    b_lo, b_hi = cp_interval(bs, bn, confidence)
    c_pt = cs / cn
    b_pt = bs / bn
    # non-overlapping CIs in the drop direction: the two runs are statistically
    # distinguishable and current is the worse one.
    significant = c_hi < b_lo
    lower_dropped = (b_lo - c_lo) * 100.0 >= drop_pts
    return {
        "regressed": bool(significant or lower_dropped),
        "significant": bool(significant),
        "lower_dropped": bool(lower_dropped),
        "current_point": c_pt,
        "baseline_point": b_pt,
        "current_ci": (c_lo, c_hi),
        "baseline_ci": (b_lo, b_hi),
        "ci_lower_drop_pts": (b_lo - c_lo) * 100.0,
    }


# --------------------------------------------------------------------------
# self-test (no external test runner needed on the board)
# --------------------------------------------------------------------------
def _selftest():
    import doctest

    fails, _ = doctest.testmod(verbose=False)
    checks = []

    def expect(name, cond, detail=""):
        checks.append((name, cond, detail))
        print("  %-28s %s  %s" % (name, "PASS" if cond else "FAIL", detail))

    print("stats.py self-test")
    lo, hi = cp_interval(39, 39)
    expect("cp(39,39) lower ~= 0.91", abs(lo - 0.9097) < 1e-3, "lo=%.4f" % lo)
    expect("cp(39,39) upper == 1.0", hi == 1.0)
    lo, hi = cp_interval(20, 40)
    expect("cp(20,40) ~ symmetric", abs(lo - 0.3386) < 1e-3 and abs(hi - 0.6614) < 1e-3,
           "[%.4f, %.4f]" % (lo, hi))
    lo, hi = cp_interval(0, 40)
    expect("cp(0,40) lower == 0", lo == 0.0, "hi=%.4f" % hi)
    expect("trials_needed(.95,.95)==59", trials_needed(0.95, 0.95) == 59)
    expect("trials_needed(.90,.95)==29", trials_needed(0.90, 0.95) == 29)
    r = regression_check((20, 40), (39, 40))
    expect("regress 20/40 vs 39/40", r["regressed"] and r["significant"])
    r = regression_check((40, 40), (40, 40))
    expect("no-regress identical", not r["regressed"])
    r = regression_check((36, 40), (40, 40))
    expect("CI-lower-drop flags", r["lower_dropped"], "drop=%.1f pts" % r["ci_lower_drop_pts"])

    ok = fails == 0 and all(c for _, c, _ in checks)
    print("doctests: %s ; asserts: %d/%d" %
          ("PASS" if fails == 0 else "FAIL(%d)" % fails,
           sum(1 for _, c, _ in checks if c), len(checks)))
    print("SELFTEST %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def _usage():
    print(__doc__.strip().splitlines()[0])
    print("usage:")
    print("  stats.py cp <successes> <trials> [confidence]")
    print("  stats.py trials <target_rate> [confidence]")
    print("  stats.py regress <cur_s> <cur_n> <base_s> <base_n> [confidence]")
    print("  stats.py selftest")


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        _usage()
        return 0
    cmd = argv[0]
    try:
        if cmd == "cp":
            s, n = int(argv[1]), int(argv[2])
            conf = float(argv[3]) if len(argv) > 3 else 0.95
            lo, hi = cp_interval(s, n, conf)
            print("%.1f%% [%.1f%%, %.1f%%] (Clopper-Pearson %.0f%%)" %
                  (100.0 * s / n, 100.0 * lo, 100.0 * hi, 100.0 * conf))
        elif cmd == "trials":
            target = float(argv[1])
            conf = float(argv[2]) if len(argv) > 2 else 0.95
            print(trials_needed(target, conf))
        elif cmd == "regress":
            cs, cn, bs, bn = (int(argv[1]), int(argv[2]), int(argv[3]), int(argv[4]))
            conf = float(argv[5]) if len(argv) > 5 else 0.95
            r = regression_check((cs, cn), (bs, bn), conf)
            verdict = "REGRESSION" if r["regressed"] else "ok"
            print("%s: current %.1f%% CI[%.1f%%,%.1f%%] vs baseline %.1f%% "
                  "CI[%.1f%%,%.1f%%]  (lower-drop %.1f pts, significant=%s)" % (
                      verdict, 100 * r["current_point"], 100 * r["current_ci"][0],
                      100 * r["current_ci"][1], 100 * r["baseline_point"],
                      100 * r["baseline_ci"][0], 100 * r["baseline_ci"][1],
                      r["ci_lower_drop_pts"], r["significant"]))
            return 1 if r["regressed"] else 0
        elif cmd == "selftest":
            return _selftest()
        else:
            _usage()
            return 2
    except (IndexError, ValueError) as e:
        print("error: %s" % e)
        _usage()
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
