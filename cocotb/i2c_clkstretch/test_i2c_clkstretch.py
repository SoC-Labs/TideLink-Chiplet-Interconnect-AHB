"""SHORTCOMINGS-14a reproduction + fix validation (de44db6 lineage).

Drives the real i2c_master_axil to perform the exact transaction shapes the
autoneg FSM issues against the peer's i2c_slave_axil_master:

  * a multi-byte WRITE (2 addr bytes + payload, like MASK_RES_TX)

The slave-side AXIL target injects APB_WAIT clk cycles of latency on every
write/read, so for multi-byte transfers the slave core MUST clock-stretch
SCL (hold it low) until each byte's APB round-trip lands. tb_top's
+SCL_STRETCH_PASS plusarg selects the buggy mux (stretch discarded, slave
SCL forced 1) vs the fixed mux (slave's open-drain SCL passed through) —
the exact decision axi_chiplet_controller.sv makes for a slave-role board.

The verdict keys off the slave-side AXIL *ground truth* (slv_first_wdata /
slv_last_wdata / slv_wr_count, set by the real i2c_slave_axil_master
bridge) so it is independent of the cocotb I2C driver:

  SCL_STRETCH_PASS=0 -> bridge never sees the correct multi-byte words
                        (the bug); test confirms the breakage (negative
                        control: it MUST NOT look clean).
  SCL_STRETCH_PASS=1 -> bridge writes the full multi-byte payload cleanly
                        through the slow APB; fix proven (positive).
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, with_timeout
from cocotb.triggers import SimTimeoutError

CLK_NS = 10

REG_STATUS, REG_COMMAND, REG_DATA, REG_PRESCALE = 0x0, 0x4, 0x8, 0xC
C_START, C_READ, C_WRITE = 1 << 8, 1 << 9, 1 << 10
C_WRMUL, C_STOP = 1 << 11, 1 << 12
S_BUSY, S_MISS_ACK = 1 << 0, 1 << 3

DEV_ADDR = 0x7E
PRESCALE = 4   # I2C bit ~16 clk
STRETCH_PASS = int(os.environ.get("SCL_STRETCH_PASS", "1"))

# The i2c_slave_axil_master bridge coalesces I2C bytes and issues one AXIL
# write per 16-byte (4 x 32b word) boundary, OR at I2C-STOP. To force a
# *mid-transaction* AXIL write — so the slave core must clock-stretch SCL
# while the prior word's slow-APB B is still pending — the write must carry
# > 16 data bytes. Word 0 = bytes[0:4], last word = bytes[16:20].
N_DATA = 20
DATA_BYTES = [(0x10 + i) & 0xFF for i in range(N_DATA)]
EXPECT_W0 = int.from_bytes(bytes(DATA_BYTES[0:4]), "little")    # first word
EXPECT_LAST = int.from_bytes(bytes(DATA_BYTES[16:20]), "little")  # last word


async def axil_write(dut, addr, data):
    dut.m_axil_awaddr.value = addr
    dut.m_axil_awvalid.value = 1
    dut.m_axil_wdata.value = data
    dut.m_axil_wstrb.value = 0xF
    dut.m_axil_wvalid.value = 1
    dut.m_axil_bready.value = 1
    while True:
        await RisingEdge(dut.clk)
        if dut.m_axil_bvalid.value == 1:
            break
    dut.m_axil_awvalid.value = 0
    dut.m_axil_wvalid.value = 0
    await RisingEdge(dut.clk)
    dut.m_axil_bready.value = 0


async def axil_read(dut, addr):
    dut.m_axil_araddr.value = addr
    dut.m_axil_arvalid.value = 1
    dut.m_axil_rready.value = 1
    while True:
        await RisingEdge(dut.clk)
        if dut.m_axil_rvalid.value == 1:
            val = int(dut.m_axil_rdata.value)
            break
    dut.m_axil_arvalid.value = 0
    await RisingEdge(dut.clk)
    dut.m_axil_rready.value = 0
    return val


async def init(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.rst.value = 1
    for sig in ("m_axil_awaddr", "m_axil_awvalid", "m_axil_wdata",
                "m_axil_wstrb", "m_axil_wvalid", "m_axil_bready",
                "m_axil_araddr", "m_axil_arvalid", "m_axil_rready"):
        getattr(dut, sig).value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 5)
    await axil_write(dut, REG_PRESCALE, PRESCALE)


async def wait_idle(dut, timeout_us):
    """Poll STATUS until busy clears after being observed set.
    Returns final status, or raises SimTimeoutError on a wedge."""
    async def poll():
        seen_busy = False
        while True:
            st = await axil_read(dut, REG_STATUS)
            if st & S_BUSY:
                seen_busy = True
            elif seen_busy:
                return st
            await ClockCycles(dut.clk, 10)
    return await with_timeout(poll(), timeout_us, "us")


async def push_byte(dut, b, last=False):
    await axil_write(dut, REG_DATA, ((1 << 9) if last else 0) | (b & 0xFF))


async def i2c_cmd(dut, bits):
    await axil_write(dut, REG_COMMAND, bits | DEV_ADDR)


@cocotb.test()
async def test_multibyte_i2c_over_slow_apb(dut):
    """Real master+slave cores: a >16-byte I2C write through a slow APB
    target — the autoneg MASK_RES_TX shape. Wedges/corrupts with the old
    SCL mux (negative control), clean with the slave clock-stretch fix.
    """
    await init(dut)
    mode = "FIXED" if STRETCH_PASS else "OLD-BUGGY"
    dut._log.info("=== SCL_STRETCH_PASS=%d (%s mux) ===", STRETCH_PASS, mode)

    wedged = False
    nack = False

    # ---- Multi-byte write: 2 addr bytes + 20 data bytes -----------------
    # The bridge fires an AXIL word write at the 16-byte boundary *mid*
    # I2C transaction. While it waits in STATE_WRITE_2 for the slow APB B,
    # it stops accepting I2C bytes, so the i2c_slave core asserts SCL low
    # to clock-stretch. With the buggy mux that stretch is discarded: the
    # I2C master clocks the next byte anyway and the transfer desyncs.
    payload = [0x00, 0x00] + DATA_BYTES        # addr 0x0000, then 20 data
    for i, b in enumerate(payload):
        await push_byte(dut, b, last=(i == len(payload) - 1))
    await i2c_cmd(dut, C_START | C_WRMUL | C_STOP)
    try:
        st = await wait_idle(dut, 1500)
        await ClockCycles(dut.clk, 100)        # let final word retire
        if st & S_MISS_ACK:
            nack = True
    except SimTimeoutError:
        wedged = True
        dut._log.warning("multi-byte WRITE WEDGED (no completion)")

    wr_cnt    = int(dut.slv_wr_count.value)
    first_w   = int(dut.slv_first_wdata.value)
    last_w    = int(dut.slv_last_wdata.value)
    stretched = int(dut.slv_ever_stretched.value)
    dut._log.info("AXIL writes=%d first=%#010x last=%#010x "
                  "slave_ever_stretched=%d  (expect first=%#010x "
                  "last=%#010x, >=2 writes)",
                  wr_cnt, first_w, last_w, stretched,
                  EXPECT_W0, EXPECT_LAST)

    # ---- Verdict (slave-side AXIL ground truth) -------------------------
    # A correct multi-byte transfer => >=2 AXIL writes, first/last words
    # exactly right, and the slave DID exercise its clock-stretch.
    clean = ((not wedged) and (not nack) and wr_cnt >= 2
             and first_w == EXPECT_W0 and last_w == EXPECT_LAST)

    if STRETCH_PASS == 0:
        # NEGATIVE CONTROL: the buggy mux must NOT complete cleanly.
        assert not clean, (
            "SHORTCOMINGS-14a NOT reproduced: the buggy mux somehow "
            f"completed the multi-byte write (writes={wr_cnt} "
            f"first={first_w:#010x} last={last_w:#010x})")
        dut._log.info("REPRO CONFIRMED: buggy mux (SCL stretch discarded) "
                      "broke the >16-byte I2C write — wedged=%s nack=%s "
                      "writes=%d first=%#010x last=%#010x",
                      wedged, nack, wr_cnt, first_w, last_w)
    else:
        # POSITIVE: the fix must complete the whole payload cleanly AND
        # the slave must actually have exercised the clock-stretch path.
        assert not wedged, "multi-byte write wedged even WITH the fix"
        assert not nack, "slave NACKed even WITH the fix"
        assert stretched, ("slave never clock-stretched — repro not "
                           "exercising the stretch path; raise APB_WAIT")
        assert wr_cnt >= 2, (
            f"only {wr_cnt} AXIL write(s); expected >=2 (mid-transaction "
            "word write did not occur — repro invalid)")
        assert first_w == EXPECT_W0, (
            f"first word {first_w:#010x} != {EXPECT_W0:#010x} — "
            "multi-byte write corrupted despite the fix")
        assert last_w == EXPECT_LAST, (
            f"last word {last_w:#010x} != {EXPECT_LAST:#010x} — "
            "multi-byte write corrupted despite the fix")
        dut._log.info("FIX VALIDATED: 22-byte I2C write completed cleanly "
                      "across a mid-transaction clock-stretch (writes=%d, "
                      "first=%#010x, last=%#010x)",
                      wr_cnt, first_w, last_w)
