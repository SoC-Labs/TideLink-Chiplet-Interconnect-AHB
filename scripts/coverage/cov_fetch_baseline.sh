#!/usr/bin/env bash
# cov_fetch_baseline.sh - get the baseline a delta is measured against.
#
#   scripts/coverage/cov_fetch_baseline.sh --out imp/coverage/_baseline
#
# TWO SOURCES, IN ORDER, AND THE SECOND IS NOT A DEGRADED MODE.
#
#   1. verif-baseline in the store. The full artifact: the merged database
#      (replayable), the text report, the summary. Needs a credential.
#   2. docs/coverage/*.summary.json in this very checkout. The small half --
#      the canonical metrics, the scoped unexercised list, the manifest.
#      Roughly 10 KB per run, git-tracked, present in every clone, and enough
#      to compute the ENTIRE delta.
#
# Source 2 exists because a trend that only works while a server is up is a
# trend nobody consults. Everything cov_diff.py needs is in the summary; the
# database is needed only to ask a NEW question of an OLD run (what covered
# this line?), which is the rarer case and the one worth a credential.
#
# It fails LOUDLY when neither source yields a baseline. "No baseline" is not
# "no regression": the first is a missing measurement and the second is a
# result, and this project has already published a report where those two
# collapsed together.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${TIDELINK_HOME:-$(cd "$HERE/../.." && pwd)}"
OUT=""
BASE_URL="${ASIC_ARTIFACT_BASE:-}"
REPO="verif-baseline"
TRACKED="$ROOT/docs/coverage"

die() { echo "cov_fetch_baseline: $*" >&2; exit 1; }
note() { echo "[baseline] $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out)  OUT="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --base) BASE_URL="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$OUT" ] || die "--out is required"
mkdir -p "$OUT"

# ---- source 1: the store ----------------------------------------------------
if [ -n "$BASE_URL" ] && [ -r "$HOME/.netrc" ]; then
  note "trying $REPO at $BASE_URL"
  # AQL, not api/storage?list -- that endpoint is Artifactory Pro only on this
  # instance and returns an errors BODY that a naive parser reads as zero
  # results, i.e. "the store is empty". Recorded in artifactory.py's header;
  # it has already produced a wrong answer told to a human.
  q='items.find({"repo":"'"$REPO"'","name":"cov_summary.json"}).include("repo","path","name","modified").sort({"$desc":["modified"]}).limit(1)'
  body="$(curl -sS -n -X POST -H 'Content-Type: text/plain' -d "$q" \
          "$BASE_URL/api/search/aql" || true)"
  if printf '%s' "$body" | grep -q '"errors"'; then
    note "store returned an errors body -- treating the store as UNAVAILABLE,"
    note "not as empty. Falling through to the git-tracked baseline."
  else
    path="$(printf '%s' "$body" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
r=d.get("results") or []
if r:
    print("%s" % r[0]["path"])
' || true)"
    if [ -n "$path" ]; then
      # path is <project>/<block>/<run_tag>/report ; strip the last segment
      runpath="${path%/report}"
      note "baseline run: $runpath"
      ok=1
      for f in report/cov_summary.json unexercised/unexercised_scoped.json \
               manifest/cov_manifest.json; do
        mkdir -p "$OUT/$(dirname "$f")"
        curl -sS -n -f -o "$OUT/$f" "$BASE_URL/$REPO/$runpath/$f" || ok=0
      done
      if [ "$ok" = 1 ]; then
        echo "$REPO/$runpath" > "$OUT/BASELINE_SOURCE.txt"
        note "fetched from the store: $REPO/$runpath"
        exit 0
      fi
      note "partial fetch -- discarding it rather than diffing against half a"
      note "baseline, and falling through."
      rm -rf "${OUT:?}"/report "${OUT:?}"/unexercised "${OUT:?}"/manifest
    else
      note "no baseline in $REPO (the repo may be legitimately empty -- there"
      note "is no baseline until one is promoted)"
    fi
  fi
else
  note "no ASIC_ARTIFACT_BASE and/or no ~/.netrc -- not contacting the store"
fi

# ---- source 2: the git-tracked half ----------------------------------------
if [ -d "$TRACKED" ]; then
  # newest by name: run tags are UTC-stamped and sort lexically. No `head` in a
  # pipeline under pipefail.
  newest=""
  while IFS= read -r f; do newest="$f"; done < <(find "$TRACKED" -maxdepth 1 \
      -name '*.summary.json' -printf '%f\n' | sort)
  if [ -n "$newest" ]; then
    tag="${newest%.summary.json}"
    mkdir -p "$OUT/report" "$OUT/unexercised" "$OUT/manifest"
    cp "$TRACKED/$tag.summary.json"      "$OUT/report/cov_summary.json"
    [ -f "$TRACKED/$tag.unexercised.json" ] && \
      cp "$TRACKED/$tag.unexercised.json" "$OUT/unexercised/unexercised_scoped.json"
    [ -f "$TRACKED/$tag.manifest.json" ] && \
      cp "$TRACKED/$tag.manifest.json"    "$OUT/manifest/cov_manifest.json"
    echo "git:docs/coverage/$tag" > "$OUT/BASELINE_SOURCE.txt"
    note "using the git-tracked baseline docs/coverage/$tag"
    note "(the merged database is NOT here -- metric and unexercised deltas are"
    note " complete, 'which test covered this line' is not answerable offline)"
    exit 0
  fi
fi

die "no baseline available from either source.

  This is a HARD FAILURE, not a pass. 'No baseline' means the comparison was
  not made; it does not mean nothing regressed. Establish one with:

      make cov_pack && make cov_track && git add docs/coverage/
      make cov_baseline          # once credentials and the repo exist

  Until verif-baseline holds a promoted run, the git-tracked summaries in
  docs/coverage/ are the baseline, and there must be at least one."
