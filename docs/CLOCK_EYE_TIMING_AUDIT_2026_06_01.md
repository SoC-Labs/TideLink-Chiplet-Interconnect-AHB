# Clock-Eye Timing Audit — `pad_clk_tx` ODDR investigation (Build #10)

**Date:** 2026-06-01
**Trigger:** Scope observation that `pad_clk_tx` arrives **late within the data eye** — symptomatic of a source-synchronous TX without centred-launch.
**Scope:** read-only RTL/XDC inspection. No commits.

---

## 1. Verdict

**NO** — Build #10's bitstream does **NOT** use an ODDR on `pad_clk_tx`.

The `pynq-z2-pair-all` (master) and `pynq-z2-pair-flip-all` (slave) targets used by
Build #9/#10 wire `tidelink_0/pad_clk_tx` directly to the BD output port, with
no ODDR re-launch and no MMCM-derived phase shift. The clock is a plain
combinational forward through an `OBUF` (Vivado-inferred default).

The scope symptom (clock late in the eye) is **expected** for this
configuration: data uses an IOB output FF (`OFF`-packed mux output), while the
clock takes a slower LUT/clock-gate path. The receiver compensates with
per-lane `IDELAYE2` taps + calibrator phase sweeps — i.e. RX-side phase
recovery, not TX-side centred launch.

---

## 2. RTL paths traced

### TX clock launch (master)
- `src/rtl/local_overrides/WavD2DGpioTx.v:308` —
  `assign io_pad_clk = hs_clk_gated_wcg_io_clk_out;`
  Combinational assign out of a `WavClockGate` cell (line 293). No ODDR, no
  register stage between the gated clock and the pad.
- `src/rtl/local_overrides/WavD2DGpio.v:850` —
  `assign io_pad_clk_tx = gpiotx_0_io_pad_clk;` (forwards lane-0 TX clock to
  the GPIO pad).
- `src/rtl/local_overrides/Wlink.v:1698` —
  `assign pad_clk_tx = phy_pad_clk_tx;` (Wlink top passthrough).
- `src/rtl/local_overrides/axi_chiplet_controller.sv:1681` —
  `.pad_clk_tx (pad_clk_tx)` (chiplet controller passthrough).
- `src/rtl/tidelink_top.sv:2027` — `.pad_clk_tx (pad_clk_tx)` (tidelink_top port).

### TX data launch (master, lanes [7:0])
- `WavD2DGpioTx.v:307` —
  `assign io_pad = 4'hf == count ? tx_pad_array_15 : _GEN_14;`
  16-to-1 mux of `_link_data_eff` selected by the `count` register (lines
  274-286). Vivado's IOB packer normally absorbs the mux output into an `OFF`
  inside the IOB → fast, near-zero-skew launch.

### BD-level wiring (Build #10 target)
- `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl:558` —
  `connect_bd_net [get_bd_pins tidelink_0/pad_clk_tx] [get_bd_ports pad_clk_tx]`
  (direct wire, no ODDR cell inserted).
- `fpga/targets/pynq-z2-pair-flip-all/tidelink_design.tcl:540` — same.

### XDC constraint
- `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_timing.xdc:158-167` declares
  `pad_clk_tx_fwd` as a generated clock 1:1 off `clk_wiz_0/clk_out1` (25 MHz
  `hclk`) and constrains `pad_tx[*]` with a symmetric ±5 ns window. The
  constraint is a virtual forwarded-clock model — there is no physical phase
  shift on the launching clock.

### ODDR primitive — exists, but in a DIFFERENT target
- `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_clk_tx_oddr.v:47-59`
  — SAME_EDGE ODDR with `D1=0`, `D2=1`, `INIT=1'b0` (canonical UG903
  Example-6 centred-launch).
- `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-flip-all/tidelink_clk_tx_oddr.v`
  — flip-side copy.
- Wrappers added in commit `6ace849` (2026-05-28); reset cleanup `68b6359`.
- **Neither variant is the one Build #10 uses.**

---

## 3. Comparison to known-good 72c280b (16/16)

`git show 72c280b -- fpga/targets/` returns no ODDR references; `git ls-tree
72c280b fpga/targets/` shows no `*oddr*` files. The verified-good 16/16
configuration also had **no ODDR** on `pad_clk_tx`. Its TX path is identical
to Build #10's: combinational launch + RX-side `IDELAYE2`/calibrator
absorption. So Build #10 has not regressed *relative to 72c280b* on this
axis — but the centred-launch fix has never landed on the default `pair-all`
targets. The improvement was developed in `pair-mmcmbypass-oddr-{,flip-}all`
and left as an opt-in variant.

