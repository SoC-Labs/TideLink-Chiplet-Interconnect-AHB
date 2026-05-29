#!/bin/bash
# Autonomous I²C-coordinated lane-lock bring-up — the turnkey replacement
# for the manual sw_coord_autocal_region8.sh + phase_recal_sweep.sh flow.
#
# With Fix A (slave clock-stretch) + Fix B (real link_lane_mask_hs_result
# @ 0x21C) + the autoneg peer-mask handshake + mask_hs_bypass=0 in the BD,
# the two chiplets coordinate role-lock THEMSELVES over the inter-board
# I²C bus. The host no longer needs the old concurrent/synchronised SSH
# SWI_RECAL pulsing or a manual phase sweep — each board is configured
# independently, in any order, and the hardware handshake handles the
# overlap that used to fault every lane under a staggered bring-up.
#
# Per board it does only:
#   1. PAIR_BASE_ADDR  (TideLink APB +0x00) = 0x44032000  (FC frame target)
#   2. I2C_PRESCALE    (ctrl_reg idx3, +0x8C) — optional; RTL reset default
#      is now 128 (safe for the on-ribbon W9/V7 weak internal pull). Only
#      written if I2C_PRESCALE env is set.
#   3. NEGO_TRAIN_CFG  (Region 8 slot 3, +0x10C) = 0x0001 (train_auto_en=1)
#      Drives autoneg through ST_TRAIN_ENTER→RUN→POLL→EXIT so the link
#      actually transitions OUT of training mode. Without this, autoneg
#      locks role/mask then parks in ST_NEGO_DONE with both sides still in
#      training mode → no traffic. See tidelink_autoneg.sv:887-908.
#   4. NEGO_CFG        (ctrl_reg idx4, +0x90) = 0x61
#        bit0 nego_en | bit5 nego_force_lock | bit6 mask_hs_auto_en
#      0x41 (no force_lock) negotiates but never latches role_lock — the
#      classic gotcha; 0x61 is the proven value (cocotb e2e + Edit 4).
#   5. Poll ROLE_STATUS (idx1,+0x84) bit[1]=role_locked and NEGO_STATUS
#      (idx5,+0x94) until lock or timeout.
# It does NOT write ROLE_CFG[1] (that is the manual lock path this
# replaces) and needs NO apb_debug_unlock (ctrl_reg is the controller's
# own always-writable APB, not the Wlink passthrough mux).
#
# ── PRE-FLIGHT (build-time facts the host cannot introspect) ────────────
#   * Bitstream MUST be the on-ribbon I²C variant: pynq-z2-pair-all (die_a)
#     / pynq-z2-pair-flip-all (die_b), with BD Edits 1–4 applied
#     (i2c_sda_io=W9/i2c_scl_io=V7 IOBUF; mask_hs_bypass xlconst=0).
#   * COLLISION GUARD: that build's lane 7 must be B19/F20, NOT W9/V7 —
#     W9/V7 = J13 13/37 is also the lane-7-remap pair (superproject
#     5d34baf). If the bitstream carries the lane-7 remap, ABORT (W9/V7
#     would be double-driven). See docs/archive/proposals/i2c_train/J13_PIN_BUDGET.md.
#   * ELECTRICAL: W9/V7 have no on-board pull-up; the FPGA weak internal
#     pull holds the bus, so I²C runs slow (prescale ≥128). Scope-verify
#     SCL/SDA rise time once per bench (HW_VALIDATION_PLAN.md Stage 1).
# Because the host cannot verify these, the script refuses to run unless
# you assert them with --confirm-onribbon (or I2C_ONRIBBON_CONFIRMED=1).
#
# ── HAZARD ──────────────────────────────────────────────────────────────
# DO NOT WRITE AHB_TX (0x4400_0000) UNTIL LINK IS VERIFIED UP. A wedged
# Wlink TX FC node makes the PS mmap write hang in kernel space and kills
# SSH (physical power-cycle needed). This script only touches APB
# (ctrl_reg / PAIR_BASE_ADDR) — always-safe paths. role_locked=1 is
# necessary but NOT sufficient for traffic (SHORTCOMINGS §14b, orthogonal).
#
# Usage:
#   bringup_autocal_i2c.sh --confirm-onribbon --pair
#   bringup_autocal_i2c.sh --confirm-onribbon BOARD_IP LABEL ROLE
#     ROLE = die_a | die_b   (informational: poll/log expectations)
# Env:
#   DIE_A_IP (def 192.168.4.101)  DIE_B_IP (def 192.168.6.101)
#   TIDELINK_BOARD_PASS (def xilinx)  LOCK_TIMEOUT_S (def 30)
#   I2C_PRESCALE (unset = keep RTL default 128; set = force that value)
set -euo pipefail

