#!/usr/bin/env bash
# build.sh <worktree> [--dry-run]
#
# V2 kr260-pair-onchip FPGA image of a TideLink worktree, with every precondition checked before Vivado starts
# and every claim about the result checked after it.  Nothing here touches a board.  Originally written for the
# rev-2 port of the five compute-chiplet fixes (A7, H30/H31, EMA+SRAM[ASIC-only], TL-036, ErrInjection 0x23C host fix)
# and extended with the TL-059 design-E markers.
#
# Start it (about 45 to 90 minutes; Wave C builds took 40 to 95 minutes), from your own terminal or tmux:
#   nohup bash scripts/hw/build.sh <worktree> > $HW_OUT/logs/build-$(date +%m%d-%H%M).log 2>&1 &
# The last line of the log is always  BUILD_EXIT=<n>:
#   0  built, and every assertion held                  2  a precheck failed (Vivado never started)
#   3  a source marker is missing (Vivado never started) 4  built, but an assertion on the result failed
#   other  make/Vivado exit status
# --dry-run: run every precheck and the source-marker check, print what would run, start nothing.
#
# Environment (see scripts/hw/hw_rig.env.example):
#   PHC_REPO_DIR   REQUIRED. PHC (ptp-hardware-clock-ahb) checkout; must be clean at PHC_PIN_SHA
#   PHC_PIN_SHA    default 615e2b4
#   HW_OUT         default <repo>/imp/hw_regress: logs/ and builds/<sha8>/ evidence go here (hw_test.sh reads builds/)
#   MIN_FREE_GB    default 40
#   MARKER_GROUPS  default a7,h30,h31,tl036,errinj,asic,tl059  (narrow it only to build a partial tree on purpose)
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd -P)
HW_OUT=${HW_OUT:-$REPO/imp/hw_regress}
mkdir -p "$HW_OUT/logs" "$HW_OUT/builds"
TARGET=kr260-pair-onchip
WT=""; DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) [ -z "$WT" ] && WT="$a" || { echo "unexpected argument: $a"; exit 2; } ;;
  esac
done
RC=2
trap 'echo "BUILD_EXIT=$RC$([ "$DRY" = 1 ] && echo " (dry-run: no Vivado was run)")"' EXIT
[ -n "$WT" ] || { echo "usage: build.sh <worktree> [--dry-run]"; RC=2; exit 2; }

PHC=${PHC_REPO_DIR:-}
PHC_PIN=${PHC_PIN_SHA:-615e2b4}
MIN_FREE_GB=${MIN_FREE_GB:-40}
MARKER_GROUPS=${MARKER_GROUPS:-a7,h30,h31,tl036,errinj,asic,tl059}
FLIST=tidelink_fpga_v2.flist
NFAIL=0
pre() { # pre PASS|FAIL|INFO name detail
  printf '[PRECHECK %-4s] %s: %s\n' "$1" "$2" "$3"
  [ "$1" = FAIL ] && NFAIL=$((NFAIL + 1))
  return 0
}

echo "build.sh start $(date '+%F %T')  host=$(hostname)  dry_run=$DRY"
echo "worktree arg : $WT"

# ---- P1/P2/P3 worktree ------------------------------------------------------------------------
if [ -d "$WT" ] && TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null); then
  WT=$(cd "$WT" && pwd -P)
  if [ "$TOP" = "$WT" ]; then pre PASS worktree "$WT is a git worktree root"
  else pre FAIL worktree "$WT is inside $TOP, not a worktree root"; fi
else
  pre FAIL worktree "$WT is not a git worktree"; RC=2; exit 2
fi
HEAD_FULL=$(git -C "$WT" rev-parse HEAD)
HEAD_SHORT=$(git -C "$WT" rev-parse --short=8 HEAD)
BRANCH=$(git -C "$WT" branch --show-current)
pre INFO head "$HEAD_FULL (branch ${BRANCH:-detached})"
DIRTY=$(git -C "$WT" status --porcelain 2>&1)       # same command tl_git_sha uses; untracked counts
if [ -z "$DIRTY" ]; then pre PASS clean "git status --porcelain is empty (manifest will say git_dirty false)"
else pre FAIL clean "worktree is dirty, the manifest would say git_dirty true: $(printf '%s' "$DIRTY" | head -3 | tr '\n' '|')"; fi

