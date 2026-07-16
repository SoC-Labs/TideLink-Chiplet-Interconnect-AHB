#!/bin/bash
# =============================================================================
# reg_safety_probe.sh — isolate WHICH register access bus-errors, one at a time.
#
# WHY. `lane_health_preflight.sh` Phase 2 SIGBUSes on both dies and yields
# `"lanes": {}`. Its sweep touches THREE FSM-owned registers per tap:
#   settap():  write 0x118 (coarse nibble, KNOWN SAFE) + write 0x1B4 (SWI_PHASE_LSB)
#   measure(): write 0x1B0 (SYNC_DIST_SEL) + read 0x1AC (SYNC_DIST_OBS)
# The project rule is "NEVER WRITE 0x21B0/0x21B4 — the winscan FSM owns them", and
# "0x21AC read BUS-ERRORS on this build". But we have never ISOLATED which of the
# three faults, so we cannot fix the sweep with confidence. This probe reads/writes
# each candidate register INDIVIDUALLY, catching SIGBUS per access, and reports a
# per-register SAFE/FAULT verdict. It is the "verify the instrument" step.
#
# It also probes the calibrator-eye path (0x2150 read / 0x2154 select, a DIFFERENT
# APB region) as a candidate replacement distance source.
#
# Read-mostly and reversible: writes only lane-select/tap values it restores.
# Run with autonomy DISARMED (fresh deploy, no arm) so the winscan FSM is in
# WS_IDLE and does NOT own the taps — if a register STILL faults disarmed, the
# fault is structural (decode/build), not FSM contention.
#
# USAGE: TD_DEPLOY_DIR=/tmp/... ./reg_safety_probe.sh [a|b]   (default: both)
# =============================================================================
set -u
# =============================================================================
# ⚠ SUPERSEDED 2026-07-10: DO NOT RUN AGAINST 0x1AC/0x1B0/0x1B4.
# Those reads/writes HARD-STALL the CPU thread (uninterruptible hung AXI access,
# external-SIGKILL-only) — they do NOT bus-error, so this script's SIGBUS handler
# does NOT protect you and it will hang the board until killed. The distance-obs
# path is unusable from the PS. Use the calibrator eye (0x150/0x154) after the
# calibrator locks. This file is kept only for the safe control reads (0x1B8/0x15C).
# =============================================================================
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/td_v2_hwlib.sh"
DIES="${1:-a b}"

# One SIGBUS-catching Python probe per die. mmap the 0x44032000 page, then try
# each access inside its own try/except so one fault does not abort the rest.
probe_py() {
cat <<'PYEOF'
import mmap,os,ctypes,signal,sys
P=4096; fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC)
bb=0x44032000 & ~(P-1); o=0x44032000-bb
m=mmap.mmap(fd,((0x400+o+P-1)//P)*P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=bb)
def u32(off): return ctypes.c_uint32.from_buffer(m,o+off)
# SIGBUS -> exception, so each access is individually survivable.
class BusErr(Exception): pass
def _h(s,f): raise BusErr()
signal.signal(signal.SIGBUS,_h)
def rd(off):
    try: return ("OK", u32(off).value)
    except BusErr: return ("FAULT", None)
    except Exception as e: return ("ERR", str(e))
def wr(off,v):
    try: u32(off).value=v & 0xffffffff; return ("OK",None)
    except BusErr: return ("FAULT", None)
    except Exception as e: return ("ERR", str(e))
def line(name,off,res):
    st=res[0]; val=("=0x%08x"%res[1]) if res[1] is not None else ""
    print("  %-22s @0x%03x  %-6s%s"%(name,off,st,val),flush=True)
# --- reads (RO, no state change) ---
line("SYNC_DIST_OBS(0x1AC)",0x1AC, rd(0x1AC))          # the suspect read
line("WINSCAN_OBS(0x1B8)",  0x1B8, rd(0x1B8))          # known-good control (marker 0x57)
line("SYNCSEEN(0x15C)",     0x15C, rd(0x15C))          # known-good control (marker 0x5F)
line("CAL_EYE(0x150)",      0x150, rd(0x150))          # candidate replacement source
# --- writes (restore after) ---
sel0 = rd(0x1B0)                                        # SYNC_DIST_SEL current
line("DIST_SEL wr(0x1B0)",  0x1B0, wr(0x1B0, 2))        # select lane 2
line("SYNC_DIST_OBS after sel", 0x1AC, rd(0x1AC))       # does the read work AFTER a select?
if sel0[0]=="OK": wr(0x1B0, sel0[1])                    # restore
lsb0 = rd(0x1B4)
line("PHASE_LSB wr(0x1B4)", 0x1B4, wr(0x1B4, (lsb0[1] or 0)))  # write-back same value (no-op change)
eye0 = rd(0x154)
line("EYE_SEL wr(0x154)",   0x154, wr(0x154, 2))        # calibrator eye: select lane 2
line("CAL_EYE after sel",   0x150, rd(0x150))
if eye0[0]=="OK": wr(0x154, eye0[1])
line("PHASE_NIB wr(0x118)", 0x118, wr(0x118, rd(0x118)[1] or 0))  # known-safe control write
PYEOF
}

for d in $DIES; do
  ip=$(die_ip "$d" 2>/dev/null || { [ "$d" = a ] && echo "$A_IP" || echo "$B_IP"; })
  echo "== die_$d ($ip) register-safety probe (autonomy should be DISARMED) =="
  b64=$(probe_py | base64 -w0)
  $SSH "$BOARD_USER@$ip" "echo $b64 | base64 -d > /tmp/td_regprobe.py && echo ${TD_BOARD_PW:-xilinx}|sudo -S -p '' python3 -u /tmp/td_regprobe.py" 2>&1 | sed 's/^/  /'
  echo ""
done
echo "VERDICT KEY:"
echo "  If 0x1AC FAULTs but 0x150/0x15C/0x1B8 are OK -> the SYNC-dist obs path is the"
echo "     broken one; switch the eye sweep to the calibrator-eye source (0x150/0x154)."
echo "  If 0x1B0/0x1B4 writes FAULT even DISARMED -> structural (decode/build), not FSM"
echo "     contention; the sweep must not touch them at all."
echo "  If everything is OK disarmed -> the preflight fault was FSM contention (it ran"
echo "     while armed); gate the sweep behind an explicit disarm."
