#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - PYNQ Overlay
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# PYNQ Overlay class for the TideLink chiplet bridge on PYNQ-Z2.
#
# Supports both the paired bitstream (with AXI GPIO strap at 0x4404_0000)
# and the single-instance bitstream (no strap region; role fixed to die_a).
#
# Address map (from fpga/targets/pynq-z2-pair/tidelink_design.tcl):
#   0x4000_0000  ahb_sub  256 MB  (transparent chiplet window)
#   0x4400_0000  ahb_tx    64 KB  (TX aperture)
#   0x4401_0000  ahb_fifo  64 KB  (RX FIFO window)
#   0x4402_0000  ahb_ptp    4 KB  (PTP TX write port)
#   0x4403_0000  apb       32 KB  (unified config registers)
#   0x4404_0000  strap      4 KB  (AXI GPIO; paired bitstream only)
#
# Usage:
#   from overlay import TidelinkOverlay
#   ol = TidelinkOverlay()          # loads tidelink.bit next to this file
#   ol.set_role("die_b")            # or os.environ["FPGAHUB_LOCAL_ROLE"]
#   pidr = ol.read_pidr()
#-----------------------------------------------------------------------------

import os
from pynq import Overlay, MMIO

# Block design address map — keep in sync with tidelink_design.tcl
AHB_SUB_BASE  = 0x4000_0000
AHB_SUB_RANGE = 0x1000_0000  # 256 MB

AHB_TX_BASE   = 0x4400_0000
AHB_TX_RANGE  = 0x0001_0000  # 64 KB

AHB_FIFO_BASE = 0x4401_0000
AHB_FIFO_RANGE= 0x0001_0000  # 64 KB

AHB_PTP_BASE  = 0x4402_0000
AHB_PTP_RANGE = 0x0000_1000  # 4 KB

APB_BASE      = 0x4403_0000
APB_RANGE     = 0x0000_8000  # 32 KB

STRAP_BASE    = 0x4404_0000
STRAP_RANGE   = 0x0000_1000  # 4 KB

# Xilinx AXI GPIO register offsets
GPIO_DATA_OFF = 0x000  # GPIO_DATA register (channel 1)

# APB CTRL register offset (from tidelink_apb_regs.sv, paddr[4:2]==3'h7 -> 0x01C)
APB_CTRL_OFF  = 0x01C
APB_CTRL_FLUSH_BIT = (1 << 1)  # bit[1] = FLUSH (self-clearing; EN must be 0)


class TidelinkOverlay(Overlay):
    """PYNQ Overlay for the TideLink chiplet bridge.

    Exposes six MMIO apertures:
        ahb_sub  : transparent chiplet window (256 MB)
        ahb_tx   : TX aperture (64 KB)
        ahb_fifo : RX FIFO window (64 KB)
        ahb_ptp  : PTP TX write port (4 KB)
        apb      : unified config registers (32 KB)
        strap    : AXI GPIO role strap (4 KB) — None on single-instance bitstreams

    Parameters
    ----------
    bitfile : str or None
        Path to the bitstream. Defaults to ``tidelink.bit`` in the same
        directory as this module.
    paired : bool
        Set False to suppress opening the strap MMIO aperture (single-instance
        bitstream). Default True (attempt to open strap; caller passes False
        explicitly for single-instance builds).
    **kwargs
        Forwarded to ``pynq.Overlay``.
    """

    def __init__(self, bitfile=None, paired=True, **kwargs):
        if bitfile is None:
            bitfile = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   'tidelink.bit')
        super().__init__(bitfile, **kwargs)
        self.ahb_sub  = MMIO(AHB_SUB_BASE,  AHB_SUB_RANGE)
        self.ahb_tx   = MMIO(AHB_TX_BASE,   AHB_TX_RANGE)
        self.ahb_fifo = MMIO(AHB_FIFO_BASE, AHB_FIFO_RANGE)
        self.ahb_ptp  = MMIO(AHB_PTP_BASE,  AHB_PTP_RANGE)
        self.apb      = MMIO(APB_BASE,       APB_RANGE)
        self.strap    = MMIO(STRAP_BASE, STRAP_RANGE) if paired else None

    # -------------------------------------------------------------------------
    # Role strap helpers (paired bitstream only)
    # -------------------------------------------------------------------------

    def set_role(self, role: str):
        """Write the role strap GPIO.

        Parameters
        ----------
        role : ``"die_a"`` or ``"die_b"``
            die_a -> strap = 0 (slave); die_b -> strap = 1 (master).
        """
        if self.strap is None:
            raise RuntimeError(
                "set_role() called on a single-instance overlay (no strap GPIO)")
        if role not in ("die_a", "die_b"):
            raise ValueError(f"role must be 'die_a' or 'die_b', got {role!r}")
        self.strap.write(GPIO_DATA_OFF, 1 if role == "die_b" else 0)

    def get_role(self) -> str:
        """Read back the current role strap.

        Returns ``"die_a"`` if the strap aperture is unavailable (single-instance).
        """
        if self.strap is None:
            return "die_a"
        val = self.strap.read(GPIO_DATA_OFF)
        return "die_b" if (val & 1) else "die_a"

    # -------------------------------------------------------------------------
    # CoreSight ID helpers (APB)
    # -------------------------------------------------------------------------

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

    # -------------------------------------------------------------------------
    # Controller reset
    # -------------------------------------------------------------------------

    def reset_controller(self):
        """Assert FLUSH via APB CTRL[1].

        EN (bit 0) must be 0 before FLUSH is honoured (per tidelink_apb_regs.sv).
        Write EN=0,FLUSH=1 -> hardware self-clears FLUSH after one clock cycle.
        """
        self.apb.write(APB_CTRL_OFF, APB_CTRL_FLUSH_BIT)  # EN=0, FLUSH=1
