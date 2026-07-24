"""Cross-version throughput comparison — "is v39 actually faster than
v38, and how do we know?".

The arithmetic here is trivial. The ``warnings`` list is the feature.

This project has already burned a debugging saga on a rate ladder that
was structurally confounded: the compared points did not share their
parameters, nobody noticed, and the resulting "improvement" was an
artefact of the measurement, not of the RTL. A comparison that silently
mixes parameters is strictly worse than no comparison — it manufactures
confidence. So every group carries its provenance (params_key,
fifo_label, source_commit, error counts) and anything that would make
the numbers non-comparable is stated in plain text:

  * runs inside one version that do not share a params_key,
  * versions being compared against each other that do not,
  * n < 3 (you cannot claim an improvement from two samples),
  * different fifo_label (a different RX FIFO build is a different DUT),
  * runs whose summary recorded errors,
  * a delta that is inside the observed p5..p95 spread — i.e. noise.

``delta_exceeds_spread`` exists so the UI cannot draw a confident bar
for a +2% delta measured inside a +-15% band. It is False whenever the
spread is unknown (n < 2 either side): an unknown spread is not a
cleared one.

Only ``state="done"`` runs are considered; the response says so in
``included_states`` rather than leaving the caller to assume.
"""
from __future__ import annotations

import math
import statistics
from typing import Optional

from .store import parse_params_key

# Metric must be a scalar produced by orchestrator.ThroughputRun._summary().
# Whitelisted rather than free-form: "master"/"slave" are nested dicts and
# an arbitrary key would silently yield an empty comparison.
KNOWN_METRICS = (
    "throughput_mbps_mean",
    "throughput_mbps_p5",
    "throughput_mbps_p95",
    "packets",
    "errors",
    "rx_throughput_mbps_mean",
    "rx_drained_words",
)

DEFAULT_METRIC = "throughput_mbps_mean"
INCLUDED_STATES = ("done",)
MIN_SAMPLES = 3          # below this we refuse to call a delta a result
_ROW_LIMIT = 100000      # the index holds hundreds of rows, not millions
UNKNOWN_VERSION = "unknown"


# ── small stats helpers (stdlib only, no numpy on the host) ──────────

def percentile(values: list, q: float) -> Optional[float]:
    """Linear-interpolation percentile (numpy's default method)."""
    xs = sorted(float(v) for v in values)
    if not xs:
        return None
    if len(xs) == 1:
        return xs[0]
    pos = (len(xs) - 1) * (q / 100.0)
    lo, hi = int(math.floor(pos)), int(math.ceil(pos))
    if lo == hi:
        return xs[lo]
    return xs[lo] + (xs[hi] - xs[lo]) * (pos - lo)


def _stats(values: list) -> dict:
    xs = [float(v) for v in values]
    n = len(xs)
    if n == 0:
        return {"n": 0, "mean": None, "median": None, "p5": None,
                "p95": None, "stdev": None}
    return {
        "n": n,
        "mean": round(statistics.fmean(xs), 6),
        "median": round(statistics.median(xs), 6),
        "p5": round(percentile(xs, 5.0), 6),
        "p95": round(percentile(xs, 95.0), 6),
        # POPULATION stdev: these runs are the whole set we are
        # describing, not a sample of a larger one. statistics.stdev
        # would raise on n == 1; pstdev is 0.0 there, which is honest
        # (one run has no spread) as long as the n < 3 warning fires.
        "stdev": round(statistics.pstdev(xs), 6) if n >= 2 else 0.0,
    }


def _spread_half_width(group: dict) -> Optional[float]:
    """Half the p5..p95 band, or None when it is unknowable (n < 2)."""
    if group["n"] < 2 or group["p5"] is None or group["p95"] is None:
        return None
    return abs(group["p95"] - group["p5"]) / 2.0


def delta_exceeds_spread(baseline: dict, candidate: dict) -> bool:
    """True when |mean difference| is larger than the two p5..p95 bands
    can account for — i.e. the bands do not overlap.

    Deliberately conservative: an unknown spread (either side n < 2)
    returns False. "We cannot tell" must never render as "improved"."""
    hb = _spread_half_width(baseline)
    hc = _spread_half_width(candidate)
    if hb is None or hc is None:
        return False
    if baseline["mean"] is None or candidate["mean"] is None:
        return False
    return abs(candidate["mean"] - baseline["mean"]) > (hb + hc)


