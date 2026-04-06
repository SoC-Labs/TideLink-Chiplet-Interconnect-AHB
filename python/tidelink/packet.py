"""TideLink FIFO packet data object.

Packet format (2-word header + optional payload):
  Word 0: length[31:20] | pkt_type[19:18] | src_id[17:13] | dest_id[12:8] | tag[7:0]
  Word 1: dest_addr[31:0]
  Words 2..N+1: Data payload (type-specific)

length (N) = payload word count only; total FIFO occupancy = N + 2.
"""

# ── Packet type constants (pkt_type field, 2 bits) ──────────────────────────
PKT_RD_REQ   = 0b00   # Read request  — N=0 (single) or N=1 (burst descriptor)
PKT_WR_REQ   = 0b01   # Write request — N data words as payload
PKT_RSP      = 0b10   # Response      — read data, write ack, or error
PKT_RESERVED = 0b11   # Reserved for future use

PKT_TYPE_NAMES = {
    PKT_RD_REQ:   "RD_REQ",
    PKT_WR_REQ:   "WR_REQ",
    PKT_RSP:      "RSP",
    PKT_RESERVED: "RESERVED",
}

# ── Burst descriptor constants (RD_REQ payload word, N=1) ──────────────────
# beat_count[31:3] | size[2:0]
SIZE_BYTE     = 0
SIZE_HALFWORD = 1
SIZE_WORD     = 2


# ── Field encoding / decoding helpers ────────────────────────────────────────

def _mask(width):
    return (1 << width) - 1


def encode_word0(length, pkt_type=PKT_RD_REQ, src_id=0, dest_id=0, tag=0):
    """Pack Word 0 from its fields."""
    return (
        ((length   & _mask(12)) << 20) |
        ((pkt_type & _mask(2))  << 18) |
        ((src_id   & _mask(5))  << 13) |
        ((dest_id  & _mask(5))  <<  8) |
        ((tag      & _mask(8))  <<  0)
    )


def decode_word0(word):
    """Unpack Word 0 into a dict of fields."""
    return {
        "length":   (word >> 20) & _mask(12),
        "pkt_type": (word >> 18) & _mask(2),
        "src_id":   (word >> 13) & _mask(5),
        "dest_id":  (word >>  8) & _mask(5),
        "tag":      (word >>  0) & _mask(8),
    }


def encode_burst_descriptor(beat_count, size=SIZE_WORD):
    """Encode a burst read descriptor payload word (RD_REQ N=1)."""
    return ((beat_count & _mask(29)) << 3) | (size & _mask(3))


def decode_burst_descriptor(word):
    """Decode a burst read descriptor payload word into (beat_count, size)."""
    return (word >> 3) & _mask(29), word & _mask(3)


# ── FifoPacket ───────────────────────────────────────────────────────────────

class FifoPacket:
    """Represents a packet written into / read from the TideLink FIFO.

    2-word header (packed Word 0 + dest_addr) followed by payload data words.
    """

    def __init__(self, data=None, pkt_type=PKT_RD_REQ, src_id=0, dest_id=0,
                 tag=0, dest_addr=0):
        self.data      = data if data is not None else []
        self.pkt_type  = pkt_type
        self.src_id    = src_id
        self.dest_id   = dest_id
        self.tag       = tag
        self.dest_addr = dest_addr

    @property
    def length(self):
        """Number of payload data words (excludes the 2-word header)."""
        return len(self.data)

    @property
    def total_words(self):
        """Total SRAM words consumed: 2 (header) + N (payload)."""
        return self.length + 2

    @property
    def word0(self):
        """Packed Word 0 value."""
        return encode_word0(self.length, self.pkt_type, self.src_id,
                            self.dest_id, self.tag)

    @property
    def all_words(self):
        """Word 0 (packed header), Word 1 (dest_addr), then payload."""
        return [self.word0, self.dest_addr] + self.data

    @property
    def addrs(self):
        """Byte addresses for each beat (0x0000, 0x0004, ...)."""
        return [i * 4 for i in range(self.total_words)]

    @classmethod
    def from_words(cls, words):
        """Create a FifoPacket from a raw list of 32-bit words.

        *words* must start with Word 0 (packed header).
        """
        if len(words) < 2:
            raise ValueError(
                f"Need at least 2 words (header + dest_addr), got {len(words)}")

        fields = decode_word0(words[0])
        n = fields["length"]
        if len(words) < n + 2:
            raise ValueError(
                f"Length field says {n} payload words, "
                f"but only {len(words) - 2} provided")

        return cls(
            data      = list(words[2:n + 2]),
            pkt_type  = fields["pkt_type"],
            src_id    = fields["src_id"],
            dest_id   = fields["dest_id"],
            tag       = fields["tag"],
            dest_addr = words[1] & 0xFFFFFFFF,
        )


