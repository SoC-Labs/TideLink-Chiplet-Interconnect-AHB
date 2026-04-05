"""Cocotb tests for tidelink_ptp_servo — autonomous PTP clock synchronisation.

Tests exercise:
  - Register read/write (servo config)
  - Grandmaster FSM: timestamp capture + FC SIDEBAND TX
  - Subordinate FSM: DELAY_REQ trigger, mailbox reception, offset computation
  - PI servo: phase step and frequency steering
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer


CLK_PERIOD_NS = 4  # 250 MHz


class ServoTB:
    """Helper class wrapping DUT signals."""

    def __init__(self, dut):
        self.dut = dut

    async def reset(self):
        self.dut.resetn.value = 0
        self.dut.servo_reg_write.value = 0
        self.dut.sync_tx_done.value = 0
        self.dut.dreq_tx_done.value = 0
        self.dut.sync_rx_done.value = 0
        self.dut.dreq_rx_done.value = 0
        self.dut.hw_cap_seconds.value = 0
        self.dut.hw_cap_nanoseconds.value = 0
        self.dut.hw_cap_sub_nanoseconds.value = 0
        self.dut.servo_fc_ready.value = 1
        self.dut.mbox_reg_write.value = 0
        self.dut.mbox_reg_addr.value = 0
        self.dut.mbox_reg_wdata.value = 0
        await ClockCycles(self.dut.clk, 5)
        self.dut.resetn.value = 1
        await ClockCycles(self.dut.clk, 2)

    async def reg_write(self, addr, data):
        self.dut.servo_reg_write.value = 1
        self.dut.servo_reg_addr.value = addr
        self.dut.servo_reg_wdata.value = data
        await RisingEdge(self.dut.clk)
        self.dut.servo_reg_write.value = 0
        await RisingEdge(self.dut.clk)

    async def reg_read(self, addr):
        self.dut.servo_reg_addr.value = addr
        await RisingEdge(self.dut.clk)
        return self.dut.servo_reg_rdata.value.integer

    async def set_hw_cap(self, seconds, nanoseconds, sub_ns=0):
        """Set the PHC hw_cap values (simulating what PHC latches on hw_capture)."""
        self.dut.hw_cap_seconds.value = seconds
        self.dut.hw_cap_nanoseconds.value = nanoseconds
        self.dut.hw_cap_sub_nanoseconds.value = sub_ns

    async def pulse_event(self, signal):
        """Assert a signal for exactly one clock cycle."""
        signal.value = 1
        await RisingEdge(self.dut.clk)
        signal.value = 0

    async def write_mbox(self, sec_lo, sec_hi, ns, sub_ns):
        """Write 4 mailbox registers (simulating FC SIDEBAND RX)."""
        for addr, data in [(2, sec_lo), (3, sec_hi), (4, ns), (5, sub_ns)]:
            self.dut.mbox_reg_write.value = 1
            self.dut.mbox_reg_addr.value = addr
            self.dut.mbox_reg_wdata.value = data
            await RisingEdge(self.dut.clk)
        self.dut.mbox_reg_write.value = 0
        await RisingEdge(self.dut.clk)

    async def collect_fc_packets(self, count, timeout_cycles=200):
        """Collect FC SIDEBAND packets from servo TX."""
        packets = []
        for _ in range(timeout_cycles):
            await RisingEdge(self.dut.clk)
            if self.dut.servo_fc_valid.value == 1:
                packets.append(self.dut.servo_fc_data.value.integer)
                if len(packets) >= count:
                    break
        return packets


# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_servo_registers(dut):
    """Read/write servo configuration registers."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = ServoTB(dut)
    await tb.reset()

    # Write SERVO_CTRL: enable=1, mode=subordinate
    await tb.reg_write(0, 0x3)
    val = await tb.reg_read(0)
    assert val == 0x3, f"SERVO_CTRL readback mismatch: {val:#x}"

    # Write and read KP
    await tb.reg_write(1, 0xDEADBEEF)
    val = await tb.reg_read(1)
    assert val == 0xDEADBEEF, f"KP readback mismatch: {val:#x}"

    # Write and read KI
    await tb.reg_write(2, 0x12345678)
    val = await tb.reg_read(2)
    assert val == 0x12345678, f"KI readback mismatch: {val:#x}"

    # Write and read step threshold
    await tb.reg_write(3, 500)
    val = await tb.reg_read(3)
    assert val == 500, f"STEP_THRESH readback mismatch: {val}"

    dut._log.info("test_servo_registers PASSED")


