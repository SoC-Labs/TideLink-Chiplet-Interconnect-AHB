#!/bin/bash
# =============================================================================
# lib_hwtest.sh — common helpers for the TideLink HW test suite.
#
# Source this in every hwtest/NN_*.sh category script. Provides:
#   * Per-board APB read/write helpers via /dev/mem (mirror of wlink_probe.sh
#     and bringup_pair_converge.sh so the safety-audited code path stays one).
#   * Lane-status decoder + verify_link_up() — THE gate that must pass before
#     any AHB_TX write. Every test that touches AHB_TX MUST call it.
#   * Pass/fail accounting helpers (tt_pass/tt_fail/tt_skip + tt_summary).
#   * Deploy-pair convenience wrapper (parallel, provenance-guarded).
#
# Style: mirrors the bringup_pair_converge.sh / wlink_probe.sh idiom — direct
# /dev/mem mmap via embedded Python over sshpass+ssh, no PYNQ overlay loading.
# Slow but identical-to-validated; do NOT introduce a new transport.
#
# Conventions:
#   MASTER_IP / SLAVE_IP    192.168.4.101 / 192.168.6.101 (override via env)
#   APB base (TideLink)     0x4403_2000
#   APB base (Wlink)        0x4403_0000
#   debug_unlock GPIO       0x4404_1000  (write 1 first)
#   AHB_TX aperture         0x4400_0000  (32 KB) — WEDGE HAZARD
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
# license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================

# ---------------------------------------------------------------------------
# Shell hygiene: do NOT `set -e` here — category scripts manage their own
# pass/fail; an `set -e` at library level would mask test assertions.
# ---------------------------------------------------------------------------

: "${MASTER_IP:=192.168.4.101}"
: "${SLAVE_IP:=192.168.6.101}"
: "${TIDELINK_BOARD_PASS:=xilinx}"
: "${ARTEFACTS:=/tmp/tidelink_deploy}"
: "${HWTEST_LOGDIR:=/tmp/tidelink_hwtest_logs}"
: "${HWTEST_VERBOSE:=0}"

PASS="$TIDELINK_BOARD_PASS"
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

mkdir -p "$HWTEST_LOGDIR" 2>/dev/null

