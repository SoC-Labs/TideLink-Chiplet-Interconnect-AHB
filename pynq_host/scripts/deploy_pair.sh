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
#
# **HAZARD — DO NOT WRITE TO AHB_TX (0x4400_0000) FROM PS UNTIL THE LINK
# IS VERIFIED UP.**  If the Wlink TX FC node is wedged (RX deserializer
# unsynced, ribbon wiring wrong, RX clock unusable), the FC adapter never
# asserts HREADY back to the AXI-Lite-to-AHB bridge. SmartConnect then
# stalls, the PS mmap write hangs in kernel space, and SSH gets killed.
# Bench evidence (2026-04-27): an AHB_TX write on z2_02 took it offline
# and required a physical power-cycle (UART reboot did not recover).
#
# Safe-to-execute always: APB reads/writes, strap GPIO writes, role-lock
# writes, doorbell trigger (the doorbell goes through APB, which is a
# separate path). Run wlink_probe.sh first to inspect link state before
# attempting any AHB_TX traffic.
set -e

BOARD_IP="$1"
LABEL="$2"
ROLE="$3"
ARTEFACTS="${4:-/tmp/tidelink_deploy}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"

# When using a STRAIGHT-THROUGH RPi GPIO ribbon (1:1 cable, e.g. The
# Pi Hut 40-pin), the two boards need MIRRORED pin maps so that one
# board's TX pads land on the other board's RX pads. die_a runs the
# standard pynq-z2-pair bitstream (TX on RPi GPIO 0..8); die_b runs
# the pynq-z2-pair-flip bitstream (TX on RPi GPIO 9..17). With a
# custom cross-strap ribbon you'd run pynq-z2-pair on both boards;
# set FORCE_ARTEFACTS=tidelink to opt out of the per-role selection.
if [ -n "${FORCE_ARTEFACTS:-}" ]; then
    BIN="${FORCE_ARTEFACTS}.bin"
    HWH="${FORCE_ARTEFACTS}.hwh"
elif [ -f "${ARTEFACTS}/tidelink.bin" ] && [ ! -f "${ARTEFACTS}/tidelink-flip.bin" ]; then
    # Single-bitstream layout (legacy / cross-strap-cable workflow).
    BIN="tidelink.bin"; HWH="tidelink.hwh"
else
    # Two-bitstream layout (straight-through cable). die_a gets the
    # canonical pynq-z2-pair bitstream; die_b gets the flip.
    case "$ROLE" in
        die_a) BIN="tidelink.bin";       HWH="tidelink.hwh" ;;
        die_b) BIN="tidelink-flip.bin";  HWH="tidelink-flip.hwh" ;;
    esac
fi

# PHASE = swi_phase_offset (Wlink PHY ctrl reg WL+0x0000, bits[20:17]).
# SHORTCOMINGS-14b: in strap-driven init, master's POR releases first;
# slave's RX deserialiser counter ends up ~3 pad_clks ahead of master's
# TX framing. Setting phase=3 on slave realigns adj_count to 0.
# Encoded as the full 32-bit register value: phase << 17.
case "$ROLE" in
    die_a) STRAP=0 ; CTRL=0x2 ; PHASE=0x00000000 ;;   # master, phase=0
    die_b) STRAP=1 ; CTRL=0x3 ; PHASE=0x00060000 ;;   # slave,  phase=3
    *) echo "ROLE must be die_a or die_b (got '$ROLE')" >&2; exit 2 ;;
esac

# Optional override: PHASE_OVERRIDE env var (full 32-bit register value).
# Used for empirical phase sweeps during bring-up debug.
if [ -n "${PHASE_OVERRIDE:-}" ]; then
    PHASE="$PHASE_OVERRIDE"
fi

[[ -z "$BOARD_IP" || -z "$LABEL" ]] && {
    sed -n '4,18p' "$0" | sed 's/^# *//'; exit 2; }

SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "==== $LABEL @ $BOARD_IP — role=$ROLE strap=$STRAP ctrl=$CTRL bitstream=$BIN ===="

# 1. Copy artefacts (renaming on the board to the canonical name so
#    fpga_manager always loads from /lib/firmware/tidelink.bin).
sshpass -p "$PASS" scp $SSHCOMMON \
    "$ARTEFACTS/$BIN" \
    "xilinx@$BOARD_IP:/tmp/tidelink.bin"
sshpass -p "$PASS" scp $SSHCOMMON \
    "$ARTEFACTS/$HWH" \
    "xilinx@$BOARD_IP:/tmp/tidelink.hwh"

