"""Shared register helpers, lane-status parsers, packet helpers used by
the stress_toolkit web runner and pytest suite.

Pattern: most helpers take a ``read_fn(addr) -> int`` and
``write_fn(addr, val) -> None`` pair so the same parsing logic can run
against:

  * real /dev/mem MMIO (driven over SSH by the runner — see
    runner.py's ``MmioRemote`` adapter that wraps
    ``_ptp_common.sh::remote_w / remote_r`` semantics in Python),
  * a fake in-memory MMIO for pytest,
  * a cocotb backplane (not exercised here but the shape matches).

NO writes to AHB_TX (0x4400_0000) happen in this module — every write
target is the APB (0x4403_0000) or the AHB_FIFO (0x4401_0000) RX
window, both of which are wedge-safe once the link is up.

See:
  * pynq_host/overlay.py for the canonical address map.
  * pynq_host/scripts/_ptp_common.sh for the bash equivalents.
  * deps/tidelink-gpio-phy/docs/TRAINING_MODULE_SPEC.md §6 for the
    PHY-regs APB slave (used as a passive health monitor).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, List, Optional, Tuple

# ── Address map (Wave B2 paired bitstream) ────────────────────────────────
AHB_TX_BASE   = 0x4400_0000   # NEVER WRITE — wedge hazard
AHB_FIFO_BASE = 0x4401_0000   # RX FIFO window (64 KB)
AHB_PTP_BASE  = 0x4402_0000   # PTP TX write port (4 KB)
APB_BASE      = 0x4403_0000   # Unified config registers (32 KB)

# Within APB:
APB_OFF_TIDELINK = 0x2000     # TideLink config + PTP regs
APB_OFF_REGION8  = 0x2100     # Region 8: chiplet extended (PHY align)
APB_OFF_PMOD     = 0x44042000  # PMOD-B trigger GPIO (absolute, separate IP)

# TideLink config offsets within APB (absolute addresses are APB_BASE + off):
APB_OFF_DOORBELL          = 0x0014
APB_OFF_REL_THRESHOLD     = 0x0004
APB_OFF_CREDIT_COUNT      = 0x000C
APB_OFF_PKT_WORD_LEN      = 0x0008
APB_OFF_STATUS            = 0x0010
APB_OFF_RELEASED_ACC      = 0x0020
APB_OFF_DOORBELL_RESP_ACC = 0x0024
APB_OFF_PAIR_CREDIT_CTR   = 0x0028

# PTP / servo offsets within APB (absolute = APB_BASE + off):
APB_OFF_PTP_CTRL          = 0x2034
APB_OFF_HW_SYNC_CTRL      = 0x2040
APB_OFF_HW_SYNC_INTERVAL  = 0x2044
APB_OFF_HW_SYNC_STATUS    = 0x2048
APB_OFF_SERVO_CTRL        = 0x204C
APB_OFF_SERVO_KP          = 0x2050
APB_OFF_SERVO_KI          = 0x2054
APB_OFF_SERVO_STEP_THRESH = 0x2058
APB_OFF_SERVO_STATUS      = 0x205C
APB_OFF_SERVO_DELAY       = 0x2060
APB_OFF_SERVO_NS_FRAC     = 0x2064

# Region 8 (SWI_LANE_STATUS lives at APB_BASE + 0x2108):
SWI_LANE_STATUS_OFF       = 0x2108
SWI_TRAINING_MODE_OFF     = 0x2100
SWI_BIT_SLIP_LO_OFF       = 0x2104
NEGO_TRAIN_CFG_OFF        = 0x210C
NEGO_TRAIN_STATUS_OFF     = 0x2110
ECC_COUNTERS_OFF          = 0x2114
PHY_ALIGN_ID_OFF          = 0x211C

# tidelink_gpio_phy_apb_regs slave (TRAINING_MODULE_SPEC.md §6).
# Layout (8 RW/RO registers, 32 bytes total):
#   +0x00  SWI_LANE_THRESH      RW
#   +0x04  SWI_LANE_NOISE_RAW_LO  RO  (4 lanes × 8-bit)
#   +0x08  SWI_LANE_NOISE_RAW_HI  RO
#   +0x0C  SWI_LANE_NOISE_VOTED_LO RO
#   +0x10  SWI_LANE_NOISE_VOTED_HI RO
#   +0x14  SWI_LANE_NOISE_MODE   RW
#   +0x18  SWI_LANE_WIRING_STATUS RO  (8 lanes × 2-bit, packed)
#   +0x1C  SWI_LANE_CANARY_STATUS RO  (canary_pass[7:0], canary_valid[15:8])
GPIO_PHY_REGS_BASE        = 0x4403_2160  # user-spec position
GPIO_PHY_OFF_THRESH       = 0x00
GPIO_PHY_OFF_NOISE_RAW_LO = 0x04
GPIO_PHY_OFF_NOISE_RAW_HI = 0x08
GPIO_PHY_OFF_NOISE_VOTED_LO = 0x0C
GPIO_PHY_OFF_NOISE_VOTED_HI = 0x10
GPIO_PHY_OFF_NOISE_MODE   = 0x14
GPIO_PHY_OFF_WIRING_STATUS = 0x18
GPIO_PHY_OFF_CANARY_STATUS = 0x1C

# AHB_FIFO offsets (used for packet write/read on AHB_FIFO base, which is
# wedge-safe — only the TX aperture at 0x4400_0000 is dangerous).
FIFO_OFF_HEADER = 0x0000

# PHC base + offsets — same as _ptp_common.sh
PHC_BASE                   = 0x4405_0000
PHC_OFF_CTRL               = 0x000
PHC_OFF_STATUS             = 0x004
PHC_OFF_NS_INCR            = 0x008
PHC_OFF_NS_INCR_FRAC       = 0x00C
PHC_OFF_SET_SECONDS_LO     = 0x010
PHC_OFF_SET_SECONDS_HI     = 0x014
PHC_OFF_SET_NANOSECONDS    = 0x018
PHC_OFF_HW_CAP_SECONDS_LO  = 0x040
PHC_OFF_HW_CAP_SECONDS_HI  = 0x044
PHC_OFF_HW_CAP_NANOSECONDS = 0x048
PHC_OFF_HW_CAP_NS_FRAC     = 0x04C
PHC_CTRL_EN                = 1
PHC_CTRL_SET_TIME          = 2
PHC_CTRL_CAPTURE           = 4

NS_INCR_FOR_50MHZ          = 20

MAX_CREDITS                = 4096


# ── Type aliases ──────────────────────────────────────────────────────────

ReadFn = Callable[[int], int]
WriteFn = Callable[[int, int], None]


# ── Lane status parsing ───────────────────────────────────────────────────

@dataclass
class LaneStatus:
    """Decoded SWI_LANE_STATUS @ 0x4403_2108."""
    raw: int
    locked_mask: int         # [7:0]
    fault_mask: int          # [15:8]
    cal_done: bool           # [16]
    fcsm_state: int          # [20:17]
    ll_rx_state: int         # [22:21]
    cr_pkt_seen: bool        # [23]
    crack_pkt_seen: bool     # [24]
    is_short_pkt: bool       # [25]
    is_long_pkt: bool        # [26]
    pkt_is_cr_pkt: bool      # [27]
    pkt_is_crack: bool       # [28]
    llrx_valid: bool         # [29]

    @property
    def lock_count(self) -> int:
        return bin(self.locked_mask).count("1")

    @property
    def fault_count(self) -> int:
        return bin(self.fault_mask).count("1")

    @property
    def link_idle(self) -> bool:
        """Per wlink_probe.sh comments, FCSM 'wedges at 1 in the credit-path
        failure'. LINK_IDLE in the credit-path FSM is encoded as state==0."""
        return self.fcsm_state == 0

    def to_dict(self) -> dict:
        return {
            "raw": self.raw,
            "locked_mask": self.locked_mask,
            "locked": self.lock_count,
            "fault_mask": self.fault_mask,
            "fault": self.fault_count,
            "cal_done": self.cal_done,
            "fcsm_state": self.fcsm_state,
            "ll_rx_state": self.ll_rx_state,
            "cr_pkt_seen": self.cr_pkt_seen,
            "crack_pkt_seen": self.crack_pkt_seen,
            "is_short_pkt": self.is_short_pkt,
            "is_long_pkt": self.is_long_pkt,
            "pkt_is_cr_pkt": self.pkt_is_cr_pkt,
            "pkt_is_crack": self.pkt_is_crack,
            "llrx_valid": self.llrx_valid,
            "link_idle": self.link_idle,
        }