def _differing_params(keys: list) -> list:
    """Which parameter names actually differ across these params_keys."""
    dicts = [parse_params_key(k) for k in keys]
    names = sorted({n for d in dicts for n in d})
    return [n for n in names
            if len({d.get(n, "<absent>") for d in dicts}) > 1]


# ── version index ────────────────────────────────────────────────────

def list_versions(store, *, limit: int = _ROW_LIMIT) -> list:
    """``[{artefact_version, source_commit, rtl_tag, runs, first, last}]``
    newest first (by most recent run)."""
    acc: dict = {}
    for row in store.list_runs(limit=limit):        # newest first
        ver = row.get("artefact_version") or UNKNOWN_VERSION
        created = row.get("created") or ""
        g = acc.get(ver)
        if g is None:
            # First row for this version is the newest one — take its
            # identity fields.
            g = acc[ver] = {
                "artefact_version": ver,
                "source_commit": row.get("source_commit") or "",
                "rtl_tag": row.get("rtl_tag") or "",
                "runs": 0, "done": 0,
                "first": created, "last": created,
                "tests": set(), "params_keys": set(),
            }
        g["runs"] += 1
        if row.get("state") == "done":
            g["done"] += 1
        if created:
            g["first"] = min(g["first"] or created, created)
            g["last"] = max(g["last"] or created, created)
        if row.get("test"):
            g["tests"].add(row["test"])
        g["params_keys"].add(row.get("params_key") or "")
    out = []
    for g in acc.values():
        g["tests"] = sorted(g["tests"])
        g["params_keys"] = sorted(g["params_keys"])
        out.append(g)
    out.sort(key=lambda g: (g["last"], g["artefact_version"]), reverse=True)
    return out


# ── the comparison ───────────────────────────────────────────────────

def compare_versions(store, *, test: str,
                     versions: Optional[list] = None,
                     params_key: Optional[str] = None,
                     metric: str = DEFAULT_METRIC,
                     baseline: Optional[str] = None,
                     limit: int = _ROW_LIMIT) -> dict:
    """Group finished runs of ``test`` by artefact_version and compare
    ``metric`` against a baseline version.

    Baseline defaults to the OLDEST version in the selection (you
    improve *from* something). Raises ValueError for an unknown metric.
    """
    if metric not in KNOWN_METRICS:
        raise ValueError(
            "unknown metric %r — known: %s" % (metric,
                                               ", ".join(KNOWN_METRICS)))
    warnings: list = []

    rows = [r for r in store.list_runs(test=test, params_key=params_key,
                                       limit=limit)
            if r.get("state") in INCLUDED_STATES]
    # Deterministic total order even when several runs share a created
    # second (the index stamps at 1 s resolution).
    rows.sort(key=lambda r: (r.get("created") or "", r.get("run_id") or ""))

    wanted = [v for v in (versions or []) if v]
    grouped: dict = {}
    for row in rows:
        grouped.setdefault(row.get("artefact_version") or UNKNOWN_VERSION,
                           []).append(row)
    if wanted:
        for v in wanted:
            if v not in grouped:
                warnings.append(
                    "requested version %s has no done runs for test %s%s"
                    % (v, test,
                       " with params_key %s" % params_key
                       if params_key else ""))
        grouped = {v: rs for v, rs in grouped.items() if v in wanted}

    groups = []
    for ver, runs in grouped.items():
        groups.append(_build_group(ver, runs, metric, warnings))
    # Oldest version first: the baseline reads left-to-right as "before".
    groups.sort(key=lambda g: (g["first"], g["version"]))

    if not groups:
        warnings.append(
            "no done runs for test %s%s — nothing to compare"
            % (test, " with params_key %s" % params_key
               if params_key else ""))
        return {"test": test, "metric": metric, "params_key": params_key,
                "baseline": None, "included_states": list(INCLUDED_STATES),
                "groups": [], "warnings": warnings}

    base = _pick_baseline(groups, baseline, warnings)
    _fill_deltas(groups, base, warnings)
    _cross_group_warnings(groups, warnings)

    # Report the fingerprint actually in force: the request filter if
    # one was given, else the single shared key when every included run
    # agrees, else None (and a confounding warning will have fired).
    shared = {k for g in groups for k in g["params_keys"]}
    effective = params_key or (shared.pop() if len(shared) == 1 else None)

    return {
        "test": test,
        "metric": metric,
        "params_key": effective,
        "baseline": base["version"],
        "included_states": list(INCLUDED_STATES),
        "groups": groups,
        "warnings": warnings,
    }


