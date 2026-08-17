"""Unit gate for tidelink_link_clk_div — the D2D link-clock divider.

Every test here checks a MECHANISM, not an outcome. The distinction matters:
an integration bench can show "the link still works at /4" while the divider
is emitting a runt pulse on every ratio change, because the PHY happens to
tolerate it that day. These tests fail on the mechanism.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Copyright 2026, SoC Labs (www.soclabs.org)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge, Edge
from cocotb.utils import get_sim_time

CLK_PERIOD_NS = 10.0          # 100 MHz — the eth chiplet's actual link rate
PS_PER_NS = 1000.0

# ratio code -> divide value
RATIOS = {0: 1, 1: 2, 2: 4, 3: 8, 4: 16}


def _ps():
    return get_sim_time("ps")


async def _reset(dut, ratio=0, scan=0):
    """Bring the DUT up with a known ratio. Reset is async-assert."""
    dut.ratio_i.value = ratio
    dut.scan_mode.value = scan
    dut.rst_n.value = 0
    await Timer(5 * CLK_PERIOD_NS, units="ns")
    dut.rst_n.value = 1
    await Timer(5 * CLK_PERIOD_NS, units="ns")


async def _start_clk(dut):
    cocotb.start_soon(Clock(dut.clk_in, CLK_PERIOD_NS, units="ns").start())


async def _measure_period_ps(dut, edges=8):
    """Mean full period of clk_out over `edges` rising edges."""
    await RisingEdge(dut.clk_out)
    t0 = _ps()
    for _ in range(edges):
        await RisingEdge(dut.clk_out)
    return (_ps() - t0) / edges


class RuntMonitor:
    """Records every clk_out half-period and flags any shorter than the
    shortest LEGAL one.

    The shortest legal half-period in this design is that of /1 bypass, i.e.
    half of clk_in. A glitchless mux may produce a LONGER half-period during
    handover (both legs briefly disabled) — that is expected and benign. It
    must never produce a shorter one: that is a runt, and a runt on this net
    goes straight into the PHY and out onto the pad.
    """

    def __init__(self, dut, floor_ps):
        self.dut = dut
        self.floor_ps = floor_ps
        self.violations = []
        self.half_periods = []
        self._task = None

    def start(self):
        self._task = cocotb.start_soon(self._run())

    def stop(self):
        if self._task is not None:
            self._task.kill()

    async def _run(self):
        await Edge(self.dut.clk_out)
        last = _ps()
        while True:
            await Edge(self.dut.clk_out)
            now = _ps()
            hp = now - last
            last = now
            self.half_periods.append(hp)
            # Ignore the very first interval: it can be a partial phase left
            # over from reset release rather than a real emitted half-cycle.
            if len(self.half_periods) > 1 and hp < self.floor_ps:
                self.violations.append((now, hp))


@cocotb.test()
async def test_reset_default_is_bypass(dut):
    """/1 is the reset configuration and clk_out tracks clk_in 1:1.

    This is the regression gate for the whole change: if this fails, inserting
    the divider was not behaviour-preserving and nothing downstream is safe.
    """
    await _start_clk(dut)
    await _reset(dut, ratio=0)

    period = await _measure_period_ps(dut)
    expected = CLK_PERIOD_NS * PS_PER_NS
    assert abs(period - expected) < 1.0, (
        f"/1 bypass must be transparent: measured {period} ps, expected {expected} ps"
    )
    assert int(dut.ratio_o.value) == 0, "ratio_o should read back /1"


@cocotb.test()
async def test_each_ratio_period(dut):
    """Every supported ratio divides by the advertised amount."""
    await _start_clk(dut)
    await _reset(dut, ratio=0)

    for code, div in RATIOS.items():
        dut.ratio_i.value = code
        # Allow the CDC sync + stability filter and the handover to settle.
        await Timer(60 * CLK_PERIOD_NS, units="ns")

        period = await _measure_period_ps(dut)
        expected = CLK_PERIOD_NS * div * PS_PER_NS
        assert abs(period - expected) < 1.0, (
            f"ratio code {code} (/{div}): measured {period} ps, expected {expected} ps"
        )
        assert int(dut.ratio_o.value) == code, (
            f"ratio_o readback {int(dut.ratio_o.value)} != requested {code}"
        )


@cocotb.test()
async def test_divided_duty_cycle_is_50pc(dut):
    """Divided ratios are exactly 50% duty.

    Not cosmetic. The forwarded pad clock IS the far receiver's eye reference,
    and duty-cycle distortion eats eye directly. The divider takes its output
    from a single toggle flop precisely so this holds regardless of the input
    duty cycle.
    """
    await _start_clk(dut)

    for code, div in RATIOS.items():
        if div == 1:
            continue  # bypass inherits the source duty cycle by definition
        await _reset(dut, ratio=code)
        await Timer(60 * CLK_PERIOD_NS, units="ns")

        await RisingEdge(dut.clk_out)
        t_rise = _ps()
        await Edge(dut.clk_out)
        t_fall = _ps()
        await Edge(dut.clk_out)
        t_rise2 = _ps()

        high = t_fall - t_rise
        full = t_rise2 - t_rise
        duty = high / full
        assert abs(duty - 0.5) < 0.01, (
            f"/{div} duty cycle {duty:.4f} is not 50% "
            f"(high {high} ps of {full} ps)"
        )


@cocotb.test()
async def test_no_runt_on_live_ratio_change(dut):
    """No runt pulse on any live ratio change, in either direction.

    The documented discipline is to change the ratio only under PHY POR, but
    this asserts the interlock holds even when that discipline is violated —
    which is the entire reason the handover is interlocked rather than trusted.
    """
    await _start_clk(dut)
    await _reset(dut, ratio=0)

    floor_ps = (CLK_PERIOD_NS / 2.0) * PS_PER_NS * 0.9
    mon = RuntMonitor(dut, floor_ps)
    mon.start()

    # Walk up, walk back down, then jump across non-adjacent ratios — the
    # non-adjacent jumps are the ones a careless SW write actually produces.
    sequence = [1, 2, 3, 4, 3, 2, 1, 0, 4, 0, 2, 0]
    for code in sequence:
        dut.ratio_i.value = code
        await Timer(60 * CLK_PERIOD_NS, units="ns")

    mon.stop()

    assert mon.half_periods, "monitor saw no clk_out activity at all"
    assert not mon.violations, (
        f"{len(mon.violations)} runt pulse(s) on clk_out during ratio changes; "
        f"floor is {floor_ps} ps. First few: {mon.violations[:5]}"
    )


@cocotb.test()
async def test_x_ratio_falls_back_to_bypass(dut):
    """An X / undriven ratio_i leaves the module in /1 bypass.

    LOAD-BEARING. This is the property that lets tidelink_top gain a new port
    without every existing cocotb tb_top.sv having to connect it, and that lets
    the compute chiplet adopt this module on its next bump with no coordinated
    change. If this test fails, that whole integration argument collapses and
    the port must be connected everywhere before the change is safe.
    """
    await _start_clk(dut)
    await _reset(dut, ratio=0)

    try:
        dut.ratio_i.value = cocotb.binary.BinaryValue("xxx", n_bits=3)
    except Exception:
        from cocotb.types import LogicArray
        dut.ratio_i.value = LogicArray("xxx")

    await Timer(60 * CLK_PERIOD_NS, units="ns")

    period = await _measure_period_ps(dut)
    expected = CLK_PERIOD_NS * PS_PER_NS
    assert abs(period - expected) < 1.0, (
        f"X ratio must hold /1 bypass: measured {period} ps, expected {expected} ps"
    )


@cocotb.test()
async def test_out_of_range_clamps_to_slowest(dut):
    """Codes 5/6/7 clamp to /16 rather than decoding to something undefined.

    Slower is the safe direction, so the clamp saturates rather than wrapping.
    """
    await _start_clk(dut)

    for code in (5, 6, 7):
        await _reset(dut, ratio=code)
        await Timer(60 * CLK_PERIOD_NS, units="ns")

        period = await _measure_period_ps(dut)
        expected = CLK_PERIOD_NS * 16 * PS_PER_NS
        assert abs(period - expected) < 1.0, (
            f"out-of-range code {code} should clamp to /16: "
            f"measured {period} ps, expected {expected} ps"
        )
        assert int(dut.ratio_o.value) == 4, (
            f"ratio_o should report the clamped /16 code 4, got {int(dut.ratio_o.value)}"
        )


@cocotb.test()
async def test_scan_mode_forces_bypass(dut):
    """scan_mode forces /1 regardless of the programmed ratio, so DFT sees a
    single clock rather than a divided one."""
    await _start_clk(dut)
    await _reset(dut, ratio=4, scan=1)
    await Timer(60 * CLK_PERIOD_NS, units="ns")

    period = await _measure_period_ps(dut)
    expected = CLK_PERIOD_NS * PS_PER_NS
    assert abs(period - expected) < 1.0, (
        f"scan_mode must force bypass: measured {period} ps, expected {expected} ps"
    )
