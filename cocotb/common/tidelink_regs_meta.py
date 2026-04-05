"""Register metadata for TideLink FIFO config registers.

Used by hal_bridge.py for shadow-buffer pre-population and replay.
Matches the TIDELINK_CFG_TypeDef struct in src/sw/tidelink.h.
"""

ADDRMAP_NAME = "tidelink_cfg"
REG_SPACE_SIZE = 0x034  # 13 registers, 0x000-0x030

# Read-write registers (pre-populated for RMW, diffed for replay)
RW_OFFSETS = [0x000, 0x004, 0x01C, 0x020, 0x024, 0x030]

# Read-only registers (pre-populated only, never replayed)
RO_OFFSETS = [0x008, 0x00C, 0x010, 0x018, 0x028]

# Write-only registers
WO_OFFSETS = [0x014, 0x02C]

# Trigger registers (replayed last to preserve write ordering)
TRIGGER_OFFSETS = [0x014, 0x01C]  # DOORBELL, CTRL (FLUSH)

REGISTERS = [
    {"name": "PAIR_BASE",          "offset": 0x000, "access": "__IO"},
    {"name": "REL_THRESHOLD",      "offset": 0x004, "access": "__IO"},
    {"name": "PKT_WORD_LEN",       "offset": 0x008, "access": "__I"},
    {"name": "CREDIT_COUNT",       "offset": 0x00C, "access": "__I"},
    {"name": "STATUS",             "offset": 0x010, "access": "__I"},
    {"name": "DOORBELL",           "offset": 0x014, "access": "__O"},
    {"name": "REL_ACC",            "offset": 0x018, "access": "__I"},
    {"name": "CTRL",               "offset": 0x01C, "access": "__IO"},
    {"name": "RELEASED_ACC",       "offset": 0x020, "access": "__IO"},
    {"name": "DOORBELL_RESP_ACC",  "offset": 0x024, "access": "__IO"},
    {"name": "PAIR_CREDIT_CTR",    "offset": 0x028, "access": "__I"},
    {"name": "PAIR_CREDIT_CONSUME","offset": 0x02C, "access": "__O"},
    {"name": "PAIR_CREDIT_EN",     "offset": 0x030, "access": "__IO"},
]
