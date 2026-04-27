#!/bin/bash
# Deploy the pynq-z2-pair bitstream onto a paired board and bring the link up.
#
# Run from a host that can reach the PYNQ Linux on the board (e.g. mapstone-dev,
# which has direct routes to the per-board /24 networks). Boards' default user
# is xilinx with password xilinx. Both .bin and .hwh must be staged at
# $ARTEFACTS_DIR (defaults to /tmp/tidelink_deploy).
#
# Usage:
#   deploy_pair.sh BOARD_IP BOARD_LABEL ROLE [ARTEFACTS_DIR]
#     ROLE = die_a | die_b   (controls strap polarity — die_a -> master)
#     ARTEFACTS_DIR optional; defaults to /tmp/tidelink_deploy
#
# Example workflow on mapstone-dev:
#   mkdir -p /tmp/tidelink_deploy
#   # ... copy tidelink.bit/.bin/.hwh into that dir ...
#   ssh mapstone-dev /opt/fpgahub/bin/fpgahub pair lease acquire bridge1 \
#         --user $(whoami) --ttl 3600
#   ./deploy_pair.sh 192.168.4.101 z2_02 die_a
#   ./deploy_pair.sh 192.168.6.101 z2_03 die_b
#
# After both boards return:
#   - LD0 (link_active) should be solid on both
#   - LD1 (role_is_master_o) on for the die_a board only
#
# If you change the role or want to retry the link, the bitstream must be
# reloaded — role_lock_reg is W1S with POR-only clear.
set -e

BOARD_IP="$1"
LABEL="$2"
ROLE="$3"
ARTEFACTS="${4:-/tmp/tidelink_deploy}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"

case "$ROLE" in
    die_a) STRAP=0 ; CTRL=0x2 ;;   # master
    die_b) STRAP=1 ; CTRL=0x3 ;;   # slave
    *) echo "ROLE must be die_a or die_b (got '$ROLE')" >&2; exit 2 ;;
esac

[[ -z "$BOARD_IP" || -z "$LABEL" ]] && {
    sed -n '4,18p' "$0" | sed 's/^# *//'; exit 2; }

SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "==== $LABEL @ $BOARD_IP — role=$ROLE strap=$STRAP ctrl=$CTRL ===="

# 1. Copy artefacts
sshpass -p "$PASS" scp $SSHCOMMON \
    "$ARTEFACTS/tidelink.bin" "$ARTEFACTS/tidelink.hwh" \
    xilinx@$BOARD_IP:/tmp/

# 2. Load bitstream via Linux fpga_manager
sshpass -p "$PASS" ssh $SSHCOMMON xilinx@$BOARD_IP \
    "echo '$PASS' | sudo -S sh -c '
        cp /tmp/tidelink.bin /lib/firmware/tidelink.bin
        cp /tmp/tidelink.hwh /lib/firmware/tidelink.hwh
        echo tidelink.bin > /sys/class/fpga_manager/fpga0/firmware
        sleep 1
        printf \"  fpga_manager: %s\n\" \"\$(cat /sys/class/fpga_manager/fpga0/state)\"
    '"

# 3. Configure role + lock — this is what releases Wlink from reset.
#    AXI GPIO strap at 0x4404_0000 sets the strap bit; APB ROLE_CFG at
#    0x4403_2080 latches bit[1] = role_lock (W1S, POR-only clear).
sshpass -p "$PASS" ssh $SSHCOMMON xilinx@$BOARD_IP \
    "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a):
    b=a&~(P-1); return mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),(a-b)
s,so=mm(0x44040000)              # strap GPIO
struct.pack_into(\"<I\",s,so,$STRAP)
r,ro=mm(0x44032000)              # TideLink APB
struct.pack_into(\"<I\",r,ro+0x80,$CTRL)
val=struct.unpack_from(\"<I\",r,ro+0x80)[0]
print(\"  ROLE_CFG = 0x{:02x} (lock={}, cfg={})\".format(val,(val>>1)&1,val&1))
'"

echo "==== $LABEL done ===="
