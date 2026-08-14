#!/usr/bin/env bash
# =============================================================================
# tl035_ab.sh — hardware A/B for TL-035 (state-7 NACK watchdog self-defeat).
#
# Produces a re-checkable HW artefact per arm, which is what sign-off needs
# (docs/REPO_ASSESSMENT_2026_08_10.md:53 — "No HW log exists for any bug").
#
#   usage: KR260_PASSWORD=... tl035_ab.sh <arm-name>
#     arm-name: free-form label for the evidence dir, e.g. "unfixed" / "tl035fix"
#
# Assumes the intended .bin is ALREADY staged at ~/td/tidelink.bin on both
# boards (deploy is a separate, explicit step — this script never picks a
# bitstream for you).
#
# Sequence per arm (the order is load-bearing; skipping any step wedges the PS
# and reads as a "degraded rig"):
#   1. JTAG POR both dies            (kpor on mapstone-dev)
#   2. fpgautil -f Full  both dies   (a POR clears the PL)
#   3. kr260_afi.sh fix  both dies   (MANDATORY after every PL load)
#   4. bringup die_a + die_b CONCURRENTLY (cal_done gates on the peer)
#   5. status      both dies         (expect fcsm=4)
#   6. R1 delivery: plain cross-die write, die_a -> die_b
#   7. R1 errinject: single-bit AW inject -> does die_a wedge? (the TL-035 repro)
#   8. post-mortem reachability of both dies
# =============================================================================
set -u

ARM="${1:?usage: tl035_ab.sh <arm-name>}"
: "${KR260_PASSWORD:?KR260_PASSWORD not set}"

ETH=/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet
RUN="$ETH/tidelink/pynq_host/scripts/kr260_eth_run.sh"
KB="$(cd "$(dirname "$0")" && pwd)/kb.sh"
IP_A=10.22.24.159
IP_B=10.22.24.153
OUT="${OUTDIR:-/tmpdir/claude-74755/-home-dam1n19-SoCLabs-tidelink/029fa128-e7f4-41b2-a3bf-6880af5cca50/scratchpad/hw_gate}/tl035_$ARM"
mkdir -p "$OUT"

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/00_run.log"; }
alive() { ping -c1 -W2 "$1" >/dev/null 2>&1 && echo UP || echo DOWN; }

# ssh_wait — block until the board actually answers SSH, not merely ping.
# After a JTAG POR the network stack answers ICMP well before sshd is listening,
# so a ping-only readiness check races the first privileged command and returns
# EMPTY output — which the md5 gate then (correctly) treats as an unverifiable
# image and aborts on. Wait for a real command to succeed.
ssh_wait() {
    local ip="$1" tries="${2:-60}" i
    for i in $(seq 1 "$tries"); do
        if timeout 10 sshpass -p "$KR260_PASSWORD" ssh -o StrictHostKeyChecking=no \
             -o ConnectTimeout=5 "ubuntu@$ip" true >/dev/null 2>&1; then
            log "  ssh ready on $ip (after ${i} attempt(s))"; return 0
        fi
        sleep 5
    done
    log "  ssh NEVER became ready on $ip after $((tries*5))s"; return 1
}

log "=== TL-035 HW arm '$ARM' — started $(date -u +%FT%TZ) ==="

# --- 1. POR both dies ------------------------------------------------------
log "step 1: JTAG POR both dies"
ssh -o BatchMode=yes mapstone-dev "~/bin/kpor kr260-01 --wait" > "$OUT/01_por_a.log" 2>&1 &
pa=$!
ssh -o BatchMode=yes mapstone-dev "~/bin/kpor kr260-02 --wait" > "$OUT/01_por_b.log" 2>&1 &
pb=$!
wait $pa; wait $pb
log "  ping: die_a=$(alive $IP_A) die_b=$(alive $IP_B)"
ssh_wait $IP_A || exit 5
ssh_wait $IP_B || exit 5

