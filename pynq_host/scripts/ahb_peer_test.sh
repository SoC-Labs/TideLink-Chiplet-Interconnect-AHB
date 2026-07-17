#!/usr/bin/env bash
# ahb_peer_test.sh — validate M→S and S→M AHB data-path after v25 deploy
#
# Checks:
#   1. sync_det_cnt > 0 on BOTH boards (SYNC guard fix verification)
#   2. M→S: write 0xDEADBEEF to master peer aperture 0x40000000,
#            check slave FIFO 0x44010000 for receipt
#   3. S→M: write 0xCAFEBABE to slave peer aperture 0x40000000,
#            check master FIFO 0x44010000 for receipt
#   4. Report FCSM states on both boards throughout
#
# Run from mapstone-dev:
#   TIDELINK_BOARD_PASS=xilinx bash ahb_peer_test.sh
# =============================================================================
set -eu

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


MASTER_IP="${MASTER_IP:-192.168.4.101}"
SLAVE_IP="${SLAVE_IP:-192.168.6.101}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHCOMMON="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -q"

PYTHON_READ='
import mmap,struct,os,sys
P=4096; fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
    b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
    return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
def rd(a):
    m,o=mm(a); v=struct.unpack_from("<I",m,o)[0]; m.close(); return v
def wr(a,v):
    m,o=mm(a); struct.pack_into("<I",m,o,v); m.close()
'

probe() {
    local ip=$1 label=$2
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$ip" \
      "echo '$PASS' | sudo -S python3 -c '
${PYTHON_READ}
try:
    s=rd(0x44032108)
    s2=rd(0x44032114)
    lk=s&0xff; cd=(s>>16)&1; fs=(s>>17)&0xF
    cr=(s>>23)&1; ck=(s>>24)&1; sd=(s2>>16)&0xFFFF
    fcsm_names={0:\"LINK_IDLE\",1:\"SEND_CR\",2:\"WAIT_CRACK\",3:\"SEND_CRACK\",4:\"LINK_IDLE_4\",5:\"LINK_RUNNING\",7:\"SEND_NACK\"}
    print(\"lk=0x%02x cd=%d fs=%d(%s) cr=%d ck=%d sd=%d\"%(lk,cd,fs,fcsm_names.get(fs,\"?\"),cr,ck,sd))
except Exception as e:
    print(\"ERR:\"+str(e)); import sys; sys.exit(1)
'" 2>/dev/null | sed "s/^/$label: /"
}

write_peer() {
    local ip=$1 label=$2 val=$3
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$ip" \
      "echo '$PASS' | sudo -S python3 -c '
${PYTHON_READ}
try:
    # Write to peer aperture (AHB TX → remote slave RX FIFO)
    wr(0x40000000, $val)
    print(\"wrote 0x%08x to 0x40000000\" % $val)
    import time; time.sleep(0.05)
    # Read FCSM state after write
    s=rd(0x44032108); fs=(s>>17)&0xF
    print(\"fcsm_after_write=%d\" % fs)
except Exception as e:
    print(\"ERR:\"+str(e)); import sys; sys.exit(1)
'" 2>/dev/null | sed "s/^/$label write: /"
}

read_fifo() {
    local ip=$1 label=$2
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$ip" \
      "echo '$PASS' | sudo -S python3 -c '
${PYTHON_READ}
try:
    # RX FIFO: 0x44010000 = data FIFO head
    # Read first word from local RX FIFO
    v=rd(0x44010000)
    print(\"rx_fifo_head=0x%08x\" % v)
    # Also check FCSM
    s=rd(0x44032108); fs=(s>>17)&0xF; cd=(s>>16)&1
    print(\"fcsm=%d cal_done=%d\" % (fs, cd))
except Exception as e:
    print(\"ERR:\"+str(e)); import sys; sys.exit(1)
'" 2>/dev/null | sed "s/^/$label fifo: /"
}

echo "=== AHB Peer Data-Path Test (v25 SYNC guard fix validation) ==="
echo "  master: $MASTER_IP"
echo "  slave:  $SLAVE_IP"
echo ""

echo "--- Step 1: Initial probe (check sync_det_cnt > 0 on both) ---"
probe "$MASTER_IP" "master"
probe "$SLAVE_IP" "slave"
echo ""

echo "--- Step 2: M→S: write 0xDEADBEEF from master peer aperture ---"
write_peer "$MASTER_IP" "master" "0xDEADBEEF"
sleep 0.2
echo ""

echo "--- Step 3: Slave RX FIFO after M→S write ---"
read_fifo "$SLAVE_IP" "slave"
echo ""

echo "--- Step 4: S→M: write 0xCAFEBABE from slave peer aperture ---"
write_peer "$SLAVE_IP" "slave" "0xCAFEBABE"
sleep 0.2
echo ""

echo "--- Step 5: Master RX FIFO after S→M write ---"
read_fifo "$MASTER_IP" "master"
echo ""

echo "--- Step 6: Final probe ---"
probe "$MASTER_IP" "master"
probe "$SLAVE_IP" "slave"
echo ""

echo "=== Done. Key checks: ==="
echo "  sync_det_cnt > 0 on BOTH boards → SYNC guard fix works"
echo "  rx_fifo_head = 0xDEADBEEF on slave → M→S data path OK"
echo "  rx_fifo_head = 0xCAFEBABE on master → S→M data path OK"
echo "  fcsm=5 (LINK_RUNNING) on both throughout → link stable"
