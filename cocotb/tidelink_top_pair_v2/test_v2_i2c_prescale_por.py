"""i2c_prescale POR value is derived from the apb_clk period (0c7b02e8).

The controller's I2C PRESCALE register resets to
  round((2.5e8 / I2C_BUS_KHZ) / APB_CLK_PERIOD_PS)
i.e. 100 kHz autoneg I2C at any apb_clk: 125 at 50 MHz (20000 ps), 250 at
100 MHz (10000 ps). APB_CLK_PERIOD_PS comes from the SoC-wide define
NANOSOC_SYS_CLK_PERIOD_PS; undefined -> 20000 ps -> the historical 16'd125.

EXPECT_I2C_PRESCALE (env, default 125) is the value the build must reset to:
  default build                          -> 125 (unchanged for eth/FPGA/cocotb)
  make I2C_SYS_CLK_PS=10000              -> 250 (compute 100 MHz recipe)
  make I2C_SYS_CLK_PS=12500              -> 200
Pre-change (091d9c0a) the second and third builds reset to 125 -> this FAILS.
Read directly after POR/HRESETn release, before the autoneg FSM can run.
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB


@cocotb.test()
async def i2c_prescale_por_value(dut):
    expect = int(os.environ.get("EXPECT_I2C_PRESCALE", "125"))
    tb = PairV2TB(dut)
    dut.poresetn.value = 0
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 2)
    for side in ("m", "s"):
        got = int(tb.top(side).u_chiplet_controller.i2c_prescale_reg.value)
        dut._log.info(f"{side}: i2c_prescale_reg={got} expect={expect}")
        assert got == expect, f"{side}: i2c_prescale_reg POR={got}, expected {expect}"