# ---- P4 site.env and what it names ------------------------------------------------------------
if [ -f "$WT/site.env" ]; then
  pre PASS site.env "present"
  SITE=$( set +u; cd "$WT" && source ./site.env >/dev/null 2>&1; echo "CMSDK_DIR=${CMSDK_DIR:-}"; echo "CMSDK_FPGA_SRAM_V=${CMSDK_FPGA_SRAM_V:-}"; echo "XHB500_IP_DIR=${XHB500_IP_DIR:-}" )
  eval "$(printf '%s\n' "$SITE" | sed 's/^/S_/')"
  if [ -n "${S_CMSDK_DIR:-}" ] && [ -d "$S_CMSDK_DIR" ]; then pre PASS CMSDK_DIR "$S_CMSDK_DIR"; else pre FAIL CMSDK_DIR "unset or not a directory: '${S_CMSDK_DIR:-}'"; fi
  SRAMV=${S_CMSDK_FPGA_SRAM_V:-${S_CMSDK_DIR:-}/logical/models/memories/cmsdk_fpga_sram.v}
  if [ -f "$SRAMV" ]; then pre PASS CMSDK_FPGA_SRAM_V "$SRAMV"; else pre FAIL CMSDK_FPGA_SRAM_V "file not found: $SRAMV"; fi
  if [ -n "${S_XHB500_IP_DIR:-}" ] && [ -d "$S_XHB500_IP_DIR" ]; then pre PASS XHB500_IP_DIR "$S_XHB500_IP_DIR"; else pre FAIL XHB500_IP_DIR "unset or not a directory: '${S_XHB500_IP_DIR:-}'"; fi
else
  pre FAIL site.env "missing: copy site.env from a working worktree (it is gitignored, fresh clones have none)"
fi

# ---- P5 V2 PHY ---------------------------------------------------------------------------------
if [ -n "${TIDELINK_PHY_V2:-}" ] && [ "${TIDELINK_PHY_V2}" != 1 ]; then
  pre FAIL TIDELINK_PHY_V2 "caller exported TIDELINK_PHY_V2='${TIDELINK_PHY_V2}'; a KR260 build must be V2 (=1)"
else
  pre PASS TIDELINK_PHY_V2 "will be exported as 1 for package_ip and build_design (the manifest phy_marker is checked afterwards)"
fi
export TIDELINK_PHY_V2=1

# ---- P6 PHC pin --------------------------------------------------------------------------------
if [ -z "$PHC" ]; then
  pre FAIL PHC_REPO_DIR "not set: export PHC_REPO_DIR=<clean ptp-hardware-clock-ahb checkout at $PHC_PIN>"
elif [ -d "$PHC/.git" ] || [ -f "$PHC/.git" ]; then
  PHC_HEAD=$(git -C "$PHC" rev-parse --short=7 HEAD 2>/dev/null); PHC_DIRTY=$(git -C "$PHC" status --porcelain 2>/dev/null)
  if [ "$PHC_HEAD" = "$PHC_PIN" ] && [ -z "$PHC_DIRTY" ]; then pre PASS PHC_REPO_DIR "$PHC clean at $PHC_HEAD"
  else pre FAIL PHC_REPO_DIR "$PHC is at '$PHC_HEAD' dirty='${PHC_DIRTY:+yes}' (need clean $PHC_PIN)"; fi
else
  pre FAIL PHC_REPO_DIR "$PHC is not a git checkout"
fi

# ---- P7 Vivado ---------------------------------------------------------------------------------
if command -v vivado >/dev/null 2>&1; then
  pre PASS vivado "$(command -v vivado)  $(vivado -version 2>/dev/null | head -1)"
else
  pre FAIL vivado "not on PATH (module load / source settings64.sh first)"
fi

# ---- P8 disk -----------------------------------------------------------------------------------
FREE_GB=$(df -Pk "$WT" | awk 'NR==2{printf "%d", $4/1048576}')
if [ "${FREE_GB:-0}" -ge "$MIN_FREE_GB" ]; then pre PASS disk "${FREE_GB} GB free (need $MIN_FREE_GB)"; else pre FAIL disk "${FREE_GB:-?} GB free, need $MIN_FREE_GB"; fi

# ---- P9 deps and generated trees the flist reads ----------------------------------------------
for d in deps/tidelink-phy/rtl deps/axi-chiplet-controller/logical/wlink; do
  if [ -d "$WT/$d" ] && [ -n "$(ls -A "$WT/$d" 2>/dev/null)" ]; then pre PASS "$d" "populated"; else pre FAIL "$d" "missing or empty (git submodule update --init)"; fi
done
if [ -d "$WT/deps/xhb500/generated" ] && [ -n "$(ls -A "$WT/deps/xhb500/generated" 2>/dev/null)" ]; then
  pre PASS xhb500.generated "populated (manifest xhb500_tree must read match)"
else
  pre FAIL xhb500.generated "empty: set_env.sh would generate it, but then xhb500_tree is not the recorded RTL; copy it from a known-good worktree"
