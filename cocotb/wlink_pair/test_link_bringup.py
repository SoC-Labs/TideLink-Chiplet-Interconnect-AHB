"""Pair-Wlink bring-up simulation.

Both chiplet controllers share apb_clk (most optimistic case). Tests:
  test_01: do roles lock and Wlink come out of POR-reset?
  test_02: does cr_pkt_seen_rx ever latch on either side?
  test_03: do FC TX FIFOs ever drain?
  test_04: with debug strap set on slave, can we apply same Wlink config
           to slave that we'd apply to master?

If test_02 succeeds in sim → bring-up protocol is sound, bench failure
is physical. If test_02 fails in sim → there's a real RTL gap.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

# Wlink APB offsets (from RDL)
WL_LINK_ENABLE_RESET = 0x0208
WL_LANE_MASK         = 0x0214
WL_LINK_STATUS       = 0x0234
WL_LINK_INTERRUPTS   = 0x0240
WL_FC_TIDELK_BASE    = 0x1700  # TideLk FC node
FC_TX_FIFO_OFF       = 0x08
FC_ACK_NACK_OFF      = 0x10

# Chiplet controller ctrl_reg addresses (3-bit)
CTRL_REG_ROLE_CFG    = 0     # 3-bit ctrl_reg_addr


async def setup(dut, master_period_ns=20.0, slave_period_ns=20.0,
                 stagger_por_cycles=0):
    """Start both clocks (each side with its own period) and perform POR.

    master_period_ns / slave_period_ns control PLL drift simulation.
    stagger_por_cycles delays slave's POR-deassertion by that many master
    clocks, simulating the ~1 s gap between fpga_manager loads on the bench.
    """
    # Sim precision is 1 ps (-timescale=1ns/1ps), so use ps units.
    # 20.001 ns = 20001 ps is exactly representable; 20001 fs would not be.
    cocotb.start_soon(Clock(dut.master_clk, int(round(master_period_ns * 1000)),
                            unit="ps").start())
    cocotb.start_soon(Clock(dut.slave_clk,  int(round(slave_period_ns  * 1000)),
                            unit="ps").start())
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
    dut.m_hresetn.value  = 0; dut.s_hresetn.value  = 0
    await ClockCycles(dut.master_clk, 5)
    # Master comes out of POR first
    dut.m_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1
    if stagger_por_cycles > 0:
        await ClockCycles(dut.master_clk, stagger_por_cycles)
    # Slave POR deassertion
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)


async def ctrl_write(dut, side, addr, data):
    """Single-cycle ctrl_reg write."""
    sig_w = getattr(dut, f"{side}_ctrl_reg_write")
    sig_a = getattr(dut, f"{side}_ctrl_reg_addr")
    sig_d = getattr(dut, f"{side}_ctrl_reg_wdata")
    await RisingEdge(dut.apb_clk)
    sig_a.value = addr
    sig_d.value = data
    sig_w.value = 1
    await RisingEdge(dut.apb_clk)
    sig_w.value = 0


async def lock_master(dut):
    await ctrl_write(dut, 'm', 0, 0x02)  # role=0 (master), lock=1


async def lock_slave(dut):
    await ctrl_write(dut, 's', 0, 0x03)  # role=1 (slave), lock=1


async def apb_read(dut, side, addr):
    psel = getattr(dut, f"{side}_apb_psel")
    pen = getattr(dut, f"{side}_apb_penable")
    pwr = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pready = getattr(dut, f"{side}_apb_pready")
    prdata = getattr(dut, f"{side}_apb_prdata")
    await RisingEdge(dut.apb_clk)
    psel.value = 1
    paddr.value = addr & 0x1FFF
    pwr.value = 0
    pen.value = 0
    await RisingEdge(dut.apb_clk)
    pen.value = 1
    while True:
        await RisingEdge(dut.apb_clk)
        if int(pready.value):
            data = int(prdata.value)
            break
    psel.value = 0
    pen.value = 0
    return data


async def apb_write(dut, side, addr, data):
    psel = getattr(dut, f"{side}_apb_psel")
    pen = getattr(dut, f"{side}_apb_penable")
    pwr = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pwdata = getattr(dut, f"{side}_apb_pwdata")
    pstrb = getattr(dut, f"{side}_apb_pstrb")
    pready = getattr(dut, f"{side}_apb_pready")
    await RisingEdge(dut.apb_clk)
    psel.value = 1
    paddr.value = addr & 0x1FFF
    pwr.value = 1
    pwdata.value = data
    pstrb.value = 0xF
    pen.value = 0
    await RisingEdge(dut.apb_clk)
    pen.value = 1
    while True:
        await RisingEdge(dut.apb_clk)
        if int(pready.value):
            break
    psel.value = 0
    pen.value = 0
    pwr.value = 0


async def snapshot(dut, side, label):
    le = await apb_read(dut, side, WL_LINK_ENABLE_RESET)
    lm = await apb_read(dut, side, WL_LANE_MASK)
    ls = await apb_read(dut, side, WL_LINK_STATUS)
    li = await apb_read(dut, side, WL_LINK_INTERRUPTS)
    tx = await apb_read(dut, side, WL_FC_TIDELK_BASE + FC_TX_FIFO_OFF)
    an = await apb_read(dut, side, WL_FC_TIDELK_BASE + FC_ACK_NACK_OFF)
    locked = int(getattr(dut, f"{side}_role_locked").value)
    is_master = int(getattr(dut, f"{side}_role_is_master").value)
    dut._log.info(f"  [{side}/{label}] role_locked={locked} is_master={is_master}")
    dut._log.info(f"    link_enable_reset(0x208) = 0x{le:08x}")
    dut._log.info(f"    lane_mask(0x214)         = 0x{lm:08x}")
    dut._log.info(f"    link_status(0x234)       = 0x{ls:08x}  in_err={(ls>>2)&1} tx_ready={(ls>>3)&1} rx_data_valid={(ls>>4)&1}")
    dut._log.info(f"    link_interrupts(0x240)   = 0x{li:08x}")
    dut._log.info(f"    TideLk tx_fifo(0x1708)   = 0x{tx:08x}  empty={tx&1}")
    dut._log.info(f"    TideLk ack_nack(0x1710)  = 0x{an:08x}  empty={an&1}")


async def run_bringup_scenario(dut, master_period_ns, slave_period_ns,
                                stagger_por_cycles, label):
    """Common bring-up + state-probe loop for various scenarios."""
    await setup(dut, master_period_ns, slave_period_ns, stagger_por_cycles)
    await lock_master(dut)
    await lock_slave(dut)

    m_state_h = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.state
    s_state_h = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.state
    m_cr_seen = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx
    s_cr_seen = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx

    max_state_master = 0; max_state_slave = 0
    cr_seen_m = False; cr_seen_s = False
    for chunk in range(60):
        await ClockCycles(dut.master_clk, 50)
        ms = int(m_state_h.value); ss = int(s_state_h.value)
        max_state_master = max(max_state_master, ms)
        max_state_slave  = max(max_state_slave, ss)
        if int(m_cr_seen.value): cr_seen_m = True
        if int(s_cr_seen.value): cr_seen_s = True
    dut._log.info(f"  [{label}] master max_state={max_state_master} cr_seen={cr_seen_m}")
    dut._log.info(f"  [{label}] slave  max_state={max_state_slave} cr_seen={cr_seen_s}")
    return max_state_master, max_state_slave, cr_seen_m, cr_seen_s


@cocotb.test()
async def test_01_role_lock_and_link_active(dut):
    """After POR + master/slave lock + ~50 cycles, both link layers should
    be enabled and tx_ready should rise."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.master_clk, 50)

    assert int(dut.m_role_locked.value) == 1, "master role_locked should be 1"
    assert int(dut.s_role_locked.value) == 1, "slave role_locked should be 1"
    assert int(dut.m_role_is_master.value) == 1, "master is_master should be 1"
    assert int(dut.s_role_is_master.value) == 0, "slave is_master should be 0"

    await snapshot(dut, 'm', 'after lock+50cyc')
    await snapshot(dut, 's', 'after lock+50cyc')