CONFIRM=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --confirm-onribbon) CONFIRM=1 ;;
    --pair)             ARGS+=("--pair") ;;
    *)                  ARGS+=("$a") ;;
  esac
done
[ "${I2C_ONRIBBON_CONFIRMED:-0}" = "1" ] && CONFIRM=1

usage() {
  cat >&2 <<'USAGE'
Usage:
  bringup_autocal_i2c.sh --confirm-onribbon --pair
  bringup_autocal_i2c.sh --confirm-onribbon BOARD_IP LABEL ROLE
    ROLE = die_a | die_b   (informational: poll/log expectations)
  Env: DIE_A_IP DIE_B_IP TIDELINK_BOARD_PASS LOCK_TIMEOUT_S I2C_PRESCALE
USAGE
}

if [ "$CONFIRM" != "1" ]; then
  cat >&2 <<'PRE'
PRE-FLIGHT (build-time facts the host cannot introspect — verify, then
re-run with --confirm-onribbon):
  * Bitstream is the on-ribbon I2C variant (pynq-z2-pair-all /
    pynq-z2-pair-flip-all) with BD Edits 1-4 applied
    (i2c_sda_io=W9 / i2c_scl_io=V7 IOBUF; mask_hs_bypass xlconst=0).
  * COLLISION GUARD: that build's lane 7 is B19/F20, NOT W9/V7
    (W9/V7 = J13 13/37 is the lane-7-remap pair, superproj 5d34baf).
  * ELECTRICAL: W9/V7 have no on-board pull-up; I2C runs on the FPGA
    weak internal pull at prescale >=128 — scope-verify SCL/SDA rise
    time once per bench (HW_VALIDATION_PLAN.md Stage 1).
PRE
  echo >&2
  echo "REFUSING: re-run with --confirm-onribbon once verified." >&2
  usage
  exit 3
fi

PASS="${TIDELINK_BOARD_PASS:-xilinx}"
DIE_A_IP="${DIE_A_IP:-192.168.4.101}"
DIE_B_IP="${DIE_B_IP:-192.168.6.101}"
LOCK_TIMEOUT_S="${LOCK_TIMEOUT_S:-30}"
PRESCALE_ENV="${I2C_PRESCALE:-}"
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# ── one board: configure for autonomous lock + poll ─────────────────────
bringup_one() {
  local BOARD_IP="$1" LABEL="$2" ROLE="$3"
  echo "==== $LABEL @ $BOARD_IP — role=$ROLE : autonomous I²C lane-lock ===="
  local PY
  PY=$(cat <<PYEOF
import mmap,struct,os,sys,time
P=4096; fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC)
def mm(a):
    b=a&~(P-1); return mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),(a-b)
TL=0x44032000
r,o=mm(TL)
def rd(off): return struct.unpack_from("<I",r,o+off)[0]
def wr(off,v): struct.pack_into("<I",r,o+off,v);
CR=0x80                                  # ctrl_reg window base in TideLink APB
ROLE_CFG=CR+0x00; ROLE_STS=CR+0x04; I2C_PSC=CR+0x0C
NEGO_CFG=CR+0x10; NEGO_STS=CR+0x14
# Region 8 chiplet-extended (paddr[8:5]=1000 → byte offsets 0x100..0x11C).
# NEGO_TRAIN_CFG @ slot 3 = 0x10C — see docs/REGISTER_MAP.md §Region 8 and
# axi_chiplet_controller.sv:565 (bit[0]=auto_en, bit[1]=sw_step, bit[2]=W1P
# retrain, bits[7:4]=poll_timeout, bits[15:8]=fsm_wait_hi).
NEGO_TRAIN_CFG=0x10C
ver=rd(0x14)
if ver==0 or ver==0xFFFFFFFF:
    print("  ABORT: TIDELINK_VERSION reads 0x%08x — bitstream not loaded "
          "or wrong design" % ver); sys.exit(4)
wr(0x00,TL)                              # PAIR_BASE_ADDR
psc_env="$PRESCALE_ENV"
if psc_env:
    wr(I2C_PSC,int(psc_env,0))
