#!/usr/bin/env bash
# ila_run_tl035.sh -- die_a ILA capture of the synth-B ARMING question (2026-08-13).
#
# Adapted from imp/hw_gate/ila_2026_08_12/ila_capture_run.sh, which is proven to
# capture through the PS deadlock. Changes: die_a bits are the NEW 37-probe build
# (XHB500 arming path, not the sideband set), the trigger is
# dbg_ahb_sub_hreadyout==0, and the decode answers the arming question rather
# than the transport one.
#
# THE QUESTION: on a lost-completion wedge, does synth-B ARM?
#   synth_b_pending never 1  -> arming-starved. tidelink_top.sv:1667 resets the
#     age timer on `|| sub_axi_progress` (= sub_r_done | sub_b_done, :1574), so
#     reads and SIBLING write-Bs keep rearming the stuck write's timer.
#     FIX = separate head-of-line write-age timer.
#   synth_b_pending == 1      -> armed, and the synthetic B failed to retire the
#     PS write. DIFFERENT defect, different fix.
# sub_r_done vs sub_b_done are probed separately so we can see WHICH resets it.
set -u
ROOT=/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet
SC="$ROOT/tidelink/pynq_host/scripts"
SCR=/tmpdir/claude-74755/-home-dam1n19-SoCLabs-tidelink/029fa128-e7f4-41b2-a3bf-6880af5cca50/scratchpad
export TIDELINK_HOME="$ROOT/tidelink"; export PYTHONPATH="$SC/coverage"
ILA="$TIDELINK_HOME/imp/fpga/output/kr260-eth-chiplet"            # NEW 37-probe die_a build
FLIP="$TIDELINK_HOME/imp/fpga/output/kr260-eth-chiplet-flip.tl033" # die_b, same as the tl035 A/B arm
OUT="$SCR/hw_gate/ila_tl035_run"; mkdir -p "$OUT"
LOG="$OUT/run.log"; SUM="$OUT/summary.txt"; DONE="$OUT/done"
: > "$LOG"; : > "$SUM"; rm -f "$DONE"
A=ubuntu@10.22.24.159; B=ubuntu@10.22.24.153
DEP="$SC/kr260_deploy.sh"
PW="${KR260_PASSWORD:-soclabs2026}"
mask(){ sed "s/${PW}/***/g" | grep -vaE 'password for|\[sudo\]'; }
MAX_TRIES="${MAX_TRIES:-6}"; LEASE_TTL="${LEASE_TTL:-5400}"
up(){ ping -c1 -W2 "${1#*@}" >/dev/null 2>&1 && timeout 12 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=6 "$1" true 2>/dev/null && echo up; }
MS(){ timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 mapstone-dev "/opt/fpgahub/bin/fpgahub $*" 2>&1; }
MDEV(){ timeout "${2:-30}" ssh -o BatchMode=yes -o ConnectTimeout=10 mapstone-dev "$1" 2>&1; }
por_one(){ timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=12 mapstone-dev "curl -sS --max-time 90 --unix-socket /run/fpgahub/fpgahub.sock -X POST http://localhost/api/v1/targets/$1/reset -H 'Content-Type: application/json' -d '{\"method\":\"default\",\"confirm\":true}'" >/dev/null 2>&1; }
bssh(){ local h="$1" cmd="$2" t="${3:-30}"; timeout "$t" ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$h" "cd td && echo '$PW' | sudo -S -p '' $cmd 2>/dev/null"; }
TA=""; TB=""
rel(){ [ -n "$TA" ] && MS lease release kr260_01 --token "$TA" >/dev/null 2>&1; [ -n "$TB" ] && MS lease release kr260_02 --token "$TB" >/dev/null 2>&1; echo "leases released"; }
finish(){ rel; echo; echo "===== TL-035 ILA SUMMARY ====="; cat "$SUM"; echo DONE > "$DONE"; }
trap finish EXIT
echo "logging to $LOG" >&2; exec >>"$LOG" 2>&1
echo "==== TL-035 ILA CAPTURE START $(date -u) ===="
# The Vivado build writes .bit; the ZynqMP .bin is a SEPARATE conversion step
# (127-byte header strip, NO byte-swap). Do it here rather than assuming a
# previous session left one lying around — a stale .bin beside a fresh .bit is
# the same provenance hazard as a stale .bit beside a fresh .ltx.
B2B="$TIDELINK_HOME/fpga/scripts/bit2bin_zynqmp.py"
for d in "$ILA" "$FLIP"; do
  [ -f "$d/tidelink.bit" ] || { echo "MISSING: $d/tidelink.bit" | tee -a "$SUM"; exit 1; }
  if [ ! -f "$d/tidelink.bin" ] || [ "$d/tidelink.bit" -nt "$d/tidelink.bin" ]; then
    echo "converting $(basename "$d")/tidelink.bit -> .bin"
    python3 "$B2B" "$d/tidelink.bit" "$d/tidelink.bin" || { echo "bit2bin FAILED for $d" | tee -a "$SUM"; exit 1; }
  fi
done
for f in "$ILA/tidelink.bin" "$ILA/tidelink_design_wrapper.ltx" "$FLIP/tidelink.bin"; do
  [ -f "$f" ] || { echo "MISSING: $f" | tee -a "$SUM"; exit 1; }
done
# PROVENANCE GUARD — the .bit/.bin and the .ltx MUST come from the same build.
# The .ltx is written during implementation and the bitstream after it, so a
# consistent pair has bin NEWER than ltx. A stale bitstream beside a fresh .ltx
# means the probe file describes probes that are not in the loaded design, and
# the capture returns names with no signals behind them — unattributable, and
# indistinguishable from "the probes did not survive synthesis". This is the same
# failure class as the rig being found running an ILA .bin beside a foreign .hwh.
if [ "$ILA/tidelink_design_wrapper.ltx" -nt "$ILA/tidelink.bit" ]; then
  echo "ABORT: $ILA/tidelink.bin is OLDER than the .ltx — stale bitstream vs fresh probe file." | tee -a "$SUM"
  echo "       bin: $(date -r "$ILA/tidelink.bin"  -u +%F_%H:%M:%SZ)" | tee -a "$SUM"
  echo "       ltx: $(date -r "$ILA/tidelink_design_wrapper.ltx" -u +%F_%H:%M:%SZ)" | tee -a "$SUM"
  echo "       Wait for the build to finish writing the bitstream, then re-run." | tee -a "$SUM"
  exit 1
fi
echo "provenance OK: bin $(date -r "$ILA/tidelink.bin" -u +%F_%H:%M:%SZ) >= ltx $(date -r "$ILA/tidelink_design_wrapper.ltx" -u +%F_%H:%M:%SZ)"
echo "die_a bits : $ILA/tidelink.bin  (md5 $(md5sum "$ILA/tidelink.bin" | cut -c1-12))"
echo "die_b bits : $FLIP/tidelink.bin (md5 $(md5sum "$FLIP/tidelink.bin" | cut -c1-12))"

deploy_both(){
  RUN_AFI=1 KR260_HOST="$A" TARGET=kr260-eth-chiplet BIN="$ILA/tidelink.bin"  BITSTREAM="$ILA/tidelink.bit"  KR260_PASSWORD="$PW" timeout 240 bash "$DEP" 2>&1 | mask | grep -iaE 'deploy OK|ERROR|FAIL' | tail -1
  RUN_AFI=1 KR260_HOST="$B" TARGET=kr260-eth-chiplet BIN="$FLIP/tidelink.bin" BITSTREAM="$FLIP/tidelink.bit" KR260_PASSWORD="$PW" timeout 240 bash "$DEP" 2>&1 | mask | grep -iaE 'deploy OK|ERROR|FAIL' | tail -1
  for h in "$A" "$B"; do timeout 25 scp -q -o BatchMode=yes -o StrictHostKeyChecking=no "$SC/eth_sysval_board.py" "$h:td/scripts/eth_sysval_board.py" 2>/dev/null; done
}
canary(){ bssh "$A" "python3 scripts/eth_sysval_board.py write 8 0x8E770000" 30 >/dev/null 2>&1 || return 1; bssh "$B" "python3 scripts/eth_sysval_board.py verify 8 0x8E770000" 30 2>&1 | mask | grep -qa "8/8 byte-exact"; }

for i in $(seq 1 120); do
  a=$(MS lease show kr260_01); b=$(MS lease show kr260_02)
  if echo "$a" | grep -qa 'not leased' && echo "$b" | grep -qa 'not leased'; then
    TA=$(MS lease acquire kr260_01 --user dam1n19 --ttl "$LEASE_TTL" | grep -oE 'token=[A-Za-z0-9_-]+' | cut -d= -f2)
    TB=$(MS lease acquire kr260_02 --user dam1n19 --ttl "$LEASE_TTL" | grep -oE 'token=[A-Za-z0-9_-]+' | cut -d= -f2)
    [ -n "$TA" ] && [ -n "$TB" ] && break
    [ -n "$TA" ] && { MS lease release kr260_01 --token "$TA" >/dev/null 2>&1; TA=""; }
    [ -n "$TB" ] && { MS lease release kr260_02 --token "$TB" >/dev/null 2>&1; TB=""; }
  fi
  echo "waiting for BOTH boards free (try $i/120)"; sleep 30
done
{ [ -z "$TA" ] || [ -z "$TB" ]; } && { echo "ACQUIRE FAILED" | tee -a "$SUM"; exit 1; }
echo "leases acquired"

timeout 60 scp -q -o BatchMode=yes "$ILA/tidelink_design_wrapper.ltx" mapstone-dev:/tmp/tidelink_design_wrapper.ltx
timeout 40 scp -q -o BatchMode=yes "$SCR/ila_capture_tl035.tcl" mapstone-dev:/tmp/ila_capture.tcl

good=0
for t in $(seq 1 "$MAX_TRIES"); do
  echo "-- try $t/$MAX_TRIES: POR + deploy + bringup --"
  por_one kr260_01; por_one kr260_02
  for k in $(seq 1 18); do sleep 10; [ "$(up "$A")" = up ] && [ "$(up "$B")" = up ] && break; done
  { [ "$(up "$A")" != up ] || [ "$(up "$B")" != up ]; } && { echo "boards down; retry"; continue; }
  deploy_both
  DIE_A="$A" DIE_B="$B" KR260_PASSWORD="$PW" MAX_TRIES=6 timeout 480 bash "$SC/kr260_eth_bringup_pair.sh" 2>&1 | mask | grep -iaE 'RE-ANCHORED|fcsm' | tail -1
  canary || { echo "BAD eye try $t; re-roll"; continue; }
  good=1; echo "[GOOD EYE] try $t"; break
done
[ "$good" -eq 0 ] && { echo "NO good eye in $MAX_TRIES tries" >> "$SUM"; exit 1; }

echo "== arming die_a ILA over JTAG (mapstone-dev, 2MHz, trigger dbg_ahb_sub_hreadyout==0) =="
MDEV "rm -f /tmp/ila_armed /tmp/ila_done /tmp/ila_fail /tmp/do_capture /tmp/ila_capture.csv; cd /tmp && nohup timeout 400 /tools/Xilinx/2025.2/Vivado/bin/vivado -mode batch -notrace -source /tmp/ila_capture.tcl >/tmp/ila_capture.log 2>&1 & echo launched" 20
armed=0
for i in $(seq 1 40); do
  s=$(MDEV "ls /tmp/ila_armed /tmp/ila_fail 2>/dev/null" 15)
  echo "$s" | grep -qa 'ila_fail' && { echo "ARM FAILED: $(MDEV 'cat /tmp/ila_fail; tail -6 /tmp/ila_capture.log' 20 | mask)"; echo 'RESULT: ILA arm failed' >> "$SUM"; exit 1; }
  echo "$s" | grep -qa 'ila_armed' && { armed=1; break; }
  sleep 8
done
[ "$armed" -eq 0 ] && { echo "ARM TIMEOUT: $(MDEV 'tail -8 /tmp/ila_capture.log' 20 | mask)"; echo 'RESULT: ILA arm timeout' >> "$SUM"; exit 1; }
# record which probes the core actually exposes — catch a missing probe HERE
MDEV "grep -aE 'ILA_PROBE_COUNT|ILA_PROBE_OK|ILA_PROBE_MISSING|ILA_TRIGGER' /tmp/ila_capture.log" 20 | tee -a "$SUM"

# die_b LOCAL memory BEFORE the inject. Paired with the post-inject read this
# makes "the landed writes and the frozen wedge write are DIFFERENT writes" a
# SINGLE-RUN FACT rather than an inference across two separate runs. Local read
# of shared_sram_0, no link traversal, so it cannot wedge while die_a is hung.
MEMPRE=$(timeout 40 ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$B" "cd td && echo '$PW' | sudo -S -p '' python3 scripts/dieb_dump.py 32" 2>/dev/null | tr -d '\r' | grep -E "^DUMP" | tail -1)
echo "pre_inject  die_b $MEMPRE" | tee -a "$SUM"

echo "ILA ARMED. Firing RAW AW inject (NO POR -> die_a stays wedged, debug hub alive)."
bssh "$A" "python3 scripts/kr260_eth_xfer.py --mode sender --payload 0xC0FFEE01" 30 >/dev/null 2>&1
bssh "$A" "python3 scripts/eth_tlapb_poke.py inject 0x80 0 0" 20 >/dev/null 2>&1
( bssh "$A" "python3 scripts/kr260_eth_soak_fwd.py write 32 0xB0008000" 90 >/dev/null 2>&1 ) &
echo "provoke write fired (bg); waiting ~20s"
sleep 20
if bssh "$A" "python3 scripts/eth_tlapb_poke.py read 0x2010" 15 2>/dev/null | grep -qaE '0x[0-9a-fA-F]'; then
  echo "WARN: die_a still responsive (may not be wedged) — capturing anyway"; wedged=0
else
  echo "die_a WEDGED (obs read timed out)"; wedged=1
fi
echo "die_a wedged after raw AW inject: $([ "$wedged" = 1 ] && echo YES || echo NO)" >> "$SUM"
MDEV "touch /tmp/do_capture" 15

cap=0
for i in $(seq 1 45); do
  s=$(MDEV "ls /tmp/ila_done /tmp/ila_fail 2>/dev/null" 15)
  echo "$s" | grep -qa 'ila_fail' && { echo "CAPTURE FAILED: $(MDEV 'cat /tmp/ila_fail; tail -6 /tmp/ila_capture.log' 25 | mask)"; echo 'RESULT: capture failed' >> "$SUM"; por_one kr260_01; exit 1; }
  echo "$s" | grep -qa 'ila_done' && { cap=1; break; }
  sleep 7
done
[ "$cap" -eq 0 ] && { echo "CAPTURE TIMEOUT: $(MDEV 'tail -8 /tmp/ila_capture.log' 25 | mask)"; echo 'RESULT: capture timeout' >> "$SUM"; por_one kr260_01; exit 1; }

# die_b LOCAL memory AFTER the inject — read BEFORE the POR, while the wedge is
# still frozen, so the memory state and the ILA window describe the same instant.
MEMPOST=$(timeout 40 ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$B" "cd td && echo '$PW' | sudo -S -p '' python3 scripts/dieb_dump.py 32" 2>/dev/null | tr -d '\r' | grep -E "^DUMP" | tail -1)
echo "post_inject die_b $MEMPOST" | tee -a "$SUM"
python3 - "$MEMPRE" "$MEMPOST" 2>/dev/null | tee -a "$SUM" <<'PY'
import sys
def w(s): return [x for x in s.split() if len(x)==8 and all(c in "0123456789abcdef" for c in x)]
a,b=w(sys.argv[1]),w(sys.argv[2])
if not a or not b or len(a)!=len(b):
    print("  LOCALMEM: unavailable/length mismatch — cannot diff"); raise SystemExit
ch=[i for i in range(len(a)) if a[i]!=b[i]]
print("  LOCALMEM changed idx %s"%(ch if ch else "NONE"))
for i in ch[:8]: print("    idx%-3d 0x%s -> 0x%s"%(i,a[i],b[i]))
if ch:
    print("  => writes DID land on die_b in THIS run, while die_a's frozen state shows")
    print("     sub_aw_accept=0 for the wedge write. Landed writes and the wedge write")
    print("     are DIFFERENT writes — now a single-run fact, not a cross-run inference.")
else:
    print("  => NOTHING landed in this run; the landed-vs-wedge reconciliation does NOT")
    print("     hold here and must not be asserted from the earlier batch.")
PY

echo "capture done -> POR die_a to recover"; por_one kr260_01
timeout 60 scp -q -o BatchMode=yes mapstone-dev:/tmp/ila_capture.csv "$OUT/ila_capture.csv"
MDEV "grep -aE 'TRIG_STATUS|CAPTURE_DONE|PRE_STATUS|ILA_CORE|ILA_DEV' /tmp/ila_capture.log" 20 | mask | tee -a "$SUM"
echo "CSV: $(wc -l < "$OUT/ila_capture.csv" 2>/dev/null) lines"

echo "== ARMING DECISION ==" | tee -a "$SUM"
python3 - "$OUT/ila_capture.csv" 2>&1 | tee -a "$SUM" <<'PY'
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1])))
if not rows: print("empty CSV"); sys.exit()
cols=list(rows[0].keys())
def col(n):
    for c in cols:
        if n in c.lower(): return c
    return None