def parse_lane_status(raw: int) -> LaneStatus:
    return LaneStatus(
        raw=raw,
        locked_mask=raw & 0xFF,
        fault_mask=(raw >> 8) & 0xFF,
        cal_done=bool((raw >> 16) & 1),
        fcsm_state=(raw >> 17) & 0xF,
        ll_rx_state=(raw >> 21) & 0x3,
        cr_pkt_seen=bool((raw >> 23) & 1),
        crack_pkt_seen=bool((raw >> 24) & 1),
        is_short_pkt=bool((raw >> 25) & 1),
        is_long_pkt=bool((raw >> 26) & 1),
        pkt_is_cr_pkt=bool((raw >> 27) & 1),
        pkt_is_crack=bool((raw >> 28) & 1),
        llrx_valid=bool((raw >> 29) & 1),
    )


def parse_ecc_counters(raw: int) -> dict:
    """Decode the packed ECC counters at APB+0x2114."""
    corrupted = raw & 0xFFFF
    corrected = (raw >> 16) & 0xFFFF
    return {
        "ecc_corrupted_cnt": corrupted,
        "ecc_corrected_cnt": corrected,
        "ecc_corrupted_saturated": corrupted == 0xFFFF,
        "ecc_corrected_saturated": corrected == 0xFFFF,
    }


