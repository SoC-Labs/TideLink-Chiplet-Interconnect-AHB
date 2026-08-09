#!/usr/bin/env bash
# =============================================================================
# run_ptp_pair.sh  --  Wave-2 PTP run on the KR260 pair (first-silicon PTP sync).
#
# Off-rig authored, on-rig runnable. Verifies the timing-clean -ptp bitstreams
# exist, leases BOTH dies (token-scoped), POR-freshes them, deploys (RUN_AFI=0),
# applies the mandatory AFI width fix, then runs the canonical KR260 PTP demo
# (fpga/hw_regression/td_v2_channels.sh) and captures the FOUR PTP gates. The
# demo itself performs bring-up (gate_link) and the PTP sequence (gate_ptp), per
# tidelink/docs/PTP_DEMO_RUNBOOK.md -- you do NOT write new bring-up code.
#
# THE FOUR PTP GATES CAPTURED (from gate_ptp, td_v2_channels.sh):
#   1. PHC canary        -- ns_incr=40 write+readback verified on both dies
#   2. PHC free-run      -- both PHCs strictly advance (anti-tie-off; delta>0)
#   3. GM SYNC advance   -- HW_SYNC seq_num advanced (the GM actually emitted SYNCs)
#   4. round-trip offset -- slave servo computed a non-zero real offset (full
#                           SYNC t1..t4 + DELAY_REQ crossed the link)
#   (+ convergence, informational: final |offset| <= PTP_TOL_NS)
#
# KEY CAVEATS (baked into gate_ptp; see PTP_DEMO_RUNBOOK.md):
#   * phc_locked_i is TIED 0 in every FPGA bitstream (BD never connects it), so
#     the initiator is armed with HW_SYNC_CTRL=0x5 (force_en|enable) -- force_en
#     is MANDATORY on FPGA or the PTP TX FSM deadlocks in TX_WAIT_IDLE. Never
#     gate PASS on HW_SYNC_STATUS[18].
#   * Servo roles: SERVO_GM (0x1) on die_a=master, SERVO_SUB (0x3) on die_b=slave;
#     roles + step-threshold BEFORE ptp_enable BEFORE arming (gate_ptp order,
#     mirrors sim _setup_ptp / release_training bilateral sequencing).
#   * Ordering trap (runbook trap #1): if gate_link aborts with master fcsm=2 /
#     slave fcsm=4, issue the swreset triplet by hand (runbook §2.2) then re-run.
#
# SAFETY / CONTRACT (identical envelope to run_categoryA_goodeye.sh):
#   * If the -ptp .bin is NOT built, the script SKIPs cleanly and NEVER touches
#     the rig (no lease, no ssh, no POR).
#   * Token-scoped release ONLY (never `board lease revoke`).
#   * JTAG-POR = POST to the fpgahubd unix socket on mapstone-dev. Never reboot.
#   * Every ssh/scp/demo is `timeout`-wrapped; a hang == wedge -> POR-recover.
#   * Password derived from the bring-up default and MASKED in all output.
#   * Idempotent; time-budget bounded; emits a .done sentinel + a gates file.
#
# ENV OVERRIDES: DEMO_TMO (900)  TIME_BUDGET_S (5400)  LEASE_TTL (5400)
#                PTP_OUT (<scratchpad>)
#
# A joint work commissioned on behalf of SoC Labs.
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

ROOT=/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet
SC="$ROOT/tidelink/pynq_host/scripts"
SCR="/tmpdir/claude-74755/-home-dam1n19-SoCLabs-nanosoc-ethernet-chiplet/e31cf0db-becf-4762-a881-c1c17e74fb93/scratchpad"
cd "$SC" || { echo "cannot cd $SC" >&2; exit 1; }

OUT_DIR="${PTP_OUT:-$SCR}"
mkdir -p "$OUT_DIR" 2>/dev/null || { OUT_DIR="$ROOT/verif/hw_runs"; mkdir -p "$OUT_DIR"; }
LOG="$OUT_DIR/run_ptp_pair.log"
GATES="$OUT_DIR/run_ptp_pair_gates.txt"
DONE="$OUT_DIR/run_ptp_pair.done"
: > "$LOG"; : > "$GATES"; rm -f "$DONE"

