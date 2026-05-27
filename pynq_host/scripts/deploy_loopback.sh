#!/bin/bash
# Deploy a TideLink LOOPBACK bitstream onto a single Pynq-Z2 and bring the
# link up against itself. Two variants supported via LOOPBACK_KIND:
#
#   LOOPBACK_KIND=external  (default) — image = pynq-z2-loopback-ext
#       Pads leave the FPGA via J13 RPi header; user has physically
#       jumpered TX pins to RX pins (see fpga/targets/pynq-z2-loopback-ext/
#       loopback_wiring.md). BD is identical to pynq-z2-pair-all (PHC +
#       IDELAY + debug-unlock + PMOD-B), so the deploy sequence matches
#       deploy_pair.sh — including the debug_unlock GPIO at 0x44041000.
#
#   LOOPBACK_KIND=internal — image = pynq-z2-loopback
#       Pads are tied TX→RX inside the FPGA fabric by the wrapper; no
#       FPGA pins exposed for the link. BD is the simple legacy variant
#       (no debug_unlock GPIO, no IDELAY) — the deploy skips the
#       debug_unlock write.
#
# Usage:
#   deploy_loopback.sh BOARD_IP LABEL [ARTEFACTS_DIR] [options]
#     ARTEFACTS_DIR optional; defaults to /tmp/tidelink_deploy
#
#   --no-verify             skip provenance check (no manifest available)
#   --expect-sha256 <hex>   abort unless staged .bin matches this hash
#   --manifest <path>       read expected sha256 from a manifest.json
#
# Strap is hard-coded to MASTER (strap=0, ROLE_CFG=0x2, phase=0) because
# loopback has no peer to negotiate with. role_lock is set immediately;
# the script does NOT wait for peer-convergence (there is no peer).
#
# **HAZARD — DO NOT WRITE TO AHB_TX (0x4400_0000) FROM PS UNTIL THE LINK
# IS VERIFIED UP.** Same bench rule as the paired flow — if the loopback
# wires are wrong or the FCSM never converges, AHB_TX writes hang the PS.
# Run wlink_probe.sh first.
set -e

BOARD_IP="$1"
LABEL="$2"
if [ -n "${3:-}" ] && [ "${3#-}" = "$3" ]; then
    ARTEFACTS="$3"; shift 3
else
    ARTEFACTS="/tmp/tidelink_deploy"; [ "$#" -ge 2 ] && shift 2
fi
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
KIND="${LOOPBACK_KIND:-external}"

EXPECT_SHA=""
MANIFEST=""
NO_VERIFY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --expect-sha256) EXPECT_SHA="$2"; shift 2 ;;
        --expect-sha256=*) EXPECT_SHA="${1#*=}"; shift ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --manifest=*) MANIFEST="${1#*=}"; shift ;;
        --no-verify) NO_VERIFY=1; shift ;;
        *) echo "deploy_loopback.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

case "$KIND" in
    internal) BIN="tidelink.bin"; HWH="tidelink.hwh"; WRITE_DBG_UNLK=0 ;;
    external) BIN="tidelink.bin"; HWH="tidelink.hwh"; WRITE_DBG_UNLK=1 ;;
    *) echo "deploy_loopback.sh: LOOPBACK_KIND must be 'internal' or 'external' (got '$KIND')" >&2; exit 2 ;;
esac

STRAP=0
CTRL=0x2
PHASE=0x00000000
if [ -n "${PHASE_OVERRIDE:-}" ]; then
    PHASE="$PHASE_OVERRIDE"
fi

[[ -z "$BOARD_IP" || -z "$LABEL" ]] && {
    sed -n '4,30p' "$0" | sed 's/^# *//'; exit 2; }

SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
if [ -n "${PYNQ_PROXY:-}" ]; then
    SSHCOMMON="$SSHCOMMON -o ProxyJump=$PYNQ_PROXY"
fi

STAGED_BIN="$ARTEFACTS/$BIN"
MANIFEST_LABEL=""

manifest_field() {
    [ -f "$1" ] || { echo ""; return; }
    grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
        | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
}

if [ -z "$MANIFEST" ] && [ -f "${STAGED_BIN}.manifest.json" ]; then
    MANIFEST="${STAGED_BIN}.manifest.json"
fi
if [ -n "$MANIFEST" ]; then
    if [ ! -f "$MANIFEST" ]; then
        echo "DEPLOY-ABORT: manifest not found: $MANIFEST" >&2; exit 4
    fi
    MANIFEST_LABEL=$(manifest_field "$MANIFEST" label)
    [ -z "$EXPECT_SHA" ] && EXPECT_SHA=$(manifest_field "$MANIFEST" sha256)
fi

ACTUAL_SHA=""
if [ -f "$STAGED_BIN" ]; then
    ACTUAL_SHA=$(sha256sum "$STAGED_BIN" 2>/dev/null | awk '{print $1}')
fi

if [ -n "$EXPECT_SHA" ]; then
    if [ -z "$ACTUAL_SHA" ]; then
        echo "DEPLOY-ABORT: cannot hash staged $STAGED_BIN" >&2; exit 4
    fi
    if [ "$ACTUAL_SHA" != "$EXPECT_SHA" ]; then
        echo "DEPLOY-ABORT: sha256 mismatch — expected $EXPECT_SHA, got $ACTUAL_SHA" >&2; exit 4
    fi
    echo "  provenance OK: $BIN sha256 ${ACTUAL_SHA:0:12}…"
