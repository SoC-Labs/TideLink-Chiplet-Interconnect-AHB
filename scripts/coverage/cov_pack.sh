#!/usr/bin/env bash
# cov_pack.sh - assemble ONE coverage artifact from a gate run.
#
#   scripts/coverage/cov_pack.sh --out imp/coverage \
#       --suites "$(make -s sim_gate_list)" \
#       --vdb 'cocotb/*/sim_build/simv.vdb' --vdb 'uvm/*/sim_build/simv.vdb'
#
# Produces, under --out/<run_tag>/, the exact tree that cov_publish.py uploads:
#
#   merged/cov_merged.vdb.tar.zst    the replayable database    ~2.4 MB measured
#   report/cov_report_text.tar.zst   urg -format text           ~173 KB measured
#   report/cov_summary.json          canonical metrics, small, UNCOMPRESSED
#   report/urg.log                   urg stdout+stderr -- the ONLY place the
#                                    "No source found" warning ever appears
#   unexercised/unexercised_scoped.json
#   unexercised/unexercised_scoped.txt
#   manifest/cov_manifest.json       fail-closed identity + all digests
#   manifest/SCOPE.txt               the scope file CONTENT, not just its digest
#   manifest/vdb_inputs.txt          every database that went into the merge
#
# The HTML report is generated for local viewing when --html is passed and is
# NEVER part of the artifact: measured 2026-08-26 it is ~11 MB against a 2.7 MB
# database it can be regenerated from in seconds. Publishing it would quadruple
# the store cost of every run to carry something derivable.
#
# SHELL RULES OBSERVED HERE, because this project has been bitten by each:
#   * `find ... | head -1` under `set -o pipefail` kills the script mid-run with
#     the exit code masked -- it bit three times in three different files in the
#     Artifactory tooling. Use `-print -quit`, or list into a variable.
#   * never `tar -tzf f | grep -q`, same reason.
#   * rsync/tar option lists go in ARRAYS, never in a `${var:+--opt="$x"}`
#     expansion, which keeps the quotes literal and silently does nothing.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${TIDELINK_HOME:-$(cd "$HERE/../.." && pwd)}"
SCOPE="$HERE/SCOPE.txt"
OUT="$ROOT/imp/coverage"
SUITES=""
SUITES_DIR="$ROOT/imp/sim_gate"
METRICS="line+cond+fsm+tgl+branch"
WANT_HTML=0
declare -a VDB_GLOBS=()

die() { echo "cov_pack: $*" >&2; exit 1; }
note() { echo "[cov_pack] $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out)        OUT="$2"; shift 2 ;;
    --scope)      SCOPE="$2"; shift 2 ;;
    --suites)     SUITES="$2"; shift 2 ;;
    --suites-dir) SUITES_DIR="$2"; shift 2 ;;
    --vdb)        VDB_GLOBS+=("$2"); shift 2 ;;
    --metrics)    METRICS="$2"; shift 2 ;;
    --html)       WANT_HTML=1; shift ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

command -v urg >/dev/null 2>&1 || die "urg not on PATH -- source ./set_env.sh first"
command -v zstd >/dev/null 2>&1 || die "zstd not on PATH"
[ -f "$SCOPE" ] || die "scope file not found: $SCOPE"

