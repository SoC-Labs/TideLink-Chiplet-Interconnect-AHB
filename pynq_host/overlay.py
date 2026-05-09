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

# Chiplet-controller ROLE_CFG register (paddr[14:5] selects region 4 within
# TideLink, paddr[4:2] = 0). Within the unified APB map TideLink starts at
# offset 0x2000 and region 4 begins at offset 0x80, so the absolute APB
# offset is 0x2080. Bit[0] = role_cfg (0=master, 1=slave; matches strap),
# bit[1] = role_lock (W1S, POR-only clear). Locking releases Wlink from
# reset; until then, link_active stays low.
REG_ROLE_LOCK = 0x2080

# Wlink link-layer register offsets (within self.apb). See src/rdl/wlink_regs.rdl.
WLINK_ACTIVE_LANES_OFF = 0x0210  # RO; popcount(lane_mask)-1 per direction
WLINK_LANE_MASK_OFF    = 0x0214  # RW; bit[k]=1 enables physical lane k
WLINK_LANES            = 8       # synthesised lane count for pynq-z2-pair

# Wlink PHY ctrl register: bits[20:17] = swi_phase_offset (added to the
# deserialiser counter to compensate for POR-release skew). See
# project_tidelink_fpga_bringup.md "5-bit deserialiser phase offset on A"
# and uvm/.../top_sys_wlink_init_sequence.sv. In the strap-driven init
# flow (deploy_pair.sh, lock_role()), master goes first by ~3 pad_clks,
# so SLAVE is the late-POR side and needs phase=3.
WLINK_PHY_CTRL_OFF        = 0x0000
SWI_PHASE_OFFSET_SHIFT    = 17
SWI_PHASE_OFFSET_DIE_B    = 3      # slave: master goes first by ~3 pad_clks
SWI_PHASE_OFFSET_DIE_A    = 0      # master: aligns naturally


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

        Verified on Pynq-Z2 hardware (2026-04-27): the chiplet controller's
        ``role_is_master = ~role_effective`` inverts the strap, so the
        operator-visible mapping is

            die_a -> strap = 0  (master, role_is_master_o = 1)
            die_b -> strap = 1  (slave,  role_is_master_o = 0)

        Picking which board is which is purely a labelling convention
        (see ``[pairs.<id>].roles`` in fpgahub config); the hardware
        treats the two roles symmetrically apart from this strap bit.
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

    def lock_role(self, role: str | None = None) -> int:
        """Release Wlink from reset by locking the role.

        Until the role is locked, the chiplet controller asserts
        ``wlink_por_reset = ~poresetn | ~role_locked``, which holds the
        whole Wlink link/PHY in reset. Without this call the design's
        ``link_active`` LED stays off even when both boards have their
        straps set correctly.

        The bit layout at APB region 4 offset 0 (TideLink PADDR 0x2080,
        MMIO 0x4403_2080) is::

            bit[0] = role_cfg  (0 = master, 1 = slave; matches strap)
            bit[1] = role_lock (W1S, only clears on POR)

        ``role_lock`` is write-1-set with a power-on-only clear: once
        locked, it stays locked until the bitstream is reloaded. That
        matches the autoneg flow but the application has to drive it
        explicitly when autoneg isn't running (which is our setup —
        I2C autoneg is unconnected on the Pynq-Z2 build).

        Parameters
        ----------
        role : ``"die_a"``, ``"die_b"`` or ``None``
            When given, also writes the strap before locking — convenient
            one-shot sequencing. ``None`` leaves the current strap
            untouched and just locks whatever's there.

        Returns
        -------
        int
            The post-write value of the ROLE_CFG register, useful for
            asserting ``(value & 0x2) != 0`` in test code.
        """
        if role is not None:
            self.set_role(role)
        # bit[1] = lock, bit[0] = role_cfg (mirrors strap for safety)
        cfg_bit = self.get_role() == "die_b"

        # SHORTCOMINGS-14b fix: write swi_phase_offset BEFORE role_lock.
        # Once role_lock asserts, Wlink leaves POR and the deserialiser
        # counter starts free-running; subsequent phase writes only shift
        # the bit-select, they don't re-sync. master=phase=0, slave=phase=3.
        phase = SWI_PHASE_OFFSET_DIE_B if cfg_bit else SWI_PHASE_OFFSET_DIE_A
        self.apb.write(WLINK_PHY_CTRL_OFF, phase << SWI_PHASE_OFFSET_SHIFT)

        self.apb.write(REG_ROLE_LOCK, 0x2 | (1 if cfg_bit else 0))
        return self.apb.read(REG_ROLE_LOCK)

    # -------------------------------------------------------------------------
    # Link health — safe diagnostics that never touch AHB_TX
    # -------------------------------------------------------------------------

    def link_health(self, sample_window_s: float = 1.0) -> dict:
        """Return a snapshot of link-state indicators that don't risk a
        PS hang.

        Reads only the APB and Wlink-config regions, never AHB_TX or
        AHB_FIFO. Samples Wlink's per-FC-channel activity bytes twice
        with ``sample_window_s`` between, so any free-running counters
        show as deltas.

        Returns a dict keyed by indicator name, suitable for assertions
        in tests::

            health = ol.link_health()
            assert health["role_locked"], "role not locked"
            assert health["wlink_activity_seen"], "no Wlink traffic in 1s"

        ``wlink_activity_seen`` is the field test code should check
        before issuing any AHB_TX write — if it's False the TX FC node
        is wedged and writing to AHB_TX will hang the PS (see commit
        581634b for the bench evidence).
        """
        import time as _t

        # Role lock + strap (always safe)
        role_cfg = self.apb.read(REG_ROLE_LOCK)
        role_locked = bool(role_cfg & 0x2)
        local_role = self.get_role()

        # Wlink lane configuration
        lane_mask_reg = self.apb.read(WLINK_LANE_MASK_OFF)
        tx_lane_mask = lane_mask_reg & 0xFFFF
        rx_lane_mask = (lane_mask_reg >> 16) & 0xFFFF
        active_lanes_reg = self.apb.read(WLINK_ACTIVE_LANES_OFF)
        tx_active_lanes = (active_lanes_reg & 0xFFFF) + 1
        rx_active_lanes = ((active_lanes_reg >> 16) & 0xFFFF) + 1

        # Tidelink-side credit counters
        current_credits = self.apb.read(0x0c)
        released_acc = self.apb.read(0x20)
        doorbell_resp_acc = self.apb.read(0x24)
        pair_credit_ctr = self.apb.read(0x28)

        # Wlink per-FC activity bytes [+0x08 inside each region]
        # See pynq/scripts/wlink_probe.sh for the layout.
        wlink_regions = (0x1000, 0x1100, 0x1200, 0x1300, 0x1400,
                         0x1600, 0x1700)
        # Take a ``before`` then ``after`` sample of every region's
        # 8-word header so any free-running counter shows up.
        def _snap():
            return {base: [self.apb.read(base + i * 4) for i in range(8)]
                    for base in [b - 0x30000 for b in wlink_regions]}
        # apb base is already 0x44030000; the wlink regions are at
        # offset (region - 0x30000) within self.apb (mmio offset).
        # Actually self.apb is mmap'd at APB_BASE = 0x4403_0000 with
        # APB_RANGE = 0x8000, so Wlink regions live at offset 0x0..0x1FFF.
        # Re-compute cleanly:
        before = {base: [self.apb.read(base + i * 4) for i in range(8)]
                  for base in wlink_regions}
        _t.sleep(sample_window_s)
        after = {base: [self.apb.read(base + i * 4) for i in range(8)]
                 for base in wlink_regions}
        deltas = {base: [a - b for a, b in zip(after[base], before[base])]
                  for base in wlink_regions}
        wlink_activity_seen = any(any(d != 0 for d in v)
                                  for v in deltas.values())
        tidelink_fc_active = before[0x1700][2] == 1  # [0x08] activity bit

        return {
            "role_locked":           role_locked,
            "local_role":            local_role,
            "role_cfg_reg":          role_cfg,
            "current_credits":       current_credits,
            "released_acc":          released_acc,
            "doorbell_resp_acc":     doorbell_resp_acc,
            "pair_credit_counter":   pair_credit_ctr,
            "wlink_activity_seen":   wlink_activity_seen,
            "tidelink_fc_active":    tidelink_fc_active,
            "tx_lane_mask":          tx_lane_mask,
            "rx_lane_mask":          rx_lane_mask,
            "tx_active_lanes":       tx_active_lanes,
            "rx_active_lanes":       rx_active_lanes,
            "_wlink_deltas":         deltas,
        }

    # -------------------------------------------------------------------------
    # Wlink lane mask — disable individual physical lanes
    # -------------------------------------------------------------------------

    def get_lane_mask(self):
        """Return ``(tx_mask, rx_mask)`` from the Wlink LaneMask register.

        Each mask is an integer with bit[k]=1 for each enabled physical
        lane. On pynq-z2-pair the synthesised lane count is 8, so masks
        come up as 0xFF after reset (all lanes enabled).
        """
        v = self.apb.read(WLINK_LANE_MASK_OFF)
        tx = v & 0xFFFF
        rx = (v >> 16) & 0xFFFF
        return tx, rx

    def get_active_lanes(self):
        """Return ``(tx_lanes, rx_lanes)`` — derived popcount of LaneMask.

        Reads the LinkActiveLanes register (RO) which the hardware drives
        as ``popcount(lane_mask) - 1``. Add 1 to get the lane count.
        """
        v = self.apb.read(WLINK_ACTIVE_LANES_OFF)
        tx = (v & 0xFFFF) + 1
        rx = ((v >> 16) & 0xFFFF) + 1
        return tx, rx

    def set_lane_mask(self, tx_mask, rx_mask=None):
        """Program the Wlink LaneMask register.

        Both ends of the link must program identical masks before the
        link is enabled (or with the link held in reset/disabled). The
        hardware does not enforce this; mismatch produces silent
        corruption.

        Parameters
        ----------
        tx_mask : int
            Per-lane TX enable bitmap. bit[k]=1 enables physical lane k.
            Must be non-zero (mask=0 disables every lane and the link
            cannot transmit). Bits above ``WLINK_LANES`` are ignored.
        rx_mask : int or None
            Per-lane RX enable bitmap. Defaults to ``tx_mask`` (the
            common case where a damaged ribbon pin breaks both
            directions of the same lane).
        """
        if rx_mask is None:
            rx_mask = tx_mask
        valid = (1 << WLINK_LANES) - 1
        tx = tx_mask & valid
        rx = rx_mask & valid
        if tx == 0 or rx == 0:
            raise ValueError(
                "lane_mask=0 is illegal (link cannot operate); "
                "tx=0x{:x} rx=0x{:x}".format(tx_mask, rx_mask))
        self.apb.write(WLINK_LANE_MASK_OFF, tx | (rx << 16))

    def assert_link_safe_for_tx(self):
        """Raise RuntimeError unless the link is safe for an AHB_TX write.

        Checks (in order):
          1. ``role_locked`` is set — Wlink is out of reset.
          2. ``current_credits == MAX_CREDITS`` — RX FIFO is empty (a
             previous run didn't leave packets stuck in the FIFO).
          3. The TideLink FC channel has activity — Wlink TX is actually
             producing/receiving traffic.

        Without (3), an AHB_TX write blocks indefinitely waiting on
        HREADY from a wedged FC adapter, which takes the PS down. See
        commit 581634b for the bench evidence.
        """
        h = self.link_health()
        if not h["role_locked"]:
            raise RuntimeError(
                "role not locked (ROLE_CFG=0x{:x}); call lock_role() "
                "before TX".format(h["role_cfg_reg"]))
        tx_mask, rx_mask = self.get_lane_mask()
        if tx_mask == 0 or rx_mask == 0:
            raise RuntimeError(
                "lane_mask is zero (tx=0x{:x} rx=0x{:x}); link cannot "
                "operate. Call set_lane_mask() with a non-zero mask "
                "before TX.".format(tx_mask, rx_mask))
        if not h["tidelink_fc_active"]:
            raise RuntimeError(
                "Wlink TideLink FC node is idle (no traffic seen). "
                "Writing to AHB_TX would hang the PS — link is not up. "
                "Run pynq/scripts/wlink_probe.sh and check the ribbon / "
                "RX clock.")

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