fi
[ -f "$WT/flists/$FLIST" ] && pre PASS flist "flists/$FLIST" || pre FAIL flist "flists/$FLIST missing"
OUT="$WT/imp/fpga/output/$TARGET"
if [ -e "$OUT" ]; then
  [ "$DRY" = 1 ] && pre INFO stale-output "$OUT exists (a real run deletes it first, so an old manifest can never satisfy the asserts)" \
                 || pre INFO stale-output "$OUT exists and will be deleted"
fi
[ -x "$(command -v python3)" ] && pre PASS python3 "$(command -v python3)" || pre FAIL python3 "missing"

# ---- source markers (before spending an hour of Vivado) -----------------------------------------
echo
echo "== source markers: do the files $FLIST compiles contain the fixes? =="
MK_SRC="$HW_OUT/logs/markers-source-$HEAD_SHORT.txt"
python3 "$HERE/check_markers.py" --tree "$WT" --mode source --groups "$MARKER_GROUPS" --flist "$FLIST" | tee "$MK_SRC"
MK_RC=${PIPESTATUS[0]}

echo
if [ "$DRY" = 1 ]; then
  echo "== dry-run plan (nothing below was executed) =="
  echo "  cd $WT && { set +u; source ./set_env.sh; set -u; }   # output of set_env.sh goes into the make log, never silenced"
  echo "  rm -rf imp/fpga/output/$TARGET"
  echo "  TIDELINK_PHY_V2=1 nice -n 10 make -C fpga TARGET=$TARGET PHC_REPO_DIR=$PHC build_design"
  echo "  then assert manifest: phy_marker V2, flist $FLIST, source_commit == $HEAD_FULL, git_dirty false, xhb500_tree match,"
  echo "       usr_access 0x${HEAD_FULL: -8}, manifest sha256 == sha256sum(tidelink.bit), WNS >= 0, WHS >= 0, constraints met,"
  echo "       then check_markers.py --mode built on imp/fpga/tidelink_ip/src"
  echo "dry-run summary: $NFAIL precheck failure(s); markers rc=$MK_RC"
  if [ "$NFAIL" -eq 0 ] && [ "$MK_RC" -eq 0 ]; then RC=0; else RC=2; fi
  exit "$RC"
fi

if [ "$NFAIL" -gt 0 ]; then echo "STOP: $NFAIL precheck(s) failed, Vivado not started."; RC=2; exit 2; fi
if [ "$MK_RC" -ne 0 ]; then echo "STOP: source markers missing, the tree does not contain the fixes. Vivado not started."; RC=3; exit 3; fi

# ---- build -------------------------------------------------------------------------------------
MAKELOG="$HW_OUT/logs/vivado-make-$HEAD_SHORT-onchip-V2.log"
echo "== build start $(date '+%F %T')  tidelink=$HEAD_FULL phc=$(git -C "$PHC" rev-parse HEAD)"
echo "   make log: $MAKELOG"
(
  cd "$WT" || exit 2
  set +u
  # shellcheck disable=SC1091
  source ./set_env.sh || { echo "set_env.sh failed: not building"; exit 2; }
  set -u
  export TIDELINK_PHY_V2=1
  rm -rf "imp/fpga/output/$TARGET"
  nice -n 10 make -C fpga TARGET="$TARGET" PHC_REPO_DIR="$PHC" build_design
) > "$MAKELOG" 2>&1
MK=$?
echo "== build exit $MK  $(date '+%F %T')"
if [ "$MK" -ne 0 ]; then
  echo "make/Vivado failed; last lines of $MAKELOG:"; tail -15 "$MAKELOG"
  RC=$MK; [ "$RC" -eq 0 ] && RC=4; exit "$RC"
fi

