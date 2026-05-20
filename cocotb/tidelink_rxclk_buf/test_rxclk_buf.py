"""
test_rxclk_buf — pin the tidelink_rxclk_buf boundary BUFG buffer passthrough.

src/rtl/tidelink_rxclk_buf.sv wraps a single global clock buffer on the
recovered RX clock (§9 clock fix, 2026-05-19). It is the IP-boundary BUFG
that gives `pad_clk_rx` a deterministic dedicated clock route on every FPGA
build (Vivado was inferring fabric-LUT clock distribution otherwise — the
routed netlist showed 7×Place 30-568 warnings).

The module is parameter-gated:

    generate
      if (USE_CLKBUF) begin : g_bufg
    `ifndef TIDELINK_RXCLK_NO_PRIMITIVE
          BUFG u_rxclk_bufg (.I(clk_i), .O(clk_o));  // Xilinx primitive
    `else
          assign clk_o = clk_i;                       // opt-OUT escape hatch
    `endif
      end else begin : g_passthru
          assign clk_o = clk_i;                       // sim/ASIC default
      end
    endgenerate

This unit testbench covers the two sim-elaboratable corners:

  1. test_passthru_branch_selected
     USE_CLKBUF=0 selects g_passthru — proven via the parameter value and
     the flattened child-name list (no g_bufg-scoped names).
  2. test_optout_branch_selected
     USE_CLKBUF=1 + `define TIDELINK_RXCLK_NO_PRIMITIVE selects g_bufg
     and its opt-OUT `else — proven the same way.
  3. test_passthru_bit_exact
     Drives a square wave on clk_i and asserts clk_o_passthru tracks it
     value-for-value, every delta cycle, for many edges.
  4. test_optout_bit_exact
     Same, but for clk_o_optout (USE_CLKBUF=1 opt-OUT path).

What is NOT covered (deliberately): USE_CLKBUF=1 WITHOUT the
TIDELINK_RXCLK_NO_PRIMITIVE define. That corner would elaborate a real
Xilinx BUFG primitive, which VCS cannot resolve without the unisim
library. The FPGA build flow (Vivado synth + the routed netlist) covers
it — see pynq_host/BRINGUP_NEXT_STEPS.md.

Invocation (from repo root):
    cd /home/dam1n19/td_idelay_wt && source set_env.sh
    rm -rf cocotb/tidelink_rxclk_buf/sim_build
    make -C cocotb/tidelink_rxclk_buf

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.triggers import Timer


# --------------------------------------------------------------------------
# Generate-label / hierarchy introspection helpers (mirrors the pattern
# used in cocotb/tidelink_idelay_rx/test_idelay_optout_passthrough.py).
# --------------------------------------------------------------------------
def _child_names(handle):
    """Best-effort list of (possibly generate-label-flattened) child names
    VCS exposes for `handle`. VCS + cocotb 2.0 flattens a generate label
    into the child name (e.g. `g_passthru` becomes a prefix on the names
    of declarations inside it). When a generate `else` branch holds only
    a single `assign and no decls, the flattened name list may be empty —
    so the assertions below tolerate empty lists and check the PARAMETER
    value as the load-bearing proof of which branch was selected."""
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


@cocotb.test()
async def test_passthru_branch_selected(dut):
    """USE_CLKBUF=0 must select the `g_passthru` generate branch.

    Two independent proofs:
      (a) the DUT's USE_CLKBUF parameter reads 0;
      (b) no `g_bufg`-scoped name appears in the elaborated hierarchy
          (if it did, the constant generate-if would have picked the
          USE_CLKBUF=1 arm — which is the *other* DUT instance under
          tb_top, u_optout).
    """
    use_clkbuf = int(dut.u_passthru.USE_CLKBUF.value)
    dut._log.info(f"u_passthru.USE_CLKBUF = {use_clkbuf}")
    assert use_clkbuf == 0, (
        f"u_passthru.USE_CLKBUF = {use_clkbuf}, expected 0. tb_top must "
        f"hard-set USE_CLKBUF=1'b0 on u_passthru so the `g_passthru` "
        f"branch is selected; this TB exercises the sim/ASIC default."
    )

    names = _child_names(dut.u_passthru)
    dut._log.info(f"u_passthru child names = {names}")
    g_bufg_scoped = [n for n in names if n.split(".")[0] == "g_bufg"]
    assert not g_bufg_scoped, (
        "u_passthru exposes a `g_bufg`-scoped child with USE_CLKBUF=0 "
        f"(children: {names}). The constant generate-if selected the BUFG "
        "arm — either tb_top stopped hard-setting USE_CLKBUF=1'b0 or the "
        "gating was refactored. The sim/ASIC path is broken."
    )


@cocotb.test()
async def test_optout_branch_selected(dut):
    """USE_CLKBUF=1 must select the `g_bufg` generate branch, and the
    Makefile's `+define+TIDELINK_RXCLK_NO_PRIMITIVE must select its
    opt-OUT `else (the inverted safety net).

    Two independent proofs:
      (a) the DUT's USE_CLKBUF parameter reads 1;
      (b) no `g_passthru`-scoped name appears in the elaborated hierarchy
          (if it did, the wrong arm was selected).

    LIMITATION: the opt-OUT `else has no decls / no instances, so we
    cannot positively probe a BUFG cell's ABSENCE. Instead we use the
    parameter value + branch-name absence + the fact that VCS compile
    succeeded (a real BUFG would have failed elaboration without the
    unisim library).
    """
    use_clkbuf = int(dut.u_optout.USE_CLKBUF.value)
    dut._log.info(f"u_optout.USE_CLKBUF = {use_clkbuf}")
    assert use_clkbuf == 1, (
        f"u_optout.USE_CLKBUF = {use_clkbuf}, expected 1. tb_top must "
        f"hard-set USE_CLKBUF=1'b1 on u_optout so the `g_bufg` branch "
        f"is selected; with USE_CLKBUF=0 this would just re-test the "
        f"`g_passthru` case the u_passthru instance already covers."
    )

    names = _child_names(dut.u_optout)
    dut._log.info(f"u_optout child names = {names}")
    g_passthru_scoped = [n for n in names if n.split(".")[0] == "g_passthru"]
    assert not g_passthru_scoped, (
        "u_optout exposes a `g_passthru`-scoped child with USE_CLKBUF=1 "
        f"(children: {names}). The constant generate-if selected the "
        "USE_CLKBUF=0 arm — that is the case u_passthru already covers; "
        "this DUT instance must exercise the distinct USE_CLKBUF=1 opt-OUT."
    )

    dut._log.info(
        "OK: u_optout.USE_CLKBUF=1 with NO g_passthru-scoped child — the "
        "constant generate-if selected `g_bufg`, and the Makefile "
        "+define+TIDELINK_RXCLK_NO_PRIMITIVE selects its opt-OUT `else "
        "(otherwise VCS compile would have failed on an unresolved BUFG)."
    )


async def _drive_clock_and_compare(dut, dut_clk_out, n_edges=64):
    """Drive a square wave on tb_top.clk_i and compare dut_clk_out against
    clk_i every settle window. The DUT body is a pure combinational
    `assign clk_o = clk_i;` so clk_o must track clk_i value-for-value
    after any delta cycle. We toggle clk_i with explicit Timer delays
    rather than cocotb.Clock so that the comparison is independent of
    cocotb's clock infrastructure and gives a single source of truth."""
    period_ns = 10  # 100 MHz analog, value is irrelevant — only the toggle is.
    mismatches = 0
    checked = 0
    # Start from 0 so the first toggle is a 0->1 edge.
    dut.clk_i.value = 0
    await Timer(1, unit="ns")
    for i in range(n_edges):
        # Toggle clk_i
        new_val = 1 - int(dut.clk_i.value)
        dut.clk_i.value = new_val
        await Timer(period_ns // 2, unit="ns")
        ci = int(dut.clk_i.value)
        co = int(dut_clk_out.value)
        checked += 1
        if ci != co:
            mismatches += 1
            if mismatches <= 8:
                dut._log.error(
                    f"edge#{i}: clk_i={ci} != {dut_clk_out._name}={co}"
                )
    return mismatches, checked


@cocotb.test()
async def test_passthru_bit_exact(dut):
    """USE_CLKBUF=0 (`g_passthru` branch) — clk_o must equal clk_i bit-exact
    on every cycle. Combinational `assign, so any delay/inversion/logic
    shows up as a mismatch on the very next sample window.
    """
    mismatches, checked = await _drive_clock_and_compare(
        dut, dut.clk_o_passthru, n_edges=128
    )
    assert mismatches == 0, (
        f"g_passthru NOT bit-exact: {mismatches}/{checked} mismatches. "
        f"USE_CLKBUF=0 must be a pure `assign clk_o = clk_i; — any "
        f"mismatch means the g_passthru branch was broken or the "
        f"constant generate-if no longer selects it. The sim/ASIC/UVM "
        f"recovered-clock path would corrupt."
    )
    dut._log.info(
        f"OK: g_passthru bit-exact over {checked} edges — sim/ASIC "
        f"default passthrough holds."
    )


@cocotb.test()
async def test_optout_bit_exact(dut):
    """USE_CLKBUF=1 + `TIDELINK_RXCLK_NO_PRIMITIVE (`g_bufg` opt-OUT
    `else) — clk_o must equal clk_i bit-exact on every cycle. Same
    contract as test_passthru_bit_exact but on a DIFFERENT generate
    branch, proving the inverted safety net works.
    """
    mismatches, checked = await _drive_clock_and_compare(
        dut, dut.clk_o_optout, n_edges=128
    )
    assert mismatches == 0, (
        f"g_bufg opt-OUT NOT bit-exact: {mismatches}/{checked} mismatches. "
        f"USE_CLKBUF=1 + `TIDELINK_RXCLK_NO_PRIMITIVE must be a pure "
        f"`assign clk_o = clk_i; — any mismatch means the opt-OUT `else "
        f"was broken (delay/inversion/logic inserted) or the gating was "
        f"refactored back to an opt-IN `ifdef. The non-Vivado USE_CLKBUF=1 "
        f"flow would corrupt the recovered RX clock."
    )
    dut._log.info(
        f"OK: g_bufg opt-OUT bit-exact over {checked} edges — inverted "
        f"safety net holds, the non-Vivado USE_CLKBUF=1 path is safe."
    )
