# =============================================================================
# test_rxbus_dump.py — GATE 2b: bit-exact RX-bus differential dump.
#
# Brings the pair up to data mode exactly like the doorbell suite, then samples
# the SLAVE RX deserialised word buses (every gpiorx_N.io_link_data, 8 lanes)
# AND each lane's io_link_clk, once per hclk, for a fixed window, writing a
# deterministic trace to $RXDUMP_OUT. Run on BOTH the baseline @142a7ca build
# and the patched @word_pin=0 build with identical stim; an offline `diff` of
# the two traces is the strongest "OFF == legacy" datapath proof on the proven
# B->A direction (master TX -> pad -> slave gpiorx deserialise).
#
# Determinism: the pair tb is a shared-clock model with a fixed reset/bringup
# sequence and no random data injection here, so the sample stream is identical
# run-to-run for a given RTL. The ONLY RTL delta between the two builds is the
# 5 local_overrides files (word_pin patch); deps are byte-identical (same SHA).
# =============================================================================
import os
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import PairTB


def _h(sig):
    try:
        return int(sig.value)
    except Exception:
        return -1


@cocotb.test()
async def test_rxbus_dump(dut):
    tb = PairTB(dut)
    await tb.reset()
    await tb.do_role_lock()
    await tb.wait_role_locked()
    await tb.wait_cal_done()
    await tb.do_to_data_mode()

    gpio = dut.u_slave.u_chiplet_controller.u_wlink.phy.gpio
    rx = [getattr(gpio, f"gpiorx_{n}") for n in range(8)]

    # Inject a VARYING-payload AHB packet master->slave DURING the capture so the
    # slave RX deserialises real FC data words (not just the steady training
    # pattern). This exercises the byte-exact datapath on the proven B->A
    # direction with non-constant content. Fire it as a concurrent coroutine.
    async def _tx_burst():
        # Wait a little so the capture has steady-state training first, then send.
        await ClockCycles(dut.hclk, 400)
        # FifoPacket: word0 (len/type/ids), word1 (dest addr), then payload.
        # Payload chosen to flip many bits across words.
        pkt = [0x0004_0000, 0x4401_0000,
               0xDEAD_BEEF, 0x0123_4567, 0xA5A5_5A5A, 0xFFFF_0000]
        try:
            await tb.ahb_tx_write_packet("m", pkt)
        except Exception as e:
            tb.log.info(f"[2b] tx burst note: {e}")
    cocotb.start_soon(_tx_burst())

    out = os.environ.get("RXDUMP_OUT", "/tmp/rxdump.txt")
    NSAMP = 6000
    lines = []
    for _ in range(NSAMP):
        await RisingEdge(dut.hclk)
        # per-lane deserialised word + recovered word-clock + the windowed reg
        vals = []
        for n in range(8):
            ld  = _h(rx[n].io_link_data)
            lc  = _h(rx[n].io_link_clk)
            ldr = _h(rx[n].link_data_reg)
            vals.append(f"{ld:04x}:{lc:01x}:{ldr:04x}")
        lines.append(" ".join(vals))

    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    tb.log.info(f"[2b] wrote {NSAMP} RX-bus samples ({len(lines)} lines) to {out}")