# ── PHY (training_module) regs parsing (TRAINING_MODULE_SPEC.md §6) ───────

@dataclass
class PhyHealth:
    """Snapshot of the 8 tidelink_gpio_phy_apb_regs registers."""
    thresh: List[int]          # per-lane threshold (0..7)
    noise_raw: List[int]       # per-lane dist_raw  (0..16)
    noise_voted: List[int]     # per-lane dist_voted
    wiring_status: List[int]   # per-lane (0=UNKNOWN, 1=OK, 2=SWAPPED, 3=DEAD)
    canary_pass: List[bool]    # per-lane bit-order canary
    canary_valid: List[bool]
    noise_mode: int            # 0=min, 1=max, 2=mean, 3=current

    def to_dict(self) -> dict:
        return {
            "thresh": list(self.thresh),
            "noise_raw": list(self.noise_raw),
            "noise_voted": list(self.noise_voted),
            "wiring_status": list(self.wiring_status),
            "canary_pass": [bool(x) for x in self.canary_pass],
            "canary_valid": [bool(x) for x in self.canary_valid],
            "noise_mode": self.noise_mode,
        }


_WIRE_NAMES = {0: "UNKNOWN", 1: "OK", 2: "SWAPPED", 3: "DEAD"}


def wiring_status_name(code: int) -> str:
    return _WIRE_NAMES.get(code & 0x3, f"?({code:#x})")


def _unpack_per_lane_8bit(lo: int, hi: int) -> List[int]:
    """Unpack 4 lanes in LO + 4 lanes in HI, each lane in the low 5 bits
    of an 8-bit slot."""
    out: List[int] = []
    for i in range(4):
        out.append((lo >> (8 * i)) & 0x1F)
    for i in range(4):
        out.append((hi >> (8 * i)) & 0x1F)
    return out


def _unpack_per_lane_thresh(reg: int) -> List[int]:
    """SWI_LANE_THRESH: 8 lanes × 4-bit slot, low 3 bits = threshold."""
    return [(reg >> (4 * i)) & 0x7 for i in range(8)]


def _unpack_wiring(reg: int) -> List[int]:
    """SWI_LANE_WIRING_STATUS: 8 lanes × 2-bit packed."""
    return [(reg >> (2 * i)) & 0x3 for i in range(8)]


