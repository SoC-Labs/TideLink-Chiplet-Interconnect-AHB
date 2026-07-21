#!/usr/bin/env python3
"""kr260_smoke.py — KR260 port plumbing smoke test. Runs ON the board, as root.

This is NOT a link bring-up. It verifies the three things the KR260 port newly
put at risk, and nothing else:

  1. The relocated apertures respond.  Every TideLink aperture moved off DDR
     into the MPSoC PL windows (control -> 0x8000_0000 / HPM0_LPD, data ->
     0xA000_0000 / HPM0_FPD). If the address remap or the SmartConnect wiring
     is wrong, these reads return garbage or the PL never decodes them.
  2. The die role strap reads back.   die_a images strap 0x0, die_b (flip)
     images strap 0x1 (axi_gpio C_DOUT_DEFAULT). This is the cheapest possible
     proof that you flashed the *right* bitstream to the *right* board — the
     #1 way to waste a bench session.
  3. A PL-side register is writable.  Writes debug_unlock and reads it back.

SAFETY: on ZynqMP a read of an *undecoded* PL address can hang the AXI bus
(no slave responds, no timeout) and wedge the board. So this script only ever
touches apertures that the running image is known to decode. The PTP-only
apertures (ahb_ptp, phc) are absent from the -nptp images, so they are probed
ONLY when you pass --ptp. Do not remove that gate.

Usage (after `make -C fpga deploy TARGET=kr260-pair-... BOARD=...`):

    sudo TIDELINK_SOC=kr260 python3 pynq_host/scripts/kr260_smoke.py \
         --expect-role die_a           # or die_b
    sudo TIDELINK_SOC=kr260 python3 pynq_host/scripts/kr260_smoke.py \
         --expect-role die_b --ptp --unlock

Exit status: 0 = every check passed, 1 = at least one FAIL.
"""
import argparse
import ctypes
import mmap
import os
import sys

PAGE = 4096

# --- KR260 map. Mirrors fpga/targets/kr260-pair-*/tidelink_design.tcl's
# --- assign_bd_address calls and pynq_host/overlay.py. Keep all three in step.
APB_BASE      = 0x84030000   # 32 KB  TideLink APB (Wlink + chiplet ctrl)
STRAP_BASE    = 0x84040000   #  4 KB  axi_gpio_strap        (role_strap_i)
DEBUG_BASE    = 0x84041000   #  4 KB  axi_gpio_debug_unlock
AHB_PTP_BASE  = 0x84020000   #  4 KB  PTP only
PHC_BASE      = 0x84050000   #  4 KB  PTP only

# AFI PS-master-port width registers (ZynqMP SLCR, read-only here). The stock
# Kria SOM firmware programs these; our psu_init never runs. If HPM0_LPD (ctrl)
# or HPM0_FPD (data) is left wider than our 32-bit BD, misaligned 32-bit AXI
# accesses read 0 / drop writes — the KR260 control-plane defect. This smoke
# test only REPORTS the widths; kr260_afi.sh fix corrects them. See
# docs/KR260_AFI_CHECK.md.
AFI_LPD_SLCR  = 0xFF419000   # bits [9:8] = HPM0_LPD width (control plane)
AFI_FPD_SLCR  = 0xFD615000   # bits [9:8] = HPM0_FPD width (data plane)
_AFI_WIDTH = {0: "32-bit", 1: "64-bit", 2: "128-bit", 3: "reserved"}

WLINK_PHY_CTRL_OFF     = 0x0000
WLINK_ACTIVE_LANES_OFF = 0x0210
WLINK_LANE_MASK_OFF    = 0x0214
REG_ROLE_LOCK          = 0x2080
OBS_FC_CREDIT_OFF      = 0x219C

GPIO_DATA_OFF = 0x000

_fd = None
_maps = {}


def _mm(addr):
    """mmap the page containing `addr`, caching by page base."""
    base = addr & ~(PAGE - 1)
    if base not in _maps:
        _maps[base] = mmap.mmap(_fd, PAGE, mmap.MAP_SHARED,
                                mmap.PROT_READ | mmap.PROT_WRITE,
                                offset=base)
    return _maps[base], addr - base


def rd(addr):
    m, off = _mm(addr)
    return ctypes.c_uint32.from_buffer(m, off).value


def wr(addr, val):
    m, off = _mm(addr)
    ctypes.c_uint32.from_buffer(m, off).value = val & 0xFFFFFFFF