PW=$(sed -n 's/.*KR260_PASSWORD:-\([^}]*\)}.*/\1/p' kr260_eth_bringup_pair.sh | head -1)
mask(){ if [ -n "$PW" ]; then sed "s/${PW}/***/g" | grep -vaE 'password for|\[sudo\]'
        else grep -vaE 'password for|\[sudo\]'; fi; }

A=ubuntu@10.22.24.159            # die_a = kr260_01 = master = Grandmaster (GM)
B=ubuntu@10.22.24.153            # die_b = kr260_02 = slave (flip) = Subordinate
DEP="$SC/kr260_deploy.sh"
OUT="$ROOT/tidelink/imp/fpga/output"
BIN_A="$OUT/kr260-pair-ptp/tidelink.bin"
BIN_B="$OUT/kr260-pair-flip-ptp/tidelink.bin"
export TIDELINK_HOME="$ROOT/tidelink"

DEMO_TMO="${DEMO_TMO:-900}"
TIME_BUDGET_S="${TIME_BUDGET_S:-5400}"
LEASE_TTL="${LEASE_TTL:-5400}"
START=$(date +%s)

record_gate(){ printf '%-24s %s\n' "$1" "$2" >> "$GATES"; echo "  [PTP GATE] $1 => $2"; }
finish(){
  echo; echo "===== PTP GATES ====="; cat "$GATES"
  echo DONE > "$DONE"; echo "SENTINEL DONE -> $DONE"
}

# --- PRE-RIG GUARD: verify -ptp bitstreams exist BEFORE touching anything -----
# (Current tree: kr260-pair-{,flip-}ptp are DEFINED fpga targets but UNBUILT --
#  only kr260-pair-nptp output exists. This branch SKIPs without any rig contact.)
if [ ! -f "$BIN_A" ] || [ ! -f "$BIN_B" ]; then
  echo "logging to $LOG" >&2
  exec >>"$LOG" 2>&1
  echo "==== PTP RUN $(date) ===="
  echo "SKIP: -ptp bitstream(s) not built -- no rig contact made."
  [ ! -f "$BIN_A" ] && echo "  missing: $BIN_A"
  [ ! -f "$BIN_B" ] && echo "  missing: $BIN_B"
  echo "  Build first, e.g.:  make -C $ROOT/tidelink/fpga build_pair_concurrent \\"
  echo "                          PAIR_A=kr260-pair-ptp PAIR_B=kr260-pair-flip-ptp"
  record_gate "PHC_canary"        "SKIP(no-ptp-bitstream)"
  record_gate "PHC_free_run"      "SKIP(no-ptp-bitstream)"
  record_gate "GM_SYNC_advance"   "SKIP(no-ptp-bitstream)"
  record_gate "roundtrip_offset"  "SKIP(no-ptp-bitstream)"
  record_gate "servo_converged"   "SKIP(no-ptp-bitstream)"
  finish
  exit 0
fi

# --- from here the -ptp bitstreams exist: engage the rig ----------------------
[ -z "$PW" ] && { echo "ERROR: could not derive board password" >&2; exit 1; }

up(){ ping -c1 -W2 "${1#*@}" >/dev/null 2>&1 \
      && timeout 12 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=6 "$1" true 2>/dev/null \
      && echo up; }
MS(){ timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 mapstone-dev "/opt/fpgahub/bin/fpgahub $*" 2>&1; }
por_one(){ timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=12 mapstone-dev \
             "curl -sS --max-time 90 --unix-socket /run/fpgahub/fpgahub.sock -X POST \
              http://localhost/api/v1/targets/$1/reset \
              -H 'Content-Type: application/json' -d '{\"method\":\"default\",\"confirm\":true}'" \
             >/dev/null 2>&1; }
