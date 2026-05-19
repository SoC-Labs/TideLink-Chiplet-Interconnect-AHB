#!/usr/bin/env bash
# Fast headless I2C-activity test on mapstone-dev. Boards are already
# deployed with the ila_i2c bitstreams (FSMs at fresh POR from the
# recent redeploy). Pushes the fast probe, runs slave bg + master fg
# with 5 ms polling over 5 s, prints both decoded trajectories +
# sticky-activity verdicts (i2c_busy / i2c_addr / sda_start_seen).
set -u
HW=~/tidelink_hwval; PASS=xilinx
A_IP=192.168.4.101; B_IP=192.168.6.101
TOKEN=BAWCVrMcUALEpqAmKCguoA
SSHB="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SCPB="sshpass -p $PASS scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "===== [0] lease heartbeat ====="
/opt/fpgahub/bin/fpgahub pair lease heartbeat bridge1 --token "$TOKEN" 2>&1 | tail -2

echo "===== [1] push nego_probe_fast.py to both boards ====="
$SCPB "$HW/nego_probe_fast.py" "xilinx@$A_IP:/tmp/nego_probe_fast.py" && echo z2_02 OK
$SCPB "$HW/nego_probe_fast.py" "xilinx@$B_IP:/tmp/nego_probe_fast.py" && echo z2_03 OK

echo "===== [2] slave probe (z2_03) bg ====="
$SSHB "xilinx@$B_IP" "echo $PASS | sudo -S python3 /tmp/nego_probe_fast.py slave" > /tmp/npf_slave.log 2>&1 &
SLV=$!
sleep 4
echo "===== [2] master probe (z2_02) fg ====="
$SSHB "xilinx@$A_IP" "echo $PASS | sudo -S python3 /tmp/nego_probe_fast.py master" > /tmp/npf_master.log 2>&1
wait $SLV 2>/dev/null

echo "===== [3] RESULTS ============================================"
echo "----- SLAVE  z2_03 -----"; cat /tmp/npf_slave.log
echo "----- MASTER z2_02 -----"; cat /tmp/npf_master.log
echo "===== END ===================================================="