# 2. Load bitstream via Linux fpga_manager
sshpass -p "$PASS" ssh $SSHCOMMON xilinx@$BOARD_IP \
    "echo '$PASS' | sudo -S sh -c '
        cp /tmp/tidelink.bin /lib/firmware/tidelink.bin
        cp /tmp/tidelink.hwh /lib/firmware/tidelink.hwh
        echo tidelink.bin > /sys/class/fpga_manager/fpga0/firmware
        sleep 1
        printf \"  fpga_manager: %s\n\" \"\$(cat /sys/class/fpga_manager/fpga0/state)\"
    '"

# 3. Configure role + lock + address translator. PAIR_BASE_ADDR is the
#    base address the local FC uses when sending doorbell / credit
#    frames to the peer (frame target = pair_base_addr + reg_offset).
#    Both boards have TideLink APB at the SAME local address 0x44032000,
#    so each peer's PAIR_BASE_ADDR points to that same value.
#    Without this step, frames are addressed to peer-DDR (0x00000000+offset)
#    and the peer's DOORBELL_RESP_ACC / RELEASED_ACC registers never tick.
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
# In slave mode, axi_chiplet_controller gates external APB writes to
# Wlink (wl_apb_pwrite forced 0). Asserting apb_debug_unlock_i via
# axi_gpio_debug_unlock at 0x44041000 lets the local PYNQ APB through
# so SW can write swi_phase_offset on slave. Master is unaffected
# (master path is always open).
d,do=mm(0x44041000)              # debug_unlock GPIO
struct.pack_into(\"<I\",d,do,1)
r,ro=mm(0x44032000)              # TideLink APB (chiplet-controller @+0x80)
w,wo=mm(0x44030000)              # Wlink APB (PHY ctrl @+0x00)
struct.pack_into(\"<I\",r,ro+0x00,0x44032000)   # PAIR_BASE_ADDR
# SHORTCOMINGS-14b: write swi_phase_offset BEFORE role_lock asserts.
# Two reset domains:
#   - swi_phase_offset reg has reset = apb_reset (~hresetn) — always low
#     during normal operation, so APB writes ALWAYS land regardless of
#     role_lock state.
#   - WavD2DGpioRx.count reg has reset = io_por_reset (= wlink_por =
#     ~poresetn | ~role_locked). Resets to 4hF while role_lock=0;
#     starts incrementing the moment role_lock=1.
# So the only chance to influence the deserialiser counter alignment
# is to have the right swi_phase_offset value LOADED before role_lock
# asserts, so adj_count = count + phase is correct from cycle 0.
# Setting phase AFTER role_lock only shifts the bit-select but does
# not re-sync the counter (which has already locked at the wrong phase).
struct.pack_into(\"<I\",w,wo+0x00,$PHASE)        # PHY ctrl swi_phase_offset
struct.pack_into(\"<I\",r,ro+0x80,$CTRL)        # ROLE_CFG (incl. role_lock)
# 2026-05-09 fix: drain stuck TideLink FC TX FIFO via swreset+lltx toggle.
# After role_lock, the LL_TX state machine is sometimes wedged with the
# initial cr_pkt queued but not draining. Pulsing swreset and re-enabling
# the lltx paths bootstraps the link layer. WL+0x208 layout:
#   bit[0] swi_enable, bit[1] lltx_enable, bit[2] lltx_enable_1, bit[3] swreset
import time as _t
struct.pack_into(\"<I\",w,wo+0x208,0x00027f08)  # swreset on, enables off
_t.sleep(0.005)
struct.pack_into(\"<I\",w,wo+0x208,0x00027f00)  # release swreset
_t.sleep(0.005)
struct.pack_into(\"<I\",w,wo+0x208,0x00027f07)  # re-enable swi+lltx+lltx_1
phy=struct.unpack_from(\"<I\",w,wo+0x00)[0]
pba=struct.unpack_from(\"<I\",r,ro+0x00)[0]
val=struct.unpack_from(\"<I\",r,ro+0x80)[0]
print(\"  PHY_CTRL       = 0x{:08x} (swi_phase_offset={})\".format(phy,(phy>>17)&0xF))
print(\"  PAIR_BASE_ADDR = 0x{:08x}\".format(pba))
print(\"  ROLE_CFG       = 0x{:02x} (lock={}, cfg={})\".format(val,(val>>1)&1,val&1))
'"

echo "==== $LABEL done ===="