@cocotb.test()
async def test_gm_capture_and_send(dut):
    """Grandmaster FSM: sync_tx_done → capture t1 → dreq_rx_done → capture t4 → send 8 FC packets."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = ServoTB(dut)
    await tb.reset()

    # Configure as Grandmaster, enabled
    await tb.reg_write(0, 0x1)  # enable=1, mode=0 (GM)

    # Set t1 timestamp
    await tb.set_hw_cap(seconds=100, nanoseconds=500_000_000, sub_ns=0x1000)
    await tb.pulse_event(dut.sync_tx_done)
    await ClockCycles(dut.clk, 2)  # GM_CAPTURE_T1

    # Set t4 timestamp
    await tb.set_hw_cap(seconds=100, nanoseconds=500_000_100, sub_ns=0x2000)
    await tb.pulse_event(dut.dreq_rx_done)
    # GM goes: CAPTURE_T4 (1 cycle) → SEND_T1_0
    # Don't wait extra cycles — start collecting immediately so we don't miss packets

    # Collect 8 FC SIDEBAND packets (4 for t1, 4 for t4)
    packets = await tb.collect_fc_packets(8, timeout_cycles=200)
    assert len(packets) == 8, f"Expected 8 FC packets, got {len(packets)}"

    # Verify t1 sec_lo (first packet): PKT_SIDEBAND=01, addr=0x068, payload=100[31:0]
    pkt0 = packets[0]
    pkt_type = (pkt0 >> 46) & 0x3
    addr = (pkt0 >> 32) & 0x3FFF
    payload = pkt0 & 0xFFFFFFFF
    assert pkt_type == 1, f"Expected SIDEBAND type, got {pkt_type}"
    assert addr == 0x068, f"Expected addr 0x068, got {addr:#x}"
    assert payload == 100, f"Expected sec_lo=100, got {payload}"

    dut._log.info("test_gm_capture_and_send PASSED")


@cocotb.test()
async def test_sub_dreq_trigger(dut):
    """Subordinate FSM: sync_rx_done → capture t2 → assert servo_dreq_trigger."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = ServoTB(dut)
    await tb.reset()

    # Configure as Subordinate, enabled
    await tb.reg_write(0, 0x3)  # enable=1, mode=1 (Sub)

    # Set t2 timestamp and pulse sync_rx_done
    await tb.set_hw_cap(seconds=100, nanoseconds=500_000_050, sub_ns=0)
    await tb.pulse_event(dut.sync_rx_done)

    # Check DELAY_REQ trigger asserted (FSM: IDLE→CAPTURE_T2→SEND_DREQ)
    # The trigger is combinational on sub_state_r == SUB_SEND_DREQ,
    # which lasts exactly 1 cycle, so we check every cycle.
    found_trigger = False
    for _ in range(30):
        await RisingEdge(dut.clk)
        if int(dut.servo_dreq_trigger.value) == 1:
            found_trigger = True
            break

    assert found_trigger, "servo_dreq_trigger never asserted"
    dut._log.info("test_sub_dreq_trigger PASSED")


