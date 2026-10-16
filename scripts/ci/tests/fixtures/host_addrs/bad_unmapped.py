"""FIXTURE (must FAIL check_host_addrs): offsets that are not registers (rule R1)."""
OFF_STATUS_TYPO = 0x2012                   # STATUS is 0x2010; 0x2012 is not a register
OFF_NOWHERE = 0x2F00                       # inside the 15-bit APB space but nothing lives there


def go(rd):
    return rd(0x84032111)                  # SoC literal inside the die_a APB aperture, offset 0x2111: unmapped