bssh(){ local h="$1" cmd="$2" t="${3:-30}"
  timeout "$t" ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$h" \
    "cd td && echo '$PW' | sudo -S $cmd 2>/dev/null"; }

TA=""; TB=""
rel(){
  [ -n "$TA" ] && MS lease release kr260_01 --token "$TA" >/dev/null 2>&1
  [ -n "$TB" ] && MS lease release kr260_02 --token "$TB" >/dev/null 2>&1
  echo "leases released (token-scoped; no revoke)"
}
finish_rig(){ rel; finish; }
trap 'finish_rig' EXIT

echo "logging to $LOG (gates: $GATES)" >&2
exec >>"$LOG" 2>&1
echo "==== PTP RUN START $(date) (demo timeout ${DEMO_TMO}s, budget ${TIME_BUDGET_S}s) ===="
echo "  -ptp bitstreams present: $BIN_A  +  $BIN_B"

deploy_one(){ # deploy_one <host> <target>
  local tf rc; tf=$(mktemp "$OUT_DIR/.dep.XXXXXX")
  local target="$2" bin
  case "$target" in kr260-pair-ptp) bin="$BIN_A";; *) bin="$BIN_B";; esac
  RUN_AFI=0 KR260_HOST="$1" TARGET="$target" BIN="$bin" \
    BITSTREAM="${bin%.bin}.bit" KR260_PASSWORD="$PW" timeout 240 bash "$DEP" > "$tf" 2>&1; rc=$?
  mask < "$tf" | grep -iaE 'operating|deploy|ERROR|FAIL' | tail -3; rm -f "$tf"
  return $rc
}

afi_fix(){ # afi_fix <host> ; mandatory width re-poke + canaries (PTP build decodes 0x8403/0x8405)
  local tf rc; tf=$(mktemp "$OUT_DIR/.afi.XXXXXX")
  bssh "$1" "sh scripts/kr260_afi.sh fix" 100 > "$tf" 2>&1; rc=$?
  mask < "$tf" | grep -iaE 'PASS|FAIL|canary|width|0x840|role|lane' | tail -10; rm -f "$tf"
  return $rc
}

# --- acquire leases (token-scoped) -------------------------------------------
TA=$(MS lease acquire kr260_01 --user dam1n19 --ttl "$LEASE_TTL" | grep -oE 'token=[A-Za-z0-9]+' | cut -d= -f2)
TB=$(MS lease acquire kr260_02 --user dam1n19 --ttl "$LEASE_TTL" | grep -oE 'token=[A-Za-z0-9]+' | cut -d= -f2)
if [ -z "$TA" ] || [ -z "$TB" ]; then echo "ACQUIRE FAILED (TA='${TA:+set}' TB='${TB:+set}')"; exit 1; fi
echo "leases acquired (token-scoped) for kr260_01 + kr260_02"

# --- POR-fresh both dies (runbook §1.3: a fresh POR is a precondition) --------
echo "== POR both dies (fresh RX FIFO / FCSM in reset) =="
por_one kr260_01; por_one kr260_02
for k in $(seq 1 18); do sleep 10; [ "$(up "$A")" = up ] && [ "$(up "$B")" = up ] && break; done
if [ "$(up "$A")" != up ] || [ "$(up "$B")" != up ]; then
  echo "ABORT: boards not both up after POR."
  record_gate "PHC_canary" "SKIP(boards-down)"; record_gate "PHC_free_run" "SKIP(boards-down)"
  record_gate "GM_SYNC_advance" "SKIP(boards-down)"; record_gate "roundtrip_offset" "SKIP(boards-down)"
  record_gate "servo_converged" "SKIP(boards-down)"; exit 1
fi

# --- deploy (RUN_AFI=0) then the MANDATORY AFI fix on both --------------------
echo "== deploy both (RUN_AFI=0): kr260-pair-ptp @ die_a, kr260-pair-flip-ptp @ die_b =="
deploy_one "$A" kr260-pair-ptp;      da=$?
deploy_one "$B" kr260-pair-flip-ptp; db=$?
if [ "$da" != 0 ] || [ "$db" != 0 ]; then
  echo "ABORT: deploy failed (die_a rc=$da die_b rc=$db)."
  record_gate "PHC_canary" "SKIP(deploy-fail)"; record_gate "PHC_free_run" "SKIP(deploy-fail)"
  record_gate "GM_SYNC_advance" "SKIP(deploy-fail)"; record_gate "roundtrip_offset" "SKIP(deploy-fail)"
  record_gate "servo_converged" "SKIP(deploy-fail)"; exit 1
