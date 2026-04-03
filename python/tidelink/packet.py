"""TideLink FIFO packet data object."""

# ── Packet type constants (pkt_type field, 4 bits) ──────────────────────────
PKT_RD_REQ = 0x1   # Read request  — header only, no payload
PKT_WR_REQ = 0x2   # Write request — header + data payload
PKT_RD_RSP = 0x3   # Read response — header + data payload
PKT_WR_RSP = 0x4   # Write response — header only, no payload
PKT_ERROR  = 0xF   # Error response

PKT_TYPE_NAMES = {
    PKT_RD_REQ: "RD_REQ",
    PKT_WR_REQ: "WR_REQ",
    PKT_RD_RSP: "RD_RSP",
    PKT_WR_RSP: "WR_RSP",
    PKT_ERROR:  "ERROR",
}

# ── Burst type constants (burst_type field, 2 bits) ─────────────────────────
BURST_SINGLE = 0
BURST_INCR   = 1
BURST_WRAP   = 2

# ── Status constants (status field, 2 bits) ─────────────────────────────────
STATUS_OKAY    = 0
STATUS_ERROR   = 1
STATUS_TIMEOUT = 2

# ── Size constants (size field, 3 bits — mirrors AHB HSIZE) ─────────────────
SIZE_BYTE     = 0
SIZE_HALFWORD = 1
SIZE_WORD     = 2


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


# ── Field encoding / decoding helpers ────────────────────────────────────────

def _mask(width):
    return (1 << width) - 1


def _encode_control(pkt_type, src_id, dest_id, tag, status, burst_type):
    """Pack the Control word (Word 1) from its fields."""
    return (
        ((pkt_type   & _mask(4))  << 28) |
        ((src_id     & _mask(8))  << 20) |
        ((dest_id    & _mask(8))  << 12) |
        ((tag        & _mask(8))  <<  4) |
        ((status     & _mask(2))  <<  2) |
        ((burst_type & _mask(2))  <<  0)
    )


def _decode_control(word):
    """Unpack the Control word into a dict of fields."""
    return {
        "pkt_type":   (word >> 28) & _mask(4),
        "src_id":     (word >> 20) & _mask(8),
        "dest_id":    (word >> 12) & _mask(8),
        "tag":        (word >>  4) & _mask(8),
        "status":     (word >>  2) & _mask(2),
        "burst_type": (word >>  0) & _mask(2),
    }


def _encode_length_size(length, size):
    """Pack Word 3: length[15:3], size[2:0]."""
    return ((length & _mask(13)) << 3) | (size & _mask(3))


def _decode_length_size(word):
    """Unpack Word 3 into (length, size)."""
    return (word >> 3) & _mask(13), word & _mask(3)


# ── DescriptorPacket ─────────────────────────────────────────────────────────

