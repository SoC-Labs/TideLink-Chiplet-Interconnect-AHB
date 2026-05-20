"""
test_idelay_optout_passthrough — pins the IDELAY OPT-OUT escape hatch.

fpga/rtl/tidelink_idelay_rx.sv gates a Xilinx IDELAYE2/IDELAYCTRL RX-delay
path. After commit 1b2e87e the gating is:

    generate
      if (USE_IDELAY) begin : g_idelay
    `ifndef TIDELINK_IDELAY_NO_PRIMITIVE
          ... real IDELAYE2/IDELAYCTRL (unisim — NOT elaboratable in VCS) ...
    `else
          assign pad_rx_o = pad_rx_i;          // <-- opt-OUT passthrough
    `endif
      end else begin : g_passthru
          assign pad_rx_o = pad_rx_i;          // sim/ASIC default
      end

The OPT-OUT corner — USE_IDELAY=1 AND `define TIDELINK_IDELAY_NO_PRIMITIVE
=> bit-exact passthrough with NO unisim primitive — is the inverted safety
net that lets a non-Vivado flow force USE_IDELAY=1 without a unisim library.
It had ZERO test coverage: cocotb/phy_align/test_idelay_tap_wiring.py only
covers the USE_IDELAY=0 `g_passthru` arm (the wlink_pair TB hard-wires
USE_IDELAY=0). A future edit that re-breaks the gating (reinstating an
opt-IN `ifdef, or breaking the opt-OUT `else) must be caught by THIS fast
sim, not only by a 22-minute FPGA build.

This standalone TB (tb_top.sv) instantiates tidelink_idelay_rx with
USE_IDELAY=1'b1 (so the `g_idelay` branch is selected) and the Makefile
compiles with +define+TIDELINK_IDELAY_NO_PRIMITIVE (so that branch takes
its opt-OUT `else). The tests:

  1. test_optout_branch_selected — proves the USE_IDELAY=1 branch was
     elaborated, via two independent VCS-introspectable facts:
       (a) the `USE_IDELAY` parameter on the DUT reads 1; and
       (b) the DUT's child list contains the `g_idelay`-scoped tie-off
           `_unused_idelay` (VCS flattens the generate label, exposing it
           as the child name "g_idelay._unused_idelay") and does NOT
           contain a `g_passthru`-scoped one.
     Together these prove the constant generate-if selected `g_idelay`,
     distinguishing this from the USE_IDELAY=0 `g_passthru` case that
     test_idelay_tap_wiring.py already covers. (cocotb 2.0/VCS does not
     resolve the bare generate label via getattr — see the limitation
     note in test_optout_branch_selected.)
  2. test_optout_passthrough_bit_exact — drives random vectors on
     pad_rx_i and asserts pad_rx_o is bit-exact equal to pad_rx_i every
     cycle. Combinational `assign, so it must track value-for-value
     (including the all-ones / walking patterns) with zero delay.

Invocation (from repo root):
    cd /home/dam1n19/td_idelay_wt && source set_env.sh
    rm -rf cocotb/tidelink_idelay_rx/sim_build
    make -C cocotb/tidelink_idelay_rx

(The simv is NOT rebuilt on RTL/+define+ edits — clean sim_build first or a
stale simv gives a false PASS. This matters most for the negative control.)
"""
import random

import cocotb
from cocotb.triggers import Timer


# --------------------------------------------------------------------------
# Generate-label / hierarchy introspection
# --------------------------------------------------------------------------
def _dut(dut):
    """The tidelink_idelay_rx instance under the TB top."""
    return dut.u_dut


def _child_names(handle):
    """Best-effort list of the (possibly generate-label-flattened) child
    names VCS exposes for `handle`.

    VCS + cocotb 2.0 does NOT resolve a bare generate label
    (`getattr(u_dut, "g_idelay")` raises) — instead it FLATTENS the label
    into the child name, e.g. the `_unused_idelay` tie-off declared inside
    `generate ... begin : g_idelay` is exposed as the single child name
    "g_idelay._unused_idelay". So iterate children and read `_name`.
    """
    names = []
    try:
        for k in handle:
            try:
                names.append(k._name)
            except Exception:  # noqa: BLE001 - cocotb raises plain Exception
                pass
    except Exception:  # noqa: BLE001
        pass
    return names


