#!/bin/sh
# kr260_afi.sh — AFI PS-master-port width check / fix for KR260 (ZynqMP).
#
# WHY THIS EXISTS
# ---------------
# KR260 boards run plain Ubuntu 22.04 (no PYNQ). The TideLink design's
# psu_init never runs, so the stock Kria SOM firmware's PS configuration
# persists across every PL load. That firmware programs the AFI PS-master
# port data widths in the afi_fs SLCR registers. Our block design
# (fpga/targets/kr260-pair-ptp/tidelink_design.tcl) drives BOTH PS master
# ports — HPM0_LPD (control, 0x8000_0000 window) and HPM0_FPD (data,
# 0xA000_0000 window) — at 32-bit. If the firmware left either port at a
# wider setting, every 32-bit AXI access at a misaligned lane reads 0 /
# drops writes: exactly the KR260 control-plane defect (0x214 IGNORED,
# PHC 0x8405_0008 IGNORED, while 0x230 and the hardwired 0x200=0x88 work).
#
#   LPD_SLCR 0xFF419000  bits [9:8]  = HPM0_LPD width   (control plane)
#   FPD_SLCR 0xFD615000  bits [9:8]  = HPM0_FPD width   (data plane)
#                        bits [11:10] = HPM1_FPD width  (UNUSED — leave alone)
#
#   width field: 00 = 32-bit (silicon default, what our BD wants)
#                01 = 64-bit
#                10 = 128-bit
#                11 = reserved
#
# afi_fs is documented "static — do not modify during operation". Only
# reprogram it while the PL is quiescent: right after a PL load, BEFORE any
# AXI traffic. That is why the deploy path calls `fix` immediately after the
# bitstream is loaded and before the smoke test.
#
# USAGE
#   kr260_afi.sh check     read both regs, decode widths, PASS/MISMATCH vs 32-bit
#   kr260_afi.sh fix       read-modify-write [9:8]->00 on both, re-check, canaries
#   kr260_afi.sh help      this text
#
# Must run as root (needs /dev/mem). Idempotent — running `fix` on an
# already-correct board writes nothing new and passes. Refuses to run on a
# non-ZynqMP host. Exit 0 = all good, non-zero = mismatch left / canary fail.
set -eu

# ---------------------------------------------------------------------------
# Register + expectation constants
# ---------------------------------------------------------------------------
LPD_SLCR=0xFF419000        # HPM0_LPD width in [9:8]  (control plane)
FPD_SLCR=0xFD615000        # HPM0_FPD width in [9:8]  (data plane); [11:10]=HPM1 (unused)
WIDTH_MASK=0x300           # bits [9:8]
EXPECT_FIELD=0             # 00 => 32-bit

# Canary APB registers (absolute PL addresses on KR260).
CAN_ROLE=0x84030204        # expect 0x00000001
CAN_MASK=0x84030214        # expect 0x0000E4E4
CAN_NEG=0x84030200         # negative control: hardwired 0x88, works regardless

# ---------------------------------------------------------------------------
# devmem backend — prefer devmem(8)/busybox devmem; fall back to python mmap.
# ---------------------------------------------------------------------------
DM_BACKEND=""
_pick_backend() {
    [ -n "$DM_BACKEND" ] && return 0
    if command -v devmem >/dev/null 2>&1; then
        DM_BACKEND="devmem"
    elif command -v busybox >/dev/null 2>&1 && busybox devmem 2>&1 | grep -qi 'devmem'; then
        DM_BACKEND="busybox"
    elif command -v python3 >/dev/null 2>&1; then
        DM_BACKEND="python3"
    elif command -v python >/dev/null 2>&1; then
        DM_BACKEND="python"
    else
        echo "ERROR: no devmem, busybox devmem, or python found — cannot access /dev/mem" >&2
        exit 3
    fi
}

