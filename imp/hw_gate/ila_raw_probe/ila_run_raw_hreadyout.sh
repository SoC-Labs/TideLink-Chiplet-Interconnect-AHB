#!/usr/bin/env bash
# ila_run_raw_hreadyout.sh -- die_a ILA capture of xhb_sub_hreadyout_raw at the
# TL-042 wedge (2026-08-13).
#
# Adapted from imp/hw_gate/ila_run_tl035.sh (ILA arm/capture handshake, proven to
# capture through the PS deadlock) + imp/hw_gate/tl035_ab.sh (the POR -> PL load
# -> MANDATORY AFI -> concurrent bring-up -> errinject sequence). The originals
# are left untouched.
#
# DIFFERENCES FROM ila_run_tl035.sh, all deliberate:
#   * PROBE NAMES. The tl035 tcl globs `dbg_*`-prefixed probes that DO NOT EXIST
#     in this build. Fixed in ila_capture_raw_hreadyout.tcl.
#   * TRIGGER wr_hold_r == 1 (the wedge state).
#   * die_a ONLY is reflashed, with the ILA build. die_b keeps its already-staged
#     td/tl_arm_baseline.bin; its PL is merely RELOADED after the POR (a POR
#     clears the PL), from the bits already on the board. No new bits go to die_b.
#   * Leases are acquired and released OUTSIDE this script, by the operator, so a
#     script crash cannot strand a board holding a lease.
#
# THE QUESTION: is xhb_sub_hreadyout_raw 0 or 1 at the wedge?
#   See imp/hw_gate/PREREG_RAW_HREADYOUT_PROBE_2026_08_13.md for P1/P2/P3.
set -u
ROOT=/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet
TIDELINK_HOME="$ROOT/tidelink"; export TIDELINK_HOME
SC="$TIDELINK_HOME/pynq_host/scripts"
HG="$TIDELINK_HOME/imp/hw_gate"
KB="$HG/kb.sh"
export PYTHONPATH="$SC/coverage"
ILA="$TIDELINK_HOME/imp/fpga/output/kr260-eth-chiplet"
OUT="${OUTDIR:-$HG/ila_raw_probe/run}"; mkdir -p "$OUT"
LOG="$OUT/run.log"; SUM="$OUT/summary.txt"; DONE="$OUT/done"
: > "$LOG"; : > "$SUM"; rm -f "$DONE"
IP_A=10.22.24.159; IP_B=10.22.24.153
A=ubuntu@$IP_A;    B=ubuntu@$IP_B
PW="${KR260_PASSWORD:?KR260_PASSWORD is not set. Export the board ssh password before running this script; it is deliberately not hardcoded (this repository is public).}"
export KR260_PASSWORD="$PW"
MD5_A_WANT=8045683b6f8cf3d16f7a332c41045e56   # the ILA build, die_a
MD5_B_WANT=13573e46c3b27bb6b03b41b2ce730aa8   # die_b baseline, ALREADY on board
MAX_TRIES="${MAX_TRIES:-4}"
mask(){ sed "s/${PW}/***/g" | grep -vaE 'password for|\[sudo\]'; }
MDEV(){ timeout "${2:-30}" ssh -o BatchMode=yes -o ConnectTimeout=10 mapstone-dev "$1" 2>&1; }
# bk -- privileged board command, in the PROVEN form from ila_run_tl035.sh:bssh:
# `cd td` happens as the LOGIN user, then sudo runs the payload. Doing the cd
# under sudo instead (`sudo cd td && ...`) silently fails. All payload paths are
# therefore relative to ~/td (i.e. `scripts/foo.py`, not `td/scripts/foo.py`).
bk(){ local ip="$1" cmd="$2" t="${3:-40}"
      timeout "$t" sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
        -o ServerAliveInterval=15 "ubuntu@$ip" \
        "cd td && echo '$PW' | sudo -S -p '' $cmd" 2>/dev/null | tr -d '\r'; }
alive(){ ping -c1 -W2 "$1" >/dev/null 2>&1 && echo UP || echo DOWN; }
finish(){ echo; echo "===== RAW-HREADYOUT ILA SUMMARY ====="; cat "$SUM"; echo DONE > "$DONE"; }
trap finish EXIT
echo "logging to $LOG" >&2; exec >>"$LOG" 2>&1
echo "==== RAW HREADYOUT ILA CAPTURE START $(date -u) ===="