@cocotb.test()
async def test_optout_branch_selected(dut):
    """USE_IDELAY=1 must select the `g_idelay` generate branch (NOT
    `g_passthru`). This is what distinguishes the OPT-OUT corner from the
    USE_IDELAY=0 case test_idelay_tap_wiring.py already covers.

    Two independent VCS-introspectable proofs:

      (a) the DUT's `USE_IDELAY` parameter reads 1 (cocotb exposes it as a
          readable handle on this VCS build); and
      (b) the DUT's flattened child-name list contains a `g_idelay`-scoped
          name (the `_unused_idelay` tie-off that lives inside the
          generate block, exposed by VCS as "g_idelay._unused_idelay")
          and NO `g_passthru`-scoped name.

    LIMITATION: cocotb 2.0 + VCS 2022.06 does not resolve the bare
    generate label via getattr (`u_dut.g_idelay` raises "contains no child
    object named g_idelay"), and the opt-OUT `else body has no
    instances/IDELAYE2 to introspect (it is a pure `assign + one tie-off
    wire). So we cannot positively probe an IDELAYE2's ABSENCE; instead we
    use the label-scoped tie-off NAME + the USE_IDELAY parameter value,
    both of which uniquely identify the selected branch.
    """
    dutc = _dut(dut)

    # (a) The parameter the constant generate-if switches on.
    use_idelay = int(dutc.USE_IDELAY.value)
    dut._log.info(f"u_dut.USE_IDELAY = {use_idelay}")
    assert use_idelay == 1, (
        f"u_dut.USE_IDELAY = {use_idelay}, expected 1. tb_top must "
        f"hard-set USE_IDELAY=1'b1 so the `g_idelay` branch is selected; "
        f"with USE_IDELAY=0 this TB would just re-test the `g_passthru` "
        f"case test_idelay_tap_wiring.py already covers."
    )

    # (b) Flattened generate-label-scoped child names.
    names = _child_names(dutc)
    dut._log.info(f"u_dut child names = {names}")
    g_idelay_scoped = [n for n in names if n.split(".")[0] == "g_idelay"]
    g_passthru_scoped = [n for n in names if n.split(".")[0] == "g_passthru"]
    dut._log.info(
        f"g_idelay-scoped children = {g_idelay_scoped}   "
        f"g_passthru-scoped children = {g_passthru_scoped}"
    )

    assert g_idelay_scoped, (
        "No `g_idelay`-scoped child in the elaborated DUT hierarchy "
        f"(children: {names}). The opt-OUT `else declares an "
        "`_unused_idelay` tie-off inside `generate ... begin : g_idelay`, "
        "which VCS exposes as 'g_idelay._unused_idelay'. Its absence means "
        "the USE_IDELAY=1 `g_idelay` branch was NOT selected — either "
        "tb_top stopped hard-setting USE_IDELAY=1 or the gating was "
        "refactored back to an opt-IN `ifdef. This TB no longer tests the "
        "OPT-OUT corner."
    )
    assert not g_passthru_scoped, (
        "A `g_passthru`-scoped child IS present with USE_IDELAY=1 "
        f"(children: {names}) — the constant generate-if selected the "
        "USE_IDELAY=0 arm. That is the case test_idelay_tap_wiring.py "
        "already covers; this TB must exercise the distinct USE_IDELAY=1 "
        "OPT-OUT branch."
    )

    dut._log.info(
        "OK: USE_IDELAY=1 AND a g_idelay-scoped child present with NO "
        "g_passthru-scoped child — the constant generate-if selected the "
        "`g_idelay` branch, and (Makefile +define+"
        "TIDELINK_IDELAY_NO_PRIMITIVE) its opt-OUT `else. This is the "
        "distinct OPT-OUT corner, NOT the USE_IDELAY=0 g_passthru case."
    )


@cocotb.test()
async def test_optout_passthrough_bit_exact(dut):
    """USE_IDELAY=1 + `TIDELINK_IDELAY_NO_PRIMITIVE => pad_rx_o must equal
    pad_rx_i bit-exact, combinationally, for every driven vector. The
    opt-OUT body is a pure `assign pad_rx_o = pad_rx_i; — any inserted
    delay, inversion, or logic (a broken opt-OUT) shows up immediately.

    pad_rx_i is 8 bits (NUM_LANES). We sweep all 256 exhaustive values
    (cheap, removes any randomness flake) PLUS extra randomised vectors,
    settle a delta-cycle, and compare .binstr (0/1/x/z literal — exactly
    what a combinational passthrough must satisfy)."""
    dutc = _dut(dut)
    width = len(dutc.pad_rx_i)

    # Idle the unrelated control inputs — they are tied off / unused in the
    # opt-OUT body but must not float into the comparison via X.
    dutc.idelay_ref_clk.value = 0
    dutc.idelay_rst.value = 0
    dutc.phase_tap_i.value = 0
    await Timer(1, units="ns")

    rng = random.Random(0xC0FFEE)
    # Exhaustive over an 8-lane bus, then 256 random reseeds of the same
    # space to also wiggle phase_tap_i (must NOT affect pad_rx_o).
    exhaustive = list(range(1 << width))
    randomised = [rng.getrandbits(width) for _ in range(256)]

    mismatches = 0
    checked = 0
    for i, vec in enumerate(exhaustive + randomised):
        dutc.pad_rx_i.value = vec
        # Stir the would-be IDELAY tap source; the opt-OUT passthrough must
        # be totally insensitive to it.
        dutc.phase_tap_i.value = rng.getrandbits(len(dutc.phase_tap_i))
        await Timer(1, units="ns")  # let the combinational `assign settle

        pi = dutc.pad_rx_i.value.binstr
        po = dutc.pad_rx_o.value.binstr
        checked += 1
        if pi != po:
            mismatches += 1
            if mismatches <= 8:
                dut._log.error(
                    f"vec#{i}: pad_rx_i={pi} != pad_rx_o={po} "
                    f"(drove 0x{vec:0{(width + 3) // 4}x})"
                )

    assert mismatches == 0, (
        f"OPT-OUT passthrough NOT bit-exact: {mismatches}/{checked} "
        f"pad_rx_i != pad_rx_o vectors. With USE_IDELAY=1 + "
        f"`TIDELINK_IDELAY_NO_PRIMITIVE the RTL must be a pure "
        f"`assign pad_rx_o = pad_rx_i; — any mismatch means the opt-OUT "
        f"`else was broken (delay/inversion/logic inserted) or the gating "
        f"was refactored. The non-Vivado USE_IDELAY=1 flow would corrupt "
        f"the RX bus."
    )
    dut._log.info(
        f"OK: USE_IDELAY=1 + `TIDELINK_IDELAY_NO_PRIMITIVE opt-OUT "
        f"passthrough bit-exact over {checked} vectors "
        f"({len(exhaustive)} exhaustive + {len(randomised)} random, "
        f"phase_tap_i stirred throughout) — the inverted safety net holds."
    )