fi
echo "== AFI width fix + canaries (mandatory before AXI traffic) =="
if ! afi_fix "$A" || ! afi_fix "$B"; then
  echo "ABORT: AFI fix/canaries failed -- refusing to run PTP traffic on an unfixed link."
  record_gate "PHC_canary" "SKIP(afi-fail)"; record_gate "PHC_free_run" "SKIP(afi-fail)"
  record_gate "GM_SYNC_advance" "SKIP(afi-fail)"; record_gate "roundtrip_offset" "SKIP(afi-fail)"
  record_gate "servo_converged" "SKIP(afi-fail)"; exit 1
fi

# --- budget check before the (long) demo -------------------------------------
now=$(date +%s)
if [ $((now-START)) -ge "$TIME_BUDGET_S" ]; then
  echo "ABORT: time budget exhausted before demo."
  for g in PHC_canary PHC_free_run GM_SYNC_advance roundtrip_offset servo_converged; do
    record_gate "$g" "SKIP(budget)"; done
  exit 1
fi

# --- run the canonical KR260 PTP demo (bring-up + data + doorbell + ptp) ------
# --no-lease: we already hold token-scoped per-board leases; do not let the demo
# acquire/release its own pair lease. TIDELINK_SOC=kr260 must cross the ssh hop.
echo "== PTP demo: td_v2_channels.sh --demo --channels 'data doorbell ptp' $(date +%H:%M:%S) =="
tf=$(mktemp "$OUT_DIR/.ptp.XXXXXX")
( cd "$ROOT/tidelink" && \
  TD_MASTER_IP=10.22.24.159 TD_SLAVE_IP=10.22.24.153 \
  TD_BOARD_USER=ubuntu TD_BOARD_PW="$PW" \
  TD_TL39=/home/ubuntu/td/scripts/tl39.py TIDELINK_SOC=kr260 \
  timeout "$DEMO_TMO" bash fpga/hw_regression/td_v2_channels.sh \
    --no-lease --demo --channels "data doorbell ptp" ) > "$tf" 2>&1
drc=$?
demo=$(mask < "$tf"); rm -f "$tf"
echo "$demo" | tail -120

# --- wedge handling ----------------------------------------------------------
if [ "$drc" = 124 ]; then
  echo "== DEMO TIMED OUT (== wedge) -- POR both dies =="
  por_one kr260_01; por_one kr260_02
  for g in PHC_canary PHC_free_run GM_SYNC_advance roundtrip_offset servo_converged; do
    record_gate "$g" "WEDGE(timeout)"; done
  echo "==== PTP RUN END (wedge) $(date) ===="
  exit 1
fi

# --- parse the four PTP gates (+ convergence) from the demo DETAIL lines ------
gate(){ # gate <label> <ok-regex> <fail-regex>
  if   echo "$demo" | grep -qaiE "$2"; then record_gate "$1" "PASS"
  elif echo "$demo" | grep -qaiE "$3"; then record_gate "$1" "FAIL"
  else record_gate "$1" "ABSENT/SKIP"; fi
}
gate "PHC_canary"       "ok +PHC canary OK"                 "FAIL +PHC canary|PHC canary: (no answer|implausible|did not stick)"
gate "PHC_free_run"     "ok +PHC (master|slave) free-running" "PHC free-run.*FAIL|FAIL +PHC free-run"
gate "GM_SYNC_advance"  "ok +PTP GM emitted SYNCs"          "PTP GM never fired|FAIL +PTP GM"
gate "roundtrip_offset" "ok +PTP round trip complete"       "PTP round trip incomplete|FAIL +PTP round"
gate "servo_converged"  "ok +PTP servo converged"           "FAIL +PTP servo|did not converge"

# --- capture the measured metric + the round-by-round offset trend -----------
echo "== measured PTP metrics =="
echo "$demo" | grep -aE 'MEASURED:' | tail -5
echo "$demo" | grep -aiE '\[ptp\] (round|.offset.)' | tail -12

echo "==== PTP RUN END (demo rc=$drc) $(date) ===="