# ssh_wait -- block until the board answers SSH, not merely ping. After a JTAG POR
# the network stack answers ICMP well before sshd listens, so a ping-only check
# races the first privileged command and returns EMPTY output, which the md5 gate
# then (correctly) treats as an unverifiable image.
ssh_wait(){ local ip="$1" i; for i in $(seq 1 "${2:-60}"); do
    if timeout 10 sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
         "ubuntu@$ip" true >/dev/null 2>&1; then echo "  ssh ready on $ip (try $i)"; return 0; fi
    sleep 5; done; echo "  ssh NEVER ready on $ip"; return 1; }

# ---- preflight: provenance of the LOCAL artefacts -------------------------
for f in "$ILA/tidelink.bin" "$ILA/tidelink_design_wrapper.ltx"; do
  [ -f "$f" ] || { echo "MISSING: $f" | tee -a "$SUM"; exit 1; }
done
GOTMD5=$(md5sum "$ILA/tidelink.bin" | awk '{print $1}')
if [ "$GOTMD5" != "$MD5_A_WANT" ]; then
  echo "ABORT: local ILA bin md5 $GOTMD5 != expected $MD5_A_WANT" | tee -a "$SUM"; exit 1
fi
echo "local ILA bin md5 OK: $GOTMD5" | tee -a "$SUM"
# The .ltx is written during implementation, the bitstream after it, so a
# consistent pair has the bin NEWER than the ltx. A stale bitstream beside a
# fresh .ltx means the probe file describes probes that are not in the loaded
# design -- names with no signals behind them, unattributable.
if [ "$ILA/tidelink_design_wrapper.ltx" -nt "$ILA/tidelink.bin" ]; then
  echo "ABORT: bin OLDER than ltx -- stale bitstream vs fresh probe file" | tee -a "$SUM"; exit 1
fi
echo "provenance OK: bin $(date -r "$ILA/tidelink.bin" -u +%F_%H:%M:%SZ) >= ltx $(date -r "$ILA/tidelink_design_wrapper.ltx" -u +%F_%H:%M:%SZ)" | tee -a "$SUM"

timeout 90 scp -q -o BatchMode=yes "$ILA/tidelink_design_wrapper.ltx" mapstone-dev:/tmp/tidelink_design_wrapper.ltx || { echo "ltx stage FAILED" | tee -a "$SUM"; exit 1; }
timeout 60 scp -q -o BatchMode=yes "$HG/ila_raw_probe/ila_capture_raw_hreadyout.tcl" mapstone-dev:/tmp/ila_capture.tcl || { echo "tcl stage FAILED" | tee -a "$SUM"; exit 1; }
echo "staged ltx + tcl on mapstone-dev"

