#!/bin/bash
# Full recovery + bring-up sequence after z2_02 (master) power cycle.
#
# Run from mapstone-dev (or a host with routes to .4.x and .6.x networks).
# Assumes v32 bitstreams are already staged at /tmp/tidelink_deploy_v32/ on mapstone-dev.
#
# Usage:
#   bash recover_and_bringup.sh [--redeploy-both]
#     --redeploy-both  Also redeploy z2_03 (default: only redeploy z2_02)
#
# Sequence:
#   1. Wait for z2_02 to respond to ping
#   2. Deploy v32 to z2_02 (and optionally z2_03)
#   3. Wait for both boards to be SSH-ready
#   4. Run simultaneous Wlink swreset on both boards
#   5. Probe and print full link state
#   6. Report pass/fail
set -e

# --- ZynqMP (KR260) SAFETY GUARD (inline) ------------------------------------
# This tool mmaps RAW Pynq-Z2 control literals (0x4403_xxxx / 0x4404_xxxx /
# 0x4405_xxxx) over /dev/mem, un-relocated. On a ZynqMP (KR260) those addresses
# are UNDECODED with NO bus timeout => a hard PS hang (power-cycle to recover).
# Pynq-Z2 ONLY. Refuse the moment we start if TIDELINK_SOC names anything else.
# Safe on a KR260: tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.
_tl_guard_soc=$(printf '%s' "${TIDELINK_SOC:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
case "$_tl_guard_soc" in
  ""|z2|pynq-z2|pynq_z2|zynq7|zynq) : ;;
  *)
    printf '\n[%s] REFUSING TO RUN on TIDELINK_SOC=%s — mmaps RAW Z2 literals (0x4403_xxxx)\n' "${0##*/}" "$TIDELINK_SOC" >&2
    printf '  UNDECODED on a ZynqMP (KR260) => hard PS hang. This tool is Pynq-Z2 ONLY.\n' >&2
    printf '  On a KR260 use tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.\n' >&2
    exit 3 ;;
esac


MASTER_IP="192.168.4.101"
SLAVE_IP="192.168.6.101"
# Try persistent home-dir location first, fall back to /tmp staging
if [ -f "$HOME/tidelink_artefacts/v33/tidelink.bin" ]; then
    ARTEFACTS="$HOME/tidelink_artefacts/v33"
elif [ -f "$HOME/tidelink_artefacts/v32/tidelink.bin" ]; then
    ARTEFACTS="$HOME/tidelink_artefacts/v32"
else
    ARTEFACTS="/tmp/tidelink_deploy_v32"
fi
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
DEPLOY_BOTH=0
[[ "${1:-}" == "--redeploy-both" ]] && DEPLOY_BOTH=1

SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
# Support both: direct execution ($(dirname)) and piped-via-SSH (fallback to project path)
_SELF="${BASH_SOURCE[0]:-}"
if [ -n "$_SELF" ] && [ -f "$(dirname "$_SELF")/deploy_pair.sh" ]; then
    SCRIPTS_DIR="$(dirname "$_SELF")"
else
    SCRIPTS_DIR="$HOME/SoCLabs/tidelink/pynq_host/scripts"
fi
DEPLOY_SCRIPT="$SCRIPTS_DIR/deploy_pair.sh"

echo "=== TideLink v33 Recovery + Bring-up ==="
echo "  Master: $MASTER_IP (z2_02, die_a)"
echo "  Slave : $SLAVE_IP (z2_03, die_b)"
echo ""

# ---- Step 1: wait for z2_02 to respond --------------------------------
echo ">> Waiting for z2_02 to respond to ping..."
for i in $(seq 1 60); do
    if ping -c 1 -W 2 "$MASTER_IP" >/dev/null 2>&1; then
        echo "   z2_02 UP (${i}x2s = $((i*2))s)"
        break
    fi
    [ $i -eq 60 ] && { echo "ERROR: z2_02 still not pinging after 2 min"; exit 1; }
    sleep 2
done

# Wait for SSH to be ready too (sshd starts a few seconds after ping)
echo ">> Waiting for z2_02 SSH..."
for i in $(seq 1 30); do
    if sshpass -p "$PASS" ssh $SSHCOMMON xilinx@"$MASTER_IP" 'hostname' >/dev/null 2>&1; then
        echo "   z2_02 SSH ready"
        break
    fi
    [ $i -eq 30 ] && { echo "ERROR: z2_02 SSH not ready after 60s"; exit 1; }
    sleep 2
done

