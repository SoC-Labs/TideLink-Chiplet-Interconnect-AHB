#!/usr/bin/env bash
# ila_capture_run.sh -- autonomous die_a ILA capture of the rc=124 wedge.
# Deploys die_a=_ila (debug core) + die_b=_tl033 flip, good-eye bring-up, arms the ILA over
# JTAG (mapstone-dev hw_server, cable XFL1MHS3ZB1PA @2MHz, trigger dbg_a2l_wedged==1), then fires
# the deterministic AW CRC inject and uploads the CSV BEFORE the errinject's ~60s-timeout POR.
# Good-citizen leasing. Wedge-safe. Reads the decision tree from the CSV at the end.
set -u
ROOT=/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet
SC="$ROOT/tidelink/pynq_host/scripts"
SCR=/tmpdir/claude-74755/-home-dam1n19-SoCLabs-nanosoc-ethernet-chiplet/e31cf0db-becf-4762-a881-c1c17e74fb93/scratchpad
export TIDELINK_HOME="$ROOT/tidelink"; export PYTHONPATH="$SC/coverage"
ILA="$TIDELINK_HOME/imp/fpga/output/_ila"
FLIP="$TIDELINK_HOME/imp/fpga/output/_tl033/kr260-eth-chiplet-flip"
OUT="$SCR/ila_capture_run"; mkdir -p "$OUT"; LOG="$OUT/run.log"; SUM="$OUT/summary.txt"; DONE="$OUT/done"
: > "$LOG"; : > "$SUM"; rm -f "$DONE"
A=ubuntu@10.22.24.159; B=ubuntu@10.22.24.153
DEP="$SC/kr260_deploy.sh"
# Board password from the environment. This USED TO scrape the literal out of
# kr260_eth_bringup_pair.sh's "${KR260_PASSWORD:-<literal>}" default, which is
# both a way of depending on a hardcoded credential at a distance and a silent
# no-op the moment that default goes away (PW="" and mask() stops masking).
PW="${KR260_PASSWORD:?KR260_PASSWORD is not set. Export the board ssh password before running this script; it is deliberately not hardcoded (this repository is public).}"
mask(){ if [ -n "$PW" ]; then sed "s/${PW}/***/g" | grep -vaE 'password for|\[sudo\]'; else grep -vaE 'password for|\[sudo\]'; fi; }
MAX_TRIES="${MAX_TRIES:-8}"; LEASE_TTL="${LEASE_TTL:-5400}"
up(){ ping -c1 -W2 "${1#*@}" >/dev/null 2>&1 && timeout 12 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=6 "$1" true 2>/dev/null && echo up; }
MS(){ timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 mapstone-dev "/opt/fpgahub/bin/fpgahub $*" 2>&1; }
MDEV(){ timeout "${2:-30}" ssh -o BatchMode=yes -o ConnectTimeout=10 mapstone-dev "$1" 2>&1; }
por_one(){ timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=12 mapstone-dev "curl -sS --max-time 90 --unix-socket /run/fpgahub/fpgahub.sock -X POST http://localhost/api/v1/targets/$1/reset -H 'Content-Type: application/json' -d '{\"method\":\"default\",\"confirm\":true}'" >/dev/null 2>&1; }
bssh(){ local h="$1" cmd="$2" t="${3:-30}"; timeout "$t" ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$h" "cd td && echo '$PW' | sudo -S -p '' $cmd 2>/dev/null"; }
TA=""; TB=""
rel(){ [ -n "$TA" ] && MS lease release kr260_01 --token "$TA" >/dev/null 2>&1; [ -n "$TB" ] && MS lease release kr260_02 --token "$TB" >/dev/null 2>&1; echo "leases released"; }
finish(){ rel; echo; echo "===== ILA CAPTURE SUMMARY ====="; cat "$SUM"; echo DONE > "$DONE"; }
trap finish EXIT
echo "logging to $LOG" >&2; exec >>"$LOG" 2>&1
echo "==== ILA CAPTURE START $(date) ===="
[ -z "$PW" ] && { echo "ERR no pw"; exit 1; }
[ -f "$ILA/tidelink.bin" ] || { echo "_ila bits missing"; exit 1; }
[ -f "$FLIP/tidelink.bin" ] || { echo "_tl033 flip missing"; exit 1; }
[ -f "$ILA/tidelink_design_wrapper.ltx" ] || { echo ".ltx missing"; exit 1; }
deploy_both(){
  RUN_AFI=1 KR260_HOST="$A" TARGET=kr260-eth-chiplet BIN="$ILA/tidelink.bin" BITSTREAM="$ILA/tidelink.bit" KR260_PASSWORD="$PW" timeout 240 bash "$DEP" 2>&1 | mask | grep -iaE 'deploy OK|ERROR|FAIL' | tail -1
  RUN_AFI=1 KR260_HOST="$B" TARGET=kr260-eth-chiplet BIN="$FLIP/tidelink.bin" BITSTREAM="$FLIP/tidelink.bit" KR260_PASSWORD="$PW" timeout 240 bash "$DEP" 2>&1 | mask | grep -iaE 'deploy OK|ERROR|FAIL' | tail -1
  for h in "$A" "$B"; do timeout 25 scp -q -o BatchMode=yes -o StrictHostKeyChecking=no "$SC/eth_sysval_board.py" "$h:td/scripts/eth_sysval_board.py" 2>/dev/null; done
}
canary(){ bssh "$A" "python3 scripts/eth_sysval_board.py write 8 0x8E770000" 30 >/dev/null 2>&1 || return 1; bssh "$B" "python3 scripts/eth_sysval_board.py verify 8 0x8E770000" 30 2>&1 | mask | grep -qa "8/8 byte-exact"; }
# good-citizen acquire (both free)
for i in $(seq 1 180); do
  a=$(MS lease show kr260_01); b=$(MS lease show kr260_02)
  if echo "$a" | grep -qa 'not leased' && echo "$b" | grep -qa 'not leased'; then
    TA=$(MS lease acquire kr260_01 --user dam1n19 --ttl "$LEASE_TTL" | grep -oE 'token=[A-Za-z0-9-]+' | cut -d= -f2)
    TB=$(MS lease acquire kr260_02 --user dam1n19 --ttl "$LEASE_TTL" | grep -oE 'token=[A-Za-z0-9-]+' | cut -d= -f2)
    [ -n "$TA" ] && [ -n "$TB" ] && break
    [ -n "$TA" ] && { MS lease release kr260_01 --token "$TA" >/dev/null 2>&1; TA=""; }
    [ -n "$TB" ] && { MS lease release kr260_02 --token "$TB" >/dev/null 2>&1; TB=""; }
  fi
  echo "waiting for BOTH boards free (try $i/180)"; sleep 60
done
[ -z "$TA" ] || [ -z "$TB" ] && { echo "ACQUIRE FAILED" | tee -a "$SUM"; exit 1; }
echo "leases acquired"
# stage the .ltx + capture tcl onto mapstone-dev
timeout 40 scp -q -o BatchMode=yes "$ILA/tidelink_design_wrapper.ltx" mapstone-dev:/tmp/tidelink_design_wrapper.ltx 2>&1
timeout 40 scp -q -o BatchMode=yes "$SCR/ila_capture.tcl" mapstone-dev:/tmp/ila_capture.tcl 2>&1
good=0
for t in $(seq 1 "$MAX_TRIES"); do
  echo "-- try $t/$MAX_TRIES: POR+deploy(die_a=_ila, die_b=_tl033-flip)+bringup --"
  por_one kr260_01; por_one kr260_02
  for k in $(seq 1 18); do sleep 10; [ "$(up "$A")" = up ] && [ "$(up "$B")" = up ] && break; done
  { [ "$(up "$A")" != up ] || [ "$(up "$B")" != up ]; } && { echo "boards down; retry"; continue; }
  deploy_both
  DIE_A="$A" DIE_B="$B" KR260_PASSWORD="$PW" MAX_TRIES=6 timeout 480 bash "$SC/kr260_eth_bringup_pair.sh" 2>&1 | mask | grep -iaE 'RE-ANCHORED|fcsm' | tail -1
  canary || { echo "BAD eye try $t; re-roll"; continue; }
  good=1; echo "[GOOD EYE] try $t"; break
done
[ "$good" -eq 0 ] && { echo "NO good eye in $MAX_TRIES tries" >> "$SUM"; exit 1; }
# ARM the ILA over JTAG (mapstone-dev vivado, background)
echo "== arming die_a ILA over JTAG (mapstone-dev, 2MHz) =="
MDEV "rm -f /tmp/ila_armed /tmp/ila_done /tmp/ila_fail /tmp/ila_capture.csv; cd /tmp && nohup timeout 400 /tools/Xilinx/2025.2/Vivado/bin/vivado -mode batch -notrace -source /tmp/ila_capture.tcl >/tmp/ila_capture.log 2>&1 & echo launched" 20
# poll for ARMED (vivado launch + connect + arm ~60-150s)
armed=0
for i in $(seq 1 40); do
  s=$(MDEV "ls /tmp/ila_armed /tmp/ila_fail 2>/dev/null" 15)
  echo "$s" | grep -qa 'ila_fail' && { echo "ILA ARM FAILED: $(MDEV 'cat /tmp/ila_fail 2>/dev/null; tail -5 /tmp/ila_capture.log' 20 | mask)"; printf 'RESULT: ILA arm failed\n' >> "$SUM"; exit 1; }
  echo "$s" | grep -qa 'ila_armed' && { armed=1; break; }
  sleep 8
done
[ "$armed" -eq 0 ] && { echo "ILA never armed: $(MDEV 'tail -8 /tmp/ila_capture.log' 20 | mask)"; printf 'RESULT: ILA arm timeout\n' >> "$SUM"; exit 1; }
echo "ILA ARMED. Firing RAW AW inject (NO POR -> die_a stays wedged, debug hub alive for force-capture)."
# raw inject: arm CAM sentinel + arm one-shot AW injector (data_id 0x80) + provoke write (hangs=wedge)
bssh "$A" "python3 scripts/kr260_eth_xfer.py --mode sender --payload 0xC0FFEE01" 30 >/dev/null 2>&1
bssh "$A" "python3 scripts/eth_tlapb_poke.py inject 0x80 0 0" 20 >/dev/null 2>&1
( bssh "$A" "python3 scripts/kr260_eth_soak_fwd.py write 32 0xB0008000" 90 >/dev/null 2>&1 ) &
echo "provoke write fired (bg); waiting ~20s for the wedge to set in"
sleep 20
# confirm die_a wedged: an obs read should now time out (PS<->PL hung)
if bssh "$A" "python3 scripts/eth_tlapb_poke.py read 0x2010" 15 2>/dev/null | grep -qaE '0x[0-9a-fA-F]|=[0-9a-fA-F]'; then
  echo "WARN: die_a still responsive after inject (may not be wedged) — capturing anyway"; wedged=0
else
  echo "die_a WEDGED (obs read timed out) — capturing frozen state"; wedged=1
fi
printf 'die_a wedged after raw AW inject: %s\n' "$([ "$wedged" = 1 ] && echo YES || echo NO)" >> "$SUM"
# request the force-capture of the frozen state
MDEV "touch /tmp/do_capture" 15
# poll for ILA capture DONE
cap=0
for i in $(seq 1 45); do
  s=$(MDEV "ls /tmp/ila_done /tmp/ila_fail 2>/dev/null" 15)
  echo "$s" | grep -qa 'ila_fail' && { echo "ILA CAPTURE FAILED: $(MDEV 'cat /tmp/ila_fail; tail -6 /tmp/ila_capture.log' 25 | mask)"; printf 'RESULT: ILA capture failed\n' >> "$SUM"; por_one kr260_01; exit 1; }
  echo "$s" | grep -qa 'ila_done' && { cap=1; break; }
  sleep 7
done
if [ "$cap" -eq 0 ]; then echo "ILA capture timeout: $(MDEV 'tail -8 /tmp/ila_capture.log' 25 | mask)"; printf 'RESULT: ILA capture timeout\n' >> "$SUM"; por_one kr260_01; exit 1; fi
# recover die_a (POR) now that the frozen state is captured
echo "capture done -> POR die_a to recover"; por_one kr260_01
# fetch the CSV
timeout 40 scp -q -o BatchMode=yes mapstone-dev:/tmp/ila_capture.csv "$OUT/ila_capture.csv" 2>&1
echo "CSV fetched: $(wc -l < "$OUT/ila_capture.csv" 2>/dev/null) lines"
MDEV "grep -aE 'ILA_TRIG_STATUS|CAPTURE_DONE|ILA_CORE|ILA_DEV' /tmp/ila_capture.log" 20 | mask
# read the decision tree at the trigger sample
echo "== DECISION TREE (values at/near the trigger) ==" | tee -a "$SUM"
python3 - "$OUT/ila_capture.csv" >> "$SUM" 2>&1 <<'PY'
import csv,sys
f=sys.argv[1]
try:
    rows=list(csv.DictReader(open(f)))
except Exception as e:
    print("CSV parse error:",e); sys.exit()
if not rows: print("empty CSV"); sys.exit()
# find the trigger sample (dbg_a2l_wedged first ==1), else last sample
cols={c.strip():c for c in rows[0].keys()}
def col(name):
    for k in cols:
        if name in k.lower(): return cols[k]
    return None
wcol=col('dbg_a2l_wedged')
tw=None
if wcol:
    for i,r in enumerate(rows):
        if str(r[wcol]).strip() in ('1','1\'b1','0x1'): tw=i; break
if tw is None: tw=len(rows)//2
r=rows[tw]
print("trigger sample idx=%d of %d"%(tw,len(rows)))
for label in ['dbg_fcsm_state','dbg_a2l_full','dbg_a2l_wptr','dbg_a2l_sack','dbg_a2l_app_rdy','dbg_a2l_app_v','dbg_a2l_lnk_empty','dbg_a2l_rreset','dbg_cr_seen','dbg_fe_rx_cred','dbg_a2l_wedged']:
    c=col(label); print("  %-20s = %s"%(label, r[c] if c else 'N/A'))
PY
echo "==== ILA CAPTURE END $(date) ===="