# ---- assertions on the result ------------------------------------------------------------------
BIT="$OUT/tidelink.bit"; MAN="$OUT/tidelink_manifest.json"
RPT=$(ls "$OUT"/*timing_summary_routed.rpt 2>/dev/null | head -1)
FAILS=0
chk() { # chk PASS|FAIL name detail
  printf '[ASSERT %-4s] %s: %s\n' "$1" "$2" "$3"; [ "$1" = FAIL ] && FAILS=$((FAILS + 1)); return 0; }
[ -f "$BIT" ] && chk PASS bit-exists "$BIT" || chk FAIL bit-exists "$BIT not produced"
[ -f "$MAN" ] && chk PASS manifest-exists "$MAN" || chk FAIL manifest-exists "$MAN not produced"
BIT_SHA=""
if [ -f "$BIT" ] && [ -f "$MAN" ]; then
  BIT_SHA=$(sha256sum "$BIT" | cut -d' ' -f1)
  ASSERT_OUT=$(HEAD_FULL="$HEAD_FULL" BIT_SHA="$BIT_SHA" MAN="$MAN" FLIST="$FLIST" TARGET="$TARGET" RPT="${RPT:-}" python3 - <<'PYEOF'
import json, os, re
m = json.load(open(os.environ["MAN"]))
out = []
def a(ok, name, detail): out.append("[ASSERT %-4s] %s: %s" % ("PASS" if ok else "FAIL", name, detail))
head = os.environ["HEAD_FULL"]
a(m.get("phy_marker") == "V2", "manifest.phy_marker", "%r (need 'V2')" % m.get("phy_marker"))
a(m.get("flist") == os.environ["FLIST"], "manifest.flist", "%r (need %r)" % (m.get("flist"), os.environ["FLIST"]))
a(m.get("source_commit") == head, "manifest.source_commit", "%s (worktree HEAD %s)" % (m.get("source_commit"), head))
a(m.get("git_dirty") is False, "manifest.git_dirty", repr(m.get("git_dirty")))
a(m.get("xhb500_tree") == "match", "manifest.xhb500_tree", repr(m.get("xhb500_tree")))
a(m.get("target") == os.environ["TARGET"], "manifest.target", repr(m.get("target")))
a(m.get("usr_access") == "0x" + head[-8:], "manifest.usr_access", "%s (need 0x%s)" % (m.get("usr_access"), head[-8:]))
a(m.get("sha256") == os.environ["BIT_SHA"], "manifest.sha256 == sha256sum(tidelink.bit)", "%s vs %s" % (m.get("sha256"), os.environ["BIT_SHA"]))
rpt = os.environ.get("RPT", "")
if rpt and os.path.isfile(rpt):
    txt = open(rpt, errors="replace").read()
    i = txt.find("Design Timing Summary")
    nums = None
    if i >= 0:
        lines = txt[i:].split("\n")
        for k, l in enumerate(lines):
            if "WNS(ns)" in l:
                for l2 in lines[k + 1: k + 6]:
                    f = l2.split()
                    if f and re.match(r"^-?\d", f[0]):
                        nums = f; break
                break
    if nums:
        wns, whs = float(nums[0]), float(nums[4])
        a(wns >= 0, "timing.WNS", "%.3f ns" % wns)
        a(whs >= 0, "timing.WHS", "%.3f ns" % whs)
    else:
        a(False, "timing.summary", "could not parse WNS/WHS from %s" % rpt)
    a("All user specified timing constraints are met." in txt, "timing.constraints_met", rpt.split("/")[-1])
else:
    a(False, "timing.report", "no *timing_summary_routed.rpt in the output directory")
print("\n".join(out))
PYEOF
)
  printf '%s\n' "$ASSERT_OUT"
  FAILS=$((FAILS + $(printf '%s\n' "$ASSERT_OUT" | grep -c '^\[ASSERT FAIL\]')))
fi
NERR=$(grep -c '^ERROR:' "$MAKELOG" 2>/dev/null); NCRIT=$(grep -c 'CRITICAL WARNING' "$MAKELOG" 2>/dev/null)
echo "[INFO] Vivado log: ${NERR:-0} ERROR lines, ${NCRIT:-0} CRITICAL WARNING lines ($MAKELOG)"

echo
echo "== built markers: do the sources Vivado actually synthesised (packaged IP) contain the fixes? =="
MK_BLT="$HW_OUT/logs/markers-built-$HEAD_SHORT.txt"
python3 "$HERE/check_markers.py" --tree "$WT" --mode built --groups "$MARKER_GROUPS" --flist "$FLIST" | tee "$MK_BLT"
[ "${PIPESTATUS[0]}" -eq 0 ] || FAILS=$((FAILS + 1))

# ---- keep the evidence outside the git tree --------------------------------------------------
EV="$HW_OUT/builds/$HEAD_SHORT"; mkdir -p "$EV"
cp -f "$MAN" "$EV/" 2>/dev/null; cp -f "$MK_SRC" "$MK_BLT" "$EV/" 2>/dev/null
[ -n "$RPT" ] && cp -f "$RPT" "$EV/" 2>/dev/null
{ echo "$BIT_SHA  $BIT"; echo "worktree=$WT"; echo "head=$HEAD_FULL"; } > "$EV/BUILD_INFO.txt"

echo
echo "BIT_SHA256=$BIT_SHA"
echo "BITDIR=$OUT"
echo "NEXT: bash $HERE/hw_test.sh $OUT   (rig settings: scripts/hw/hw_rig.env.example)"
if [ "$FAILS" -eq 0 ]; then RC=0; echo "BUILD RESULT: PASS (image trustworthy for hardware)"
else RC=4; echo "BUILD RESULT: FAIL ($FAILS assertion(s) failed): do NOT deploy this image"; fi
exit "$RC"