def val(r,c):
    # Vivado ILA CSV encodes multi-bit probes as HEX, unprefixed and quoted:
    # '015fc' '01600' ... An all-DIGIT hex value ('01600') is indistinguishable
    # from decimal by inspection, so a base-10-first parser silently returns 1600
    # where the true value is 0x1600 = 5632. That fabricated a 100-point "sawtooth"
    # in a counter that is actually a clean monotonic +1/clock ramp, and the fake
    # sawtooth was then used to argue a mechanism. PARSE HEX FIRST, ALWAYS.
    if c is None: return None
    s=str(r[c]).strip().strip("'")
    if s.lower().startswith("0x"): s=s[2:]
    try: return int(s,16)
    except: return None
NAMES=['synth_b_pending','sub_osr_ctr_r','sub_wr_os_ctr','sub_axi_progress','sub_r_done',
       'sub_b_done','sub_wr_stuck_fire','dbg_ahb_sub_hreadyout','sub_axi_outstanding',
       'sub_err1_r','sub_rd_os_r','sub_osr_expired','sub_aw_accept','sub_stall_ctr_r',
       # round-2: the :1909 override terms themselves, to say WHICH one gates
       'dbg_wr_hold_r','dbg_wr_hold_set','dbg_wr_hold_clr','dbg_ext_is_nonseq',
       'dbg_pipe_valid_r','dbg_rd_pipe_r']