# Color (only when stderr is a tty — keep CI logs clean).
if [ -t 2 ]; then
    C_R='\033[31m'; C_G='\033[32m'; C_Y='\033[33m'; C_B='\033[34m'; C_N='\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_N=''
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
tt_log()  { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }
tt_info() { printf "${C_B}INFO${C_N}  %s\n" "$*" >&2; }
tt_warn() { printf "${C_Y}WARN${C_N}  %s\n" "$*" >&2; }
tt_err()  { printf "${C_R}ERR${C_N}   %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# /dev/mem helpers — embedded Python over sshpass.
# Each helper outputs a single line on stdout (or empty on failure).
# ---------------------------------------------------------------------------

# tt_devmem_read IP ADDR    -> hex word "0xXXXXXXXX" or ""
tt_devmem_read() {
    local IP=$1 ADDR=$2
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os,sys
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
a=$ADDR; b=a&~(P-1); o=a-b
m=mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b)
print(\"0x%08x\" % struct.unpack_from(\"<I\",m,o)[0])'" 2>/dev/null
}

# tt_devmem_write IP ADDR VAL    -> 0 on success
tt_devmem_write() {
    local IP=$1 ADDR=$2 VAL=$3
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
a=$ADDR; b=a&~(P-1); o=a-b
m=mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b)
struct.pack_into(\"<I\",m,o,$VAL & 0xFFFFFFFF)'" >/dev/null 2>&1
}

# Open debug_unlock GPIO (0x4404_1000) — required before any non-trivial
# Region-4/8 access on the slave. Idempotent; calling multiple times is fine.
tt_debug_unlock() {
    tt_devmem_write "$1" 0x44041000 1
}

# Batch read several offsets relative to TIDELINK APB base 0x4403_2000.
# tt_tl_read_batch IP OFF1 OFF2 ...  -> one hex word per line in order
tt_tl_read_batch() {
    local IP=$1; shift
    local offs="$*"
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
base=0x44032000; b=base&~(P-1); o=base-b
m=mmap.mmap(fd,4096,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b)
for off in [$(echo "$offs" | sed 's/ /,/g')]:
    print(\"0x%08x\" % struct.unpack_from(\"<I\",m,o+off)[0])'" 2>/dev/null
}

# Batch write list of (off,val) pairs to TideLink APB base. Caller passes
# pairs flat: tt_tl_write_batch IP OFF1 VAL1 OFF2 VAL2 ...
tt_tl_write_batch() {
    local IP=$1; shift
    local pairs=""
    while [ "$#" -ge 2 ]; do
        [ -n "$pairs" ] && pairs="$pairs, "
        pairs="$pairs($1, $2)"
        shift 2
    done
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
base=0x44032000; b=base&~(P-1); o=base-b
m=mmap.mmap(fd,4096,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b)
for (off,val) in [$pairs]:
    struct.pack_into(\"<I\",m,o+off,val & 0xFFFFFFFF)'" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Lane status + link verification — THE wedge-hazard gate
# ---------------------------------------------------------------------------

# tt_read_lane_status IP   -> "locked_hex fault_hex cal_done popcount fcsm cr_seen"
# (identical decoder to bringup_pair_converge.sh::read_status)
tt_read_lane_status() {
    local IP=$1
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
 b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
 return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
r,o=mm(0x44032000,0x400); s=struct.unpack_from(\"<I\",r,o+0x108)[0]
lk=s&0xff; ft=(s>>8)&0xff
print(\"0x%02x 0x%02x %d %d %d %d\"%(lk,ft,(s>>16)&1,bin(lk).count(\"1\"),(s>>17)&0xF,(s>>23)&1))'" 2>/dev/null
}

# tt_link_popcount IP  -> popcount of locked byte, or "0" on failure
tt_link_popcount() {
    tt_read_lane_status "$1" | awk '{print $4+0}'
}

# Return 0 if both boards report 8/8 lanes locked + cal_done=1.
# Outputs a one-line summary regardless. Caller is responsible for the
# absolute gating (do NOT proceed to AHB_TX writes if non-zero return).
tt_verify_link_up() {
    local M S MP SP MCD SCD MFT SFT
    M=$(tt_read_lane_status "$MASTER_IP")
    S=$(tt_read_lane_status "$SLAVE_IP")
    MP=$(echo "$M" | awk '{print $4+0}'); SP=$(echo "$S" | awk '{print $4+0}')
    MCD=$(echo "$M" | awk '{print $3+0}'); SCD=$(echo "$S" | awk '{print $3+0}')
    MFT=$(echo "$M" | awk '{print $2}');  SFT=$(echo "$S" | awk '{print $2}')
    tt_info "link: master=${MP}/8 cal_done=${MCD} fault=${MFT}   slave=${SP}/8 cal_done=${SCD} fault=${SFT}"
    if [ "${MP:-0}" -eq 8 ] && [ "${SP:-0}" -eq 8 ] && \
       [ "${MCD:-0}" -eq 1 ] && [ "${SCD:-0}" -eq 1 ]; then
        return 0
    fi
    return 1
}

# AHB_TX safety wrapper. ABORTS the script with exit 3 if link not verified up.
# Every script that writes AHB_TX MUST call this first.
tt_gate_ahb_tx() {
    if ! tt_verify_link_up; then
        tt_err "AHB_TX GATE FAILED — link not 16/16 + cal_done. ABORTING (wedge hazard)."
        tt_err "  Run pynq_host/scripts/bringup_pair_converge.sh first."
        exit 3
    fi
    tt_info "AHB_TX gate PASSED — link 16/16 cal_done both sides; proceeding."
}

# ---------------------------------------------------------------------------
# AHB_TX helpers — ONLY safe after tt_gate_ahb_tx() returns
# ---------------------------------------------------------------------------

# tt_ahb_tx_write IP ADDR VAL  — write to AHB_TX aperture (0x4400_0000+).
# ADDR is absolute; caller should keep within [0x4400_0000, 0x4400_8000).
tt_ahb_tx_write() {
    local IP=$1 ADDR=$2 VAL=$3
    tt_devmem_write "$IP" "$ADDR" "$VAL"
}

# tt_ahb_tx_read IP ADDR -> "0xXXXXXXXX" (read-back; goes through FC and
# returns peer's response). This is also a potential wedge if link drops
# mid-test, so callers should periodically re-verify link.
tt_ahb_tx_read() {
    tt_devmem_read "$1" "$2"
}

# ---------------------------------------------------------------------------
# Assertion helpers (test-result accounting)
# ---------------------------------------------------------------------------

TT_PASS_CNT=0
TT_FAIL_CNT=0
TT_SKIP_CNT=0
TT_START_TS=$(date +%s)

tt_pass()  { TT_PASS_CNT=$((TT_PASS_CNT+1)); printf "${C_G}PASS${C_N}  %s\n" "$*"; }
tt_fail()  { TT_FAIL_CNT=$((TT_FAIL_CNT+1)); printf "${C_R}FAIL${C_N}  %s\n" "$*" >&2; }
tt_skip()  { TT_SKIP_CNT=$((TT_SKIP_CNT+1)); printf "${C_Y}SKIP${C_N}  %s\n" "$*" >&2; }

# tt_assert_eq EXPECTED GOT MSG
tt_assert_eq() {
    if [ "$2" = "$1" ]; then tt_pass "$3 (got $2)"
    else tt_fail "$3 (expected $1, got $2)"; fi
}

# tt_assert_neq EXPECTED GOT MSG
tt_assert_neq() {
    if [ "$2" != "$1" ]; then tt_pass "$3 (got $2)"
    else tt_fail "$3 (got forbidden $2)"; fi
}

# tt_assert_in_range LO HI VAL MSG (decimal)
tt_assert_in_range() {
    if [ "$3" -ge "$1" ] 2>/dev/null && [ "$3" -le "$2" ] 2>/dev/null; then
        tt_pass "$4 (got $3 in [$1..$2])"
    else
        tt_fail "$4 (got $3, expected [$1..$2])"
    fi
}

tt_summary() {
    local now elapsed
    now=$(date +%s); elapsed=$(( now - TT_START_TS ))
    printf "\n=============================================================\n"
    printf " RESULT: %d pass / %d fail / %d skip   (elapsed %ds)\n" \
        "$TT_PASS_CNT" "$TT_FAIL_CNT" "$TT_SKIP_CNT" "$elapsed"
    printf "=============================================================\n"
    [ "$TT_FAIL_CNT" -eq 0 ] && return 0 || return 1
}

# ---------------------------------------------------------------------------
# Convenience: snapshot every register the suite cares about.
# Useful at test entry/exit for diff reporting.
# ---------------------------------------------------------------------------
tt_snapshot_regs() {
    local IP=$1
    local OFFS="0x000 0x004 0x008 0x00C 0x010 0x014 0x018 0x01C \
                0x020 0x024 0x028 0x030 0x034 0x038 0x03C \
                0x040 0x044 0x048 \
                0x080 \
                0x100 0x104 0x108 0x10C 0x110 0x114 0x118 0x11C"
    tt_log "snapshot $IP:"
    for off in $OFFS; do
        local v
        v=$(tt_devmem_read "$IP" "$(( 0x44032000 + off ))")
        printf "  %s = %s\n" "$off" "${v:-<unreadable>}"
    done
}

# Read the build / version ID register (R0 0x014 doubles as TIDELINK_VERSION).
# Returns "0x544C_0100" on a v1.0 build.
tt_read_version() {
    tt_devmem_read "$1" 0x44032014
}