# ── DescriptorPacket ─────────────────────────────────────────────────────────

class DescriptorPacket(FifoPacket):
    """High-level packet constructor with factory methods for each type.

    Word 0: length[31:20] | pkt_type[19:18] | src_id[17:13] | dest_id[12:8] | tag[7:0]
    Word 1: dest_addr[31:0]
    Words 2+: Payload (type-specific)
    """

    def __init__(self, pkt_type=PKT_RD_REQ, src_id=0, dest_id=0, tag=0,
                 dest_addr=0, payload=None):
        payload = list(payload) if payload is not None else []
        super().__init__(
            data=payload,
            pkt_type=pkt_type,
            src_id=src_id,
            dest_id=dest_id,
            tag=tag,
            dest_addr=dest_addr,
        )

    # ── Factory methods ──────────────────────────────────────────────────

    @classmethod
    def read_request(cls, dest_addr, src_id=0, dest_id=0, tag=0):
        """Create a single-read RD_REQ packet (N=0, 2 credits)."""
        return cls(pkt_type=PKT_RD_REQ, src_id=src_id, dest_id=dest_id,
                   tag=tag, dest_addr=dest_addr)

    @classmethod
    def burst_read_request(cls, dest_addr, beat_count, size=SIZE_WORD,
                           src_id=0, dest_id=0, tag=0):
        """Create a burst-read RD_REQ packet (N=1, 3 credits)."""
        descriptor = encode_burst_descriptor(beat_count, size)
        return cls(pkt_type=PKT_RD_REQ, src_id=src_id, dest_id=dest_id,
                   tag=tag, dest_addr=dest_addr, payload=[descriptor])

    @classmethod
    def write_request(cls, dest_addr, payload, src_id=0, dest_id=0, tag=0):
        """Create a WR_REQ packet (N=len(payload), N+2 credits)."""
        return cls(pkt_type=PKT_WR_REQ, src_id=src_id, dest_id=dest_id,
                   tag=tag, dest_addr=dest_addr, payload=payload)

    @classmethod
    def response(cls, dest_addr=0, payload=None, src_id=0, dest_id=0, tag=0):
        """Create a RSP packet. N=0 for write ack, N>0 for read data."""
        return cls(pkt_type=PKT_RSP, src_id=src_id, dest_id=dest_id,
                   tag=tag, dest_addr=dest_addr, payload=payload)

    @classmethod
    def error_response(cls, src_id=0, dest_id=0, tag=0):
        """Create an error RSP packet (N=0, dest_addr=0xFFFFFFFF)."""
        return cls(pkt_type=PKT_RSP, src_id=src_id, dest_id=dest_id,
                   tag=tag, dest_addr=0xFFFFFFFF)

    # ── Display ──────────────────────────────────────────────────────────

    @property
    def pkt_type_name(self):
        return PKT_TYPE_NAMES.get(self.pkt_type, f"UNKNOWN(0x{self.pkt_type:X})")

    def __repr__(self):
        parts = [
            f"DescriptorPacket({self.pkt_type_name}",
            f"src={self.src_id:#x}",
            f"dest={self.dest_id:#x}",
            f"tag={self.tag:#x}",
            f"addr={self.dest_addr:#010x}",
            f"len={self.length}",
        ]
        if self.data:
            parts.append(f"payload=[{', '.join(f'0x{w:08X}' for w in self.data)}]")
        return ", ".join(parts) + ")"
