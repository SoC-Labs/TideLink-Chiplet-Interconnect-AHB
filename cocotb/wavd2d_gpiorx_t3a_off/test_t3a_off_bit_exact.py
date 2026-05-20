"""
test_t3a_off_bit_exact — pin USE_T3A=0 bit-exact passthrough of the legacy
free-running `count` in WavD2DGpioRx (sim/ASIC/UVM default path).

The T3a comma-hunt restructure (USE_T3A parameter, 2026-05-19) added a
generate block in WavD2DGpioRx.v:

    generate
      if (USE_T3A) begin : g_t3a_realign
          ... shifter + FSM + slip arithmetic + count slip-aware update ...
      end else begin : g_t3a_passthru
          // Bit-exact legacy: count free-runs from 4'hf, +1 every cycle.
          always @(posedge w_cnt_clk or posedge io_por_reset) begin
            if (io_por_reset) count <= 4'hf;
            else              count <= count + 4'h1;
          end
      end
    endgenerate

This test pins USE_T3A=0 = the strict-legacy arm. The contract under
test is:
  1. g_t3a_passthru is the elaborated arm (no g_t3a_realign-scoped child
     names; USE_T3A parameter reads 0).
  2. After POR deassertion, count resets to 4'hf and increments by 1
     every w_cnt_clk cycle (mod 16) — observed via the hierarchical
     handle into u_dut.count.
  3. The increment holds for many cycles across a POR re-arm — there is
     NO comma-hunt slip event, NO settling pause; count just runs.

If the generate-if regressed (e.g. picked g_t3a_realign with USE_T3A=0),
or the legacy always-block was inadvertently modified, this test catches
it in seconds before the ASIC/UVM flow notices a deserialiser regression.

Invocation:
    cd /home/dam1n19/td_idelay_wt && source set_env.sh
    rm -rf cocotb/wavd2d_gpiorx_t3a_off/sim_build
    make -C cocotb/wavd2d_gpiorx_t3a_off

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


def _child_names(handle):
    names = []
    try:
        for k in handle:
            try:
                names.append(k._name)
            except Exception:  # noqa: BLE001
                pass
    except Exception:  # noqa: BLE001
        pass
    return names


async def _start_clock(dut):
    cocotb.start_soon(Clock(dut.io_pad_clk, 10, unit="ns").start())


@cocotb.test()
async def test_use_t3a0_branch_selected(dut):
    """USE_T3A=0 must select the `g_t3a_passthru` generate arm — the bit-
    exact legacy free-running counter. We prove this via:
      (a) u_dut.USE_T3A parameter == 0; and
      (b) no `g_t3a_realign`-scoped child name appears in the elaborated
          hierarchy (if it did, the constant generate-if picked the
          USE_T3A=1 arm — the realign shifter / FSM / slip arithmetic
          would be live, NOT the legacy free-run).
    """
    use_t3a = int(dut.u_dut.USE_T3A.value)
    dut._log.info(f"u_dut.USE_T3A = {use_t3a}")
    assert use_t3a == 0, (
        f"u_dut.USE_T3A = {use_t3a}, expected 0. tb_top must hard-set "
        f"USE_T3A=1'b0 so the g_t3a_passthru legacy arm is selected; "
        f"otherwise this TB does not exercise the sim/ASIC default."
    )

    names = _child_names(dut.u_dut)
    g_realign_scoped = [n for n in names if n.split(".")[0] == "g_t3a_realign"]
    assert not g_realign_scoped, (
        f"u_dut exposes a `g_t3a_realign`-scoped child with USE_T3A=0 "
        f"(children: {names}). The constant generate-if selected the T3a "
        f"realign arm — the legacy bit-exact free-running counter is no "
        f"longer the sim/ASIC default."
    )
    dut._log.info(
        "OK: USE_T3A=0 and no g_t3a_realign-scoped child — the legacy "
        "free-running counter arm is the elaborated path."
    )


@cocotb.test()
async def test_count_resets_to_f_and_free_runs(dut):
    """After POR deassertion, `count` must reset to 4'hf and increment
    by 1 every w_cnt_clk cycle (mod 16). This is the strict legacy
    behaviour the USE_T3A=0 arm must reproduce bit-exact.

    We sample u_dut.count via the hierarchical handle every cycle for
    a full sweep (32 cycles = 2 full count rotations), and assert
    monotonic +1 mod 16.
    """
    await _start_clock(dut)

    # Hold POR and idle.
    dut.io_por_reset.value = 1
    dut.io_pad.value = 0
    await ClockCycles(dut.io_pad_clk, 8)
    # The async-reset path forces count <= 4'hf during io_por_reset=1.
    val = int(dut.u_dut.count.value)
    assert val == 0xF, (
        f"u_dut.count = 0x{val:X} during io_por_reset=1, expected 0xF "
        f"(the legacy async-reset value). The USE_T3A=0 reset path "
        f"regressed."
    )

    # Deassert POR. cocotb writes are non-blocking — the next RisingEdge
    # may or may not see the new value depending on scheduler ordering.
    # We synchronise by sampling AFTER the first edge and using the
    # sampled value as our anchor; then assert monotonic +1 mod 16 from
    # there. This is robust to whether the first edge after deassertion
    # already saw POR=0 or still saw POR=1.
    dut.io_por_reset.value = 0
    await RisingEdge(dut.io_pad_clk)
    # Skip a settling cycle so subsequent samples are guaranteed to be in
    # the post-POR steady-state +1 region.
    await RisingEdge(dut.io_pad_clk)
    samples = []
    for _ in range(32):
        await RisingEdge(dut.io_pad_clk)
        samples.append(int(dut.u_dut.count.value))

    dut._log.info(f"count samples after POR: {[hex(v) for v in samples[:18]]} ...")

    # Verify monotonic +1 mod 16 from cycle 0 of the captured window.
    failures = []
    for i in range(1, len(samples)):
        expected = (samples[i - 1] + 1) & 0xF
        if samples[i] != expected:
            failures.append(
                f"  cycle {i}: count = 0x{samples[i]:X}, "
                f"expected 0x{expected:X} (prev was 0x{samples[i - 1]:X})"
            )

    assert not failures, (
        f"count did NOT free-run +1 mod 16 — USE_T3A=0 legacy arm broken:\n"
        + "\n".join(failures[:10])
    )

    # Cross-check by re-asserting POR — count must snap back to 0xF.
    dut.io_por_reset.value = 1
    await ClockCycles(dut.io_pad_clk, 4)
    val = int(dut.u_dut.count.value)
    assert val == 0xF, (
        f"u_dut.count = 0x{val:X} after re-asserting io_por_reset, "
        f"expected 0xF. The async-reset arm is broken on USE_T3A=0."
    )

    dut._log.info(
        "OK: USE_T3A=0 count is bit-exact legacy free-running counter — "
        "resets to 0xF, increments +1 mod 16, async-resets on POR."
    )