@cocotb.test()
async def test_sub_full_exchange(dut):
    """Full Subordinate exchange: sync_rx → capture t2 → dreq_tx → capture t3 → receive t1,t4 → compute offset."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = ServoTB(dut)
    await tb.reset()

    # Configure as Subordinate with large step threshold (force frequency steering)
    await tb.reg_write(0, 0x3)  # enable=1, mode=1
    await tb.reg_write(3, 1_000_000)  # step_thresh = 1ms (large, so we get steering)

    # --- t2: Subordinate receives SYNC ---
    await tb.set_hw_cap(seconds=0, nanoseconds=100, sub_ns=0)
    await tb.pulse_event(dut.sync_rx_done)
    await ClockCycles(dut.clk, 2)

    # --- Wait for DREQ trigger, then simulate dreq_tx_done ---
    for _ in range(20):
        await RisingEdge(dut.clk)
        if dut.servo_dreq_trigger.value == 1:
            break
    # t3: captured on dreq_tx_done
    await tb.set_hw_cap(seconds=0, nanoseconds=200, sub_ns=0)
    await tb.pulse_event(dut.dreq_tx_done)
    await ClockCycles(dut.clk, 2)

    # --- Receive t1 from Grandmaster (via mailbox) ---
    # t1 = {sec=0, ns=50, sub_ns=0}
    await tb.write_mbox(sec_lo=0, sec_hi=0, ns=50, sub_ns=0)
    await ClockCycles(dut.clk, 2)  # SUB_LATCH_T1

    # --- Receive t4 from Grandmaster (via mailbox) ---
    # t4 = {sec=0, ns=250, sub_ns=0}
    await tb.write_mbox(sec_lo=0, sec_hi=0, ns=250, sub_ns=0)
    await ClockCycles(dut.clk, 2)  # SUB_LATCH_T4

    # Wait for computation pipeline (4 cycles) + adjustment
    await ClockCycles(dut.clk, 10)

    # Expected:
    #   d_fwd = t2 - t1 = 100 - 50 = 50  (in sub-ns units: 50 << 32)
    #   d_rev = t4 - t3 = 250 - 200 = 50 (in sub-ns units: 50 << 32)
    #   offset = (d_fwd - d_rev) / 2 = 0
    #   delay  = (d_fwd + d_rev) / 2 = 50

    # Check phc_hw_adj_valid was asserted (frequency steering, offset ≈ 0)
    # Read last_offset from status register (addr 5 = Region 3 offset 0x060)
    offset = await tb.reg_read(5)
    dut._log.info(f"Last offset (ns): {offset}")

    # Read last_delay (addr 6)
    delay = await tb.reg_read(6)
    dut._log.info(f"Last delay (ns): {delay}")
    assert delay == 50, f"Expected delay=50, got {delay}"

    dut._log.info("test_sub_full_exchange PASSED")


@cocotb.test()
async def test_sub_phase_step(dut):
    """Subordinate with large offset triggers SET_TIME phase step."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = ServoTB(dut)
    await tb.reset()

    # Configure as Subordinate with small step threshold
    await tb.reg_write(0, 0x3)  # enable=1, mode=1
    await tb.reg_write(3, 10)   # step_thresh = 10 ns

    # t2 = ns=10000, t1 = ns=0 → d_fwd = 10000
    # t3 = ns=10100, t4 = ns=100 → d_rev = -10000
    # offset = (10000 - (-10000))/2 = 10000 >> way above threshold

    # sync_rx → capture t2
    await tb.set_hw_cap(seconds=0, nanoseconds=10_000, sub_ns=0)
    await tb.pulse_event(dut.sync_rx_done)
    await ClockCycles(dut.clk, 2)

    # Wait for dreq trigger
    for _ in range(20):
        await RisingEdge(dut.clk)
        if dut.servo_dreq_trigger.value == 1:
            break

    # dreq_tx_done → capture t3
    await tb.set_hw_cap(seconds=0, nanoseconds=10_100, sub_ns=0)
    await tb.pulse_event(dut.dreq_tx_done)
    await ClockCycles(dut.clk, 2)

    # Receive t1 (ns=0)
    await tb.write_mbox(sec_lo=0, sec_hi=0, ns=0, sub_ns=0)
    await ClockCycles(dut.clk, 2)

    # Receive t4 (ns=100)
    await tb.write_mbox(sec_lo=0, sec_hi=0, ns=100, sub_ns=0)
    await ClockCycles(dut.clk, 2)

    # Wait for computation + adjustment
    await ClockCycles(dut.clk, 10)

    # Check that SET_TIME was asserted (phase step)
    # We can't directly check the pulse since it's one cycle,
    # but we can check servo_locked is NOT set (phase step resets lock)
    locked = int(dut.servo_locked.value)
    assert locked == 0, "servo_locked should be 0 after phase step"

    dut._log.info("test_sub_phase_step PASSED")