def read_phy_health(read_fn: ReadFn, *,
                    base: int = GPIO_PHY_REGS_BASE) -> PhyHealth:
    thresh = _unpack_per_lane_thresh(read_fn(base + GPIO_PHY_OFF_THRESH))
    raw_lo = read_fn(base + GPIO_PHY_OFF_NOISE_RAW_LO)
    raw_hi = read_fn(base + GPIO_PHY_OFF_NOISE_RAW_HI)
    voted_lo = read_fn(base + GPIO_PHY_OFF_NOISE_VOTED_LO)
    voted_hi = read_fn(base + GPIO_PHY_OFF_NOISE_VOTED_HI)
    mode = read_fn(base + GPIO_PHY_OFF_NOISE_MODE) & 0x3
    wiring = _unpack_wiring(read_fn(base + GPIO_PHY_OFF_WIRING_STATUS))
    canary_reg = read_fn(base + GPIO_PHY_OFF_CANARY_STATUS)
    cp = [bool((canary_reg >> i) & 1) for i in range(8)]
    cv = [bool((canary_reg >> (8 + i)) & 1) for i in range(8)]
    return PhyHealth(
        thresh=thresh,
        noise_raw=_unpack_per_lane_8bit(raw_lo, raw_hi),
        noise_voted=_unpack_per_lane_8bit(voted_lo, voted_hi),
        wiring_status=wiring,
        canary_pass=cp,
        canary_valid=cv,
        noise_mode=mode,
    )


def phy_health_anomalies(h: PhyHealth) -> List[str]:
    """Return a list of human-readable anomaly strings — empty list ==
    healthy. The runner surfaces these to the SSE stream."""
    out: List[str] = []
    for i in range(8):
        if h.canary_valid[i] and not h.canary_pass[i]:
            out.append(
                f"lane {i}: bit-order canary FAILED (MSB/LSB reversed)")
        ws = h.wiring_status[i]
        if ws == 2:
            out.append(f"lane {i}: WIRING_SWAPPED")
        elif ws == 3:
            out.append(f"lane {i}: WIRING_DEAD")
        # Structured-noise alarm — voted is much better than raw means
        # nothing structured; raw≈voted with elevated raw means
        # structured noise (TRAINING_MODULE_SPEC.md §5).
        if h.noise_raw[i] >= 3 and abs(h.noise_raw[i] - h.noise_voted[i]) <= 1:
            out.append(
                f"lane {i}: structured-noise alarm "
                f"(raw={h.noise_raw[i]} ≈ voted={h.noise_voted[i]})")
    return out


# ── FifoPacket helper (minimal local copy — runner uses the canonical
# python.tidelink.packet.FifoPacket on the board, but the web-side stress
# orchestrator only needs total_words for credit accounting). ────────────

def packet_total_words(data: List[int]) -> int:
    """Per python/tidelink/packet.py: total FIFO occupancy = header (2)
    + payload length (len(data))."""
    return len(data) + 2


def expected_credits_after_write(current: int, data: List[int]) -> int:
    """Predict CURRENT_CREDITS post-write given pre-write value."""
    return current - packet_total_words(data)


# ── Stress test result aggregator ────────────────────────────────────────

@dataclass
class StressStats:
    """Live rolling stats for the AHB packet stress test."""
    tx_packets: int = 0
    rx_packets: int = 0
    errors: int = 0
    bytes_tx: int = 0
    bytes_rx: int = 0
    start_ts: float = 0.0
    last_ts: float = 0.0

    def to_dict(self) -> dict:
        elapsed = max(self.last_ts - self.start_ts, 1e-6)
        return {
            "tx_packets": self.tx_packets,
            "rx_packets": self.rx_packets,
            "errors": self.errors,
            "bytes_tx": self.bytes_tx,
            "bytes_rx": self.bytes_rx,
            "tx_pps": self.tx_packets / elapsed,
            "rx_pps": self.rx_packets / elapsed,
            "tx_bps": self.bytes_tx * 8 / elapsed,
            "rx_bps": self.bytes_rx * 8 / elapsed,
            "elapsed_s": elapsed,
        }


# ── PHC helpers — port of bringup_ptp_sync.sh ─────────────────────────────

def phc_quiesce_servo(write_fn: WriteFn, *,
                      apb_base: int = APB_BASE) -> None:
    """Disable autonomous servo + HW_SYNC initiator."""
    write_fn(apb_base + APB_OFF_HW_SYNC_CTRL, 0)
    write_fn(apb_base + APB_OFF_SERVO_CTRL, 0)