# dm_read ADDR  -> prints 0xXXXXXXXX
dm_read() {
    _pick_backend
    case "$DM_BACKEND" in
        devmem)  _v=$(devmem "$1" 32) ;;
        busybox) _v=$(busybox devmem "$1" 32) ;;
        python3|python) _v=$("$DM_BACKEND" - "$1" <<'PY'
import sys, mmap, os, ctypes
addr = int(sys.argv[1], 0); page = 4096; base = addr & ~(page-1)
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, page, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
print("0x%08X" % ctypes.c_uint32.from_buffer(m, addr - base).value)
PY
) ;;
    esac
    # Normalise to 0x%08X.
    printf '0x%08X\n' "$_v"
}

# dm_write ADDR VAL
dm_write() {
    _pick_backend
    case "$DM_BACKEND" in
        devmem)  devmem "$1" 32 "$2" >/dev/null ;;
        busybox) busybox devmem "$1" 32 "$2" >/dev/null ;;
        python3|python) "$DM_BACKEND" - "$1" "$2" <<'PY'
import sys, mmap, os, ctypes
addr = int(sys.argv[1], 0); val = int(sys.argv[2], 0) & 0xFFFFFFFF
page = 4096; base = addr & ~(page-1)
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, page, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
ctypes.c_uint32.from_buffer(m, addr - base).value = val
PY
        ;;
    esac
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
_require_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "ERROR: must run as root (needs /dev/mem). Use sudo." >&2
        exit 2
    fi
}

_require_zynqmp() {
    for f in /sys/firmware/devicetree/base/compatible /proc/device-tree/compatible; do
        if [ -r "$f" ] && tr -d '\0' < "$f" | grep -q 'xlnx,zynqmp'; then
            return 0
        fi
    done
    echo "ERROR: this host does not look like a ZynqMP (no 'xlnx,zynqmp' in" >&2
    echo "       device-tree compatible). The afi_fs registers 0xFF419000 /" >&2
    echo "       0xFD615000 are ZynqMP-only — refusing to poke them here." >&2
    exit 4
}

# _decode_width FIELD -> prints "32-bit" / "64-bit" / "128-bit" / "reserved"
_decode_width() {
    case "$1" in
        0) echo "32-bit" ;;
        1) echo "64-bit" ;;
        2) echo "128-bit" ;;
        *) echo "reserved" ;;
    esac
}

# _field VAL SHIFT -> (VAL >> SHIFT) & 0x3
_field() { echo $(( ( $1 >> $2 ) & 0x3 )); }