C={n:col(n) for n in NAMES}
missing=[n for n,c in C.items() if c is None]
if missing: print("  PROBES MISSING FROM CSV:", missing)
print("  samples=%d"%len(rows))
# window summary — this is what answers the question, not a single sample
for n in NAMES:
    c=C[n]
    if c is None: continue
    vs=[val(r,c) for r in rows]; vs=[v for v in vs if v is not None]
    if not vs: continue
    print("  %-24s min=%-8s max=%-8s ones=%-6s distinct=%s"%(n,min(vs),max(vs),sum(1 for v in vs if v),len(set(vs))))
sb=[val(r,C['synth_b_pending']) for r in rows] if C['synth_b_pending'] else []
sb=[v for v in sb if v is not None]
print()
if sb and max(sb)==0:
    print("  => synth_b_pending NEVER ASSERTS across the captured window.")
    print("     Consistent with ARMING STARVATION: the :1667 `|| sub_axi_progress`")
    print("     term keeps resetting the age timer. Check sub_osr_ctr_r max vs the")
    print("     2**16 threshold and which of sub_r_done / sub_b_done is pulsing.")
elif sb:
    print("  => synth_b_pending ASSERTS (ones=%d). synth-B ARMED and the wedge"%sum(1 for v in sb if v))
    print("     persisted anyway -> the synthetic B did not retire die_a's PS write.")
    print("     DIFFERENT defect from arming starvation; head-of-line timer is NOT the fix.")