class Report:
    def __init__(self):
        self.fails = 0

    def line(self, ok, label, detail):
        if ok is None:
            tag = "INFO"
        elif ok:
            tag = "PASS"
        else:
            tag = "FAIL"
            self.fails += 1
        print(f"[{tag}] {label:<28} {detail}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--expect-role", choices=("die_a", "die_b"), required=True,
                    help="which image you believe you flashed to THIS board")
    ap.add_argument("--ptp", action="store_true",
                    help="image is a -ptp build; also probe ahb_ptp + phc. "
                         "DO NOT pass this for a -nptp image (undecoded read "
                         "can hang the AXI bus).")
    ap.add_argument("--unlock", action="store_true",
                    help="write debug_unlock=1 and read it back (mutates PL state)")
    args = ap.parse_args()

    global _fd
    try:
        _fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    except PermissionError:
        print("ERROR: need root for /dev/mem (use sudo)", file=sys.stderr)
        return 2

    soc = os.environ.get("TIDELINK_SOC", "<unset>")
    print(f"KR260 smoke — TIDELINK_SOC={soc}  expect-role={args.expect_role}  "
          f"ptp={args.ptp}\n")
    if soc.lower() not in ("kr260", "kria", "mpsoc", "zynqmp", "kv260"):
        print("WARNING: TIDELINK_SOC is not a KR260 alias; host libs will use "
              "the Z2 map even though this script uses the KR260 one.\n")

    r = Report()

    # 0. AFI PS-master-port widths (read-only). Reported BEFORE the aperture
    #    checks because a wider-than-32-bit port is the most likely reason the
    #    apertures below misbehave. This does NOT fix anything — run
    #    `sudo sh pynq_host/scripts/kr260_afi.sh fix` for that.
    lpd = rd(AFI_LPD_SLCR)
    fpd = rd(AFI_FPD_SLCR)
    lpd_w = (lpd >> 8) & 0x3
    fpd_w = (fpd >> 8) & 0x3
    afi_ok = (lpd_w == 0 and fpd_w == 0)
    r.line(afi_ok, "AFI port widths",
           f"HPM0_LPD(ctrl)={_AFI_WIDTH[lpd_w]} HPM0_FPD(data)={_AFI_WIDTH[fpd_w]} "
           f"(0x{AFI_LPD_SLCR:08X}=0x{lpd:08X} 0x{AFI_FPD_SLCR:08X}=0x{fpd:08X})"
           + ("" if afi_ok else "  <-- NOT 32-bit; run kr260_afi.sh fix"))

    # 1. Control aperture (APB). All four images decode this.
    lanes = rd(APB_BASE + WLINK_ACTIVE_LANES_OFF)
    mask = rd(APB_BASE + WLINK_LANE_MASK_OFF)
    phy = rd(APB_BASE + WLINK_PHY_CTRL_OFF)
    obs = rd(APB_BASE + OBS_FC_CREDIT_OFF)
    role = rd(APB_BASE + REG_ROLE_LOCK)

    # A totally undecoded / dead aperture reads back all-ones or all-zeros on
    # every register. Any variation proves the APB is really answering.
    alive = len({lanes, mask, phy, obs, role}) > 1
    r.line(alive, "APB aperture alive",
           f"@0x{APB_BASE:08X} lanes=0x{lanes:08X} mask=0x{mask:08X} "
           f"phy=0x{phy:08X}")
    r.line(None, "  OBS_FC_CREDIT", f"0x{obs:08X} "
           f"(marker 0x{(obs >> 24) & 0xFF:02X}, expect 0xFC once link runs)")
    r.line(None, "  ROLE_LOCK", f"0x{role:08X} "
           f"(bit0=role_cfg bit1=role_lock)")

    # 2. Die-role strap — the cheap "did I flash the right image?" check.
    strap = rd(STRAP_BASE + GPIO_DATA_OFF) & 0x1
    want = 0 if args.expect_role == "die_a" else 1
    r.line(strap == want, "die role strap",
           f"strap=0x{strap:X} expected 0x{want:X} for {args.expect_role}"
           + ("" if strap == want else "  <-- WRONG BITSTREAM ON THIS BOARD"))

    # 3. PL register is writable.
    if args.unlock:
        wr(DEBUG_BASE + GPIO_DATA_OFF, 1)
        rb = rd(DEBUG_BASE + GPIO_DATA_OFF) & 0x1
        r.line(rb == 1, "debug_unlock writable",
               f"wrote 1, read back {rb} @0x{DEBUG_BASE:08X}")
    else:
        r.line(None, "debug_unlock", "skipped (pass --unlock to exercise)")

    # 4. PTP apertures — ONLY on a -ptp image. See SAFETY note above.
    if args.ptp:
        ptp = rd(AHB_PTP_BASE)
        phc = rd(PHC_BASE)
        r.line(not (ptp == 0xFFFFFFFF and phc == 0xFFFFFFFF),
               "PTP apertures respond",
               f"ahb_ptp@0x{AHB_PTP_BASE:08X}=0x{ptp:08X} "
               f"phc@0x{PHC_BASE:08X}=0x{phc:08X}")
    else:
        r.line(None, "PTP apertures",
               "not probed (-nptp image, or pass --ptp)")

    print()
    if r.fails:
        print(f"SMOKE FAILED — {r.fails} check(s) failed.")
        return 1
    print("SMOKE PASSED — apertures respond, strap matches the expected die.")
    print("NOTE: this proves plumbing only. It says nothing about link-up, "
          "eye quality, or data crossing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
