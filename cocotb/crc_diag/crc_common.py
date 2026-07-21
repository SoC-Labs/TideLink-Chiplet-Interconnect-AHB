"""Shared helpers for the header-CRC root-cause bench.

The link-layer CRC ships DISABLED (`out_prepend_swi_disable_crc` resets to 1 in
src/rtl/local_overrides/WlinkGenericFCSM_6.v:1159-1167, upstream default 0).
Everything here is about turning it back ON and watching what it does on
KNOWN-GOOD traffic.

Register facts (docs/REGISTER_MAP.md "FC Node" table + FC.scala:661):
    TideLink FC node base   = 0x1700  (unified 15-bit APB view)
    SM Control              = 0x1714, bit[16] = disable_crc  (RW, reset 0 upstream)
    CRC Errors              = 0x1720, [15:0] RO
    Data ID Control         = 0x1704, [7:0] = data_id (0xa1) -- confirms the base

NOTE ON THE INSTRUMENT (feedback_verify_instrument_before_dut): `crc_errors` is
FORCED TO ZERO on every io_rx_clk edge where the demetted app enable
(`en_ff2_rx_demet_io_out`) is low -- WlinkGenericFCSM_6.v:1171-1183. A
before/after counter sample therefore cannot distinguish "no CRC error" from
"the counter got erased". So we ALSO latch the combinational `crc_corrupt`
wire continuously; that is the primary evidence, the counter is corroboration.
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import PairV2TB, run_bringup_full, make_packet

# ---- APB (unified 15-bit view) --------------------------------------------
APB_FC_TIDELINK_BASE = 0x1700
APB_FC_DATA_ID       = APB_FC_TIDELINK_BASE + 0x04   # 0x1704, [7:0] data_id
APB_FC_SM_CONTROL    = APB_FC_TIDELINK_BASE + 0x14   # 0x1714, [16] disable_crc
APB_FC_CRC_ERRORS    = APB_FC_TIDELINK_BASE + 0x20   # 0x1720, [15:0] RO

# Combinational / registered signals inside WlinkGenericFCSM_6 worth latching.
WATCH = ("crc_corrupt", "valid_rx_pkt_crc_err", "pkt_is_data_pkt",
         "send_nack_req", "crcCorruptSeen")

STATIC = ("out_prepend_swi_disable_crc", "swi_data_id_1", "crc_errors",
          "en_ff2_rx_demet_io_out", "state")


def rd(fc, name, default=-1):
    try:
        return int(getattr(fc, name).value)
    except (AttributeError, ValueError, TypeError):
        return default


class CrcMonitor:
    """Latches ANY assertion of the watched wires until stopped, plus the peak
    crc_errors and the observed computed-vs-received CRC pair at the moment of
    the first mismatch."""

    def __init__(self, tb, side):
        self.tb = tb
        self.side = side
        self.fc = tb.fcsm(side)
        self.reset()
        self._run = False
        self._task = None

    def reset(self):
        self.seen = {n: 0 for n in WATCH}
        self.crc_errors_max = 0
        self.first_mismatch = None      # (computed, received, data, word_count)

    async def _loop(self):
        fc = self.fc
        while self._run:
            await RisingEdge(self.tb.dut.hclk)
            for n in WATCH:
                if rd(fc, n, 0) == 1:
                    self.seen[n] += 1
            ce = rd(fc, "crc_errors", 0)
            if ce > self.crc_errors_max:
                self.crc_errors_max = ce
            if self.first_mismatch is None and rd(fc, "crc_corrupt", 0) == 1:
                self.first_mismatch = (
                    rd(fc, "rx_crc_computed_crcgen_io_out"),
                    rd(fc, "auto_rx_in_crc"),
                    rd(fc, "auto_rx_in_data"),
                    rd(fc, "auto_rx_in_word_count"),
                )

    def start(self):
        self.reset()
        self._run = True
        self._task = cocotb.start_soon(self._loop())

    def stop(self):
        self._run = False

    def asserted(self):
        return {n: v for n, v in self.seen.items() if v}

    def report(self, ctx):
        s = (f"[{ctx}] {self.side}: asserted={self.asserted()} "
             f"crc_errors_max={self.crc_errors_max}")
        if self.first_mismatch:
            c, r, d, w = self.first_mismatch
            s += (f"  FIRST MISMATCH computed=0x{c:04x} received=0x{r:04x} "
                  f"(delta=0x{c ^ r:04x}) rx_data=0x{d:014x} wc={w}")
        return s


async def enable_crc(tb, side, log=True):
    """Try to clear disable_crc on `side`. Returns a dict describing HOW it was
    cleared, so the 'die_b's SM Control is hardware-unwritable' claim in
    WlinkGenericFCSM_6.v:1165 can be confirmed or refuted per die."""
    fc = tb.fcsm(side)
    apb = tb.apb(side)
    out = {"side": side}

    out["por"] = rd(fc, "out_prepend_swi_disable_crc")
    out["data_id"] = rd(fc, "swi_data_id_1")

    # -- 1. the documented SW path: SM Control bit[16] <- 0 ------------------
    try:
        before = await apb.read(APB_FC_SM_CONTROL)
        await apb.write(APB_FC_SM_CONTROL, before & ~(1 << 16))
        await ClockCycles(tb.dut.hclk, 50)
        after = await apb.read(APB_FC_SM_CONTROL)
        out["apb_before"] = before
        out["apb_after"] = after
        out["apb_dataid"] = await apb.read(APB_FC_DATA_ID)
    except Exception as e:                                  # noqa: BLE001
        out["apb_error"] = repr(e)

    out["after_apb"] = rd(fc, "out_prepend_swi_disable_crc")
    out["apb_worked"] = (out["after_apb"] == 0)

    # -- 2. fallback: TB-level force on the FCSM register --------------------
    # This is a cocotb Force on the harness, NOT an RTL edit. It makes the
    # datapath behave exactly as the upstream default (disable_crc = 0) would.
    if not out["apb_worked"]:
        fc.out_prepend_swi_disable_crc.value = Force(0)
        await ClockCycles(tb.dut.hclk, 20)
        out["after_force"] = rd(fc, "out_prepend_swi_disable_crc")
        out["forced"] = True
    else:
        out["forced"] = False

    out["enabled"] = (rd(fc, "out_prepend_swi_disable_crc") == 0)
    if log:
        tb.log.info(f"enable_crc[{side}]: {out}")
    return out


async def bringup(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "PRECONDITION: no CR/CRACK exchange"
    await ClockCycles(dut.hclk, 500)
    return tb


async def drain_rx(tb, side, words=4):
    """Read exactly `words` words -- NEVER more than the packet actually put in.

    DO NOT raise this above the packet length. Reading an EMPTY RX FIFO pops a
    PHANTOM zero-length packet that walks read_ptr by 2 words
    (project_rxfifo_empty_read_phantom_pop_2026_07_14), which desyncs the read
    pointer and wedges the FIFO for every subsequent packet. An earlier revision
    of this bench used words=8 against a 4-word packet and produced a WEDGE that
    looked exactly like per-packet link corruption. That artefact invalidated two
    hypotheses before it was caught -- see docs/CRC_ROOTCAUSE.md.
    """
    for i in range(words):
        await tb.ahb_fifo_read_word(side, i * 4)
    await ClockCycles(tb.dut.hclk, 200)
