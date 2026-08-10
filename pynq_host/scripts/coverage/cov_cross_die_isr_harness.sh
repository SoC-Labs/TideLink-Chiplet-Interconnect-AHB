#!/usr/bin/env bash
# =============================================================================
# cov_cross_die_isr_harness.sh — HOST harness SCAFFOLD (STAGED) for the first
#   cross-die ISR-DELIVERY proof: SWD/backdoor-load cov_die_b_mbox_isr_stub on
#   die_b, release its boot-gate, fire die_a's mailbox doorbell, then read the
#   ISR flag back over the eth_ss_0 backdoor to confirm the FAR-die ISR ran.
#
#   Source-latch (firmware-free) is already covered by cov_mbox_irq_source.py.
#   THIS proves DELIVERY (source -> NVIC -> ISR executes). It needs firmware +
#   two things that are NOT in the current bitstream — see the PREREQ gate below
#   and cov_cross_die_isr_plan.md. The harness therefore REFUSES to pretend it
#   ran end-to-end: the load/boot-gate steps are stubbed and it exits BLOCKED
#   unless COV_ISR_FORCE=1 (for dry-run wiring checks).
#
# WEDGE-SAFETY (mandatory): every board access is `timeout`-wrapped (a timeout ==
#   a PS-bus WEDGE); the fire is die_a peer WRITES only; the verdict is a die_b
#   LOCAL /dev/mem read of the flag (no peer read). Refuses unless FCSM=4 both.
#   JTAG-POR is STAGED (printed, never auto). Never touches 0x8403/0xA400/0x8000.
#
# Env: DIE_A (default ubuntu@10.22.24.159), DIE_B (default ubuntu@10.22.24.153),
#      KR260_PASSWORD (required, never hardcoded), COV_ISR_FORCE=1 to bypass the
#      staged-prereq gate for a dry run.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -eu

DIE_A=${DIE_A:-ubuntu@10.22.24.159}      # kr260_01, initiator
DIE_B=${DIE_B:-ubuntu@10.22.24.153}      # kr260_02, target (runs the ISR)
KR260_PASSWORD=${KR260_PASSWORD:-}
DEST=${KR260_DEST:-td}
HERE="$(cd "$(dirname "$0")" && pwd)"

# per-access timeouts (seconds). A hit == WEDGE.
T_GATE=20; T_POKE=20; T_FIRE=45; T_VERIFY=60; T_LOAD=120

# ISR flag in shared_sram_0 (PS-local read at 0x4_2D00_1F00); see the .c stub.
FLAG_WINDOW=0x400000000
FLAG_OFF=0x2D001F00      # ISR_RUN_COUNT ; +4 last payload ; +8 alive-signature

if [ -z "$KR260_PASSWORD" ]; then
    echo "ERROR: export KR260_PASSWORD (never hardcoded)." >&2; exit 2
fi
command -v sshpass >/dev/null || { echo "ERROR: sshpass not found." >&2; exit 2; }
command -v timeout >/dev/null || { echo "ERROR: coreutils 'timeout' not found." >&2; exit 2; }

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=15"

# ssh_t <timeout> <host> <remote-cmd> : timeout-wrapped root ssh. rc 124 == WEDGE.
ssh_t() {
    local to="$1" host="$2" cmd="$3"
    timeout "$to" sshpass -p "$KR260_PASSWORD" ssh $SSH_OPTS "$host" \
        "cd $DEST && echo '$KR260_PASSWORD' | sudo -S bash -c \"$cmd\""
}

wedge_stage() {   # $1 host $2 stage
    local tgt="kr260_?"; case "$1" in *159) tgt=kr260_01;; *153) tgt=kr260_02;; esac
    echo "  !! WEDGE during '$2' on $1 — JTAG-POR STAGED (run ON mapstone-dev):"
    echo "       OUT=<out> bash $HERE/../weekend/por_recover.sh $tgt"
    echo "     then re-bring-up (bringup_pair_release.sh). Never 'reboot' a wedged PS."
}

echo "======================================================================"
echo " cov_cross_die_isr_harness — cross-die ISR DELIVERY proof (STAGED)"
echo "   die_a(fire)=$DIE_A   die_b(ISR)=$DIE_B"
echo "======================================================================"

# --- 0. FCSM=4 gate (RO, wedge-safe) ----------------------------------------
echo "-- [0] FCSM=4 gate (both dies) --"
for H in "$DIE_A" "$DIE_B"; do
    if ! out=$(ssh_t "$T_GATE" "$H" "python3 scripts/kr260_eth_xfer.py --mode link" 2>&1); then
        rc=$?; [ "$rc" = 124 ] && wedge_stage "$H" "link-gate"
        echo "ABORT: link check failed on $H (rc=$rc):"; echo "$out"; exit 2
    fi
    echo "$out" | grep -q "fcsm=4" || { echo "ABORT: $H not FCSM=4:"; echo "$out"; exit 2; }
    echo "   $H: FCSM=4"
done