good=0
for t in $(seq 1 "$MAX_TRIES"); do
  echo "===== try $t/$MAX_TRIES : POR -> PL -> AFI -> bringup -> eye ====="
  # --- 1. JTAG POR both dies (never `reboot` a KR260; it wedges) -----------
  ssh -o BatchMode=yes mapstone-dev "~/bin/kpor kr260-01 --wait" > "$OUT/01_por_a.log" 2>&1 & pa=$!
  ssh -o BatchMode=yes mapstone-dev "~/bin/kpor kr260-02 --wait" > "$OUT/01_por_b.log" 2>&1 & pb=$!
  wait $pa; wait $pb
  echo "  post-POR ping: die_a=$(alive $IP_A) die_b=$(alive $IP_B)"
  ssh_wait $IP_A || continue
  ssh_wait $IP_B || continue

  # --- 2a. die_a: deploy the ILA build, then PROVE it by md5 --------------
  RUN_AFI=1 KR260_HOST="$A" TARGET=kr260-eth-chiplet BIN="$ILA/tidelink.bin" \
    BITSTREAM="$ILA/tidelink.bit" KR260_PASSWORD="$PW" \
    timeout 300 bash "$SC/kr260_deploy.sh" > "$OUT/02_deploy_a.log" 2>&1
  grep -iaE 'deploy OK|operating|ERROR|FAIL' "$OUT/02_deploy_a.log" | mask | tail -3
  gota=$(bk $IP_A "md5sum tidelink.bin" 60 | awk '{print $1}' | tail -1)
  echo "die_a deployed md5=$gota expected=$MD5_A_WANT" | tee -a "$SUM"
  if [ "$gota" != "$MD5_A_WANT" ]; then
    echo "ABORT: die_a deployed md5 MISMATCH -- refusing to measure a build we cannot name" | tee -a "$SUM"
    exit 4
  fi

  # --- 2b. die_b: NOT reflashed. Its baseline bits are already on the board;
  #         a POR clears the PL, so we merely RELOAD them. md5-verified so the
  #         run names the image it actually ran against.
  gotb=$(bk $IP_B "cp tl_arm_baseline.bin tidelink.bin && md5sum tidelink.bin" 60 | awk '{print $1}' | tail -1)
  echo "die_b staged  md5=$gotb expected=$MD5_B_WANT (baseline, NOT reflashed)" | tee -a "$SUM"
  if [ "$gotb" != "$MD5_B_WANT" ]; then
    echo "ABORT: die_b baseline md5 MISMATCH" | tee -a "$SUM"; exit 4
  fi
  bk $IP_B "fpgautil -b /home/ubuntu/td/tidelink.bin -f Full" 120 > "$OUT/02_pl_b.log" 2>&1
  grep -ia "successfully" "$OUT/02_pl_b.log" | mask

  # --- 3. AFI PS-master-port width fix (MANDATORY after every PL load) -----
  # NO_CANARY: the canary reads bare-link APB 0x8403_xxxx, which the eth-chiplet
  # does NOT decode -- an undecoded PL read HARD-WEDGES the ZynqMP PS.
  bk $IP_B "env KR260_AFI_NO_CANARY=1 sh scripts/kr260_afi.sh fix" 90 > "$OUT/03_afi_b.log" 2>&1
  grep -ha "^AFI:" "$OUT/03_afi_b.log" "$OUT/02_deploy_a.log" 2>/dev/null | mask | tail -6

  # stage the small read-only helpers die_b needs for the local-memory dumps
  timeout 30 sshpass -p "$PW" scp -q -o StrictHostKeyChecking=no "$HG/dieb_dump.py" "$B:td/scripts/dieb_dump.py" 2>/dev/null
  for h in "$A" "$B"; do
    timeout 30 sshpass -p "$PW" scp -q -o StrictHostKeyChecking=no "$SC/eth_sysval_board.py" "$h:td/scripts/eth_sysval_board.py" 2>/dev/null
  done

  # --- 4. bring the link up, BOTH dies together (cal_done gates on the peer) -
  DIE_A="$A" DIE_B="$B" KR260_PASSWORD="$PW" MAX_TRIES=6 \
    timeout 600 bash "$SC/kr260_eth_bringup_pair.sh" > "$OUT/04_bringup.log" 2>&1
  grep -iaE 'RE-ANCHORED|linkup=|did NOT' "$OUT/04_bringup.log" | mask | tail -3 | tee -a "$SUM"

  # --- 5. status: expect fcsm=4 on both dies ------------------------------
  for pair in "$IP_A:die_a" "$IP_B:die_b"; do
    ip=${pair%%:*}; who=${pair#*:}
    v=$(bk "$ip" "python3 scripts/eth_tlapb_poke.py read 0x2108" 40 | grep -oaE '0x[0-9a-fA-F]{8}' | tail -1)
    if [ -n "$v" ]; then
      f=$(( ( $((v)) >> 17 ) & 7 )); c16=$(( ( $((v)) >> 16 ) & 1 )); c22=$(( ( $((v)) >> 22 ) & 1 ))
      # bit[16] vs bit[22] for cal_done: the MEMORY index says [16], the poke
      # script header says [22]. Print BOTH rather than pick one and be wrong.
      echo "  $who SWI_LANE_STAT(0x2108)=$v fcsm=$f cal[16]=$c16 cal[22]=$c22" | tee -a "$SUM"
    else
      echo "  $who R8_0x2108=UNREADABLE" | tee -a "$SUM"
    fi
  done

  # --- 6. eye canary: an 8-word cross-die write that must land byte-exact --
  bk $IP_A "python3 scripts/eth_sysval_board.py write 8 0x8E770000" 60 >/dev/null 2>&1
  if bk $IP_B "python3 scripts/eth_sysval_board.py verify 8 0x8E770000" 60 | grep -qa "8/8 byte-exact"; then
    good=1; echo "[GOOD EYE] try $t" | tee -a "$SUM"; break
  fi
  echo "BAD eye on try $t -- re-rolling the whole cycle" | tee -a "$SUM"
done
[ "$good" -eq 0 ] && { echo "RESULT: no good eye in $MAX_TRIES tries -- VOID, nothing measured" | tee -a "$SUM"; exit 1; }

# ---- arm the ILA over JTAG from mapstone-dev ------------------------------
echo "== arming die_a ILA (2MHz JTAG, trigger wr_hold_r==1) =="
MDEV "rm -f /tmp/ila_armed /tmp/ila_done /tmp/ila_fail /tmp/do_capture /tmp/ila_capture.csv; cd /tmp && nohup timeout 500 /tools/Xilinx/2025.2/Vivado/bin/vivado -mode batch -notrace -source /tmp/ila_capture.tcl >/tmp/ila_capture.log 2>&1 & echo launched" 25
armed=0
for i in $(seq 1 45); do
  s=$(MDEV "ls /tmp/ila_armed /tmp/ila_fail 2>/dev/null" 15)
  echo "$s" | grep -qa 'ila_fail' && { echo "ARM FAILED: $(MDEV 'cat /tmp/ila_fail; tail -8 /tmp/ila_capture.log' 20 | mask)" | tee -a "$SUM"; echo 'RESULT: ILA arm failed' >> "$SUM"; exit 1; }
  echo "$s" | grep -qa 'ila_armed' && { armed=1; break; }
  sleep 8
done
[ "$armed" -eq 0 ] && { echo "ARM TIMEOUT: $(MDEV 'tail -10 /tmp/ila_capture.log' 20 | mask)" | tee -a "$SUM"; echo 'RESULT: ILA arm timeout' >> "$SUM"; exit 1; }
MDEV "grep -aE 'ILA_DEV|ILA_CORE|ILA_PROBE_COUNT|ILA_PROBE_OK|ILA_PROBE_MISSING|ILA_TRIGGER|WARN' /tmp/ila_capture.log" 25 | tee -a "$SUM"

# die_b LOCAL memory BEFORE the inject (local read of shared_sram_0, no link
# traversal, so the verifier itself cannot wedge while die_a is hung).
MEMPRE=$(bk $IP_B "python3 scripts/dieb_dump.py 32" 60 | grep -aE "^DUMP" | tail -1)
echo "pre_inject  die_b $MEMPRE" | tee -a "$SUM"

echo "ILA ARMED. Firing the raw AW inject (NO POR -> die_a stays wedged, debug hub alive)."
bk $IP_A "python3 scripts/kr260_eth_xfer.py --mode sender --payload 0xC0FFEE01" 60 >/dev/null 2>&1
bk $IP_A "python3 scripts/eth_tlapb_poke.py inject 0x80 0 0" 40 >/dev/null 2>&1
( bk $IP_A "python3 scripts/kr260_eth_soak_fwd.py write 32 0xB0008000" 120 >/dev/null 2>&1 ) &
echo "provoke write fired (bg); waiting ~25s"
sleep 25
# Spaced deliberately: ~25 back-to-back ssh sessions trips sshd rate limiting and
# the next command reads "Connection reset by peer", INDISTINGUISHABLE from a
# wedged board.
if bk $IP_A "python3 scripts/eth_tlapb_poke.py read 0x2010" 30 | grep -qaE '0x[0-9a-fA-F]'; then
  echo "WARN: die_a still responsive (may not be wedged) -- capturing anyway"; wedged=0
else
  echo "die_a WEDGED (obs read timed out)"; wedged=1
fi
echo "die_a wedged after raw AW inject: $([ "$wedged" = 1 ] && echo YES || echo NO)" | tee -a "$SUM"
MDEV "touch /tmp/do_capture" 15

cap=0
for i in $(seq 1 50); do
  s=$(MDEV "ls /tmp/ila_done /tmp/ila_fail 2>/dev/null" 15)
  echo "$s" | grep -qa 'ila_fail' && { echo "CAPTURE FAILED: $(MDEV 'cat /tmp/ila_fail; tail -8 /tmp/ila_capture.log' 25 | mask)" | tee -a "$SUM"; echo 'RESULT: capture failed' >> "$SUM"; exit 1; }
  echo "$s" | grep -qa 'ila_done' && { cap=1; break; }
  sleep 7
done
[ "$cap" -eq 0 ] && { echo "CAPTURE TIMEOUT: $(MDEV 'tail -10 /tmp/ila_capture.log' 25 | mask)" | tee -a "$SUM"; echo 'RESULT: capture timeout' >> "$SUM"; exit 1; }

# die_b memory AFTER the inject, read BEFORE any POR so the memory state and the
# ILA window describe the same instant.
MEMPOST=$(bk $IP_B "python3 scripts/dieb_dump.py 32" 60 | grep -aE "^DUMP" | tail -1)
echo "post_inject die_b $MEMPOST" | tee -a "$SUM"

timeout 90 scp -q -o BatchMode=yes mapstone-dev:/tmp/ila_capture.csv "$OUT/ila_capture.csv"
MDEV "grep -aE 'DO_CAPTURE|TRIG_STATUS|CAPTURE_DONE|WARN' /tmp/ila_capture.log" 25 | mask | tee -a "$SUM"
echo "CSV: $(wc -l < "$OUT/ila_capture.csv" 2>/dev/null) lines" | tee -a "$SUM"
echo "RESULT: capture complete, csv at $OUT/ila_capture.csv" >> "$SUM"
echo "==== RAW HREADYOUT ILA CAPTURE END $(date -u) ===="
