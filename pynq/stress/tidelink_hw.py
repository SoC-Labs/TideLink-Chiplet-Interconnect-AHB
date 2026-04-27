#-----------------------------------------------------------------------------
# TideLink FPGA Stress Suite - Hardware abstraction layer
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Synchronous blocking wrapper over TidelinkOverlay (Wave C1).
# Mimics the patterns in pynq/test_loopback_pair.py but exposes a clean
# per-method API suitable for calling from the stress test catalogue.
#
# Lazy import: TidelinkOverlay is imported at construction time only, so
# this module can be imported on machines without the PYNQ stack installed.
#-----------------------------------------------------------------------------

import time

# Register map — single source of truth
from tidelink.regs import (
    MAX_CREDITS,
    REG_CREDIT_COUNT, REG_STATUS, REG_CTRL, REG_PAIR_BASE,
    REG_REL_THRESHOLD, REG_REL_ACC,
    REG_DOORBELL, REG_DOORBELL_RESP_ACC,
    REG_RELEASED_ACC, REG_PAIR_CREDIT_COUNTER,
    STATUS_RETURNER_BUSY, CTRL_FLUSH, CTRL_EN,
)

# Link-state mirror register offset within the APB config window.
# Written by hardware when tl_local_link_state_o changes. 5-bit field.
REG_LINK_STATE_MIRROR = 0x034


class TidelinkTimeout(Exception):
    pass


class TidelinkHw:
    """Synchronous hardware abstraction over a single TideLink overlay port.

    Args:
        overlay : TidelinkOverlay instance (Wave C1).
        role    : 'die_a' or 'die_b' — selects which overlay port to use.
        timeout_s : default poll timeout for wait_* methods.
    """

    def __init__(self, overlay, role='die_a', timeout_s=0.5):
        self.overlay   = overlay
        self.role      = role
        self.timeout_s = timeout_s
        # The overlay exposes apertures: apb, ahb_tx, ahb_fifo, ahb_ptp, strap
        self.apb      = overlay.apb
        self.ahb_tx   = overlay.ahb_tx
        self.ahb_fifo = overlay.ahb_fifo

    # ── APB register helpers ─────────────────────────────────────────────────

    def cfg_read(self, offset):
        return self.apb.read(offset)

    def cfg_write(self, offset, value):
        self.apb.write(offset, value)

    # ── Credit / status ──────────────────────────────────────────────────────

    def read_credit_count(self):
        """Current free FIFO credits (local side)."""
        return self.cfg_read(REG_CREDIT_COUNT)

    def read_max_credits(self):
        return MAX_CREDITS

    def read_link_state(self):
        """5-bit quantised link state from tl_local_link_state_o mirror reg."""
        return self.cfg_read(REG_LINK_STATE_MIRROR) & 0x1F

    # ── Flow control ─────────────────────────────────────────────────────────

    def set_rel_threshold(self, threshold):
        self.cfg_write(REG_REL_THRESHOLD, threshold)

    def flush(self):
        """Assert FLUSH bit (self-clearing) to drain the returner."""
        ctrl = self.cfg_read(REG_CTRL)
        self.cfg_write(REG_CTRL, ctrl | (1 << CTRL_FLUSH))

    def wait_returner_idle(self, timeout_ms=200):
        """Block until STATUS.returner_busy == 0 or raise TidelinkTimeout."""
        deadline = time.monotonic() + timeout_ms / 1000.0
        while time.monotonic() < deadline:
            if not (self.cfg_read(REG_STATUS) & (1 << STATUS_RETURNER_BUSY)):
                return
            time.sleep(0.001)
        raise TidelinkTimeout("returner still busy after timeout")

    # ── Pair base address ────────────────────────────────────────────────────

    def set_pair_base(self, addr):
        self.cfg_write(REG_PAIR_BASE, addr)

    def read_pair_base(self):
        return self.cfg_read(REG_PAIR_BASE)

    # ── Packet I/O ───────────────────────────────────────────────────────────

    def write_packet(self, data):
        """Write a packet through ahb_tx. data is a list of 32-bit words."""
        self.ahb_tx.write(0x0000, len(data))
        for i, word in enumerate(data):
            self.ahb_tx.write((i + 1) * 4, word)

    def read_packet(self):
        """Read a packet from ahb_fifo. Returns list of 32-bit data words."""
        # Trigger length capture by touching offset 0
        self.ahb_fifo.read(0x0000)
        pkt_len = self.cfg_read(0x008)  # REG_PKT_WORD_LEN
        return [self.ahb_fifo.read((i + 1) * 4) for i in range(pkt_len)]

    # ── Doorbell ─────────────────────────────────────────────────────────────

    def ring_doorbell(self):
        """Write 1 to the software doorbell register (W1C)."""
        self.cfg_write(REG_DOORBELL, 1)

    def read_doorbell_resp(self):
        """Read-clear the doorbell response accumulator."""
        return self.cfg_read(REG_DOORBELL_RESP_ACC)

    def read_released_acc(self):
        """Read-clear the released credits accumulator."""
        return self.cfg_read(REG_RELEASED_ACC)

    def read_pair_credit_counter(self):
        return self.cfg_read(REG_PAIR_CREDIT_COUNTER)

    # ── Convenience reset / sanity ───────────────────────────────────────────

    def reset_soft(self):
        """Write EN=0 then EN=1 to cycle the enable bit."""
        self.cfg_write(REG_CTRL, 0)
        time.sleep(0.001)
        self.cfg_write(REG_CTRL, 1 << CTRL_EN)

    def sanity_check(self):
        """Return True if credit count is in [0, MAX_CREDITS]."""
        c = self.read_credit_count()
        return 0 <= c <= MAX_CREDITS
