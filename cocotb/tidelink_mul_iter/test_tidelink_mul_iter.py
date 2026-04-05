"""Cocotb tests for tidelink_mul_iter -- 32x32 signed x unsigned iterative multiplier.

Tests exercise:
  - Boundary values (zero, identity, max positive, min negative)
  - Mixed-sign products
  - Back-to-back operations
  - Random operand stress
  - Latency measurement
  - Reset mid-operation behaviour
"""

import ctypes
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


CLK_PERIOD_NS = 4  # 250 MHz


def to_signed32(val):
    """Interpret a 32-bit value as signed using ctypes."""
    return ctypes.c_int32(val & 0xFFFF_FFFF).value


def to_signed64(val):
    """Interpret a 64-bit value as signed using ctypes."""
    return ctypes.c_int64(val & 0xFFFF_FFFF_FFFF_FFFF).value


def reference_multiply(a_signed, b_unsigned):
    """Python reference: signed-32 * unsigned-32 -> signed-64."""
    a_s = to_signed32(a_signed)
    b_u = b_unsigned & 0xFFFF_FFFF
    return a_s * b_u


class MulTB:
    """Helper class wrapping the multiplier DUT signals."""

    def __init__(self, dut):
        self.dut = dut

    async def reset(self):
        """Assert active-low reset for 5 clock cycles, then release."""
        self.dut.resetn.value = 0
        self.dut.start.value = 0
        self.dut.a.value = 0
        self.dut.b.value = 0
        await ClockCycles(self.dut.clk, 5)
        self.dut.resetn.value = 1
        await ClockCycles(self.dut.clk, 2)

    async def multiply(self, a, b):
        """Drive a multiply operation and return the signed-64 result.

        Args:
            a: signed 32-bit value (Python int, may be negative)
            b: unsigned 32-bit value
        Returns:
            Signed 64-bit result (Python int)
        """
        # Drive operands -- encode a as unsigned 32-bit for the simulator
        self.dut.a.value = a & 0xFFFF_FFFF
        self.dut.b.value = b & 0xFFFF_FFFF

        # Pulse start for one cycle
        self.dut.start.value = 1
        await RisingEdge(self.dut.clk)
        self.dut.start.value = 0

        # Wait for done
        for _ in range(64):
            await RisingEdge(self.dut.clk)
            if self.dut.done.value == 1:
                raw = self.dut.result.value.integer
                return to_signed64(raw)

        raise RuntimeError("Multiplier did not assert done within 64 cycles")


# ---------------------------------------------------------------------------
# MUL-001: zero inputs
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_zero_inputs(dut):
    """MUL-001: a=0, b=0 -> result=0."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = MulTB(dut)
    await tb.reset()

    result = await tb.multiply(0, 0)
    assert result == 0, f"Expected 0, got {result}"


# ---------------------------------------------------------------------------
# MUL-002: identity
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_identity(dut):
    """MUL-002: a=1, b=1 -> result=1."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = MulTB(dut)
    await tb.reset()

    result = await tb.multiply(1, 1)
    assert result == 1, f"Expected 1, got {result}"


# ---------------------------------------------------------------------------
# MUL-003: positive product
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_positive_product(dut):
    """MUL-003: a=12345, b=67890 -> result=838102050."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = MulTB(dut)
    await tb.reset()

    expected = 12345 * 67890
    result = await tb.multiply(12345, 67890)
    assert result == expected, f"Expected {expected}, got {result}"


# ---------------------------------------------------------------------------
# MUL-004: negative * positive
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_negative_positive(dut):
    """MUL-004: a=-100, b=50 -> result=-5000."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = MulTB(dut)
    await tb.reset()

    result = await tb.multiply(-100, 50)
    assert result == -5000, f"Expected -5000, got {result}"


