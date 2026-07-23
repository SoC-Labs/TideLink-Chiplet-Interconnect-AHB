#!/usr/bin/env bash
# =============================================================================
# probe_autoneg_obs.sh — read TideLink calibrator / FCSM / lane-status from
# a live PYNQ-Z2 board and emit key-value lines for variance-loop parsing.
#
# Usage: probe_autoneg_obs.sh <BOARD_IP> <LABEL>
#
# Outputs (to stdout):
#   label=<LABEL>
#   cal_done=0|1
#   lane_locked=0xNN
#   fcsm_state=N
#   cr_pkt_seen=0|1
#   crack_pkt_seen=0|1
#   sync_det_cnt=N         (0x2114[31:16]; >0 = deskew delivering aligned words)
#
# Optional (if NEGO_TRAIN_STATUS register available, may be 0):
#   cal_state=N (STATE_NAME)
#   resweep_ctr=0
#
# v24 variant — expects Region 8 base 0x44032000 + APB at 0x44030000 / FIFO
# at 0x44010000 (not read here, just lane-lock + FCSM + SYNC-det counter).
#
# Run on mapstone-dev (has sshpass, routes to both /24s):
#   bash probe_autoneg_obs.sh 192.168.4.101 z2_02_master
# =============================================================================
set -u

# --- ZynqMP (KR260) SAFETY GUARD (inline) ------------------------------------
# This tool mmaps RAW Pynq-Z2 control literals (0x4403_xxxx / 0x4404_xxxx /
# 0x4405_xxxx) over /dev/mem, un-relocated. On a ZynqMP (KR260) those addresses
# are UNDECODED with NO bus timeout => a hard PS hang (power-cycle to recover).
# Pynq-Z2 ONLY. Refuse the moment we start if TIDELINK_SOC names anything else.
# Safe on a KR260: tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.
_tl_guard_soc=$(printf '%s' "${TIDELINK_SOC:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
case "$_tl_guard_soc" in
  ""|z2|pynq-z2|pynq_z2|zynq7|zynq) : ;;
  *)
    printf '\n[%s] REFUSING TO RUN on TIDELINK_SOC=%s — mmaps RAW Z2 literals (0x4403_xxxx)\n' "${0##*/}" "$TIDELINK_SOC" >&2
    printf '  UNDECODED on a ZynqMP (KR260) => hard PS hang. This tool is Pynq-Z2 ONLY.\n' >&2
    printf '  On a KR260 use tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.\n' >&2
    exit 3 ;;
esac


BOARD_IP="${1:?usage: probe_autoneg_obs.sh <BOARD_IP> <LABEL>}"
LABEL="${2:-board}"

PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHCOMMON="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -q"

# Region-8 base = 0x44032000 (SWI regs).
# SWI_LANE_STATUS  = base + 0x108 -> locked[7:0] fault[15:8] cal_done[16]
#                    fcsm[20:17] llrx_state[22:21] cr_seen[23] crack_seen[24]
# SYNC_DET / ECC   = base + 0x114 -> [15:0]=ecc_corr_cnt(dead) [31:16]=sync_det_cnt
RESULT=$(sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$BOARD_IP" \
  "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os,sys
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
  b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
  return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
try:
  r,o=mm(0x44032000,0x400)
  s=struct.unpack_from(\"<I\",r,o+0x108)[0]
  s2=struct.unpack_from(\"<I\",r,o+0x114)[0]
  lk=s&0xff
  cd=(s>>16)&1
  fs=(s>>17)&0xF
  cr=(s>>23)&1
  ck=(s>>24)&1
  sd=(s2>>16)&0xFFFF
  print(\"lk=0x%02x cd=%d fs=%d cr=%d ck=%d sd=%d\"%(lk,cd,fs,cr,ck,sd))
except Exception as e:
  print(\"ERR:\"+str(e),file=sys.stderr)
  sys.exit(1)
'" 2>/dev/null)

if [ -z "$RESULT" ]; then
  echo "label=$LABEL"
  echo "cal_done=0"
  echo "lane_locked=0x00"
  echo "fcsm_state=0"
  echo "PROBE_ERR=ssh_or_mmap_failed"
  exit 1
fi

# Parse: lk=0xNN cd=N fs=N cr=N ck=N sd=N
LK=$(echo "$RESULT" | grep -oP '(?<=lk=)0x[0-9a-f]+' || echo "0x00")
CD=$(echo "$RESULT" | grep -oP '(?<=cd=)\d' || echo "0")
FS=$(echo "$RESULT" | grep -oP '(?<=fs=)\d+' || echo "0")
CR=$(echo "$RESULT" | grep -oP '(?<=cr=)\d' || echo "0")
CK=$(echo "$RESULT" | grep -oP '(?<=ck=)\d' || echo "0")
SD=$(echo "$RESULT" | grep -oP '(?<=sd=)\d+' || echo "0")

# FCSM state name mapping (WlinkGenericFCSM_6.v state encoding)
case "$FS" in
  0) FSN="LINK_IDLE"    ;;
  1) FSN="SEND_CR"      ;;
  2) FSN="WAIT_CRACK"   ;;
  3) FSN="SEND_CRACK"   ;;
  4) FSN="LINK_IDLE_4"  ;;
  5) FSN="LINK_RUNNING" ;;
  *) FSN="UNKNOWN"      ;;
esac

echo "label=$LABEL"
echo "cal_done=$CD"
echo "lane_locked=$LK"
echo "fcsm_state=$FS"
echo "fcsm_name=$FSN"
echo "cr_pkt_seen=$CR"
echo "crack_pkt_seen=$CK"
echo "sync_det_cnt=$SD"
# cal_state and resweep_ctr not exposed in this register set; variance loop
# fallback is || echo "?" / || echo "0" — no output here is correct.
