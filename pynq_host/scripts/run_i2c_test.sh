#!/usr/bin/env bash
# Orchestrates the directed on-ribbon W9/V7 I2C electrical test ON
# mapstone-dev (which has direct routes to the boards). One invocation:
#   heartbeat lease -> re-deploy both (fresh POR re-arms autoneg) ->
#   push nego_probe.py to both boards -> slave probe (bg, long backoff,
#   sits in WAIT) -> +4s -> master probe (short backoff, claims, drives
#   I2C START over W9/V7) -> collect both 18s decoded trajectories.
# Not set -e: a board hiccup must still yield diagnostics.
set -u
HW=~/tidelink_hwval
PASS=xilinx
A_IP=192.168.4.101   # z2_02 die_a master  (pair-all)
B_IP=192.168.6.101   # z2_03 die_b slave   (flip-all)
TOKEN=rBIqcz1YxU4ZH-HqoI2hOg
SSHB="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SCPB="sshpass -p $PASS scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "===== [0] lease heartbeat ====="
/opt/fpgahub/bin/fpgahub pair lease heartbeat bridge1 --token "$TOKEN" 2>&1 | tail -3
/opt/fpgahub/bin/fpgahub pair lease show bridge1 2>&1 | head -3

echo "===== [1] re-deploy die_a (z2_02 / pair-all) ====="
( cd "$HW" && TIDELINK_BOARD_PASS=$PASS bash deploy_pair.sh "$A_IP" z2_02 die_a "$HW" ) 2>&1 | tail -8
echo "===== [1] re-deploy die_b (z2_03 / flip-all) ====="
( cd "$HW" && TIDELINK_BOARD_PASS=$PASS bash deploy_pair.sh "$B_IP" z2_03 die_b "$HW" ) 2>&1 | tail -8

echo "===== [2] push nego_probe.py to both boards ====="
$SCPB "$HW/nego_probe.py" "xilinx@$A_IP:/tmp/nego_probe.py" && echo "z2_02 <- nego_probe.py OK"
$SCPB "$HW/nego_probe.py" "xilinx@$B_IP:/tmp/nego_probe.py" && echo "z2_03 <- nego_probe.py OK"
sleep 3

echo "===== [3] slave probe (z2_03) in background ====="
$SSHB "xilinx@$B_IP" "echo $PASS | sudo -S python3 /tmp/nego_probe.py slave" > /tmp/np_slave.log 2>&1 &
SLV=$!
sleep 4   # ensure slave is enabled and sitting in WAIT before master claims
echo "===== [3] master probe (z2_02) foreground ====="
$SSHB "xilinx@$A_IP" "echo $PASS | sudo -S python3 /tmp/nego_probe.py master" > /tmp/np_master.log 2>&1
wait $SLV 2>/dev/null

echo "===== [4] RESULTS ============================================="
echo "----- SLAVE  z2_03 (192.168.6.101) -----"
cat /tmp/np_slave.log
echo "----- MASTER z2_02 (192.168.4.101) -----"
cat /tmp/np_master.log
echo "===== END ===================================================="