@cocotb.test()
async def test_02_fc_handshake_completes(dut):
    """Probe TideLk FCSM `state` register internally via hierarchical access.
    Bring-up sequence per FC.scala:
      0 = IDLE
      1 = SEND_CREDITS1   (sending own cr_pkt, waiting for peer's)
      2 = SEND_CREDITS2   (peer's cr_pkt seen, sending crack)
      3 = ?
      4 = LINK_EN_WAIT
      5+ = LINK_IDLE / data
    Bench is stuck at state 1 forever. If sim advances past 1, the protocol
    is sound and bench failure is physical (independent clocks / async POR).
    """
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    m_state_h = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.state
    s_state_h = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.state
    m_cr_seen = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx
    s_cr_seen = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx

    max_state_master = 0
    max_state_slave = 0
    cr_seen_m_latched = False
    cr_seen_s_latched = False

    for cycle_chunk in range(40):
        await ClockCycles(dut.apb_clk, 50)
        ms = int(m_state_h.value)
        ss = int(s_state_h.value)
        mc = int(m_cr_seen.value)
        sc = int(s_cr_seen.value)
        max_state_master = max(max_state_master, ms)
        max_state_slave = max(max_state_slave, ss)
        if mc: cr_seen_m_latched = True
        if sc: cr_seen_s_latched = True
        if cycle_chunk % 4 == 0 or ms != max_state_master or ss != max_state_slave:
            dut._log.info(f"  [+{(cycle_chunk+1)*50} cyc] m.state={ms} m.cr_seen={mc}  s.state={ss} s.cr_seen={sc}")

    await snapshot(dut, 'm', 'final')
    await snapshot(dut, 's', 'final')

    dut._log.info(f"  master FCSM max_state={max_state_master}, cr_pkt_seen_rx_latched={cr_seen_m_latched}")
    dut._log.info(f"  slave  FCSM max_state={max_state_slave}, cr_pkt_seen_rx_latched={cr_seen_s_latched}")

    if max_state_master >= 4 and max_state_slave >= 4:
        dut._log.info("✓ FCSMs reached LINK_EN_WAIT or beyond — bring-up SUCCEEDED in sim")
    elif max_state_master >= 2 and max_state_slave >= 2:
        dut._log.info("≈ FCSMs left SEND_CREDITS1 — partial bring-up")
    else:
        dut._log.warning(f"✗ FCSMs stuck at SEND_CREDITS1 — same symptom as bench")