# ---- Step 2: deploy v32 to z2_02 (and optionally z2_03) ---------------
echo ""
echo ">> Deploying to z2_02 (master/die_a) from $ARTEFACTS..."
bash "$DEPLOY_SCRIPT" "$MASTER_IP" z2_02 die_a "$ARTEFACTS" --no-verify
echo "   z2_02 deploy done"

if [ "$DEPLOY_BOTH" -eq 1 ]; then
    echo ">> Deploying to z2_03 (slave/die_b) from $ARTEFACTS..."
    bash "$DEPLOY_SCRIPT" "$SLAVE_IP" z2_03 die_b "$ARTEFACTS" --no-verify
    echo "   z2_03 deploy done"
else
    echo ">> Skipping z2_03 redeploy (--redeploy-both not set; z2_03 still has v32)"
fi

# ---- Step 3: wait for both boards to be SSH-ready after FPGA reload ---
echo ""
echo ">> Waiting for both boards post-deploy..."
for ip in "$MASTER_IP" "$SLAVE_IP"; do
    for i in $(seq 1 20); do
        if sshpass -p "$PASS" ssh $SSHCOMMON xilinx@"$ip" 'hostname' >/dev/null 2>&1; then
            echo "   $ip SSH ready"
            break
        fi
        sleep 3
    done
done

# ---- Step 4: simultaneous Wlink swreset on both boards ----------------
echo ""
echo ">> Running simultaneous swreset on both boards..."
SWRESET_PY='import mmap,struct,os,time
P=4096
fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC)
def mm(a):
    b=a&~(P-1); o=a-b
    return mmap.mmap(fd,4096,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
w,wo=mm(0x44030000)
r,ro=mm(0x44032000)
s=struct.unpack_from("<I",r,ro+0x108)[0]
print("Before: fcsm=%d cr=%d ck=%d cal=%d lock=0x%02x"%((s>>17)&7,(s>>23)&1,(s>>24)&1,(s>>16)&1,s&0xff))
struct.pack_into("<I",w,wo+0x208,0x00027f09)
time.sleep(0.01)
struct.pack_into("<I",w,wo+0x208,0x00027f01)
time.sleep(0.01)
struct.pack_into("<I",w,wo+0x208,0x00027f07)
time.sleep(1.5)
s=struct.unpack_from("<I",r,ro+0x108)[0]
sd=struct.unpack_from("<I",r,ro+0x114)[0]
print("After: fcsm=%d cr=%d ck=%d cal=%d lock=0x%02x sync_det=%d ecc_corr=%d"%((s>>17)&7,(s>>23)&1,(s>>24)&1,(s>>16)&1,s&0xff,(sd>>16)&0xffff,sd&0xffff))'

echo "   Master swreset..."
sshpass -p "$PASS" ssh $SSHCOMMON xilinx@"$MASTER_IP" "echo '$PASS' | sudo -S python3 -c '$SWRESET_PY'" &
MASTER_PID=$!
echo "   Slave swreset (simultaneous)..."
sshpass -p "$PASS" ssh $SSHCOMMON xilinx@"$SLAVE_IP"  "echo '$PASS' | sudo -S python3 -c '$SWRESET_PY'" &
SLAVE_PID=$!
wait $MASTER_PID || true
wait $SLAVE_PID  || true

# ---- Step 5: full probe -----------------------------------------------
echo ""
echo ">> Master (z2_02) full probe:"
bash "$SCRIPTS_DIR/wlink_probe.sh" "$MASTER_IP" 2>/dev/null || echo "   (probe failed)"

echo ""
echo ">> Slave (z2_03) full probe:"
bash "$SCRIPTS_DIR/wlink_probe.sh" "$SLAVE_IP" 2>/dev/null || echo "   (probe failed)"

# ---- Step 6: pass/fail check -----------------------------------------
echo ""
echo ">> Checking FCSM state..."
check_fcsm() {
    local ip="$1" label="$2"
    local v
    v=$(sshpass -p "$PASS" ssh $SSHCOMMON xilinx@"$ip" "echo '$PASS' | sudo -S python3 -c 'import mmap,struct,os; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC); b=0x44032000&~0xfff; r=mmap.mmap(fd,4096,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b); s=struct.unpack_from(\"<I\",r,0x108)[0]; print((s>>17)&7)'" 2>/dev/null || echo "0")
    echo "   $label FCSM state = $v"
    [ "$v" = "5" ]
}

if check_fcsm "$MASTER_IP" "Master" && check_fcsm "$SLAVE_IP" "Slave"; then
    echo ""
    echo "=== PASS: Both boards at FCSM=5 (LINK_RUNNING) ==="
else
    echo ""
    echo "=== STATUS: Link not yet at LINK_RUNNING — check probe output above ==="
    echo "   (sync_det=0 or FCSM != 5 may need additional investigation)"
fi
