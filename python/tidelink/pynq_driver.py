"""PYNQ MMIO-based TideLink driver for Zynq FPGA hardware testing.

Requires the pynq package (available on Pynq-Z2 boards).

Usage:
    from tidelink.pynq_driver import PynqTidelinkDriver

    tl = PynqTidelinkDriver(
        fifo_base_addr=0x4000_0000,
        cfg_base_addr=0x4001_0000,
    )
    tl.write_packet([0xAA, 0xBB, 0xCC])
    credits = tl.read_credit_count()
"""

from tidelink.driver import TidelinkDriver


class PynqTidelinkDriver(TidelinkDriver):
    """TideLink driver using PYNQ MMIO for register and FIFO access.

    Args:
        fifo_base_addr: Physical base address of the FIFO AHB slave port.
        cfg_base_addr:  Physical base address of the config AHB slave port
                        (goes through the AHB-to-APB bridge).
        fifo_range:     Address range for the FIFO MMIO region.
        cfg_range:      Address range for the config MMIO region.
    """

    def __init__(self, fifo_base_addr, cfg_base_addr,
                 fifo_range=0x4000, cfg_range=0x1000):
        from pynq import MMIO
        self.fifo_mmio = MMIO(fifo_base_addr, fifo_range)
        self.cfg_mmio = MMIO(cfg_base_addr, cfg_range)

    def cfg_read(self, offset):
        return self.cfg_mmio.read(offset)

    def cfg_write(self, offset, data):
        self.cfg_mmio.write(offset, data)

    def fifo_read(self, offset):
        return self.fifo_mmio.read(offset)

    def fifo_write(self, offset, data):
        self.fifo_mmio.write(offset, data)