---

## 4. Recommended fix

Two options, in increasing scope.

### Option A — switch deploy to the existing ODDR variant
Lowest-risk: re-point `make farm_build` / `bringup_pair_converge.sh` and the
master/slave deploy lines in `fpga/Makefile:451-453` from
`pynq-z2-pair-{,flip-}all` to `pynq-z2-pair-mmcmbypass-oddr-{,flip-}all`. The
ODDR wrapper, XDC delta, and BD changes already exist. No RTL edit needed.
Trade-off: also pulls in the MMCM-bypass changes; revalidate at 25 MHz.

### Option B — port the ODDR wrapper into `pair-all`
If MMCM-bypass is undesirable, copy two files into the active target and add
two BD lines:
- Copy `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_clk_tx_oddr.v`
  into `fpga/targets/pynq-z2-pair-all/` and the flip equivalent.
- In `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl`, replace line 558
  with the ODDR-routed pattern from `pynq-z2-pair-mmcmbypass-oddr-all/tidelink_design.tcl:356-359, 378-379, 653-659`
  (the `add_files` for `tidelink_clk_tx_oddr.v`, the `create_bd_cell -reference
  tidelink_clk_tx_oddr`, the two `connect_bd_net` for `clk_in`/`pad_out`, and
  the `xlconstant` reset tie).
- Repeat for `pair-flip-all` (line 540).
- Update timing XDC: `set_output_delay` source should be the ODDR `C` pin
  (see `pair-mmcmbypass-oddr-all/pynq_z2_tidelink_timing.xdc:159-176` for the
  exact wording — accounts for ODDR `Tckq`).

Either way, **leave the existing RX `IDELAYE2` + calibrator paths in place**
— centred launch shrinks the residual skew, it doesn't make RX phase
recovery unnecessary.

---

## 5. Expected scope behaviour

**At 25 MHz `hclk` (40 ns period, SDR — one bit per `hclk` cycle):**

- **Pre-fix (Build #10, today):** `pad_clk_tx` rising edge launches at the
  same `hclk` rising edge as `pad_tx[*]` (notionally aligned to the **data
  transition**, i.e. edge-aligned). Real-world: clock path through
  `WavClockGate` + OBUF is `~1-3 ns` slower than the IOB-OFF data path → clock
  edge falls **just after** the data transition, **at the start of the next
  bit**. Receiver, sampling on `pad_clk_rx` rising edge, sees the **wrong half** of
  the eye unless `IDELAYE2` adds `~15-20 ns` of compensation. This matches the
  scope.

- **Post-fix (Option A or B, ODDR D1=0/D2=1 SAME_EDGE):** `pad_clk_tx` rising
  edge launches on the `hclk` **falling edge** — i.e. 20 ns after the data
  launch. The clock edge then lands in the **centre of the 40 ns bit cell**.
  On the scope you should see `pad_clk_tx` rising edge centred between two
  `pad_tx[*]` data transitions (roughly `+20 ns` after each data edge, `-20 ns`
  before the next). Calibrator should converge with `IDELAYE2 ~ 0-5` taps
  instead of the high tap counts currently required.

---

## Appendix — files referenced

- `src/rtl/local_overrides/WavD2DGpioTx.v:293, 307, 308`
- `src/rtl/local_overrides/WavD2DGpio.v:850`
- `src/rtl/local_overrides/Wlink.v:1698`
- `src/rtl/local_overrides/axi_chiplet_controller.sv:1681`
- `src/rtl/tidelink_top.sv:2027`
- `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl:558`
- `fpga/targets/pynq-z2-pair-flip-all/tidelink_design.tcl:540`
- `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_timing.xdc:158-167`
- `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_clk_tx_oddr.v` (proposed source)
- `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_design.tcl:356-379, 648-660`
- `docs/archive/UG903_FORWARDED_CLOCKS_AUDIT_2026_05_28.md` (prior audit
  reaching the same RTL conclusion)
- Commits: `6ace849` (ODDR variant add), `68b6359` (reset tie), `72c280b`
  (known-good 16/16, also no ODDR).
