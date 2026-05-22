#!/bin/bash
# =============================================================================
# _ptp_common.sh — shared helpers for the bringup_ptp_*.sh family.
#
# Sources from a sibling bringup_ptp_*.sh via `. "$(dirname "$0")/_ptp_common.sh"`.
# Provides remote /dev/mem accessors for the PHC APB region (0x4405_0000) and
# the TideLink unified APB region (0x4403_0000), and a tiny pulse helper for
# the shared PMOD-B trigger GPIO (0x4404_2000).
#
# SAFETY: NEVER touches AHB_TX (0x4400_0000) — that is the wedge hazard. All
# scripts using this helper must verify the link is up (lane_locked == 0xFF
# both sides + cal_done) before doing anything else.
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================

PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

# Region bases — keep in sync with fpga/targets/pynq-z2-pair*/tidelink_design.tcl
PHC_BASE_DEFAULT=0x44050000
APB_BASE_DEFAULT=0x44030000
PMOD_TRIG_BASE_DEFAULT=0x44042000
SWI_LANE_STATUS_OFF=0x108     # within APB_BASE+0x2000 region 8 slot 2

# Reg offsets within PHC (PHC_BASE + offset)
PHC_OFF_CTRL=0x000
PHC_OFF_STATUS=0x004
PHC_OFF_NS_INCR=0x008
PHC_OFF_NS_INCR_FRAC=0x00C
PHC_OFF_SET_SECONDS_LO=0x010
PHC_OFF_SET_SECONDS_HI=0x014
PHC_OFF_SET_NANOSECONDS=0x018
PHC_OFF_CAP_SECONDS_LO=0x020
PHC_OFF_CAP_SECONDS_HI=0x024
PHC_OFF_CAP_NANOSECONDS=0x028
PHC_OFF_CAP_NS_FRAC=0x02C
PHC_OFF_HW_CAP_SECONDS_LO=0x040
PHC_OFF_HW_CAP_SECONDS_HI=0x044
PHC_OFF_HW_CAP_NANOSECONDS=0x048
PHC_OFF_HW_CAP_NS_FRAC=0x04C
PHC_OFF_SERVO_CTRL=0x0A0
PHC_OFF_SERVO_STATUS=0x0A8

# CTRL bits
PHC_CTRL_EN=1
PHC_CTRL_SET_TIME=2
PHC_CTRL_CAPTURE=4

# TideLink APB offsets (absolute = APB_BASE + offset)
APB_OFF_PTP_CTRL=0x2034
APB_OFF_HW_SYNC_CTRL=0x2040
APB_OFF_HW_SYNC_INTERVAL=0x2044
APB_OFF_HW_SYNC_STATUS=0x2048
APB_OFF_SERVO_CTRL=0x204C
APB_OFF_SERVO_KP=0x2050
APB_OFF_SERVO_KI=0x2054
APB_OFF_SERVO_STEP_THRESH=0x2058
APB_OFF_SERVO_STATUS=0x205C
APB_OFF_SERVO_DELAY=0x2060
APB_OFF_SERVO_NS_FRAC=0x2064

# Defaults — overridable per script
PHC_BASE="${PHC_BASE:-$PHC_BASE_DEFAULT}"
APB_BASE="${APB_BASE:-$APB_BASE_DEFAULT}"
PMOD_TRIG_BASE="${PMOD_TRIG_BASE:-$PMOD_TRIG_BASE_DEFAULT}"
NS_INCR_FOR_50MHZ=20

# -----------------------------------------------------------------------------
# Generic remote /dev/mem write/read. Reads return decimal on stdout; writes
# return empty. Returns non-zero only on SSH failure.
# -----------------------------------------------------------------------------
remote_w() {  # IP ABS_ADDR VAL
    local IP=$1 ADDR=$2 VAL=$3
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
        "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
a=$ADDR; b=a&~(P-1); o=a-b
m=mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b)
struct.pack_into(\"<I\",m,o,$VAL)'" 2>/dev/null
}