class DescriptorPacket(FifoPacket):
    """4-word descriptor header packet used by the TideLink mailbox.

    Word 0: FIFO length (N) — number of 32-bit words that follow
    Word 1: Control — pkt_type | src_id | dest_id | tag | status | burst_type
    Word 2: dest_addr[31:0]
    Word 3: length[15:3] | size[2:0]
    Words 4..N: Data payload (present for WR_REQ and RD_RSP)
    """

    # Number of header words *after* the FIFO length word
    _HEADER_WORDS = 3

    def __init__(self, pkt_type=PKT_RD_REQ, src_id=0, dest_id=0, tag=0,
                 dest_addr=0, length=1, size=SIZE_WORD, status=STATUS_OKAY,
                 burst_type=BURST_SINGLE, payload=None):
        self.pkt_type   = pkt_type
        self.src_id     = src_id
        self.dest_id    = dest_id
        self.tag        = tag
        self.dest_addr  = dest_addr
        self.beat_length = length    # beat count (descriptor field)
        self.size       = size
        self.status     = status
        self.burst_type = burst_type
        self.payload    = list(payload) if payload is not None else []

        # Initialise base FifoPacket with the words after the length word
        super().__init__(data=self._build_data())

    # ── Encoding ─────────────────────────────────────────────────────────

    def _build_data(self):
        """Build the list of words that follow the FIFO length word."""
        ctrl = _encode_control(self.pkt_type, self.src_id, self.dest_id,
                               self.tag, self.status, self.burst_type)
        ls = _encode_length_size(self.beat_length, self.size)
        return [ctrl, self.dest_addr & 0xFFFFFFFF, ls] + self.payload

    def _refresh(self):
        """Rebuild the underlying FifoPacket data after field changes."""
        self.data = self._build_data()

    def encode(self):
        """Return the full list of 32-bit words (FIFO length + header + payload)."""
        self._refresh()
        return self.all_words

    # ── Decoding ─────────────────────────────────────────────────────────

    @classmethod
    def decode(cls, words):
        """Create a DescriptorPacket from a list of 32-bit words.

        *words* must start with the FIFO length word (Word 0).
        """
        if len(words) < 4:
            raise ValueError(
                f"Need at least 4 words (length + 3 header), got {len(words)}")

        fifo_len = words[0]
        if len(words) < fifo_len + 1:
            raise ValueError(
                f"FIFO length field says {fifo_len} words follow, "
                f"but only {len(words) - 1} provided")

        ctrl_fields = _decode_control(words[1])
        dest_addr   = words[2] & 0xFFFFFFFF
        beat_length, size = _decode_length_size(words[3])
        payload     = list(words[4:fifo_len + 1])

        return cls(
            pkt_type   = ctrl_fields["pkt_type"],
            src_id     = ctrl_fields["src_id"],
            dest_id    = ctrl_fields["dest_id"],
            tag        = ctrl_fields["tag"],
            status     = ctrl_fields["status"],
            burst_type = ctrl_fields["burst_type"],
            dest_addr  = dest_addr,
            length     = beat_length,
            size       = size,
            payload    = payload,
        )

    # ── Factory methods ──────────────────────────────────────────────────

    @classmethod
    def read_request(cls, dest_addr, length=1, size=SIZE_WORD, src_id=0,
                     dest_id=0, tag=0, burst_type=BURST_SINGLE):
        """Create a RD_REQ packet (header only, no payload)."""
        return cls(pkt_type=PKT_RD_REQ, src_id=src_id, dest_id=dest_id,
                   tag=tag, dest_addr=dest_addr, length=length, size=size,
                   burst_type=burst_type)

    @classmethod
    def write_request(cls, dest_addr, payload, length=None, size=SIZE_WORD,
                      src_id=0, dest_id=0, tag=0, burst_type=BURST_SINGLE):
        """Create a WR_REQ packet (header + data payload).

        If *length* is not given it defaults to ``len(payload)``.
        """
        if length is None:
            length = len(payload)
        return cls(pkt_type=PKT_WR_REQ, src_id=src_id, dest_id=dest_id,
                   tag=tag, dest_addr=dest_addr, length=length, size=size,
                   burst_type=burst_type, payload=payload)

    @classmethod
    def read_response(cls, dest_addr, payload, length=None, size=SIZE_WORD,
                      src_id=0, dest_id=0, tag=0, status=STATUS_OKAY,
                      burst_type=BURST_SINGLE):
        """Create a RD_RSP packet (header + data payload)."""
        if length is None:
            length = len(payload)
        return cls(pkt_type=PKT_RD_RSP, src_id=src_id, dest_id=dest_id,
                   tag=tag, dest_addr=dest_addr, length=length, size=size,
                   status=status, burst_type=burst_type, payload=payload)

    @classmethod
    def write_response(cls, dest_addr=0, src_id=0, dest_id=0, tag=0,
                       status=STATUS_OKAY, burst_type=BURST_SINGLE):
        """Create a WR_RSP packet (header only, no payload)."""
        return cls(pkt_type=PKT_WR_RSP, src_id=src_id, dest_id=dest_id,
                   tag=tag, dest_addr=dest_addr, length=0, size=SIZE_WORD,
                   status=status, burst_type=burst_type)

    @classmethod
    def error_response(cls, dest_addr=0, src_id=0, dest_id=0, tag=0,
                       burst_type=BURST_SINGLE):
        """Create an ERROR packet."""
        return cls(pkt_type=PKT_ERROR, src_id=src_id, dest_id=dest_id,
                   tag=tag, dest_addr=dest_addr, length=0, size=SIZE_WORD,
                   status=STATUS_ERROR, burst_type=burst_type)

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
            f"len={self.beat_length}",
            f"size={self.size}",
        ]
        if self.payload:
            parts.append(f"payload=[{', '.join(f'0x{w:08X}' for w in self.payload)}]")
        return ", ".join(parts) + ")"