# ---------------------------------------------------------------------------
# check — read both regs, decode, PASS/MISMATCH. Returns 0 iff both are 32-bit.
# ---------------------------------------------------------------------------
do_check() {
    _require_root
    _require_zynqmp
    rc=0

    lpd=$(dm_read "$LPD_SLCR")
    fpd=$(dm_read "$FPD_SLCR")

    lpd_hpm0=$(_field "$lpd" 8)
    fpd_hpm0=$(_field "$fpd" 8)
    fpd_hpm1=$(_field "$fpd" 10)

    echo "AFI PS-master-port width check (expect 32-bit on both used ports)"
    echo "  LPD_SLCR  $LPD_SLCR = $lpd"
    if [ "$lpd_hpm0" = "$EXPECT_FIELD" ]; then
        echo "    [PASS] HPM0_LPD (control) [9:8]=$lpd_hpm0 -> $(_decode_width "$lpd_hpm0")"
    else
        echo "    [MISMATCH] HPM0_LPD (control) [9:8]=$lpd_hpm0 -> $(_decode_width "$lpd_hpm0") (want 32-bit)"
        rc=1
    fi
    echo "  FPD_SLCR  $FPD_SLCR = $fpd"
    if [ "$fpd_hpm0" = "$EXPECT_FIELD" ]; then
        echo "    [PASS] HPM0_FPD (data)    [9:8]=$fpd_hpm0 -> $(_decode_width "$fpd_hpm0")"
    else
        echo "    [MISMATCH] HPM0_FPD (data)    [9:8]=$fpd_hpm0 -> $(_decode_width "$fpd_hpm0") (want 32-bit)"
        rc=1
    fi
    echo "    [INFO] HPM1_FPD (unused)  [11:10]=$fpd_hpm1 -> $(_decode_width "$fpd_hpm1") (not driven by our BD; left as-is)"

    if [ "$rc" = "0" ]; then
        echo "AFI: PASS — both used PS master ports are 32-bit."
    else
        echo "AFI: MISMATCH — run '$0 fix' to force [9:8]->00 (32-bit)."
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# canaries — the fast proof the control/data planes now decode 32-bit words.
# ---------------------------------------------------------------------------
do_canaries() {
    rc=0
    role=$(dm_read "$CAN_ROLE")
    mask=$(dm_read "$CAN_MASK")
    neg=$(dm_read "$CAN_NEG")
    echo "AFI canaries:"
    if [ "$((role))" = "$((0x00000001))" ]; then
        echo "    [PASS] $CAN_ROLE = $role (expect 0x00000001)"
    else
        echo "    [FAIL] $CAN_ROLE = $role (expect 0x00000001)"
        rc=1
    fi
    if [ "$((mask))" = "$((0x0000E4E4))" ]; then
        echo "    [PASS] $CAN_MASK = $mask (expect 0x0000E4E4)"
    else
        echo "    [FAIL] $CAN_MASK = $mask (expect 0x0000E4E4)"
        rc=1
    fi
    # Negative control: hardwired 0x88, decodes regardless of AFI width, so it
    # is NOT a pass/fail gate — just a sanity anchor that the APB is alive.
    echo "    [INFO] $CAN_NEG = $neg (hardwired 0x00000088; works regardless of AFI)"
    return $rc
}

# ---------------------------------------------------------------------------
# fix — RMW both regs clearing [9:8], re-check, run canaries.
# ---------------------------------------------------------------------------
do_fix() {
    _require_root
    _require_zynqmp

    echo "AFI fix — clearing HPM0 width fields [9:8] to 00 (32-bit)."
    echo "  (afi_fs is static; this is safe ONLY with the PL quiescent, i.e."
    echo "   right after a fresh PL load, before any AXI traffic.)"

    # LPD (control). Read-before-write, always.
    lpd=$(dm_read "$LPD_SLCR")
    lpd_new=$(printf '0x%08X' $(( $lpd & ~WIDTH_MASK )))
    if [ "$lpd" = "$lpd_new" ]; then
        echo "  LPD_SLCR $LPD_SLCR = $lpd already 32-bit — no write."
    else
        echo "  LPD_SLCR $LPD_SLCR: $lpd -> $lpd_new"
        dm_write "$LPD_SLCR" "$lpd_new"
    fi

    # FPD (data). Clear [9:8] only; [11:10] HPM1 untouched.
    fpd=$(dm_read "$FPD_SLCR")
    fpd_new=$(printf '0x%08X' $(( $fpd & ~WIDTH_MASK )))
    if [ "$fpd" = "$fpd_new" ]; then
        echo "  FPD_SLCR $FPD_SLCR = $fpd already 32-bit (HPM0) — no write."
    else
        echo "  FPD_SLCR $FPD_SLCR: $fpd -> $fpd_new (HPM1 [11:10] preserved)"
        dm_write "$FPD_SLCR" "$fpd_new"
    fi

    echo
    # Re-check must now pass; if it does not, the write did not stick.
    if ! do_check; then
        echo "AFI: FIX FAILED — re-check still reports a mismatch (write rejected?)." >&2
        exit 5
    fi

    echo
    if ! do_canaries; then
        echo "AFI: CANARY FAILED — widths are 32-bit but the APB canaries are wrong." >&2
        echo "     The AFI width was not the (only) cause; escalate to the SmartConnect/BD trace." >&2
        exit 6
    fi

    echo
    echo "AFI: FIX OK — both ports 32-bit and canaries pass."
    return 0
}

usage() {
    # Print the contiguous comment header (lines 2..first non-comment).
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

case "${1:-help}" in
    check)  do_check ;;
    fix)    do_fix ;;
    help|-h|--help) usage ;;
    *) echo "ERROR: unknown command '${1:-}'. Use: check | fix | help" >&2; exit 64 ;;
esac