elif [ "$NO_VERIFY" -eq 1 ]; then
    echo "WARNING: --no-verify — flashing $BIN WITHOUT provenance check" >&2
else
    echo "DEPLOY-ABORT: pass --expect-sha256, --manifest, or --no-verify." >&2
    exit 5
fi

echo "==== $LABEL @ $BOARD_IP — kind=$KIND strap=$STRAP ctrl=$CTRL bitstream=$BIN ===="

MAX_LOAD_ATTEMPTS="${MAX_LOAD_ATTEMPTS:-2}"
load_attempt=1
loaded=0
while [ "$load_attempt" -le "$MAX_LOAD_ATTEMPTS" ]; do
    if ! sshpass -p "$PASS" scp $SSHCOMMON \
            "$ARTEFACTS/$BIN" "xilinx@$BOARD_IP:/tmp/tidelink.bin" >&2; then
        echo "DEPLOY-FAIL: scp .bin attempt $load_attempt failed" >&2
        load_attempt=$((load_attempt+1)); continue
    fi
    if ! sshpass -p "$PASS" scp $SSHCOMMON \
            "$ARTEFACTS/$HWH" "xilinx@$BOARD_IP:/tmp/tidelink.hwh" >&2; then
        echo "DEPLOY-FAIL: scp .hwh attempt $load_attempt failed" >&2
        load_attempt=$((load_attempt+1)); continue
    fi
    if ! sshpass -p "$PASS" ssh $SSHCOMMON xilinx@$BOARD_IP \
            "echo '$PASS' | sudo -S sh -c '
                cp /tmp/tidelink.bin /lib/firmware/tidelink.bin
                cp /tmp/tidelink.hwh /lib/firmware/tidelink.hwh
                echo tidelink.bin > /sys/class/fpga_manager/fpga0/firmware
                sleep 1
                printf \"  fpga_manager: %s\n\" \"\$(cat /sys/class/fpga_manager/fpga0/state)\"
            '"; then
        echo "DEPLOY-FAIL: load_overlay attempt $load_attempt failed" >&2
        load_attempt=$((load_attempt+1)); continue
    fi
    state=$(sshpass -p "$PASS" ssh $SSHCOMMON xilinx@$BOARD_IP \
        "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null" 2>/dev/null \
        | tr -d '[:space:]')
    if [ "$state" = "operating" ]; then loaded=1; break; fi
    echo "DEPLOY-FAIL: fpga_manager state='$state' attempt $load_attempt" >&2
    load_attempt=$((load_attempt+1)); sleep 1
done
if [ "$loaded" -ne 1 ]; then
    echo "DEPLOY-FAIL: GIVING UP after $MAX_LOAD_ATTEMPTS attempts" >&2; exit 3
fi

# Build the python register-init script. Conditionally include the
# debug_unlock write at 0x44041000 (present only on the external variant's
# BD; internal-loopback BD does not map this GPIO and the write would
# segfault).
DBG_UNLK_PY=""
if [ "$WRITE_DBG_UNLK" = "1" ]; then
    DBG_UNLK_PY="d,do=mm(0x44041000); struct.pack_into('<I',d,do,1)"
fi

read -r -d '' PYSCRIPT <<PYEOF || true
import mmap,struct,os,time
P=4096
fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC)
def mm(a):
    b=a&~(P-1); return mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),(a-b)
s,so=mm(0x44040000)
struct.pack_into("<I",s,so,$STRAP)
$DBG_UNLK_PY
r,ro=mm(0x44032000)
w,wo=mm(0x44030000)
struct.pack_into("<I",r,ro+0x00,0x44032000)
struct.pack_into("<I",w,wo+0x00,$PHASE)
struct.pack_into("<I",r,ro+0x80,$CTRL)
struct.pack_into("<I",w,wo+0x208,0x00027f09)
time.sleep(0.005)
struct.pack_into("<I",w,wo+0x208,0x00027f01)
time.sleep(0.005)
struct.pack_into("<I",w,wo+0x208,0x00027f07)
phy=struct.unpack_from("<I",w,wo+0x00)[0]
val=struct.unpack_from("<I",r,ro+0x80)[0]
print("  PHY_CTRL = 0x{:08x} (swi_phase_offset={})".format(phy,(phy>>17)&0xF))
print("  ROLE_CFG = 0x{:02x} (lock={}, cfg={})".format(val,(val>>1)&1,val&1))
PYEOF

# Encode the python script so any embedded quotes survive the ssh hop.
PYB64=$(printf '%s' "$PYSCRIPT" | base64 -w0)

sshpass -p "$PASS" ssh $SSHCOMMON xilinx@$BOARD_IP \
    "echo '$PASS' | sudo -S python3 -c \"import base64,sys; exec(base64.b64decode('$PYB64').decode())\""

echo "==== $LABEL done (kind=$KIND, sha256=${ACTUAL_SHA:0:12}…) ===="
echo ""
echo "Verify the link came up:"
echo "  pynq_host/scripts/wlink_probe.sh $BOARD_IP $LABEL"
