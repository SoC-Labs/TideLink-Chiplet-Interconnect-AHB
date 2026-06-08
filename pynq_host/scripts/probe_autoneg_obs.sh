#!/usr/bin/env bash
# probe_autoneg_obs.sh — read TideLink autoneg Region C observability registers
# Bug N7 silicon diagnosis (build v9+, commit 4a5f875 onward)
# 2026-06-02: train_status decode fix + OBS_MASK_HS (slot 0x194) + Wlink probes
#
# Usage:  ./probe_autoneg_obs.sh <BOARD_IP> [LABEL]
#   e.g.  ./probe_autoneg_obs.sh 192.168.4.101 z2_02_master
#         ./probe_autoneg_obs.sh 192.168.6.101 z2_03_slave
#
# Reads:
#   Region 4:  ROLE_CFG, NEGO_CFG, NEGO_STATUS, NEGO_PRIORITY, NEGO_TIMEOUT
#   Region 8:  NEGO_TRAIN_CFG, NEGO_TRAIN_STATUS  (training arm + done flags)
#   Region C:  OBS_DELAY_CTR, OBS_TIMEOUT_CTR, OBS_FSM_SUBSTATE,
#              OBS_I2C_MST_STATUS, OBS_ID, OBS_MASK_HS  (autoneg internals
#              + mask-handshake internals: peer masks, match/fail flags,
#              nego_lock_pending, combined gate, Wlink hs_result)
#   Wlink AHB aperture @ 0x44030000: LANE_MASK @ 0x214, HS_RESULT @ 0x21C
#
# Region C decode:
#   0x44032180  OBS_DELAY_CTR       [31:0]  autoneg.delay_ctr_r
#   0x44032184  OBS_TIMEOUT_CTR     [31:0]  autoneg.timeout_ctr_r
#   0x44032188  OBS_FSM_SUBSTATE    [17:13] init_wait_r [12:10] axl_state_r
#                                   [9:7]   txn_step_r
#   0x4403218C  OBS_I2C_MST_STATUS  [3]=miss_ack [2]=bus_active
#                                   [1]=cont [0]=busy
#   0x44032190  OBS_OBS_ID          = 0x4F420100 ("OB" v1.0)
#               If read != 0x4F420100, Region C decode is BROKEN.
#   0x44032194  OBS_MASK_HS         [ 7:0] autoneg.peer_tx_lane_mask_r
#                                   [15:8] autoneg.peer_rx_lane_mask_r
#                                   [16]   autoneg.mask_hs_local_match_r
#                                   [17]   autoneg.mask_hs_local_fail_r
#                                   [18]   controller.nego_lock_pending_reg
#                                   [19]   controller.mask_hs_match (wlink|autoneg)
#                                   [20]   controller.mask_hs_gate_open
#                                   [22:21] controller.wlink_mask_hs_result[1:0]
#
# Region 8 NEGO_TRAIN_STATUS (0x110) bit layout (per axi_chiplet_controller.sv:1019):
#   [0]=train_ok   [1]=train_fail   [2]=train_in_progress   [3]=train_peer_nack
#   [7:4]=train_state   [15:8]=train_peer_lane_locked
#   [23:16]=train_peer_lane_fault  [31:24]=train_local_lane_fault
# (Old script decoded bit[0]=train_armed, bit[1]=train_ok — WRONG.)
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <BOARD_IP> [LABEL]" >&2
  exit 2
fi

BOARD_IP="$1"
LABEL="${2:-$BOARD_IP}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "==== Probe autoneg observability — $LABEL ($BOARD_IP) ===="

sshpass -p "$PASS" ssh $SSHCOMMON xilinx@$BOARD_IP \
  "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a):
    b=a&~(P-1); return mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),(a-b)
