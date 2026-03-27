"""Abstract TideLink driver interface.

Subclassed by PynqTidelinkDriver (hardware) and potentially a cocotb
wrapper. Provides default implementations for common operations built
on four abstract primitives: cfg_read, cfg_write, fifo_read, fifo_write.
"""

import time
from abc import ABC, abstractmethod

from tidelink.regs import REG_PKT_WORD_LEN, REG_TOKEN_COUNT, REG_STATUS


class TidelinkDriver(ABC):
    """Abstract driver for a single TideLink instance."""

    @abstractmethod
    def cfg_read(self, offset):
        """Read a 32-bit value from the config register space."""

    @abstractmethod
    def cfg_write(self, offset, data):
        """Write a 32-bit value to the config register space."""

    @abstractmethod
    def fifo_read(self, offset):
        """Read a 32-bit value from the FIFO data space."""

    @abstractmethod
    def fifo_write(self, offset, data):
        """Write a 32-bit value to the FIFO data space."""

    # ── Default implementations using the four primitives ────────────────

    def read_token_count(self):
        """Read the current FIFO token count."""
        return self.cfg_read(REG_TOKEN_COUNT)

    def read_status_busy(self):
        """Return True if the returner is currently busy."""
        return bool(self.cfg_read(REG_STATUS) & 1)

    def wait_returner_idle(self, timeout_ms=100):
        """Poll until the returner is idle or timeout."""
        deadline = time.time() + timeout_ms / 1000
        while time.time() < deadline:
            if not self.read_status_busy():
                return
            time.sleep(0.001)
        raise TimeoutError("Returner still busy after timeout")

    def write_packet(self, data):
        """Write a packet into the FIFO (length word + data words)."""
        self.fifo_write(0x0000, len(data))
        for i, word in enumerate(data):
            self.fifo_write((i + 1) * 4, word)

    def read_packet(self):
        """Read a packet from the FIFO. Returns list of data words."""
        # Trigger the length capture by reading address 0
        self.fifo_read(0x0000)
        pkt_len = self.cfg_read(REG_PKT_WORD_LEN)
        data = []
        for i in range(pkt_len):
            data.append(self.fifo_read((i + 1) * 4))
        return data
