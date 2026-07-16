#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - Bare-metal overlay loader (no pynq dependency)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Drop-in replacement for pynq.MMIO + pynq.Overlay.download() that depends
# only on /dev/mem + /sys/class/fpga_manager. Useful when the PYNQ Python
# stack is unavailable (minimal rootfs, offline board, CI without pynq pkg).
#
# Bitstream loading expects a .bin file in /lib/firmware/ (strip the .bit
# header and byte-swap 32-bit words at the deploy step; the kernel FPGA
# manager handles the rest).
#
# API surface is identical to overlay.py:TidelinkOverlay so the same test
# scripts work against either import.
#-----------------------------------------------------------------------------

import mmap
import os
import struct

# Block design address map — keep in sync with tidelink_design.tcl.
# SoC selection via env TIDELINK_SOC (default "z2"). KR260 (MPSoC) relocates
# every aperture off DDR into the PL windows: control -> 0x8000_0000, data ->
# 0xA000_0000 (pure top-nibble/top-byte swap of the Z2 map, low bits preserved).
# See fpga/docs/KR260_PORT.md.
_SOC = os.environ.get("TIDELINK_SOC", "z2").lower()

if _SOC in ("kr260", "kria", "mpsoc", "zynqmp", "kv260"):
    AHB_SUB_BASE  = 0x8000_0000
    AHB_TX_BASE   = 0xA400_0000
    AHB_FIFO_BASE = 0xA401_0000
    AHB_PTP_BASE  = 0x8402_0000
    APB_BASE      = 0x8403_0000
    STRAP_BASE    = 0x8404_0000
else:                             # z2 (default) — unchanged
    AHB_SUB_BASE  = 0x4000_0000
    AHB_TX_BASE   = 0x4400_0000
    AHB_FIFO_BASE = 0x4401_0000
    AHB_PTP_BASE  = 0x4402_0000
    APB_BASE      = 0x4403_0000
    STRAP_BASE    = 0x4404_0000

AHB_SUB_RANGE = 0x1000_0000  # 256 MB
AHB_TX_RANGE  = 0x0001_0000  # 64 KB
AHB_FIFO_RANGE= 0x0001_0000  # 64 KB
AHB_PTP_RANGE = 0x0000_1000  # 4 KB
APB_RANGE     = 0x0000_8000  # 32 KB
STRAP_RANGE   = 0x0000_1000  # 4 KB

GPIO_DATA_OFF     = 0x000
APB_CTRL_OFF      = 0x01C
APB_CTRL_FLUSH_BIT = (1 << 1)


class BareMMIO:
    """Tiny pynq.MMIO-compatible class backed by /dev/mem + mmap.

    Maps `length` bytes starting at `base_addr` (must be page-aligned).
    Provides word-aligned read(off) / write(off, val) at byte offsets.
    """

    PAGE_SIZE = 4096

    def __init__(self, base_addr, length):
        if base_addr % self.PAGE_SIZE:
            raise ValueError(
                f"base_addr 0x{base_addr:x} not page-aligned ({self.PAGE_SIZE})")
        self._base = base_addr
        self._len  = length
        rounded = (length + self.PAGE_SIZE - 1) & ~(self.PAGE_SIZE - 1)
        self._fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
        try:
            self._mm = mmap.mmap(
                self._fd, rounded,
                mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
                offset=base_addr,
            )
        except Exception:
            os.close(self._fd)
            raise

    def read(self, offset, length=4):
        if length != 4:
            raise NotImplementedError("only 32-bit reads supported")
        if offset & 0x3:
            raise ValueError("offset must be 32-bit aligned")
        return struct.unpack('<I', self._mm[offset:offset + 4])[0]

    def write(self, offset, value):
        if offset & 0x3:
            raise ValueError("offset must be 32-bit aligned")
        self._mm[offset:offset + 4] = struct.pack('<I', value & 0xFFFFFFFF)

    def close(self):
        try:
            self._mm.close()
        finally:
            os.close(self._fd)

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass


def load_bitstream(bin_filename, mgr_path='/sys/class/fpga_manager/fpga0'):
    """Trigger FPGA configuration via the kernel FPGA manager.

    `bin_filename` must be the basename of a .bin file already placed in
    /lib/firmware/. The write blocks until configuration completes.
    """
    fw_path    = os.path.join(mgr_path, 'firmware')
    state_path = os.path.join(mgr_path, 'state')
    with open(fw_path, 'w') as f:
        f.write(bin_filename)
    with open(state_path) as f:
        state = f.read().strip()
    if state != 'operating':
        raise RuntimeError(f"FPGA manager state after load = {state!r}")


class TidelinkBareOverlay:
    """Bare-metal TideLink overlay. Matches TidelinkOverlay API surface.

    Parameters
    ----------
    bitfile : str or None
        Ignored (kept for API compatibility). Use ``fw_name`` instead.
    fw_name : str or None
        Basename of the .bin file in /lib/firmware/. Defaults to
        ``'tidelink.bin'``.
    paired : bool
        Set False to skip opening the strap MMIO aperture (single-instance).
    skip_load : bool
        Skip FPGA manager step (useful when bitstream is already loaded).
    """

    def __init__(self, bitfile=None, fw_name=None, paired=True, skip_load=False):
        if not skip_load:
            load_bitstream(fw_name or 'tidelink.bin')
        self.ahb_sub  = BareMMIO(AHB_SUB_BASE,  AHB_SUB_RANGE)
        self.ahb_tx   = BareMMIO(AHB_TX_BASE,   AHB_TX_RANGE)
        self.ahb_fifo = BareMMIO(AHB_FIFO_BASE, AHB_FIFO_RANGE)
        self.ahb_ptp  = BareMMIO(AHB_PTP_BASE,  AHB_PTP_RANGE)
        self.apb      = BareMMIO(APB_BASE,       APB_RANGE)
        self.strap    = BareMMIO(STRAP_BASE, STRAP_RANGE) if paired else None

    def set_role(self, role: str):
        """Write the role strap GPIO (paired bitstream only)."""
        if self.strap is None:
            raise RuntimeError(
                "set_role() called on a single-instance overlay (no strap GPIO)")
        if role not in ("die_a", "die_b"):
            raise ValueError(f"role must be 'die_a' or 'die_b', got {role!r}")
        self.strap.write(GPIO_DATA_OFF, 1 if role == "die_b" else 0)

    def get_role(self) -> str:
        """Read back the current role strap. Returns 'die_a' if no strap."""
        if self.strap is None:
            return "die_a"
        return "die_b" if (self.strap.read(GPIO_DATA_OFF) & 1) else "die_a"

    def read_pidr(self):
        """Return the 8-byte CoreSight peripheral ID as an integer."""
        pidr = 0
        for i, off in enumerate([0xFE0, 0xFE4, 0xFE8, 0xFEC,
                                  0xFD0, 0xFD4, 0xFD8, 0xFDC]):
            pidr |= (self.apb.read(off) & 0xFF) << (8 * i)
        return pidr

    def read_cidr(self):
        """Return the 4-byte CoreSight component ID as an integer."""
        cidr = 0
        for i, off in enumerate([0xFF0, 0xFF4, 0xFF8, 0xFFC]):
            cidr |= (self.apb.read(off) & 0xFF) << (8 * i)
        return cidr

    def reset_controller(self):
        """Assert FLUSH via APB CTRL[1] (EN must be 0 per tidelink_apb_regs.sv)."""
        self.apb.write(APB_CTRL_OFF, APB_CTRL_FLUSH_BIT)