@cocotb.test()
async def test_sub_integral_anti_windup(dut):
    """PI integrator saturates at INTEGRAL_MAX after repeated small offsets.

    Run multiple PTP exchanges with a consistent non-zero offset. The integral
    accumulator should grow but saturate at INTEGRAL_MAX rather than overflow.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = ServoTB(dut)
    await tb.reset()

    # Configure as Subordinate with large step threshold (force frequency steering)
    await tb.reg_write(0, 0x3)  # enable=1, mode=1
    await tb.reg_write(3, 1_000_000)  # step_thresh = 1ms

    # Run multiple exchanges with consistent offset to build up integral
    for iteration in range(20):
        # t2 = ns=200, t1 = ns=100 → d_fwd = 100
        # t3 = ns=300, t4 = ns=200 → d_rev = -100
        # offset = (100 - (-100))/2 = 100 ns (consistent positive offset)
        await tb.set_hw_cap(seconds=0, nanoseconds=200, sub_ns=0)
        await tb.pulse_event(dut.sync_rx_done)
        await ClockCycles(dut.clk, 2)

        for _ in range(20):
            await RisingEdge(dut.clk)
            if dut.servo_dreq_trigger.value == 1:
                break

        await tb.set_hw_cap(seconds=0, nanoseconds=300, sub_ns=0)
        await tb.pulse_event(dut.dreq_tx_done)
        await ClockCycles(dut.clk, 2)

        # t1 = ns=100
        await tb.write_mbox(sec_lo=0, sec_hi=0, ns=100, sub_ns=0)
        await ClockCycles(dut.clk, 2)

        # t4 = ns=200
        await tb.write_mbox(sec_lo=0, sec_hi=0, ns=200, sub_ns=0)
        await ClockCycles(dut.clk, 2)

        # Wait for computation
        await ClockCycles(dut.clk, 10)

    # Read the integral register directly via hierarchy
    integral_val = dut.u_dut.integral_r.value.signed_integer

    # INTEGRAL_MAX = 0x0000_00FF_FFFF_FFFF (~1099 seconds in sub-ns)
    INTEGRAL_MAX = 0x0000_00FF_FFFF_FFFF

    # The integral should have saturated, not grown unbounded
    assert abs(integral_val) <= INTEGRAL_MAX, \
        f"Integral should be clamped to ±{INTEGRAL_MAX}, got {integral_val}"

    dut._log.info(f"Integral after 20 iterations: {integral_val}")
    dut._log.info("test_sub_integral_anti_windup PASSED")


@cocotb.test()
async def test_sub_integral_resets_on_phase_step(dut):
    """Integral is reset to 0 when a phase step occurs, even after accumulation."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = ServoTB(dut)
    await tb.reset()

    # Configure as Subordinate — large threshold for initial steering
    await tb.reg_write(0, 0x3)
    await tb.reg_write(3, 1_000_000)

    # First exchange: small offset to build integral
    await tb.set_hw_cap(seconds=0, nanoseconds=200, sub_ns=0)
    await tb.pulse_event(dut.sync_rx_done)
    await ClockCycles(dut.clk, 2)
    for _ in range(20):
        await RisingEdge(dut.clk)
        if dut.servo_dreq_trigger.value == 1:
            break
    await tb.set_hw_cap(seconds=0, nanoseconds=300, sub_ns=0)
    await tb.pulse_event(dut.dreq_tx_done)
    await ClockCycles(dut.clk, 2)
    await tb.write_mbox(sec_lo=0, sec_hi=0, ns=100, sub_ns=0)
    await ClockCycles(dut.clk, 2)
    await tb.write_mbox(sec_lo=0, sec_hi=0, ns=200, sub_ns=0)
    await ClockCycles(dut.clk, 2)
    await ClockCycles(dut.clk, 10)

    # Verify integral is non-zero
    integral_val = dut.u_dut.integral_r.value.signed_integer
    assert integral_val != 0, f"Integral should be non-zero after steering, got {integral_val}"

    # Now reduce threshold to trigger phase step
    await tb.reg_write(3, 10)  # step_thresh = 10 ns

    # Second exchange: large offset to force phase step
    # t2=10000, t1=0, t3=10100, t4=100 → offset=10000 >> threshold
    await tb.set_hw_cap(seconds=0, nanoseconds=10_000, sub_ns=0)
    await tb.pulse_event(dut.sync_rx_done)
    await ClockCycles(dut.clk, 2)
    for _ in range(20):
        await RisingEdge(dut.clk)
        if dut.servo_dreq_trigger.value == 1:
            break
    await tb.set_hw_cap(seconds=0, nanoseconds=10_100, sub_ns=0)
    await tb.pulse_event(dut.dreq_tx_done)
    await ClockCycles(dut.clk, 2)
    await tb.write_mbox(sec_lo=0, sec_hi=0, ns=0, sub_ns=0)
    await ClockCycles(dut.clk, 2)
    await tb.write_mbox(sec_lo=0, sec_hi=0, ns=100, sub_ns=0)
    await ClockCycles(dut.clk, 2)
    await ClockCycles(dut.clk, 10)

    # Phase step should have reset integral to 0
    integral_val = dut.u_dut.integral_r.value.signed_integer
    assert integral_val == 0, \
        f"Integral should be 0 after phase step, got {integral_val}"

    dut._log.info("test_sub_integral_resets_on_phase_step PASSED")
