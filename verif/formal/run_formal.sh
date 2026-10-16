#!/usr/bin/env bash
# Bounded FPV of the CRC-replay contract on WlinkGenericFCSM_6 with Synopsys VC Formal.
#   verif/formal/run_formal.sh [main|mutant] [crc_mode 1|2|0]     (default: main, CRC on)
# Env: TL_FC_TIME=<engine seconds, default 300>  TL_FC_WALL=<wall limit, default 900>  TL_FC_STRICT=1 (no waiver W1)  FORMAL_OUT=<dir>
# Needs: `module load vc_formal` (or vcf on PATH) and a VC Formal licence (SNPSLMD_LICENSE_FILE).
set -eu
ARM=${1:-main}; export TL_FC_STRICT=${TL_FC_STRICT:-0}; export TL_FC_CRC_MODE=${2:-1}
ROOT=$(cd "$(dirname "$0")/../.." && pwd); export ROOT
OUT=${FORMAL_OUT:-$ROOT/imp/formal/$ARM}; rm -rf "$OUT"; mkdir -p "$OUT"
[ "$ARM" = mutant ] && export TL_FC_MUTANT=1 || export TL_FC_MUTANT=0
command -v vcf >/dev/null || { echo "vcf not on PATH (module load vc_formal)"; exit 2; }
# absolute-path flist (the committed one is repo-relative)
sed -e '/^\/\//d' -e "s#^#$ROOT/#" "$ROOT/verif/formal/fcsm6.f" > "$ROOT/verif/formal/fcsm6.f.resolved"
trap 'rm -f "$ROOT/verif/formal/fcsm6.f.resolved"' EXIT
cd "$OUT"
timeout "${TL_FC_WALL:-900}" vcf -batch -f "$ROOT/verif/formal/vcf_fc_crc.tcl" -out_dir "$OUT/vcf.out" -cmd_log_file cmd.log > "$OUT/vcf.log" 2>&1 || echo "vcf exit $?"
grep -E 'Fail|Proven|Bounded|Unreachable|Reachable|Covered|Inconclusive|Error' "$OUT/vcf.log" | head -60
