"""Phase-2 FPGA-bug reproduction: target the pad_clk_rx-absent hypothesis.

The XDC sets dbg_hub.clk = pad_clk_rx_IBUF and declares pad_clk_rx
asynchronous to clk_out1. Wlink samples RX on pad_clk_rx. If, at FPGA
power-up, the peer's pad_clk_tx (= local pad_clk_rx) is silent or
glitchy until the peer's clk_wiz locks, the local FCSM's RX-side
flops never see edges and `cr_pkt_seen_rx` never latches.

Test: hold slave_clk (= master's pad_clk_rx) silent for many cycles
after master comes out of reset, while the master is already
transmitting cr_pkts.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer
from test_link_bringup import setup, lock_master, lock_slave


async def _measure_async(dut, label, total_cycles=8000):
    m_state_h = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.state
    s_state_h = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.state
    m_seen = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx
    s_seen = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx
    m_max = 0; s_max = 0
    m_l = False; s_l = False
    for _ in range(total_cycles):
        await ClockCycles(dut.master_clk, 1)
        try:
            ms = int(m_state_h.value); ss = int(s_state_h.value)
            m_max = max(m_max, ms); s_max = max(s_max, ss)
        except ValueError: pass
        try:
            if int(m_seen.value): m_l = True
        except ValueError: pass
        try:
            if int(s_seen.value): s_l = True
        except ValueError: pass
    dut._log.info(f"  [{label}] m_state_max={m_max} s_state_max={s_max} "
                  f"m_seen={m_l} s_seen={s_l}")
    return m_max, s_max, m_l, s_l


@cocotb.test()
async def test_silent_pad_clk_rx_during_bringup(dut):
    """Master clock runs; slave_clk does NOT — master sees a dead pad_clk_rx.
    After master locks, start slave_clk and lock slave."""
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
    dut.m_poresetn.value = 0; dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0; dut.s_hresetn.value = 0

    # Start ONLY master clock. slave_clk stays low (= dead pad_clk_rx for master).
    cocotb.start_soon(Clock(dut.master_clk, 20000, unit="ps").start())

    await ClockCycles(dut.master_clk, 5)
    dut.m_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)

    # Lock master while slave clock is dead. Master will start TX-ing cr_pkts
    # but the master's pad_clk_rx (= slave's pad_clk_tx) is silent because
    # slave_clk hasn't started.
    await lock_master(dut)
    await ClockCycles(dut.master_clk, 2000)  # 40 us with no slave clock

    # NOW start the slave clock and bring slave out of reset
    cocotb.start_soon(Clock(dut.slave_clk, 20000, unit="ps").start())
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)
    await lock_slave(dut)

    await _measure_async(dut, "silent pad_clk_rx 2000cy", total_cycles=8000)


@cocotb.test()
async def test_glitchy_pad_clk_rx(dut):
    """slave_clk briefly runs (10 cycles) then stops then restarts later.
    Mimics a clk_wiz that loses lock after deassert."""
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

    # Both clocks running.
    cocotb.start_soon(Clock(dut.master_clk, 20000, unit="ps").start())
    slave_clock = Clock(dut.slave_clk, 20000, unit="ps")
    slave_task = cocotb.start_soon(slave_clock.start())

    await ClockCycles(dut.master_clk, 5)
    dut.m_poresetn.value = 1; dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1; dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)

    await lock_master(dut)
    await lock_slave(dut)

    # Run for 50 cycles then KILL slave clock
    await ClockCycles(dut.master_clk, 50)
    slave_task.kill()
    dut.slave_clk.value = 0
    await ClockCycles(dut.master_clk, 1000)  # 20 us with slave clock dead

    # Restart slave clock — but the slave's RX-side flops have missed edges.
    cocotb.start_soon(Clock(dut.slave_clk, 20000, unit="ps").start())

    await _measure_async(dut, "glitchy slave_clk", total_cycles=8000)


@cocotb.test()
async def test_repeated_glitches(dut):
    """Repeatedly assert/deassert slave_poresetn during bring-up — emulates
    the proc_sys_reset_0 behaviour where the system reset gets re-pulsed
    until clk_wiz locks."""
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

    cocotb.start_soon(Clock(dut.master_clk, 20000, unit="ps").start())
    cocotb.start_soon(Clock(dut.slave_clk, 20000, unit="ps").start())

    await ClockCycles(dut.master_clk, 5)
    dut.m_poresetn.value = 1; dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1; dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)

    await lock_master(dut)
    await lock_slave(dut)

    # Pulse slave reset 3 times during bring-up
    for i in range(3):
        await ClockCycles(dut.master_clk, 30)
        dut.s_poresetn.value = 0
        dut.s_hresetn.value = 0
        await ClockCycles(dut.master_clk, 5)
        dut.s_poresetn.value = 1
        await ClockCycles(dut.master_clk, 2)
        dut.s_hresetn.value = 1
        await ClockCycles(dut.master_clk, 2)
        await lock_slave(dut)

    await _measure_async(dut, "3x slave reset pulses", total_cycles=8000)


@cocotb.test()
async def test_master_locked_long_before_slave(dut):
    """Master is locked and TX-ing for 5000 cycles before slave even comes
    out of reset. Slave's RX path may have over-counted cr_pkts."""
    cocotb.start_soon(Clock(dut.master_clk, 20000, unit="ps").start())
    cocotb.start_soon(Clock(dut.slave_clk, 20000, unit="ps").start())

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
    await ClockCycles(dut.master_clk, 5)
    dut.m_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)
    await lock_master(dut)
    # Master TX-ing for 5000 cycles while slave is in reset
    await ClockCycles(dut.master_clk, 5000)

    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)
    await lock_slave(dut)

    await _measure_async(dut, "master 5000cy ahead", total_cycles=8000)