@cocotb.test()
async def test_03_drift_100ppm(dut):
    """Realistic Pynq-Z2 PLL drift. (cocotb requires even ps periods, so the
    smallest representable drift at 50 MHz is 100 ppm: 20.000 / 20.002 ns.)"""
    await run_bringup_scenario(dut,
        master_period_ns=20.000, slave_period_ns=20.002,  # 100 ppm
        stagger_por_cycles=0, label="100 ppm drift")


@cocotb.test()
async def test_04_drift_500ppm(dut):
    """Worst-case if PLLs are programmed to slightly different rates."""
    await run_bringup_scenario(dut,
        master_period_ns=20.000, slave_period_ns=20.010,  # 500 ppm
        stagger_por_cycles=0, label="500 ppm drift")


@cocotb.test()
async def test_05_staggered_por(dut):
    """Same clocks but slave's POR comes out 1000 cycles after master's
    (mimics fpga_manager loading boards sequentially)."""
    await run_bringup_scenario(dut,
        master_period_ns=20.000, slave_period_ns=20.000,
        stagger_por_cycles=1000, label="staggered POR (1000 cyc)")


@cocotb.test()
async def test_06_drift_plus_stagger(dut):
    """Combined: 100 ppm drift + staggered POR — closest to bench reality."""
    await run_bringup_scenario(dut,
        master_period_ns=20.000, slave_period_ns=20.002,
        stagger_por_cycles=1000, label="100 ppm + stagger")