if [ ${#VDB_GLOBS[@]} -eq 0 ]; then
  VDB_GLOBS=("cocotb/*/sim_build/simv.vdb" "cocotb/*/coverage.vdb"
             "uvm/*/sim_build*/simv.vdb")
fi

# ---- collect the databases -------------------------------------------------
# Listed into an array, never piped into head. An EMPTY list is a hard failure,
# not a zero-coverage artifact: "no databases found" and "nothing is covered"
# are the two readings this whole design exists to keep apart.
declare -a VDBS=()
for g in "${VDB_GLOBS[@]}"; do
  # An absolute glob is used as given; a relative one is anchored at $ROOT.
  case "$g" in /*) pat="$g" ;; *) pat="$ROOT/$g" ;; esac
  for d in $pat; do
    [ -d "$d" ] && VDBS+=("$d")
  done
done
[ ${#VDBS[@]} -gt 0 ] || die "no .vdb databases matched ${VDB_GLOBS[*]}.
  This is a HARD FAILURE on purpose. The existing GitLab coverage job exits 0
  with 'WARNING: No VDB coverage databases found. Skipping merge.' -- a green
  job that measured nothing, which is the exact class of vacuous pass this
  artifact is meant to make impossible."

note "${#VDBS[@]} database(s) will be merged"

# ---- identity FIRST --------------------------------------------------------
# Before the merge, so the recorded commit is the tree that was READ, not
# whatever it has become by the time a long urg finishes. (ARTIFACT_FLOW_PLAN
# P1-5: capture git_sha at input-read time, not at write time.)
TMPMAN="$(mktemp -t cov_manifest.XXXXXX.json)"
trap 'rm -f "$TMPMAN"' EXIT
python3 "$HERE/cov_identity.py" --root "$ROOT" --scope "$SCOPE" \
  --suites-dir "$SUITES_DIR" --suites "${SUITES// /,}" --out "$TMPMAN"

RUN_TAG="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["run_tag"])' "$TMPMAN")"
DEST="$OUT/$RUN_TAG"
mkdir -p "$DEST/merged" "$DEST/report" "$DEST/unexercised" "$DEST/manifest"
note "run_tag $RUN_TAG"
note "dest    $DEST"

printf '%s\n' "${VDBS[@]}" > "$DEST/manifest/vdb_inputs.txt"
cp "$SCOPE" "$DEST/manifest/SCOPE.txt"

# ---- merge -----------------------------------------------------------------
WORK="$(mktemp -d -t cov_pack.XXXXXX)"
trap 'rm -f "$TMPMAN"; rm -rf "$WORK"' EXIT

declare -a URG=(urg -full64 -dbname "$WORK/cov_merged.vdb"
                -report "$WORK/rpt" -metric "$METRICS")
if [ "$WANT_HTML" = 1 ]; then URG+=(-format both); else URG+=(-format text); fi
for d in "${VDBS[@]}"; do URG+=(-dir "$d"); done

note "merging..."
# urg's exit status is captured, NOT swallowed. The existing CI job pipes urg
# through `grep -E 'Note|Error|Warning' || true`, which discards urg's exit code
# entirely -- a failed merge there is a green job.
set +e
"${URG[@]}" > "$DEST/report/urg.log" 2>&1
URG_RC=$?
set -e
echo "urg_exit_status $URG_RC" >> "$DEST/report/urg.log"
if [ "$URG_RC" -ne 0 ]; then
  die "urg exited $URG_RC -- see $DEST/report/urg.log. Refusing to produce an
  artifact from a failed merge; a coverage number from a merge that errored is
  a number nobody can defend."
fi
[ -d "$WORK/cov_merged.vdb" ] || die "urg exited 0 but produced no merged database"

# ---- canonical summary + scoped unexercised list ---------------------------
python3 "$HERE/cov_report.py" --report "$WORK/rpt" --scope "$SCOPE" \
  --urg-log "$DEST/report/urg.log" --manifest "$TMPMAN" \
  --out-dir "$WORK/out"

cp "$WORK/out/cov_summary.json"        "$DEST/report/"
cp "$WORK/out/unexercised_scoped.json" "$DEST/unexercised/"
cp "$WORK/out/unexercised_scoped.txt"  "$DEST/unexercised/"

# ---- compress --------------------------------------------------------------
# -19 on the .vdb buys 15% (measured); it is kept because the artifact is tiny
# either way and a single archive is one object with one digest rather than a
# few hundred files. -19 on the TEXT report buys 92x and is unambiguous.
tar -C "$WORK" -cf - cov_merged.vdb | zstd -19 -T0 -q -o "$DEST/merged/cov_merged.vdb.tar.zst" -f
# --exclude MUST precede the path operand: GNU tar treats it positionally and
# prints "has no effect" (then exits non-zero under this tar) if it follows.
tar -C "$WORK/rpt" --exclude='*.html' --exclude='./css' --exclude='./js' -cf - . \
  | zstd -19 -T0 -q -o "$DEST/report/cov_report_text.tar.zst" -f

if [ "$WANT_HTML" = 1 ]; then
  rm -rf "$DEST/../${RUN_TAG}-html"
  cp -r "$WORK/rpt" "$DEST/../${RUN_TAG}-html"
  note "HTML report (NOT published) at $OUT/${RUN_TAG}-html/dashboard.html"
fi

# ---- finish the manifest: digests of the bytes that will be published -------
python3 - "$TMPMAN" "$DEST" <<'PY'
import hashlib, json, os, sys
man_path, dest = sys.argv[1], sys.argv[2]
man = json.load(open(man_path))

def digests(p):
    h1, h256, h5 = hashlib.sha1(), hashlib.sha256(), hashlib.md5()
    n = 0
    with open(p, "rb") as fh:
        for c in iter(lambda: fh.read(1 << 20), b""):
            h1.update(c); h256.update(c); h5.update(c); n += len(c)
    # All three, deliberately, and for the reason artifactory.py records: the
    # store indexes sha1, this project's manifests record sha256, and md5 is
    # what an external report cites. A record that omits one cannot be joined
    # to whoever cites that one.
    return {"sha1": h1.hexdigest(), "sha256": h256.hexdigest(),
            "md5": h5.hexdigest(), "bytes": n}

files = {}
for sub in ("merged", "report", "unexercised", "manifest"):
    d = os.path.join(dest, sub)
    for name in sorted(os.listdir(d)):
        p = os.path.join(d, name)
        if os.path.isfile(p) and name != "cov_manifest.json":
            files["%s/%s" % (sub, name)] = digests(p)
man.setdefault("digests", {})["files"] = files

summary = json.load(open(os.path.join(dest, "report", "cov_summary.json")))
man["digests"]["coverage_id"] = summary.get("coverage_id")
man["completeness"] = summary.get("completeness")
man["object_detail"] = summary.get("object_detail")
man["counts"] = summary.get("counts")

# A partial merge can be published (the evidence is real) but can never become
# the baseline other runs are measured against.
if man["completeness"] != "complete":
    man["verdict"]["promotable"] = False
    man["verdict"].setdefault("reasons", []).append(
        "merge is %s" % man["completeness"])

with open(os.path.join(dest, "manifest", "cov_manifest.json"), "w") as fh:
    json.dump(man, fh, indent=2, sort_keys=True)
print("[cov_pack] manifest: promotable=%s completeness=%s coverage_id=%s"
      % (man["verdict"]["promotable"], man["completeness"],
         str(man["digests"]["coverage_id"])[:16]))
PY

note "artifact assembled:"
du -sh "$DEST"/*/* 2>/dev/null | sed 's/^/[cov_pack]   /'
note "total: $(du -sh "$DEST" | cut -f1)"
note "publish (dry run):  python3 $HERE/cov_publish.py --artifact $DEST"
