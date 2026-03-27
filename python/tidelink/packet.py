"""TideLink FIFO packet data object."""


class FifoPacket:
    """Represents a packet written into / read from the TideLink FIFO.

    The first beat carries the length word, subsequent beats carry data.
    """

    def __init__(self, data=None):
        self.data = data if data is not None else []

    @property
    def length(self):
        """Number of data words (excludes the length word itself)."""
        return len(self.data)

    @property
    def total_words(self):
        """Total SRAM words consumed: 1 (length word) + N (data words)."""
        return self.length + 1

    @property
    def all_words(self):
        """Length word followed by data words."""
        return [self.length] + self.data

    @property
    def addrs(self):
        """Byte addresses for each beat (0x0000, 0x0004, ...)."""
        return [i * 4 for i in range(self.length + 1)]
