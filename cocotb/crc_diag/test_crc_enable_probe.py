"""STEP 1 — can the CRC be turned back on at all, and does it then false-fire?

Three questions, in order:

  1. What is the POR value of `out_prepend_swi_disable_crc` on each die, and can
     SW clear it over APB (SM Control 0x1714 bit[16])? The override comment at
     WlinkGenericFCSM_6.v:1165 claims die_b's SM Control register is
     "hardware-unwritable" -- that is a testable claim and is reported either
     way rather than assumed.

  2. With the CRC ENABLED on the RECEIVING die, does a single known-good short
     packet -- one that is delivered byte-exact -- trip `crc_corrupt`?

  3. If it does, capture computed-vs-received CRC at the mismatch.

The whole point is that the packet must be verified DELIVERED AND BYTE-EXACT in
the same run, otherwise a CRC assertion is ambiguous between "the CRC is broken"
and "the link is broken".
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import make_packet
from crc_common import (
    bringup, drain_rx, enable_crc, CrcMonitor, rd, STATIC,
    APB_FC_SM_CONTROL, APB_FC_CRC_ERRORS,
)


@cocotb.test()
async def test_01_disable_crc_writability(dut):
    """POR value + per-die SW writability of SM Control bit[16]."""
    tb = await bringup(dut)

    for side in ("m", "s"):
        fc = tb.fcsm(side)
        tb.log.info(f"VERDICT[static_{side}]: "
                    f"{ {n: rd(fc, n) for n in STATIC} }")

    res = {}
    for side in ("m", "s"):
        res[side] = await enable_crc(tb, side)

    for side in ("m", "s"):
        r = res[side]
        tb.log.info(
            f"VERDICT[crc_writability_{side}]: POR disable_crc={r['por']} "
            f"apb_sm_control 0x{r.get('apb_before', -1):x}->"
            f"0x{r.get('apb_after', -1):x} apb_worked={r['apb_worked']} "
            f"forced={r['forced']} enabled={r['enabled']}")

    assert res["m"]["enabled"] and res["s"]["enabled"], \
        "could not enable the CRC on both dies by either APB or force"

    # The claim under test: is the SLAVE's SM Control really unwritable?
    if res["m"]["apb_worked"] and not res["s"]["apb_worked"]:
        tb.log.warning("VERDICT[smcontrol_asymmetry]: CONFIRMS the override "
                       "comment -- master SM Control is SW-writable, slave is NOT.")
    elif res["m"]["apb_worked"] and res["s"]["apb_worked"]:
        tb.log.warning("VERDICT[smcontrol_asymmetry]: REFUTES the override "
                       "comment -- SM Control bit[16] is SW-writable on BOTH dies "
                       "in sim.")
    else:
        tb.log.warning("VERDICT[smcontrol_asymmetry]: SM Control bit[16] is NOT "
                       "SW-writable on EITHER die in sim.")


@cocotb.test()
async def test_02_good_packet_with_crc_enabled(dut):
    """A known-good packet, CRC enabled on the receiver. Delivery and CRC are
    checked in the SAME run so the result is unambiguous."""
    tb = await bringup(dut)
    for side in ("m", "s"):
        await enable_crc(tb, side)

    # m is the receiver; send s -> m.
    await drain_rx(tb, "m")
    mon = CrcMonitor(tb, "m")
    mon.start()

    words = make_packet([0x7E570001, 0xA5000001])
    await tb.ahb_tx_write_packet("s", words)
    await ClockCycles(dut.hclk, 4000)
    mon.stop()

    got = [await tb.ahb_fifo_read_word("m", i * 4) for i in range(4)]
    delivered = all(got[i] == words[i] for i in range(4))

    tb.log.info(f"VERDICT[good_pkt_crc]: delivered_byte_exact={delivered} "
                f"sent={[hex(w) for w in words]} got={[hex(w) for w in got]}")
    tb.log.info("VERDICT[good_pkt_crc_mon]: " + mon.report("good_pkt"))

    crc_apb = await tb.apb("m").read(APB_FC_CRC_ERRORS)
    tb.log.info(f"VERDICT[good_pkt_crc_errors_apb]: 0x{crc_apb:x}")

    if delivered and mon.seen.get("crc_corrupt", 0):
        tb.log.error("VERDICT[FALSE_FIRE]: the packet arrived BYTE-EXACT and the "
                     "CRC still fired -> the CRC check itself is wrong, not the "
                     "datapath. This reproduces the silicon observation.")
    elif delivered and not mon.seen.get("crc_corrupt", 0):
        tb.log.info("VERDICT[NO_FALSE_FIRE]: byte-exact delivery AND a quiet CRC "
                    "in THIS configuration -- the false-fire is configuration "
                    "dependent; see the lane-width and length tests.")
    else:
        tb.log.warning("VERDICT[UNDELIVERED]: packet did not arrive byte-exact; "
                       "a CRC assertion here is NOT evidence of a CRC defect.")