def _build_group(ver: str, runs: list, metric: str,
                 warnings: list) -> dict:
    values, used, missing = [], [], 0
    errors_total, error_runs = 0, 0
    for r in runs:
        summary = r.get("summary") or {}
        val = summary.get(metric)
        if not isinstance(val, (int, float)) or isinstance(val, bool):
            missing += 1
        else:
            values.append(float(val))
            used.append(r["run_id"])
        errs = summary.get("errors") or 0
        if isinstance(errs, (int, float)) and errs > 0:
            errors_total += int(errs)
            error_runs += 1

    pkeys = sorted({r.get("params_key") or "" for r in runs})
    fifos = sorted({r.get("fifo_label") or "" for r in runs})
    commits = sorted({r.get("source_commit") or "" for r in runs if
                      r.get("source_commit")})
    tags = sorted({r.get("rtl_tag") or "" for r in runs if r.get("rtl_tag")})
    created = [r.get("created") or "" for r in runs]

    group = dict(_stats(values))
    group.update({
        "version": ver,
        "rtl_tag": tags[0] if tags else "",
        "source_commit": commits[0] if commits else "",
        "runs": used,
        "runs_total": len(runs),
        "params_key": pkeys[0] if len(pkeys) == 1 else None,
        "params_keys": pkeys,
        "fifo_label": fifos[0] if len(fifos) == 1 else None,
        "fifo_labels": fifos,
        "errors": errors_total,
        "error_runs": error_runs,
        "first": min(created) if created else "",
        "last": max(created) if created else "",
        "delta_vs_baseline_pct": None,
        "delta_exceeds_spread": False,
    })

    if len(pkeys) > 1:
        diff = _differing_params(pkeys)
        warnings.append(
            "version %s: runs mix params_key (%d distinct: %s) — differing "
            "params: %s — comparison is CONFOUNDED"
            % (ver, len(pkeys), ", ".join(repr(k) for k in pkeys),
               ", ".join(diff) or "unknown"))
    if len(fifos) > 1:
        warnings.append(
            "version %s: runs mix fifo_label (%s) — a different RX FIFO "
            "build is a different DUT — comparison is CONFOUNDED"
            % (ver, ", ".join(fifos)))
    if len(commits) > 1:
        warnings.append(
            "version %s spans %d source_commits (%s) — the version tag "
            "does not identify one build"
            % (ver, len(commits), ", ".join(commits)))
    if group["n"] < MIN_SAMPLES:
        warnings.append(
            "version %s has only n=%d done run(s) — not enough samples to "
            "claim an improvement (need n>=%d)"
            % (ver, group["n"], MIN_SAMPLES))
    if error_runs:
        warnings.append(
            "version %s: %d of %d run(s) recorded nonzero errors (total "
            "%d) — the measured %s may be invalid"
            % (ver, error_runs, len(runs), errors_total, metric))
    if missing:
        warnings.append(
            "version %s: %d run(s) have no %s in their summary — excluded "
            "from the statistics"% (ver, missing, metric))
    return group


def _pick_baseline(groups: list, requested: Optional[str],
                   warnings: list) -> dict:
    by_ver = {g["version"]: g for g in groups}
    if requested:
        if requested in by_ver:
            return by_ver[requested]
        warnings.append(
            "requested baseline %s is not among the compared versions — "
            "using %s (oldest) instead"
            % (requested, groups[0]["version"]))
    return groups[0]