remote_r() {  # IP ABS_ADDR -> echoes decimal value
    local IP=$1 ADDR=$2
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
        "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
a=$ADDR; b=a&~(P-1); o=a-b
m=mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b)
print(struct.unpack_from(\"<I\",m,o)[0])'" 2>/dev/null
}

# -----------------------------------------------------------------------------
# PHC convenience wrappers (offset within PHC_BASE)
# -----------------------------------------------------------------------------
phc_w() {  # IP OFF VAL
    remote_w "$1" "$(( PHC_BASE + $2 ))" "$3"
}
phc_r() {  # IP OFF -> decimal
    remote_r "$1" "$(( PHC_BASE + $2 ))"
}

# Atomic capture-and-read of full HW_CAP timestamp.
# Returns: "SECS NSEC FRAC" (decimal). Uses CTRL.CAPTURE pulse (software path),
# NOT HW_CAP — for the HW_CAP path use phc_hw_cap_read.
phc_sw_capture() {  # IP -> "SECS NSEC FRAC"
    local IP=$1
    phc_w "$IP" $PHC_OFF_CTRL $(( PHC_CTRL_EN | PHC_CTRL_CAPTURE )) >/dev/null
    local lo hi ns fr
    lo=$(phc_r "$IP" $PHC_OFF_CAP_SECONDS_LO)
    hi=$(phc_r "$IP" $PHC_OFF_CAP_SECONDS_HI)
    ns=$(phc_r "$IP" $PHC_OFF_CAP_NANOSECONDS)
    fr=$(phc_r "$IP" $PHC_OFF_CAP_NS_FRAC)
    echo "$(( (hi << 32) | lo )) $ns $fr"
}

# Read the HW_CAP region (latched by phc_hw_capture | pmod_b_trig_i edge).
phc_hw_cap_read() {  # IP -> "SECS NSEC FRAC"
    local IP=$1
    local lo hi ns fr
    lo=$(phc_r "$IP" $PHC_OFF_HW_CAP_SECONDS_LO)
    hi=$(phc_r "$IP" $PHC_OFF_HW_CAP_SECONDS_HI)
    ns=$(phc_r "$IP" $PHC_OFF_HW_CAP_NANOSECONDS)
    fr=$(phc_r "$IP" $PHC_OFF_HW_CAP_NS_FRAC)
    echo "$(( (hi << 32) | lo )) $ns $fr"
}

# -----------------------------------------------------------------------------
# TideLink APB convenience wrappers (offset within APB_BASE)
# -----------------------------------------------------------------------------
apb_w() {  # IP OFF VAL
    remote_w "$1" "$(( APB_BASE + $2 ))" "$3"
}
apb_r() {  # IP OFF -> decimal
    remote_r "$1" "$(( APB_BASE + $2 ))"
}

# -----------------------------------------------------------------------------
# PMOD-B cross-board trigger pulse. The driving board writes a 1-then-0
# pattern to its axi_gpio_pmod_trig output channel (offset 0x000 in the
# GPIO IP). Both boards see the rising edge via their hw_capture_0_i mux
# (PHC) plus the sense channel (offset 0x008).
# -----------------------------------------------------------------------------
pmod_pulse() {  # IP
    local IP=$1
    remote_w "$IP" "$(( PMOD_TRIG_BASE + 0x0 ))" 1
    remote_w "$IP" "$(( PMOD_TRIG_BASE + 0x0 ))" 0
}

# -----------------------------------------------------------------------------
# Link health pre-flight. Reads SWI_LANE_STATUS (APB region 8 slot 2);
# returns 0 if both boards report lane_locked==0xFF AND cal_done==1.
# Required before running any PTP test (link-up-first per plan §5).
# -----------------------------------------------------------------------------
check_link_up() {  # M_IP S_IP
    local M=$1 S=$2 s m sl mc sc
    m=$(remote_r "$M" "$(( APB_BASE + 0x2000 + SWI_LANE_STATUS_OFF ))")
    s=$(remote_r "$S" "$(( APB_BASE + 0x2000 + SWI_LANE_STATUS_OFF ))")
    [ -z "$m" ] || [ -z "$s" ] && return 1
    local m_lk=$(( m & 0xff ))
    local s_lk=$(( s & 0xff ))
    local m_cd=$(( (m >> 16) & 1 ))
    local s_cd=$(( (s >> 16) & 1 ))
    echo "  link: master lk=0x$(printf '%02x' "$m_lk") cd=$m_cd  slave lk=0x$(printf '%02x' "$s_lk") cd=$s_cd"
    [ "$m_lk" -eq 255 ] && [ "$s_lk" -eq 255 ] && [ "$m_cd" -eq 1 ] && [ "$s_cd" -eq 1 ]
}

# -----------------------------------------------------------------------------
# Disable autonomous servo + PTP — quiesce all autonomous actors before
# injecting a perturbation. Per plan §4.3.
# -----------------------------------------------------------------------------
quiesce_servo() {  # IP
    apb_w "$1" $APB_OFF_HW_SYNC_CTRL 0 >/dev/null
    apb_w "$1" $APB_OFF_SERVO_CTRL   0 >/dev/null
}

# -----------------------------------------------------------------------------
# PHC initial programming for the 50 MHz FPGA rig. Clears NS_INCR_FRAC,
# programmes NS_INCR=20, sets time to (sec_lo, 0, 0), pulses SET_TIME,
# then enables the counter. R2 of the plan — operator MUST do this.
# -----------------------------------------------------------------------------
phc_init_50mhz() {  # IP SEC_LO
    local IP=$1 SEC=$2
    phc_w "$IP" $PHC_OFF_CTRL              0                          >/dev/null
    phc_w "$IP" $PHC_OFF_NS_INCR           $NS_INCR_FOR_50MHZ         >/dev/null
    phc_w "$IP" $PHC_OFF_NS_INCR_FRAC      0                          >/dev/null
    phc_w "$IP" $PHC_OFF_SET_SECONDS_LO    "$SEC"                     >/dev/null
    phc_w "$IP" $PHC_OFF_SET_SECONDS_HI    0                          >/dev/null
    phc_w "$IP" $PHC_OFF_SET_NANOSECONDS   0                          >/dev/null
    phc_w "$IP" $PHC_OFF_CTRL              $PHC_CTRL_SET_TIME         >/dev/null
    phc_w "$IP" $PHC_OFF_CTRL              $PHC_CTRL_EN               >/dev/null
}

# -----------------------------------------------------------------------------
# Compute signed offset (slave - master) in ns, accounting for second
# rollover. Inputs are "SECS NSEC FRAC" tuples; FRAC is ignored for offset
# calc but the sub-ns is appended in scientific form to the log.
# -----------------------------------------------------------------------------
offset_ns() {  # M_CAP S_CAP -> signed ns
    local m_sec m_ns s_sec s_ns
    m_sec=$(echo "$1" | awk '{print $1}'); m_ns=$(echo "$1" | awk '{print $2}')
    s_sec=$(echo "$2" | awk '{print $1}'); s_ns=$(echo "$2" | awk '{print $2}')
    awk -v ms="$m_sec" -v mn="$m_ns" -v ss="$s_sec" -v sn="$s_ns" \
        'BEGIN { printf("%d", (ss-ms)*1000000000 + (sn-mn)) }'
}
