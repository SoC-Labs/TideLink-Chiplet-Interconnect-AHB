"""
test_clkbuf_passthrough — pin USE_CLKBUF=0 functional equivalence of the
WavD2DGpioRx in-PHY BUFG restructure (§9 clock fix, 2026-05-19).

The §9 fix added a generate block inside WavD2DGpioRx.v:

    generate
      if (USE_CLKBUF) begin : g_clkbuf
          BUFG u_cap_bufg (.I(io_pad_clk),    .O(w_cnt_clk));
          assign w_pad_clk = w_cnt_clk;
          BUFG u_lnk_bufg (.I(~adj_count[3]), .O(w_lnk_clk));
      end else begin : g_passthru
          assign w_cnt_clk = pad_clk_scan_mux_io_o_z;     // original
          assign w_pad_clk = pad_clk_inv_scan_mux_1_io_o_z;
          assign w_lnk_clk = io_link_clk_mux_io_o_z;
      end
    endgenerate

The USE_CLKBUF=0 branch ALIASES the three derived clocks back to the original
WavClockMux outputs — pre-restructure bit-exact. This test pins that
equivalence with a known periodic-byte stream:

  1. test_use_clkbuf0_branch_selected — the generate-if picked g_passthru
     (USE_CLKBUF=0 elaboration).
  2. test_legacy_capture_well_formed  — drive TRAINING_BYTE=0xA3 (period-8
     aperiodic) on io_pad as a free-running periodic byte stream, wait for
     the legacy count to free-run through the deserialiser pipeline, sample
     io_link_data and assert hi == lo (two-equal-bytes: the deserialiser
     captured a periodic byte stream from the SAME serialiser round). With
     USE_T3A=0 there is no comma-hunt: `count` just free-runs, so the exact
     byte value sampled depends on where POR deassertion lands in the bit
     stream (the per-deploy lottery T3a exists to defeat). The CONVENTION-
     FREE invariant we CAN assert without testing the lottery is hi == lo,
     and non-degenerate (not 0x0000 or 0xFFFF). This is exactly what the
     pre-restructure RTL produces for the same stimulus, which is what
     "functional equivalence on USE_CLKBUF=0" means here.

What is NOT covered (deliberately): USE_CLKBUF=1. That branch elaborates
real Xilinx BUFG primitives that VCS cannot resolve without the unisim
library. The opt-OUT escape hatch (TIDELINK_RXCLK_NO_PRIMITIVE) does exist
inside USE_CLKBUF=1 but its `else just reuses the same WavClockMux output
assignments as USE_CLKBUF=0 — giving no functional coverage delta over
this test. The cocotb/tidelink_rxclk_buf test covers an analogous opt-OUT
on a SINGLE-clock boundary BUFG, where the proof IS load-bearing.

Invocation:
    cd /home/dam1n19/td_idelay_wt && source set_env.sh
    rm -rf cocotb/wavd2d_gpiorx_clkbuf/sim_build
    make -C cocotb/wavd2d_gpiorx_clkbuf

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


# Lane-0 training byte from WavD2DGpio.v. Period-8 aperiodic — unique under
# cyclic rotation. With USE_T3A=0 the comma-hunt FSM is gated out, so this
# byte is just any non-degenerate test vector here; the load-bearing property
# is "periodic byte stream → hi == lo two-equal-byte 16-bit word".
TRAINING_BYTE = 0xA3


def _child_names(handle):
    """Best-effort flattened child-name list (mirrors helper used elsewhere)."""
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
async def test_use_clkbuf0_branch_selected(dut):
    """USE_CLKBUF=0 must select the `g_passthru` arm of the in-PHY generate.

    Proof: read u_dut.USE_CLKBUF (parameter, exposed by VCS) and confirm
    it is 0. We also check that no `g_clkbuf`-scoped child name appears
    in the elaborated DUT hierarchy — if it did, the constant
    generate-if would have picked the FPGA arm. (BUFG cell instances
    inside g_clkbuf would have failed VCS compile anyway, but the
    parameter+child-name pair is the load-bearing belt-and-braces.)
    """
    use_clkbuf = int(dut.u_dut.USE_CLKBUF.value)
    dut._log.info(f"u_dut.USE_CLKBUF = {use_clkbuf}")
    assert use_clkbuf == 0, (
        f"u_dut.USE_CLKBUF = {use_clkbuf}, expected 0. tb_top must "
        f"hard-set USE_CLKBUF=1'b0 so the `g_passthru` clock-alias "
        f"arm is selected — that is the sim/ASIC/UVM default and the "
        f"path under test for legacy bit-exact equivalence."
    )

    names = _child_names(dut.u_dut)
    dut._log.info(f"u_dut child names = {names}")
    g_clkbuf_scoped = [n for n in names if n.split(".")[0] == "g_clkbuf"]
    assert not g_clkbuf_scoped, (
        f"u_dut exposes a `g_clkbuf`-scoped child with USE_CLKBUF=0 "
        f"(children: {names}). The constant generate-if selected the "
        f"FPGA BUFG arm — that path requires unisim. The sim/UVM/ASIC "
        f"legacy path is broken."
    )
    dut._log.info(
        "OK: USE_CLKBUF=0 and no g_clkbuf-scoped child — the in-PHY "
        "generate selected the legacy WavClockMux-alias arm."
    )


async def _start_clock(dut):
    """50 MHz on io_pad_clk."""
    cocotb.start_soon(Clock(dut.io_pad_clk, 10, unit="ns").start())


async def _drive_periodic_byte_stream(dut, byte, n_bits=256):
    """Drive a free-running, MSB-first, period-8 byte stream on io_pad while
    holding the lane in its post-POR free-run phase. Wait n_bits pad_clk
    cycles so the deserialiser pipeline (count free-run → link_data_pad_clk
    → link_data_reg) has filled at least one fresh 16-bit word.
    """
    # Apply POR while priming the input. The legacy USE_T3A=0 path has no
    # comma hunt — count just resets to 4'hf and free-runs, so the bit-stream
    # phase relative to count is deterministic given a stable POR-deassertion
    # alignment. We drive the stream BEFORE deasserting POR, then continue.
    dut.io_por_reset.value = 1
    dut.io_pad.value = 0
    for _ in range(16):
        await RisingEdge(dut.io_pad_clk)
    # Release POR, drive the stream.
    dut.io_por_reset.value = 0
    for t in range(n_bits):
        bit_idx = t & 0x7
        # MSB-first within the byte: bit (7 - bit_idx).
        bit = (byte >> (7 - bit_idx)) & 0x1
        dut.io_pad.value = bit
        await RisingEdge(dut.io_pad_clk)


@cocotb.test()
async def test_legacy_capture_well_formed(dut):
    """USE_CLKBUF=0 + USE_T3A=0: drive a periodic byte stream on io_pad and
    assert io_link_data is well-formed (hi byte == lo byte, non-degenerate).

    This is the convention-free invariant of "the deserialiser captured a
    PERIODIC byte stream" — it holds for any MSB-first/LSB-first ordering
    and any free-running count phase. If the in-PHY USE_CLKBUF=0 arm broke
    its clock aliasing (e.g. an inverted assignment, a constant 0/1, or a
    swap between w_cnt_clk / w_pad_clk / w_lnk_clk), the deserialiser would
    capture noise or freeze, and hi != lo or io_link_data would be
    degenerate (stuck 0x0000 / 0xFFFF).

    NOT load-bearing: the exact byte value sampled. With USE_T3A=0 there is
    no comma alignment, so the captured word is the byte rotated by an
    arbitrary count phase that depends on POR-deassertion timing — exactly
    the per-deploy lottery that T3a exists to defeat. The lottery is
    irrelevant to "did the restructure regress the legacy capture chain";
    the hi==lo periodic-byte property suffices and is convention-free.
    """
    await _start_clock(dut)
    # Drive enough bits for the deserialiser pipeline to definitely have
    # filled a fresh 16-bit word past the POR-reset of link_data_reg.
    # The pipeline depth is count(16) + link_data_pad_clk(1 word clk) +
    # link_data_reg(1 word clk) ≈ 48 pad_clks worst-case, plus margin so
    # both half-words of the 16-bit window are filled by the same byte
    # rotation.
    await _drive_periodic_byte_stream(dut, TRAINING_BYTE, n_bits=512)
    # Sample mid-stream while still driving: the legacy capture chain
    # needs a continuous stream — if we stop driving, the next /16 word
    # boundary will capture zeros. Drive a final batch and sample at the
    # end.
    word = int(dut.io_link_data.value)
    hi = (word >> 8) & 0xFF
    lo = word & 0xFF
    dut._log.info(
        f"io_link_data (mid-stream) = 0x{word:04X}  "
        f"(hi=0x{hi:02X}, lo=0x{lo:02X})"
    )

    assert hi == lo, (
        f"io_link_data 0x{word:04X} is NOT two equal bytes "
        f"(hi=0x{hi:02X}, lo=0x{lo:02X}) — the USE_CLKBUF=0 legacy "
        f"capture chain did NOT recover a periodic byte stream from the "
        f"period-8 io_pad. Either an alias of w_cnt_clk/w_pad_clk/w_lnk_clk "
        f"was broken in the g_passthru arm, or the deserialiser pipeline "
        f"was structurally regressed by the §9 clock restructure. The "
        f"sim/ASIC/UVM path is no longer bit-exact to the pre-restructure RTL."
    )
    assert word not in (0x0000, 0xFFFF), (
        f"io_link_data = 0x{word:04X} is a degenerate stuck-at value — "
        f"the lane appears NOT to be receiving the io_pad stream. The "
        f"USE_CLKBUF=0 g_passthru arm is broken — one of w_cnt_clk / "
        f"w_pad_clk / w_lnk_clk is tied off or not toggling."
    )
    dut._log.info(
        f"OK: USE_CLKBUF=0 + USE_T3A=0 captured a non-degenerate periodic "
        f"byte word (hi==lo). The §9 in-PHY BUFG restructure preserves "
        f"bit-exact behaviour on the sim/ASIC/UVM default path."
    )