# --- PREREQ GATE (the reason this is STAGED) --------------------------------
# These are documented in cov_cross_die_isr_plan.md and are NOT in the shipped
# bitstream. The harness refuses to fake them. COV_ISR_FORCE=1 to dry-run wiring.
echo "-- PREREQ check (staged features) --"
echo "   [ ] SWD firmware-load path to die_b CPU1 (no probe/loader in the image)"
echo "   [ ] die_b CPU1 boot-gate RELEASE (both M0 cores boot-gated in the PS flow)"
echo "   [ ] mailbox slot0 -> CPU1 NVIC IRQ0 mapping confirmed on silicon"
if [ "${COV_ISR_FORCE:-0}" != 1 ]; then
    echo "BLOCKED: prerequisites above are not in this bitstream. This harness is the"
    echo "  target design for when they land. Re-run with COV_ISR_FORCE=1 only to"
    echo "  dry-run the arm/fire/readback wiring (the ISR will NOT actually execute,"
    echo "  so RUN_COUNT will stay 0 — that is expected in a dry run)."
    exit 3
fi
echo "  COV_ISR_FORCE=1 -> dry-run: exercising arm/fire/readback (ISR won't run)."

# --- 1. build + load firmware (STUBBED — no path in the current image) -------
echo "-- [1] build + SWD-load cov_die_b_mbox_isr_stub.c onto die_b CPU1 (STUB) --"
echo "   would: arm-none-eabi-gcc -mcpu=cortex-m0plus ... cov_die_b_mbox_isr_stub.c"
echo "          -> load to die_b IMEM via OpenOCD (see docs/CROSS_DIE_DEBUG_PLAN.md"
echo "             for the DAP path) OR backdoor-write IMEM over the eth_ss_0 window."
echo "   would: release die_b CPU1 boot-gate (reset_ctrl), start the core."
# ssh_t "$T_LOAD" "$DIE_B" "openocd -f nanosoc_multicore.cfg -c 'program cov_isr.elf; reset run'"

# --- 2. arm die_b mailbox (LOCAL, wedge-safe) -------------------------------
echo "-- [2] arm die_b mailbox (clean rising edge) --"
if ! out=$(ssh_t "$T_POKE" "$DIE_B" "python3 cov_mbox_doorbell_irq.py --mode arm" 2>&1); then
    rc=$?; [ "$rc" = 124 ] && wedge_stage "$DIE_B" "arm"; echo "$out"; exit 2
fi; echo "$out" | sed 's/^/   /'

# --- 3. fire die_a doorbell (peer WRITES only) ------------------------------
echo "-- [3] die_a fire mailbox doorbell --"
if ! out=$(ssh_t "$T_FIRE" "$DIE_A" "python3 cov_mbox_doorbell_irq.py --mode send" 2>&1); then
    rc=$?; [ "$rc" = 124 ] && wedge_stage "$DIE_A" "fire"; echo "$out"; exit 2
fi; echo "$out" | sed 's/^/   /'
sleep 1   # let the far-die ISR (if firmware is loaded) run

# --- 4. read the ISR flag back over the backdoor (die_b LOCAL read) ---------
echo "-- [4] read ISR flag @ 0x4_2D00_1F00 on die_b (LOCAL read == wedge-safe) --"
READ_PY="import mmap,struct
p=$FLAG_WINDOW+$FLAG_OFF; pg=p&~0xFFF; o=p-pg
f=open('/dev/mem','rb',buffering=0); m=mmap.mmap(f.fileno(),0x1000,mmap.MAP_SHARED,mmap.PROT_READ,offset=pg)
rc,pl,sig=struct.unpack('<I',m[o:o+4])[0],struct.unpack('<I',m[o+4:o+8])[0],struct.unpack('<I',m[o+8:o+12])[0]
print('ISR_RUN_COUNT=%d LAST_PAYLOAD=0x%08X ALIVE_SIG=0x%08X'%(rc,pl,sig))"
if ! out=$(ssh_t "$T_VERIFY" "$DIE_B" "python3 -c \\\"$READ_PY\\\"" 2>&1); then
    rc=$?; [ "$rc" = 124 ] && wedge_stage "$DIE_B" "flag-read"; echo "$out"; exit 2
fi
echo "   $out"

# --- 5. verdict -------------------------------------------------------------
runcount=$(echo "$out" | sed -n 's/.*ISR_RUN_COUNT=\([0-9]*\).*/\1/p')
echo "======================================================================"
if [ "${runcount:-0}" -ge 1 ] 2>/dev/null; then
    echo " PASS — far-die ISR EXECUTED (RUN_COUNT=$runcount). First cross-die ISR"
    echo "        delivery proven on silicon."
    exit 0
fi
echo " RESULT: RUN_COUNT=${runcount:-?} — ISR did not run. Expected in a dry run"
echo "   (no firmware loaded). Once the prerequisites land, a nonzero count here is"
echo "   the delivery proof. If ALIVE_SIG!=0xD00DFEED the core never booted the app."
echo "======================================================================"
exit 1