r,ro = mm(0x44032000)
w,wo = mm(0x44030000)  # Wlink AHB aperture
def rd(off):
    return struct.unpack_from(\"<I\",r,ro+off)[0]
def rdw(off):
    return struct.unpack_from(\"<I\",w,wo+off)[0]

# Region 4 (slot offsets 0x80..0x9C)
role_cfg   = rd(0x80)
i2c_dbg    = rd(0x84)
i2c_addr   = rd(0x88)
prescale   = rd(0x8C)
nego_cfg   = rd(0x90)
nego_sts   = rd(0x94)
nego_pri   = rd(0x98)
nego_to    = rd(0x9C)

# Region 8 (training cfg + status + lane-status snapshot)
train_cfg  = rd(0x10C)
train_sts  = rd(0x110)
# Bug N14b post-mortem (2026-06-05): SWI_LANE_STATUS @ 0x108 carries the
# REAL local cal_done + lane_locked + lane_fault. The "master cal_done=0"
# Bug N14b investigation was built on probe-script blindness — without
# this register, master loser-side nego_train_status=0 reads as "wedge"
# when its actually normal loser FSM behaviour. Always read 0x108.
swi_lane_sts  = rd(0x108)

# Region C (Bug N7 obs + new mask-hs slot + M7 OBS_CAL slot)
obs_delay     = rd(0x180)
obs_timeout   = rd(0x184)
obs_substate  = rd(0x188)
obs_i2c_sta   = rd(0x18C)
obs_id        = rd(0x190)
obs_mask_hs   = rd(0x194)
# M7 OBS_CAL @ 0x198 — calibrator FSM state + resweep counter
obs_cal       = rd(0x198)

# Wlink AHB aperture
wl_lane_mask  = rdw(0x214)
wl_hs_result  = rdw(0x21C)

print(\"--- Region 4 ---\")
print(\"  role_cfg          0x{:08x}  cfg={} lock={}\".format(role_cfg, role_cfg&1, (role_cfg>>1)&1))
print(\"  i2c_slv_dbg       0x{:08x}\".format(i2c_dbg))
print(\"  i2c_slv_addr      0x{:08x}\".format(i2c_addr))
print(\"  i2c_prescale      0x{:08x}\".format(prescale))
print(\"  nego_cfg          0x{:08x}  en={} force_lock={} mask_hs={}\".format(nego_cfg, nego_cfg&1, (nego_cfg>>5)&1, (nego_cfg>>6)&1))
print(\"  nego_status       0x{:08x}  state={} done={} err={} won={} lost={} sda_start={}\".format(
    nego_sts, nego_sts&0xF, (nego_sts>>4)&1, (nego_sts>>5)&1, (nego_sts>>6)&1, (nego_sts>>7)&1, (nego_sts>>8)&1))
print(\"  nego_priority     0x{:08x}\".format(nego_pri))
print(\"  nego_timeout      0x{:08x}\".format(nego_to))
print(\"--- Region 8 ---\")
print(\"  nego_train_cfg    0x{:08x}  train_auto_en={}\".format(train_cfg, train_cfg&1))
sl_locked  =  swi_lane_sts        & 0xFF
sl_fault   = (swi_lane_sts >> 8)  & 0xFF
sl_caldone = (swi_lane_sts >> 16) & 1
sl_fcsm    = (swi_lane_sts >> 17) & 0x7
sl_llrx    = (swi_lane_sts >> 21) & 0x3
print(\"  swi_lane_status   0x{:08x}\".format(swi_lane_sts))
print(\"    lane_locked=0x{:02x} lane_fault=0x{:02x} cal_done={} fcsm_state={} llrx_state={}\".format(
    sl_locked, sl_fault, sl_caldone, sl_fcsm, sl_llrx))
t_ok      =  train_sts        & 1
t_fail    = (train_sts >> 1)  & 1
t_inprog  = (train_sts >> 2)  & 1
t_pnack   = (train_sts >> 3)  & 1
t_state   = (train_sts >> 4)  & 0xF
t_plock   = (train_sts >> 8)  & 0xFF
t_pfault  = (train_sts >> 16) & 0xFF
t_lfault  = (train_sts >> 24) & 0xFF
print(\"  nego_train_status 0x{:08x}\".format(train_sts))
print(\"    train_ok={} train_fail={} in_progress={} peer_nack={} state={}\".format(
    t_ok, t_fail, t_inprog, t_pnack, t_state))
print(\"    peer_lane_locked=0x{:02x} peer_lane_fault=0x{:02x} local_lane_fault=0x{:02x}\".format(
    t_plock, t_pfault, t_lfault))
print(\"--- Region C (Bug N7 obs) ---\")
print(\"  obs_id            0x{:08x}  (expect 0x4F420100 — else Region C BROKEN)\".format(obs_id))
if obs_id != 0x4F420100:
    print(\"  *** OBS_ID MISMATCH: decode broken, ignore other Region C values ***\")
else:
    print(\"  obs_delay_ctr     0x{:08x}  ({} dec)\".format(obs_delay, obs_delay))
    print(\"  obs_timeout_ctr   0x{:08x}  ({} dec)\".format(obs_timeout, obs_timeout))
    iw  = (obs_substate>>13) & 0x1F
    axl = (obs_substate>>10) & 0x7
    txn = (obs_substate>>7)  & 0x7
    print(\"  obs_fsm_substate  0x{:08x}  init_wait={} axl_state={} txn_step={}\".format(obs_substate, iw, axl, txn))
    print(\"  obs_i2c_mst_sta   0x{:08x}  busy={} cont={} bus_active={} miss_ack={}\".format(
        obs_i2c_sta, obs_i2c_sta&1, (obs_i2c_sta>>1)&1, (obs_i2c_sta>>2)&1, (obs_i2c_sta>>3)&1))
    peer_tx  =  obs_mask_hs        & 0xFF
    peer_rx  = (obs_mask_hs >> 8)  & 0xFF
    hs_match = (obs_mask_hs >> 16) & 1
    hs_fail  = (obs_mask_hs >> 17) & 1
    lock_pend= (obs_mask_hs >> 18) & 1
    mh_match = (obs_mask_hs >> 19) & 1
    mh_open  = (obs_mask_hs >> 20) & 1
    wl_hsr   = (obs_mask_hs >> 21) & 0x3
    print(\"  obs_mask_hs       0x{:08x}\".format(obs_mask_hs))
    print(\"    peer_tx_lane_mask=0x{:02x} peer_rx_lane_mask=0x{:02x}\".format(peer_tx, peer_rx))
    print(\"    autoneg.mask_hs_local_match={} fail={}\".format(hs_match, hs_fail))
    print(\"    nego_lock_pending={} mask_hs_match={} mask_hs_gate_open={}\".format(lock_pend, mh_match, mh_open))
    print(\"    wlink_mask_hs_result=0b{:02b} (peer_says_match=bit0={} peer_says_fail=bit1={})\".format(
        wl_hsr, wl_hsr&1, (wl_hsr>>1)&1))
    # M7 OBS_CAL — calibrator FSM state + resweep counter (discriminates H1/H2/H3)
    cal_state_names = {0:\"IDLE\",1:\"ARM\",2:\"SWEEP\",3:\"FINISH\",4:\"DONE\",
                       5:\"CANCEL\",6:\"HOLD\",7:\"PROBE\",8:\"FINALIZE\",9:\"VALIDATE\"}
    cal_st     =  obs_cal        & 0xF
    cal_rsw    = (obs_cal >> 4)  & 0xFFFF
    cal_tm     = (obs_cal >> 20) & 1
    print(\"  obs_cal           0x{:08x}\".format(obs_cal))
    print(\"    cal_state={} ({})  resweep_ctr={}  training_mode={}\".format(
        cal_st, cal_state_names.get(cal_st, \"?\"), cal_rsw, cal_tm))
print(\"--- Wlink AHB (0x44030000) ---\")
print(\"  link_lane_mask    0x{:08x}  @0x44030214  (tx[7:0] rx[15:8])\".format(wl_lane_mask))
print(\"  link_hs_result    0x{:08x}  @0x4403021C  (peer-mask handshake verdict)\".format(wl_hs_result))
' " 2>&1 | grep -vE "^Password:|sudo:" || true