# --- 2. select the arm image, VERIFY md5, then load PL ---------------------
# Provenance is load-bearing: the rig was found running an unlabelled ILA build
# whose .hwh belonged to a DIFFERENT design, so "which bitstream is on the
# board" cannot be assumed. Deploy a named arm and prove it by md5.
BIN="td/tl_arm_${ARM}.bin"
log "step 2: select $BIN, verify md5, fpgautil load (a POR clears the PL)"
# die_a and die_b run DIFFERENT images (normal vs -flip), so the two dies must
# NOT match each other. What must match is, per die, the deployed tidelink.bin
# against that die's staged arm image, and against the expected source md5
# passed in via MD5_A / MD5_B.
: "${MD5_A:?MD5_A (expected die_a md5 for arm $ARM) not set}"
: "${MD5_B:?MD5_B (expected die_b md5 for arm $ARM) not set}"
for pair in "$IP_A:$MD5_A:die_a" "$IP_B:$MD5_B:die_b"; do
  ip=${pair%%:*}; rest=${pair#*:}; want=${rest%%:*}; who=${rest#*:}
  got=$(KR260_PASSWORD="$KR260_PASSWORD" "$KB" "$ip" \
        "cp $BIN td/tidelink.bin && md5sum td/tidelink.bin" 2>/dev/null | awk '{print $1}' | tail -1)
  echo "$who deployed=$got expected=$want" >> "$OUT/02_md5.log"
  if [ "$got" != "$want" ]; then
    log "  MD5 MISMATCH on $who: got=$got want=$want — ABORTING"; exit 4
  fi
  log "  $who md5 verified: $got"
done
KR260_PASSWORD="$KR260_PASSWORD" "$KB" $IP_A "fpgautil -b td/tidelink.bin -f Full" > "$OUT/02_pl_a.log" 2>&1
KR260_PASSWORD="$KR260_PASSWORD" "$KB" $IP_B "fpgautil -b td/tidelink.bin -f Full" > "$OUT/02_pl_b.log" 2>&1
grep -h "successfully" "$OUT"/02_pl_*.log | tee -a "$OUT/00_run.log"

# --- 3. AFI width fix (MANDATORY) -----------------------------------------
log "step 3: AFI PS-master-port width fix"
KR260_PASSWORD="$KR260_PASSWORD" "$KB" $IP_A "env KR260_AFI_NO_CANARY=1 sh td/scripts/kr260_afi.sh fix" > "$OUT/03_afi_a.log" 2>&1
KR260_PASSWORD="$KR260_PASSWORD" "$KB" $IP_B "env KR260_AFI_NO_CANARY=1 sh td/scripts/kr260_afi.sh fix" > "$OUT/03_afi_b.log" 2>&1
grep -h "^AFI:" "$OUT"/03_afi_*.log | tee -a "$OUT/00_run.log"

# --- 4. bring up the link, BOTH dies together -----------------------------
log "step 4: bringup (concurrent — cal_done gates on the peer)"
KR260_PASSWORD="$KR260_PASSWORD" KR260_HOST=ubuntu@$IP_A KR260_ETH_ROLE=die_a \
    timeout 300 bash "$RUN" bringup > "$OUT/04_bringup_a.log" 2>&1 &
qa=$!
KR260_PASSWORD="$KR260_PASSWORD" KR260_HOST=ubuntu@$IP_B KR260_ETH_ROLE=die_b \
    timeout 300 bash "$RUN" bringup > "$OUT/04_bringup_b.log" 2>&1 &
qb=$!
wait $qa; wait $qb
log "  bringup rc: die_a/die_b captured in 04_bringup_*.log"

# --- 5. status -------------------------------------------------------------
log "step 5: status (expect fcsm=4 both)"
KR260_PASSWORD="$KR260_PASSWORD" KR260_HOST=ubuntu@$IP_A timeout 180 bash "$RUN" status > "$OUT/05_status_a.log" 2>&1
KR260_PASSWORD="$KR260_PASSWORD" KR260_HOST=ubuntu@$IP_B timeout 180 bash "$RUN" status > "$OUT/05_status_b.log" 2>&1
grep -h "SWI_LANE_STAT\|calibration_done\|fcsm=" "$OUT"/05_status_*.log | tee -a "$OUT/00_run.log"

# --- 6. R1 delivery: does the rig actually carry data? --------------------
log "step 6: R1 plain cross-die write (the honest delivery check)"
KR260_PASSWORD="$KR260_PASSWORD" KR260_HOST=ubuntu@$IP_B KR260_XFER_ITERS=${ITERS:-128} \
    timeout 300 bash "$RUN" xfer_recv > "$OUT/06_recv_b.log" 2>&1 &
rb=$!
sleep 3
KR260_PASSWORD="$KR260_PASSWORD" KR260_HOST=ubuntu@$IP_A KR260_XFER_ITERS=${ITERS:-128} \
    timeout 300 bash "$RUN" xfer_send > "$OUT/06_send_a.log" 2>&1
wait $rb
tail -5 "$OUT/06_send_a.log" | tee -a "$OUT/00_run.log"
log "  die_a=$(alive $IP_A) die_b=$(alive $IP_B)  (post-delivery)"

# --- 6b. Region F per-beat wedge gate (the real discriminator) -------------
# OBS_AXI_NODES 0x21E0 gives PER-CHANNEL wedge stickies for aw/w/b/ar/r on both
# initiator and target. The 08-12 ILA could not see any of this: all 22 of its
# probes read the SIDEBAND node (FCSM_6/wlink_tidelinktl) and the AHB ctrl
# adapter, never the AXI data nodes. This gate samples Region F every beat and
# fails fast BEFORE the PS AXI saturates, so it reads the answer without JTAG.
log "step 6b: Region F per-beat wedge gate (fwd)"
KR260_PASSWORD="$KR260_PASSWORD" timeout 900 python3 \
    "$ETH/tidelink/pynq_host/scripts/coverage/cov_axinode_wedge_gate.py" \
    --direction fwd --iters "${RFITERS:-200}" > "$OUT/06b_regionf_gate.log" 2>&1
log "  region-F gate rc=$?"
grep -E "PASS|FAIL|healthy|sticky|WEDGE" "$OUT/06b_regionf_gate.log" | tail -8 | tee -a "$OUT/00_run.log"

# --- 6c. INSTRUMENT LIVENESS — does the Region F front-end sample at all? ---
# Resolves the TL-039/TL-040 doubt WITHOUT an ILA rebuild. stall_live[9:0] and
# any_stall_live[22] are COMBINATIONAL (valid & ~ready, no 2**WEDGE_LOG2
# threshold), and a running write soak produces routine per-word backpressure.
#   bits MOVE under load  -> front-end is sampling; a later all-clean wedge word
#                            is TRUSTWORTHY (=> genuine never-driven B)
#   bits NEVER move       -> the sampler is dead; every all-clean read is
#                            MEANINGLESS and the AXI-node ILA is unavoidable
log "step 6c: Region F instrument liveness under load (die_a)"
KR260_PASSWORD="$KR260_PASSWORD" "$KB" $IP_A \
    "python3 td/scripts/kr260_eth_soak_fwd.py write ${LIVEN:-400} A5A50000" \
    > "$OUT/06d_liveness_soak.log" 2>&1 &
soakpid=$!
for i in $(seq 1 "${LIVEPOLLS:-25}"); do
  v=$(KR260_PASSWORD="$KR260_PASSWORD" "$KB" $IP_A \
      "python3 td/scripts/eth_tlapb_poke.py read 0x21E0" 2>/dev/null | tr -d '\r' | tail -1)
  echo "$v" >> "$OUT/06d_liveness_samples.log"
done
wait $soakpid 2>/dev/null
python3 - "$OUT/06d_liveness_samples.log" <<'PY' | tee -a "$OUT/00_run.log"
import re,sys
vals=[int(m.group(1),16) for l in open(sys.argv[1])
      for m in [re.search(r"(0x[0-9a-fA-F]{8})",l)] if m]
if not vals:
    print("  LIVENESS: no readable samples — instrument or poke path broken"); raise SystemExit
moved = any((v>>22)&1 for v in vals) or any(v & 0x3FF for v in vals)
uniq  = len({v & 0x7FFFFF for v in vals})
print(f"  LIVENESS: {len(vals)} samples, {uniq} distinct low-words, "
      f"stall bits moved = {moved}")
if moved:
    print("  => front-end IS sampling. An all-clean word at the wedge is TRUSTWORTHY")
    print("     and means a genuine never-driven B, not a dead instrument.")
else:
    print("  => stall bits NEVER moved under active write load. Treat the sampler as")
    print("     DEAD (TL-039/TL-040): every all-clean Region F read is MEANINGLESS,")
    print("     including TL-009's 0xad800000. AXI-node ILA required.")
PY

# Region F snapshot on BOTH dies BEFORE the inject (baseline for the delta).
for pair in "$IP_A:die_a" "$IP_B:die_b"; do
  ip=${pair%%:*}; who=${pair#*:}
  v=$(KR260_PASSWORD="$KR260_PASSWORD" "$KB" "$ip" \
      "python3 td/scripts/eth_tlapb_poke.py read 0x21E0" 2>/dev/null | tr -d '\r' | tail -1)
  echo "$(date -u +%H:%M:%S.%3N) pre_inject $who OBS_AXI_NODES(0x21E0)=$v" | tee -a "$OUT/00_run.log" >> "$OUT/06c_regionf_pre.log"
done

# die_b LOCAL memory state BEFORE the inject. Local read of shared_sram_0 — no
# link traversal, so the verifier itself cannot wedge. Paired with the post-inject
# read this splits the two live hypotheses for an ALL-CLEAN wedge draw:
#   memory CHANGES across the inject -> die_b was still completing writes, so the
#     write landed and its B was lost on the RETURN path (lost-B alive for that subset)
#   memory UNCHANGED               -> die_b failed UPSTREAM of the m_axi tap
#     (AW-node / a2l-replay), and Region F reads clean only because its taps sit
#     downstream of where the write actually died
mb=$(KR260_PASSWORD="$KR260_PASSWORD" "$KB" $IP_B \
     "python3 td/scripts/kr260_eth_soak_fwd.py verify 16 A5A50000" 2>/dev/null | tr -d '\r' | tail -2)
echo "$(date -u +%H:%M:%S.%3N) pre_inject die_b LOCALMEM: $mb" | tee -a "$OUT/00_run.log" >> "$OUT/06e_localmem_pre.log"
# RAW words too — the pass count cannot say WHICH address moved, and the read is
# three-way: injected marker moved (landed, B lost on return) vs only resume-stream
# addrs moved (injected beat silently dropped) vs nothing moved (die_b stopped).
dmp_pre=$(KR260_PASSWORD="$KR260_PASSWORD" "$KB" $IP_B \
          "python3 td/scripts/dieb_dump.py 32" 2>/dev/null | tr -d '\r' | grep -E "^DUMP|DUMPFAIL" | tail -1)
echo "$(date -u +%H:%M:%S.%3N) pre_inject $dmp_pre" >> "$OUT/06e_localmem_pre.log"

# --- 7. R1 errinject: the TL-035 repro ------------------------------------
# Use the directional coverage sweep, NOT kr260_eth_xfer.py --node: the xfer
# tool only accepts B/R/W, and the AW inject that provokes TL-035 exists only
# in cov_errinject_sweep.py. The sweep also enforces the DIRECTIONAL rule
# (inject on the TRANSMITTING die) that makes a B/R "survive" non-vacuous.
log "step 7: directional errinject sweep (TL-035 wedge repro) nodes=${NODES:-AW,W,B}"
COV_AUTO_POR=1 KR260_PASSWORD="$KR260_PASSWORD" \
    timeout 1800 python3 "$ETH/tidelink/pynq_host/scripts/coverage/cov_errinject_sweep.py" \
    --nodes "${NODES:-AW,W,B}" --wsoak "${WSOAK:-10}" > "$OUT/07_errinject_sweep.log" 2>&1
rc=$?
grep -E "PASS|FAIL|WEDGE|rate" "$OUT/07_errinject_sweep.log" | tail -12 | tee -a "$OUT/00_run.log"
log "  errinject sweep rc=$rc  (124 = the rc=124 wedge signature)"

# --- 7b. Region F AFTER the inject — read from die_b, which stays alive ----
# This single word discriminates the competing hypotheses directly:
#   b sticky              -> the completion path (the 08-13 "lost write response")
#   aw / w sticky         -> the write never delivered (TL-035 / data_id-drop family)
#   data_healthy=1 + hang -> the stall is upstream of the AXI nodes entirely
# Decode (src/rtl/tidelink_axinode_obs.sv:68-73):
#   [31:24]=0xAD marker, [23]=data_nodes_healthy,
#   [19:15]=ini_wedge_sticky{r,ar,b,w,aw}, [14:10]=tgt_wedge_sticky{r,ar,b,w,aw}
log "step 7b: Region F AFTER inject (die_b — survives die_a's wedge)"
for pair in "$IP_B:die_b" "$IP_A:die_a"; do
  ip=${pair%%:*}; who=${pair#*:}
  v=$(KR260_PASSWORD="$KR260_PASSWORD" "$KB" "$ip" \
      "python3 td/scripts/eth_tlapb_poke.py read 0x21E0" 2>/dev/null | tr -d '\r' | tail -1)
  [ -z "$v" ] && v="UNREADABLE (die wedged / bus hung)"
  echo "$(date -u +%H:%M:%S.%3N) post_inject $who OBS_AXI_NODES(0x21E0)=$v" | tee -a "$OUT/00_run.log" >> "$OUT/07b_regionf_post.log"
done
python3 - "$OUT/07b_regionf_post.log" <<'PY' 2>/dev/null | tee -a "$OUT/00_run.log"
import re,sys
# Full layout, verified against src/rtl/tidelink_axinode_obs.sv:65-74:
#  [4:0] tgt_stall_live{r,ar,b,w,aw}  [9:5] ini_stall_live  [14:10] tgt_wedge_sticky
#  [19:15] ini_wedge_sticky  [20] tgt_resp_err  [21] ini_resp_err
#  [22] any_stall_live  [23] data_nodes_healthy  [31:24] 0xAD marker
CH=["aw","w","b","ar","r"]
def dec(v,sh): return [CH[i] for i in range(5) if (v>>(sh+i))&1]
for line in open(sys.argv[1]):
    m=re.search(r"(die_[ab]).*?(0x[0-9a-fA-F]{8})",line)
    if not m: continue
    who,v=m.group(1),int(m.group(2),16)
    if (v>>24)&0xFF!=0xAD:
        print(f"  {who}: marker!=0xAD ({v:#010x}) — Region F absent/undecoded, word is MEANINGLESS")
        continue
    tS,iS,tW,iW = dec(v,0),dec(v,5),dec(v,10),dec(v,15)
    tE,iE,anyS,hl = (v>>20)&1,(v>>21)&1,(v>>22)&1,(v>>23)&1
    print(f"  {who} {v:#010x}: healthy={hl} any_stall={anyS}")
    print(f"    stall_live  tgt={tS or '-'} ini={iS or '-'}")
    print(f"    wedge_sticky tgt={tW or '-'} ini={iW or '-'}")
    print(f"    resp_err    tgt={tE} ini={iE}")
    # Interpretation. NOTE the asymmetry: wedge_sticky/stall_live need valid & !ready,
    # so a B that is NEVER DRIVEN (b_valid=0 forever — the AXIREC lost-completion case)
    # produces NO b stall, NO b wedge and NO resp_err. An all-clean word during a
    # CONFIRMED wedge therefore CANNOT distinguish "never-returned B" from an
    # instrument that is not really sampling (TL-039/TL-040). Only aw/w sticky is a
    # POSITIVE signal that a write was accepted and is not draining.
    w = set(tW)|set(iW)
    if w & {"aw","w"} and "b" not in w:
        print("    => WRITE STUCK PRE-COMPLETION (aw/w wedged, b clean) — TL-035 / data_id-drop family")
    elif "b" in w:
        print("    => B DRIVEN BUT REFUSED (b stalled) — completion path backpressured, NOT 'never returned'")
    elif tE or iE:
        print("    => B/R COMPLETED WITH SLVERR (resp[1]) — error response, not a lost completion")
    elif hl and not anyS:
        print("    => ALL CLEAN. AMBIGUOUS: either a never-driven B (AXIREC lost completion,")
        print("       invisible to this word by construction) OR the sampler is not sampling")
        print("       (TL-039/TL-040). NOT evidence of 'no wedge'. Needs mark_debug on")
        print("       axi_tgt_0_*/axi_ini_0_* aw/w/b to separate.")
PY

# --- 7c. die_b LOCAL memory AFTER the inject — the H1/H2 discriminator -----
mb2=$(KR260_PASSWORD="$KR260_PASSWORD" "$KB" $IP_B \
      "python3 td/scripts/kr260_eth_soak_fwd.py verify 16 A5A50000" 2>/dev/null | tr -d '\r' | tail -2)
echo "$(date -u +%H:%M:%S.%3N) post_inject die_b LOCALMEM: $mb2" | tee -a "$OUT/00_run.log" >> "$OUT/07c_localmem_post.log"
dmp_post=$(KR260_PASSWORD="$KR260_PASSWORD" "$KB" $IP_B \
           "python3 td/scripts/dieb_dump.py 32" 2>/dev/null | tr -d '\r' | grep -E "^DUMP|DUMPFAIL" | tail -1)
echo "$(date -u +%H:%M:%S.%3N) post_inject $dmp_post" >> "$OUT/07c_localmem_post.log"
# Word-by-word diff: name the CHANGED INDICES, not just "something changed".
python3 - "$dmp_pre" "$dmp_post" <<'PY' | tee -a "$OUT/00_run.log"
import sys
def words(s):
    t = s.split()
    return [x for x in t if len(x) == 8 and all(c in "0123456789abcdef" for c in x)]
a, b = words(sys.argv[1]), words(sys.argv[2])
if not a or not b or len(a) != len(b):
    print("  LOCALMEM: dump unavailable or length mismatch — cannot diff"); raise SystemExit
ch = [i for i in range(len(a)) if a[i] != b[i]]
if not ch:
    print("  LOCALMEM UNCHANGED across the inject -> die_b completed NO further writes (H1: failed upstream)")
else:
    print("  LOCALMEM CHANGED at word idx %s" % ch)
    for i in ch[:8]:
        print("    idx%-3d 0x%s -> 0x%s" % (i, a[i], b[i]))
    print("    idx0 is the injected/arming marker landing (peer 0x2F001000 -> die_b 0x2D001000).")
    print("    idx0 changed => the injected write LANDED (B lost on return, H2).")
    print("    idx0 UNCHANGED while later idx moved => injected beat SILENTLY DROPPED")
    print("    while die_b kept accepting later writes — a THIRD outcome, not H1 or H2.")
PY

# --- 8. post-mortem --------------------------------------------------------
log "step 8: post-mortem reachability"
log "  die_a=$(alive $IP_A) die_b=$(alive $IP_B)"
{
  echo "arm=$ARM"
  echo "errinject_rc=$rc"
  echo "die_a_post=$(alive $IP_A)"
  echo "die_b_post=$(alive $IP_B)"
  echo "finished=$(date -u +%FT%TZ)"
} > "$OUT/99_verdict.txt"
cat "$OUT/99_verdict.txt" | tee -a "$OUT/00_run.log"
log "=== arm '$ARM' complete — evidence in $OUT ==="