def _fill_deltas(groups: list, base: dict, warnings: list) -> None:
    for g in groups:
        if g is base or g["mean"] is None:
            continue
        if base["mean"] is None:
            continue
        if base["mean"] == 0:
            warnings.append(
                "baseline %s mean is 0 — delta percentages are undefined"
                % base["version"])
            continue
        delta = (g["mean"] - base["mean"]) / base["mean"] * 100.0
        g["delta_vs_baseline_pct"] = round(delta, 3)
        g["delta_exceeds_spread"] = delta_exceeds_spread(base, g)
        if not g["delta_exceeds_spread"]:
            hb, hc = _spread_half_width(base), _spread_half_width(g)
            if hb is None or hc is None:
                warnings.append(
                    "version %s: delta %+.2f%% vs baseline %s cannot be "
                    "checked against the observed spread (n<2 on one side "
                    "— spread unknown, NOT cleared)"
                    % (g["version"], g["delta_vs_baseline_pct"],
                       base["version"]))
            else:
                warnings.append(
                    "version %s: delta %+.2f%% vs baseline %s is INSIDE "
                    "the observed spread (+-%.4g) — not distinguishable "
                    "from noise"
                    % (g["version"], g["delta_vs_baseline_pct"],
                       base["version"], hb + hc))


def _cross_group_warnings(groups: list, warnings: list) -> None:
    if len(groups) < 2:
        return
    keys = sorted({k for g in groups for k in g["params_keys"]})
    if len(keys) > 1:
        diff = _differing_params(keys)
        detail = ", ".join(
            "%s=%s" % (g["version"], g["params_key"] or "|".join(
                g["params_keys"])) for g in groups)
        warnings.append(
            "versions being compared do not share one params_key (%s) — "
            "differing params: %s — comparison is CONFOUNDED"
            % (detail, ", ".join(diff) or "unknown"))
    # rel_threshold=-1 is the registry's "leave the image's value alone".
    # Two groups can therefore share a params_key and STILL have run at
    # different effective RELEASE_THRESHOLDs — POR is 20, which starves
    # the credit loop on small drains, so this is exactly the kind of
    # difference that masquerades as an RTL improvement.
    inherited = [g["version"] for g in groups
                 if any(parse_params_key(k).get("rel_threshold") == "-1"
                        for k in g["params_keys"])]
    if inherited:
        warnings.append(
            "versions %s ran with rel_threshold=-1 (inherit whatever the "
            "deployed image had) — the effective RELEASE_THRESHOLD is "
            "unknown and can differ per image; a delta may be a "
            "credit-release difference, not RTL. Pin it (rel_threshold=0) "
            "to compare honestly." % ", ".join(inherited))

    fifos = sorted({f for g in groups for f in g["fifo_labels"]})
    if len(fifos) > 1:
        detail = ", ".join(
            "%s=%s" % (g["version"], g["fifo_label"] or "|".join(
                g["fifo_labels"])) for g in groups)
        warnings.append(
            "versions being compared differ in fifo_label (%s) — a "
            "different RX FIFO build is a different DUT — comparison is "
            "CONFOUNDED" % detail)


# ── HTTP surface ─────────────────────────────────────────────────────

def _split_versions(raw: Optional[str]) -> Optional[list]:
    if not raw:
        return None
    return [v.strip() for v in raw.split(",") if v.strip()] or None


def build_router(get_state):
    """Router for the comparison endpoints.

    ``get_state`` is a zero-arg callable returning the app's AppState
    (so the router reaches ``state.store``) — the same injection shape
    the monitor router uses."""
    from fastapi import APIRouter, HTTPException

    router = APIRouter()

    @router.get("/api/versions")
    async def api_versions():
        return list_versions(get_state().store)

    @router.get("/api/compare")
    async def api_compare(test: str = "throughput_m2s",
                          versions: Optional[str] = None,
                          params_key: Optional[str] = None,
                          metric: str = DEFAULT_METRIC,
                          baseline: Optional[str] = None):
        try:
            return compare_versions(
                get_state().store, test=test,
                versions=_split_versions(versions),
                params_key=params_key, metric=metric, baseline=baseline)
        except ValueError as exc:
            raise HTTPException(400, str(exc))

    return router
