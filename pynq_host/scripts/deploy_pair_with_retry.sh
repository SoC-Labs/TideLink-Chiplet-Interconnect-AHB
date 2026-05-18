#!/bin/bash
# Deploy master + slave, find a phase combo that brings up TideLink FC.
# Iterates slave phase 0..15 and (optionally) master phase 0..15. After
# each redeploy, rings 5 doorbells and checks if both sides report
# TideLink FC active=1 AND DOORBELL_RESP_ACC ticks on slave (which is
# the gold-standard end-to-end test).
#
# Usage: deploy_pair_with_retry.sh
#   Env: MASTER_IP, SLAVE_IP, MAX_RETRIES (default 32), PASS (default xilinx)
set -e
MASTER_IP="${MASTER_IP:-192.168.4.101}"
SLAVE_IP="${SLAVE_IP:-192.168.6.101}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SCRIPT_DIR="${SCRIPT_DIR:-$(dirname "$0")}"

CHECK_PY='import mmap,struct,os
P=4096; fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
    b=a&~(P-1); o=a-b; pages=((sz+o+P-1)//P)*P
    return mmap.mmap(fd,pages,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
r,ro=mm(0x44032000)
w,wo=mm(0x44030000,0x2000)
import sys
mode=sys.argv[1] if len(sys.argv)>1 else "stat"
if mode=="ring":
    import time
    for _ in range(5):
        struct.pack_into("<I",r,ro+0x14,1)
        time.sleep(0.05)
    print("RANG")
else:
    fc=struct.unpack_from("<I",w,wo+0x1700+0x08)[0]
    cc=struct.unpack_from("<I",r,ro+0x0c)[0]
    rel=struct.unpack_from("<I",r,ro+0x20)[0]
    dra=struct.unpack_from("<I",r,ro+0x24)[0]
    pcc=struct.unpack_from("<I",r,ro+0x28)[0]
    print("fc={} cc={} rel={} dra={} pcc={}".format(fc,cc,rel,dra,pcc))'

run_remote() {
    local ip="$1" mode="$2"
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR "xilinx@$ip" "echo '$PASS' | sudo -S python3 -c '$CHECK_PY' $mode 2>/dev/null"
}

echo "Phase retry loop: master=0 fixed, slave sweeping 0..15..."
for ph in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    pa=$(printf 0x%08x $((ph<<17)))
    bash "$SCRIPT_DIR/deploy_pair.sh" "$MASTER_IP" master die_a > /dev/null 2>&1
    PHASE_OVERRIDE="$pa" bash "$SCRIPT_DIR/deploy_pair.sh" "$SLAVE_IP" slave die_b > /dev/null 2>&1
    sleep 0.3
    run_remote "$MASTER_IP" ring > /dev/null
    sleep 0.2
    m_stat=$(run_remote "$MASTER_IP" stat)
    s_stat=$(run_remote "$SLAVE_IP" stat)
    echo "ph=$ph M[$m_stat] S[$s_stat]"
    # Success criteria: both fc=1 AND slave dra > 0
    s_dra=$(echo "$s_stat" | grep -oP 'dra=\K\d+')
    s_fc=$(echo "$s_stat" | grep -oP 'fc=\K\d+')
    m_fc=$(echo "$m_stat" | grep -oP 'fc=\K\d+')
    if [ "$s_dra" -gt 0 ] 2>/dev/null && [ "$s_fc" = "1" ] && [ "$m_fc" = "1" ]; then
        echo "*** SUCCESS at slave_phase=$ph ***"
        exit 0
    fi
done
echo "No phase value brought up TideLink FC end-to-end"
exit 1
