#!/usr/bin/env bash
# rehearse.sh <label> [hw_test.sh args...]
#
# Stub rehearsal of hw_test.sh: NO network, NO board.  Fake ssh/sshpass/scp/flock/ping (this directory) are put first on
# PATH and hw_test.sh --rehearse refuses to run unless all five resolve here.  The image is a SYNTHETIC fixture
# (a header-valid .bit with a dummy payload and a matching manifest) built in a temp dir; nothing in the repo is written.
#
# Env passes through: EXPECT_FIXED, STREAM, BRINGUPS, CRCSTATS, CRCSTATS_N, STUB_FAIL_NTH="substr:N:rc", STUB_FAIL_MATCH,
# STUB_STORM=1, STUB_STATS_LOST=1, STUB_STATS_DETECTED=n, STUB_A7_OFF=1 ...
# REHEARSE_OUT=<dir>  where the results/console/stub log go (default: a fresh mktemp -d; printed).
# BITDIR=<dir>        use a real image directory instead of the synthetic fixture.
# REHEARSE_OMIT="V1 V2" unset these settings before the run (configuration-refusal tests).
set -u
STUBDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HERE=$(cd "$STUBDIR/.." && pwd)                 # scripts/hw
REPO=$(cd "$HERE/../.." && pwd -P)
label=${1:?usage: rehearse.sh <label> [hw_test.sh args]}; shift
OUT=${REHEARSE_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/hw-rehearsal.XXXXXX")}; mkdir -p "$OUT"
RES=$OUT/rehearsal-$label; rm -rf "$RES"; rm -f "$OUT/rehearsal-$label.log"*

if [ -z "${BITDIR:-}" ]; then
  BITDIR=$OUT/fixture/imp/fpga/output/kr260-pair-onchip; mkdir -p "$BITDIR"
  REPO="$REPO" BITDIR="$BITDIR" python3 - <<'PYEOF'
import hashlib, json, os, struct, subprocess
d, repo = os.environ["BITDIR"], os.environ["REPO"]
def fld(tag, s): return tag + struct.pack(">H", len(s)) + s
payload = bytes([0xFF] * 16 + [0xAA, 0x99, 0x55, 0x66]) + bytes(range(256)) * 4   # sync word 0xAA995566 in native order
hdr = struct.pack(">H", 9) + b"\x0f\xf0\x0f\xf0\x0f\xf0\x0f\xf0\x00" + struct.pack(">H", 1)
hdr += fld(b"a", b"fixture\x00") + fld(b"b", b"xck26\x00") + fld(b"c", b"2000/01/01\x00") + fld(b"d", b"00:00:00\x00")
hdr += b"e" + struct.pack(">I", len(payload))
bit = hdr + payload
open(os.path.join(d, "tidelink.bit"), "wb").write(bit)
open(os.path.join(d, "tidelink.hwh"), "w").write("<fixture/>\n")
head = subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"]).decode().strip()
json.dump(dict(phy_marker="V2", flist="tidelink_fpga_v2.flist", source_commit=head, git_dirty=False, xhb500_tree="match",
               target="kr260-pair-onchip", sha256=hashlib.sha256(bit).hexdigest(), fixture=True),
          open(os.path.join(d, "tidelink_manifest.json"), "w"))
PYEOF
fi

: > "$OUT/rig.lock"
# synthetic, documentation-only site values (192.0.2.0/24 is TEST-NET-1, .invalid never resolves)
export STUBDIR STUB_BOARD_DIR=$REPO/pynq_host/hw_regress STUB_BIN=$RES/tidelink.bin STUBLOG=$OUT/rehearsal-$label.log
export KR260_PASSWORD=stub-not-a-password KR260_SUDO_PASSWORD=stub-not-a-password
export KR260_LOCK=$OUT/rig.lock KR260_IP=192.0.2.10 KR260_IP2=192.0.2.11 POR_HOST=por-host.invalid
export HW_OUT=$OUT/hw_out HW_ENV_FILE=/dev/null
for v in ${REHEARSE_OMIT:-}; do unset "$v"; done      # REHEARSE_OMIT="KR260_IP ..." : prove hw_test.sh refuses a missing setting
export PATH=$STUBDIR:$PATH
bash "$HERE/hw_test.sh" "$BITDIR" --worktree "$REPO" --rehearse --results "$RES" "$@" > "$OUT/rehearsal-$label.console" 2>&1
rc=$?
echo "rehearsal $label: hw_test.sh rc=$rc  (console: $OUT/rehearsal-$label.console, results: $RES/SUMMARY.tsv)"
exit $rc
