"""FPGA-bug reproduction attempts.

Each test exercises one hypothesised root cause for the FPGA-only
TideLink-FC bring-up failure. Pass = reproduced (cr_pkt_seen_rx stays 0).
Fail = condition does NOT match the bug. We expect most to "fail" — that
itself is information.

Run individually with COCOTB_TESTCASE=<name>.
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer
from test_link_bringup import setup, lock_master, lock_slave


async def _measure(dut, cycles=5000, label=""):
    """Run for `cycles`, return (m_state_max, s_state_max, m_seen, s_seen)."""
    m_state_h = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.state
    s_state_h = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.state
    m_seen = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx
    s_seen = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx

    m_max = 0; s_max = 0
    m_latched = False; s_latched = False
    for _ in range(cycles):
        await ClockCycles(dut.master_clk, 1)
        try:
            ms = int(m_state_h.value); ss = int(s_state_h.value)
            m_max = max(m_max, ms); s_max = max(s_max, ss)
        except ValueError:
            pass
        try:
            if int(m_seen.value): m_latched = True
        except ValueError:
            pass
        try:
            if int(s_seen.value): s_latched = True
        except ValueError:
            pass
        if m_latched and s_latched and m_max >= 4 and s_max >= 4:
            break
    dut._log.info(f"  [{label}] m.state_max={m_max} s.state_max={s_max} "
                  f"m.cr_seen={m_latched} s.cr_seen={s_latched}")
    return m_max, s_max, m_latched, s_latched


@cocotb.test()
async def test_extreme_drift_2000ppm(dut):
    """4x the test_04 drift. If TideLink FC's CDC depth is insufficient at
    very high drift, we'd see cr_pkt loss."""
    await setup(dut, master_period_ns=20.000, slave_period_ns=20.040)  # 2000 ppm
    await lock_master(dut)
    await lock_slave(dut)
    m_max, s_max, m_seen, s_seen = await _measure(dut, 8000, "2000 ppm")
    dut._log.info(f"  RESULT: m_seen={m_seen} s_seen={s_seen} "
                  f"(reproduces bug if both False)")


@cocotb.test()
async def test_extreme_drift_5000ppm(dut):
    """10x test_04 drift — even more extreme."""
    await setup(dut, master_period_ns=20.000, slave_period_ns=20.100)  # 5000 ppm
    await lock_master(dut)
    await lock_slave(dut)
    m_max, s_max, m_seen, s_seen = await _measure(dut, 8000, "5000 ppm")
    dut._log.info(f"  RESULT: m_seen={m_seen} s_seen={s_seen}")


@cocotb.test()
async def test_huge_stagger_10000(dut):
    """Slave POR comes out 10000 master cycles late (= 200us)."""
    await setup(dut, stagger_por_cycles=10000)
    await lock_master(dut)
    await lock_slave(dut)
    m_max, s_max, m_seen, s_seen = await _measure(dut, 8000, "stagger 10000")
    dut._log.info(f"  RESULT: m_seen={m_seen} s_seen={s_seen}")


@cocotb.test()
async def test_long_runtime_1ms(dut):
    """Run for ~1 ms (50000 cycles) to see if TideLink FC eventually
    converges — maybe sim is just running too short."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    m_max, s_max, m_seen, s_seen = await _measure(dut, 50000, "1ms")
    dut._log.info(f"  RESULT: m_seen={m_seen} s_seen={s_seen}")


@cocotb.test()
async def test_reverse_reset_order(dut):
    """Master comes up SECOND instead of first, AND hresetn is deasserted
    before poresetn (illegal but FPGA bitstream load may do this)."""
    cocotb.start_soon(Clock(dut.master_clk, 20000, unit="ps").start())
    cocotb.start_soon(Clock(dut.slave_clk,  20000, unit="ps").start())
    # APB idle
    for prefix in ['m', 's']:
        getattr(dut, f"{prefix}_apb_psel").value = 0
        getattr(dut, f"{prefix}_apb_penable").value = 0
        getattr(dut, f"{prefix}_apb_pwrite").value = 0
        getattr(dut, f"{prefix}_apb_paddr").value = 0
        getattr(dut, f"{prefix}_apb_pwdata").value = 0
        getattr(dut, f"{prefix}_apb_pprot").value = 0
        getattr(dut, f"{prefix}_apb_pstrb").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_write").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_addr").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_wdata").value = 0
    # All resets asserted
    dut.m_poresetn.value = 0; dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0; dut.s_hresetn.value = 0
    await ClockCycles(dut.master_clk, 5)
    # Reverse order: hresetn first, then poresetn
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 100)
    dut.m_hresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_poresetn.value = 1
    await ClockCycles(dut.master_clk, 5)

    await lock_master(dut)
    await lock_slave(dut)
    m_max, s_max, m_seen, s_seen = await _measure(dut, 8000, "reverse reset")
    dut._log.info(f"  RESULT: m_seen={m_seen} s_seen={s_seen}")


@cocotb.test()
async def test_no_apb_clock_during_reset(dut):
    """The FPGA bitstream loads before clocks start. Try toggling poresetn
    while the clock is held low — emulating bitstream-load order."""
    # Don't start clocks yet
    for prefix in ['m', 's']:
        getattr(dut, f"{prefix}_apb_psel").value = 0
        getattr(dut, f"{prefix}_apb_penable").value = 0
        getattr(dut, f"{prefix}_apb_pwrite").value = 0
        getattr(dut, f"{prefix}_apb_paddr").value = 0
        getattr(dut, f"{prefix}_apb_pwdata").value = 0
        getattr(dut, f"{prefix}_apb_pprot").value = 0
        getattr(dut, f"{prefix}_apb_pstrb").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_write").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_addr").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_wdata").value = 0
    dut.m_poresetn.value = 0; dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0; dut.s_hresetn.value = 0
    # Pulse poresetn high then low without any clock — emulate FPGA
    # bitstream-load-then-clock-start order.
    dut.m_poresetn.value = 1; dut.s_poresetn.value = 1
    dut.m_hresetn.value = 1; dut.s_hresetn.value = 1
    await Timer(1000, unit='ns')  # static high for 1 us
    dut.m_poresetn.value = 0; dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0; dut.s_hresetn.value = 0
    # NOW start clocks
    cocotb.start_soon(Clock(dut.master_clk, 20000, unit="ps").start())
    cocotb.start_soon(Clock(dut.slave_clk,  20000, unit="ps").start())
    await ClockCycles(dut.master_clk, 5)
    dut.m_poresetn.value = 1; dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1; dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)

    await lock_master(dut)
    await lock_slave(dut)
    m_max, s_max, m_seen, s_seen = await _measure(dut, 8000, "static-pre-clock reset")
    dut._log.info(f"  RESULT: m_seen={m_seen} s_seen={s_seen}")


@cocotb.test()
async def test_glitchy_resets(dut):
    """Briefly re-pulse poresetn after lock — emulates a power glitch."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.master_clk, 50)
    # Glitch the slave POR after lock
    dut.s_poresetn.value = 0
    await ClockCycles(dut.master_clk, 3)
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 5)
    await lock_slave(dut)  # re-lock (since reset cleared the role lock)
    m_max, s_max, m_seen, s_seen = await _measure(dut, 8000, "glitch reset")
    dut._log.info(f"  RESULT: m_seen={m_seen} s_seen={s_seen}")