def phc_init_50mhz(write_fn: WriteFn, sec: int, *,
                   phc_base: int = PHC_BASE) -> None:
    """Programme the PHC for a 50 MHz tick (NS_INCR=20) starting at
    (sec, 0 ns, 0 frac). Disables the counter, sets time, then enables."""
    write_fn(phc_base + PHC_OFF_CTRL, 0)
    write_fn(phc_base + PHC_OFF_NS_INCR, NS_INCR_FOR_50MHZ)
    write_fn(phc_base + PHC_OFF_NS_INCR_FRAC, 0)
    write_fn(phc_base + PHC_OFF_SET_SECONDS_LO, sec & 0xFFFFFFFF)
    write_fn(phc_base + PHC_OFF_SET_SECONDS_HI, (sec >> 32) & 0xFFFFFFFF)
    write_fn(phc_base + PHC_OFF_SET_NANOSECONDS, 0)
    write_fn(phc_base + PHC_OFF_CTRL, PHC_CTRL_SET_TIME)
    write_fn(phc_base + PHC_OFF_CTRL, PHC_CTRL_EN)


def phc_hw_cap_read(read_fn: ReadFn, *,
                    phc_base: int = PHC_BASE) -> Tuple[int, int, int]:
    """Return (secs, ns, frac) from the latched HW_CAP region.

    HW_CAP is updated by the hardware capture pulse (PMOD-B trigger or
    the autonomous HW_SYNC initiator) — software does NOT pulse anything
    here.
    """
    lo = read_fn(phc_base + PHC_OFF_HW_CAP_SECONDS_LO)
    hi = read_fn(phc_base + PHC_OFF_HW_CAP_SECONDS_HI)
    ns = read_fn(phc_base + PHC_OFF_HW_CAP_NANOSECONDS)
    fr = read_fn(phc_base + PHC_OFF_HW_CAP_NS_FRAC)
    return ((hi << 32) | lo), ns, fr


def pmod_trigger_pulse(write_fn: WriteFn, *,
                       pmod_base: int = APB_OFF_PMOD) -> None:
    """One PMOD-B trigger pulse — 1 then 0."""
    write_fn(pmod_base, 1)
    write_fn(pmod_base, 0)


def offset_ns(m_cap: Tuple[int, int, int],
              s_cap: Tuple[int, int, int]) -> int:
    """Signed offset (slave - master) in ns."""
    m_sec, m_ns, _ = m_cap
    s_sec, s_ns, _ = s_cap
    return (s_sec - m_sec) * 1_000_000_000 + (s_ns - m_ns)


# ── Doorbell helpers ──────────────────────────────────────────────────────

def write_doorbell(write_fn: WriteFn, *,
                   apb_base: int = APB_BASE,
                   count: int = 1) -> None:
    """Issue `count` doorbells. Each write is a single ring; the W1C
    semantics in the RTL handle the rest.

    REG_DOORBELL is an APB write — NOT an AHB_TX write — so it is safe
    even on a wedged link (it never blocks)."""
    for _ in range(count):
        write_fn(apb_base + APB_OFF_DOORBELL, 1)


def read_doorbell_resp_acc(read_fn: ReadFn, *,
                           apb_base: int = APB_BASE) -> int:
    """Read DOORBELL_RESP_ACC (a W-add/R-clear register — reading
    clears it back to 0)."""
    return read_fn(apb_base + APB_OFF_DOORBELL_RESP_ACC)


__all__ = [
    "LaneStatus", "parse_lane_status", "parse_ecc_counters",
    "PhyHealth", "read_phy_health", "phy_health_anomalies",
    "wiring_status_name",
    "packet_total_words", "expected_credits_after_write",
    "StressStats",
    "phc_quiesce_servo", "phc_init_50mhz", "phc_hw_cap_read",
    "pmod_trigger_pulse", "offset_ns",
    "write_doorbell", "read_doorbell_resp_acc",
    "AHB_TX_BASE", "AHB_FIFO_BASE", "AHB_PTP_BASE", "APB_BASE",
    "GPIO_PHY_REGS_BASE", "PHC_BASE", "SWI_LANE_STATUS_OFF",
    "ECC_COUNTERS_OFF",
    "APB_OFF_PTP_CTRL", "APB_OFF_HW_SYNC_CTRL", "APB_OFF_HW_SYNC_INTERVAL",
    "APB_OFF_SERVO_CTRL", "APB_OFF_SERVO_STATUS", "APB_OFF_SERVO_KP",
    "APB_OFF_SERVO_KI", "APB_OFF_SERVO_STEP_THRESH",
    "MAX_CREDITS",
]