# ---------------------------------------------------------------------------
# MUL-005: max positive
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_max_positive(dut):
    """MUL-005: a=2^31-1, b=2^32-1 -> maximum positive product."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = MulTB(dut)
    await tb.reset()

    a = (1 << 31) - 1   # 2147483647
    b = (1 << 32) - 1   # 4294967295
    expected = reference_multiply(a, b)
    result = await tb.multiply(a, b)
    assert result == expected, f"Expected {expected}, got {result}"


# ---------------------------------------------------------------------------
# MUL-006: min negative
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_min_negative(dut):
    """MUL-006: a=-2^31, b=2^32-1 -> maximum magnitude negative product."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = MulTB(dut)
    await tb.reset()

    a = -(1 << 31)      # -2147483648
    b = (1 << 32) - 1   # 4294967295
    expected = reference_multiply(a, b)
    result = await tb.multiply(a, b)
    assert result == expected, f"Expected {expected}, got {result}"


# ---------------------------------------------------------------------------
# MUL-007: back-to-back multiplies
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_back_to_back(dut):
    """MUL-007: two multiplies without reset between them."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = MulTB(dut)
    await tb.reset()

    # First multiply
    r1 = await tb.multiply(42, 1000)
    assert r1 == 42000, f"First multiply: expected 42000, got {r1}"

    # Second multiply immediately after (no reset)
    r2 = await tb.multiply(-7, 300)
    assert r2 == -2100, f"Second multiply: expected -2100, got {r2}"


# ---------------------------------------------------------------------------
# MUL-008: 100 random pairs
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_random_100(dut):
    """MUL-008: 100 random operand pairs compared to Python reference."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = MulTB(dut)
    await tb.reset()

    rng = random.Random(0xDEAD_BEEF)  # deterministic seed

    for i in range(100):
        # a: random signed 32-bit
        a_raw = rng.randint(0, 0xFFFF_FFFF)
        a_signed = to_signed32(a_raw)
        # b: random unsigned 32-bit
        b_unsigned = rng.randint(0, 0xFFFF_FFFF)

        expected = reference_multiply(a_signed, b_unsigned)
        result = await tb.multiply(a_signed, b_unsigned)
        assert result == expected, (
            f"Iteration {i}: a={a_signed}, b={b_unsigned}: "
            f"expected {expected}, got {result}"
        )


# ---------------------------------------------------------------------------
# MUL-009: latency check
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_latency(dut):
    """MUL-009: verify done asserts exactly 32 cycles after start."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = MulTB(dut)
    await tb.reset()

    # Drive operands
    dut.a.value = 5 & 0xFFFF_FFFF
    dut.b.value = 3

    # Pulse start
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    # Count cycles until done
    cycle_count = 0
    for _ in range(64):
        await RisingEdge(dut.clk)
        cycle_count += 1
        if dut.done.value == 1:
            break

    assert cycle_count == 32, (
        f"Expected done after 32 cycles, got {cycle_count}"
    )

    # Also verify result correctness
    raw = dut.result.value.integer
    result = to_signed64(raw)
    assert result == 15, f"Expected 15, got {result}"


# ---------------------------------------------------------------------------
# MUL-010: reset mid-operation
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_reset_mid_operation(dut):
    """MUL-010: assert reset during multiply, verify clean recovery."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    tb = MulTB(dut)
    await tb.reset()

    # Start a multiply
    dut.a.value = 999 & 0xFFFF_FFFF
    dut.b.value = 888
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    # Wait 10 cycles (mid-operation)
    await ClockCycles(dut.clk, 10)
    assert dut.busy.value == 1, "Expected busy during operation"

    # Assert reset
    dut.resetn.value = 0
    await ClockCycles(dut.clk, 3)

    # Check that busy is cleared during reset
    assert dut.busy.value == 0, "Expected busy=0 during reset"

    # Release reset
    dut.resetn.value = 1
    await ClockCycles(dut.clk, 2)

    # Verify clean state: not busy, not done
    assert dut.busy.value == 0, "Expected busy=0 after reset release"
    assert dut.done.value == 0, "Expected done=0 after reset release"

    # Verify a new multiply works correctly after reset
    result = await tb.multiply(123, 456)
    assert result == 123 * 456, f"Expected {123 * 456}, got {result}"