else:
    print("  => synth_b_pending not readable — cannot decide. Do not infer.")

# ---- round-2: WHICH :1909 override term gates ahb_sub_hreadyout low? ----
# Priority order in the mux: rank3 (ext_is_nonseq && !pipe_valid_r) BEFORE
# rank5 (wr_hold_r). If both hold, rank3 is the operative selector and wr_hold_r
# is a passenger — so pipe_valid_r, not wr_hold_r, is the discriminator.
def ser(n):
    c=C.get(n) or col(n)
    if c is None: return None
    return [v for v in (val(r,c) for r in rows) if v is not None]
pv, wh, ws, wc, en, rp = (ser(x) for x in
    ['dbg_pipe_valid_r','dbg_wr_hold_r','dbg_wr_hold_set','dbg_wr_hold_clr',
     'dbg_ext_is_nonseq','dbg_rd_pipe_r'])
print()
print("  OVERRIDE-TERM VERDICT")
if not pv or not wh:
    print("    round-2 probes absent from this CSV — this is a round-1 capture.")
else:
    print("    pipe_valid_r  ones=%d/%d   ext_is_nonseq ones=%s"%(sum(1 for v in pv if v),len(pv), sum(1 for v in en if v) if en else '?'))
    print("    wr_hold_r     ones=%d/%d   set=%s clr=%s"%(sum(1 for v in wh if v),len(wh),
          sum(1 for v in ws if v) if ws else '?', sum(1 for v in wc if v) if wc else '?'))
    print("    rd_pipe_r     ones=%s"%(sum(1 for v in rp if v) if rp else '?'))
    rank3 = en and pv and all(v==0 for v in pv) and any(v for v in en)
    if rank3:
        print("    => RANK3 GATES: (ext_is_nonseq && !pipe_valid_r). pipe_valid_r stuck LOW —")
        print("       the pipe never fills. Root is UPSTREAM of wr_hold_r, which is a passenger")
        print("       even if it also reads 1. Do NOT attribute this to TL-002 on that basis.")
    elif all(v for v in wh) and wc and not any(v for v in wc):
        print("    => RANK5 GATES: wr_hold_r stuck HIGH with wr_hold_clr never asserting.")
        print("       TL-002 IMPLICATED: its guard clears on synth_b_pending, which cannot")
        print("       assert here (no AW counted). Deadlock is the :1828-1834 case its own")
        print("       guard does not cover. Check before signing TL-002 off.")
    elif ws and any(v for v in ws) and not any(v for v in wh):
        print("    => wr_hold_set pulses but wr_hold_r never latches — neither rank3 nor rank5.")
        print("       Fall back to rd_pipe_r / re-check the mux.")
    else:
        print("    => AMBIGUOUS on these values. Report raw, do not force a branch.")
PY
echo "==== TL-035 ILA CAPTURE END $(date -u) ===="
