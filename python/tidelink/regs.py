"""TideLink APB register map — single source of truth.

All register offsets and hardware constants for the tidelink_apb_regs module.
"""

# Hardware parameters
RAM_ADDR_W = 14
MAX_TOKENS = 1 << (RAM_ADDR_W - 2)  # 4096

# ── Region 0 (paddr[5]=0): Configuration and Status ─────────────────────────
REG_PAIR_BASE          = 0x000   # RW: pair base address (default TIDELINK_PAIR_BASE)
REG_REL_THRESHOLD      = 0x004   # RW: release threshold (default 20, 0 = immediate)
REG_PKT_WORD_LEN       = 0x008   # RO: packet word length sideband from FIFO
REG_TOKEN_COUNT        = 0x00C   # RO: available FIFO tokens (local)
REG_STATUS             = 0x010   # RO: [0] returner_busy, [1] overrun, [2] underrun, [3] master_error
REG_DOORBELL           = 0x014   # W1C: software doorbell trigger
REG_REL_ACC            = 0x018   # RO: pending unreleased tokens (debug)
REG_CTRL               = 0x01C   # RW: [0] EN, [1] FLUSH (self-clearing)

# ── Status register bit positions ────────────────────────────────────────
STATUS_RETURNER_BUSY   = 0
STATUS_OVERRUN         = 1
STATUS_UNDERRUN        = 2
STATUS_MASTER_ERROR    = 3
STATUS_PACKET_COMMITTED = 4

# ── CTRL register bit positions ──────────────────────────────────────────
CTRL_EN                = 0
CTRL_FLUSH             = 1

# ── Region 1 (paddr[5]=1): Incoming Token Receivers ─────────────────────────
REG_RELEASED_ACC       = 0x020   # W-add/R-clear: released tokens accumulator
REG_DOORBELL_RESP_ACC  = 0x024   # W-add/R-clear: doorbell response accumulator
REG_PAIR_TOKEN_COUNTER = 0x028   # RO: pair token counter
REG_PAIR_TOKEN_CONSUME = 0x02C   # WO: pair token consume
REG_PAIR_TOKEN_ENABLE  = 0x030   # RW: pair token counter enable

# ── Pair return target offsets (relative to pair_base) ───────────────────────
PAIR_RELEASED_TOKENS_OFFSET   = 0x020
PAIR_DOORBELL_RESPONSE_OFFSET = 0x024
PAIR_DOORBELL_OFFSET          = 0x014

# ── Backward-compatible aliases (OFF_ prefix used by py_pair_helpers) ────────
OFF_PAIR_BASE_ADDR     = REG_PAIR_BASE
OFF_PKT_WORD_LEN       = REG_PKT_WORD_LEN
OFF_TOKEN_COUNT        = REG_TOKEN_COUNT
OFF_STATUS             = REG_STATUS
OFF_DOORBELL           = REG_DOORBELL
OFF_RELEASED_TOKENS    = REG_RELEASED_ACC
OFF_DOORBELL_RESPONSE  = REG_DOORBELL_RESP_ACC
OFF_PAIR_TOKEN_COUNTER = REG_PAIR_TOKEN_COUNTER
OFF_PAIR_TOKEN_CONSUME = REG_PAIR_TOKEN_CONSUME
OFF_PAIR_TOKEN_ENABLE  = REG_PAIR_TOKEN_ENABLE
OFF_REL_THRESHOLD      = REG_REL_THRESHOLD
OFF_REL_ACC            = REG_REL_ACC
OFF_CTRL               = REG_CTRL