psc=rd(I2C_PSC) & 0xFFFF
if psc < 64:
    print("  WARN: I2C_PRESCALE=%d is fast for the W9/V7 weak internal "
          "pull (want >=128). Set I2C_PRESCALE env if the bus NACKs." % psc)
# 2026-05-25: write NEGO_TRAIN_CFG.train_auto_en=1 so autoneg performs
# the full training entry/exit sequence (ST_TRAIN_ENTER→RUN→POLL→EXIT)
# instead of skipping to ST_NEGO_DONE. Without this, the link locks
# but never transitions out of training mode (cr_pkt_seen=0 sticky on
# slave, doorbells don't cross). See tidelink_autoneg.sv:887-908
# and docs/TIDELINK_PHASE0_OBS_20260524_2109.md §9.
# MUST be written BEFORE NEGO_CFG.nego_en, because the autoneg FSM
# samples train_auto_en at the ST_NEGO_DONE_PRE → ST_TRAIN_ENTER
# branch point (autoneg.sv:890).
wr(NEGO_TRAIN_CFG,0x0001)                # train_auto_en=1
ntcfg=rd(NEGO_TRAIN_CFG) & 0xFFFF
if (ntcfg & 0x1) != 0x1:
    print("  ABORT: NEGO_TRAIN_CFG readback=0x%04x — train_auto_en did not "
          "land (Region 8 not present? wrong bitstream?)" % ntcfg); sys.exit(8)
print("  NEGO_TRAIN_CFG=0x%04x (train_auto_en=1) armed" % ntcfg)
wr(NEGO_CFG,0x61)                        # en | force_lock | mask_hs_auto_en
ncfg=rd(NEGO_CFG) & 0x7F
print("  TIDELINK_VERSION=0x%08x  PAIR_BASE_ADDR=0x%08x  I2C_PRESCALE=%d"
      % (ver, rd(0x00), psc))
if ncfg != 0x61:
    print("  ABORT: NEGO_CFG readback=0x%02x != 0x61 (write did not land — "
          "check ctrl_reg APB mapping / wrong bitstream)" % ncfg); sys.exit(5)
print("  NEGO_CFG=0x%02x (nego_en|force_lock|mask_hs_auto_en) armed" % ncfg)
def decode():
    rs=rd(ROLE_STS); ns=rd(NEGO_STS)
    return ((rs>>1)&1, {
      "state":ns&0xF,"done":(ns>>4)&1,"error":(ns>>5)&1,"won":(ns>>6)&1,
      "lost":(ns>>7)&1,"sda":(ns>>8)&1,"mask_mismatch":(ns>>9)&1})
t0=time.time(); TO=$LOCK_TIMEOUT_S
locked,ns=decode()
while not locked and (time.time()-t0)<TO:
    if ns["error"] or ns["mask_mismatch"]:
        print("  FAULT after %.1fs: NEGO_STATUS=%s" % (time.time()-t0,ns))
        sys.exit(6)
    time.sleep(0.25); locked,ns=decode()
dt=time.time()-t0
if locked:
    print("  LOCKED in %.1fs — role_locked=1  NEGO_STATUS=%s" % (dt,ns))
    sys.exit(0)
print("  TIMEOUT after %.1fs — role_locked=0  NEGO_STATUS=%s" % (dt,ns))
print("  (state 6=ST_BYPASS -> nego_en not set / wrong NEGO_CFG; "
      "won=1&lost=0 stuck -> peer not answering I²C: check the W9/V7 "
      "ribbon conductors + scope SCL/SDA; mask_mismatch -> lane masks "
      "differ between boards)")
sys.exit(7)
PYEOF
)
  sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$BOARD_IP" \
    "echo '$PASS' | sudo -S python3 -c '$PY' 2>&1"
  echo "==== $LABEL done ===="
}

if [ "${ARGS[0]:-}" = "--pair" ]; then
  rc=0
  bringup_one "$DIE_A_IP" z2_02 die_a || rc=$?
  # Order/concurrency no longer matter — the I²C handshake coordinates the
  # overlap in hardware. Sequential is fine (the whole point of this work).
  bringup_one "$DIE_B_IP" z2_03 die_b || rc=$?
  echo "==== pair bring-up exit=$rc (0=both locked) ===="
  exit $rc
else
  [ "${#ARGS[@]}" -ge 3 ] || { usage; exit 2; }
  bringup_one "${ARGS[0]}" "${ARGS[1]}" "${ARGS[2]}"
fi
