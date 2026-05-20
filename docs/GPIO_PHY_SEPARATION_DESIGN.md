# TideLink GPIO PHY — Clean Architectural Separation Design

Author:  SoC Labs (David Mapstone, `d.a.mapstone@soton.ac.uk`)
Date:    2026-05-20
Branch:  `feat/td-combined` (parent), `deps/axi-chiplet-controller` @ `678a9b3`+
Status:  PROPOSAL — design document, not yet implemented.
Audit:   Operationalises the architectural recommendation in
         `docs/GPIO_PHY_ARCHITECTURE.md` §10.3 and the 16-modification
         audit (agent ac91...) recorded in
         `~/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/`
         project_tidelink_fpga_bringup.md (top ★★★★★★★ entry).

---

## 0. TL;DR

The §9 silicon bring-up worked. The RTL it left behind did not age well:
five SoC Labs additions are scattered across three files in two
repositories, three FPGA-only gate parameters (`USE_IDELAY`,
`USE_CLKBUF`, `USE_T3A`) thread five hierarchy levels deep, and the
`axi_chiplet_controller.sv` module — nominally a link-layer block — now
directly instantiates IDELAYE2 logic and wires the alignment calibrator
into Wlink's internal `swi_*` ports.

The functional behaviour is correct. The module boundary that carries
it is not. This document proposes a strict-mechanical refactor: hoist
the PHY-side logic into one `tidelink_gpio_phy.sv` top, collapse the
three gate parameters into one `USE_FPGA_PRIMITIVES` boundary, and
restore byte-identical pristine vendor Chisel files (`WavD2DGpio*.v`)
by relocating their SoC Labs patches into a new `tidelink_gpio_rx_align.sv`
per-lane wrapper. Five steps, each bit-exact on a passing regression,
and the chiplet-controller emerges with a clean PHY interface plus an
APB slave — no more reaching into Wlink internals.

Recommendation: schedule for the post-v1 cleanup window, defer if the
window slips. Don't do this between now and silicon tape-out.

---

## 1. Goals and non-goals

### 1.1 Goals

1. **Self-contained PHY.** The TideLink GPIO PHY is one module
   (`tidelink_gpio_phy`) with a well-bounded link-side interface, a
   small APB slave for calibration registers, and a clean pad bundle.
   No module outside the PHY reaches into PHY internals.

2. **One FPGA-primitives boundary.** All Xilinx 7-series primitives
   (`IDELAYE2`, `IDELAYCTRL`, `BUFG`) live behind a single
   `USE_FPGA_PRIMITIVES` parameter, at one module boundary. Today
   three independent gate parameters (`USE_IDELAY`, `USE_CLKBUF`,
   `USE_T3A`) cross five hierarchy levels, each threaded explicitly
   from `tidelink_vivado_wrapper` down to `WavD2DGpioRx`.

3. **Vendor-freezable Chisel files.** `WavD2DGpio.v`, `WavD2DGpioRx.v`,
   `WavD2DGpioTx.v` are byte-identical to the Chisel emitter's output.
   No SoC Labs edits inside them. A CI golden-checksum regression
   catches drift. This unblocks future Chisel-rebuild flows and makes
   IP vendor swap mechanically possible.

4. **Independent PHY verification.** The PHY can be exercised in
   isolation — per-lane unit tests, pair-level integration tests —
   without elaborating Wlink, the FCSM, the AXI bridges, or the
   chiplet-controller's APB plumbing.

5. **Vendor IP swap path.** If a future PHY (`tidelink_gpio_phy_v2`)
   based on `ISERDESE2` or `GTX` arrives, it drops in as a sibling
   module exposing the same link-side interface; nothing in the
   chiplet controller changes.

### 1.2 Non-goals

* **No behavioural change.** This is a shape refactor. Every existing
  cocotb regression and the silicon-validated bitstream must produce
  bit-identical synthesised netlists pre- and post-refactor. The cocotb
  `wlink_pair / phy_align` sweep TBs, the ASIC flist
  (`tidelink_top_full_asic.flist`), and the FPGA build must all be
  invariant. (Where structural-renaming forces hierarchy-path changes
  in cocotb hierarchical-force tests, that change is mechanical and
  testbench-local.)

* **No on-wire change.** Training pattern bytes, lane rate, training
  sequence, FCSM protocol — all unchanged.

* **No pin-assignment change.** XDC files, IDELAYCTRL placement,
  IODELAY_GROUP membership, clock-region affinity all preserved.

* **No calibrator algorithm change.** Best-of-sweep, T3 re-sweep, T3.2
  S_HOLD are all preserved as-is. The calibrator just moves from
  `axi_chiplet_controller.sv` into `tidelink_gpio_phy.sv`.

* **NOT a redesign opportunity.** This proposal explicitly rejects
  using the refactor window to switch the deserialiser to ISERDESE2,
  to change the lane rate, or to add bank-aware calibration (the
  §10.2 future work).

---

## 2. The current entanglement (what's wrong today)

### 2.1 Hand-patches inside vendor Chisel files

Every SoC Labs edit inside `deps/axi-chiplet-controller/logical/wlink/`
that breaks vendor-freeze:

| File | Lines | Patch |
|---|---|---|
| `WavD2DGpioTx.v` | 16–17 | Added `io_training_mode`, `io_training_pattern[7:0]` ports |
| `WavD2DGpioTx.v` | 43–45 | `{pattern, pattern}` mux feeding `_link_data_eff` |
| `WavD2DGpioRx.v` | 1–21 | `USE_CLKBUF` parameter and rationale comment block |
| `WavD2DGpioRx.v` | 22–53 | `USE_T3A` + `TRAINING_BYTE` parameter block |
| `WavD2DGpioRx.v` | 60–67 | `io_phase_offset[3:0]` port + comment |
| `WavD2DGpioRx.v` | 68–74 | `io_bit_slip[2:0]` port + comment |
| `WavD2DGpioRx.v` | 109–112 | `adj_count = count + io_phase_offset` |
| `WavD2DGpioRx.v` | 180–186 | `_link_data_rep` + bit-slip rotation |
| `WavD2DGpioRx.v` | 201–207 | `~adj_count[3]` divided clock derivation |
| `WavD2DGpioRx.v` | 209–240 | `g_clkbuf` / `g_passthru` generate (USE_CLKBUF) |
| `WavD2DGpioRx.v` | 241–390 | T3a comma-hunt FSM, rotation match, count slip |
| `WavD2DGpio.v` | 1–12 | `USE_CLKBUF` and `USE_T3A` parameter declarations |
| `WavD2DGpio.v` | 305 | `swi_phase_offset` reg |
| `WavD2DGpio.v` | 322–324 | `out_prepend_1` widened to 21 bits |
| `WavD2DGpio.v` | 350–368 | `effective_bit_slip`, `effective_training_mode`, per-lane phase merge |
| `WavD2DGpio.v` | 491,505,519,533,547,561,575,589 | Per-lane `TRAINING_BYTE` overrides on the 8 `WavD2DGpioRx` instances (lane 0=`0xA3`, …, lane 7=`0x2D`) |
| `WavD2DGpio.v` | 59–71 | `io_swi_bit_slip_in`, `io_swi_training_mode_in`, `io_swi_phase_offset_in` ports |
| `WlinkGPIOPHY.v` | 1–6 | `USE_CLKBUF`, `USE_T3A` parameter pass-through |
| `WlinkGPIOPHY.v` | 53–58 | `swi_bit_slip_in`, `swi_training_mode_in`, `swi_phase_offset_in` ports |
| `WlinkGPIOPHY.v` | 101 | `WavD2DGpio #(.USE_CLKBUF, .USE_T3A)` instantiation |
| `Wlink.v` | 1–6 | `USE_CLKBUF`, `USE_T3A` parameter declarations |
| `Wlink.v` | 1054 | `WlinkGPIOPHY #(.USE_CLKBUF, .USE_T3A)` instantiation |

This is **23 distinct patches in 4 generated files**. Each is correct,
documented, and minimal — but together they make `deps/axi-chiplet-controller/logical/wlink/`
non-vendor-freezable. A Chisel re-emit would silently overwrite all of
them, an irreversible loss of months of forensic work.

### 2.2 PHY-related signals in `axi_chiplet_controller.sv`

The chiplet controller is supposed to be the link-layer block. Today
it carries the entire PHY-alignment subsystem inside its `endmodule`:

| Reference | What it is |
|---|---|
| `axi_chiplet_controller.sv:23–29` | `AUTOCAL_ENABLE` parameter |
| `axi_chiplet_controller.sv:30–47` | `USE_IDELAY`, `USE_CLKBUF`, `USE_T3A` parameters |
| `axi_chiplet_controller.sv:272–276` | `pad_clk_tx`, `pad_tx[7:0]`, `pad_clk_rx`, `pad_rx[7:0]` pad bundle |
| `axi_chiplet_controller.sv:278–284` | `idelay_ref_clk`, `idelay_rst` IDELAY ports |
| `axi_chiplet_controller.sv:458–477` | Calibrator output net declarations (forward-declared because `default_nettype none`) |
| `axi_chiplet_controller.sv:541–706` | Region 8 control/status registers (SWI_BIT_SLIP, SWI_RECAL, SWI_PHASE_OFFSET, SWI_LANE_STATUS, …) |
| `axi_chiplet_controller.sv:1271–1310` | `tidelink_lane_checker` instance |
| `axi_chiplet_controller.sv:1321–1355` | `tidelink_phy_align_calibrator` instance + `autocal_force_enable_q` |
| `axi_chiplet_controller.sv:1357–1372` | OR-mux merging calibrator outputs with Region 8 SW overrides |
| `axi_chiplet_controller.sv:1374–1405` | `tidelink_idelay_rx` instance (FPGA IDELAYE2 wrapper) |
| `axi_chiplet_controller.sv:1415–1430` | `tidelink_rxclk_buf` instance (FPGA boundary BUFG) |
| `axi_chiplet_controller.sv:1435` | `Wlink #(.USE_CLKBUF, .USE_T3A) u_wlink` instantiation |
| `axi_chiplet_controller.sv:1584` | `Wlink.pad_clk_rx ← pad_clk_rx_buf` (BUFG output) |
| `axi_chiplet_controller.sv:1587–1594` | `Wlink.pad_rx_N ← pad_rx_dly[N]` (IDELAY output) |
| `axi_chiplet_controller.sv:1609–1613` | `Wlink.swi_bit_slip_in / swi_training_mode_in / swi_phase_offset_in` wires |
| `axi_chiplet_controller.sv:1616–1617` | `Wlink.phy_link_rx_rx_link_data_o / _link_clk_o` outputs feeding the calibrator |

In total **15 distinct PHY-side signal groups cross the
chiplet-controller / PHY boundary today**, none of them through a clean
interface. The forward-declared `phy_link_rx_rx_link_data_w` (line 476)
is particularly telling: an internal Wlink port escapes Wlink, gets
hand-routed through the controller, and lands inside a calibrator
instance. Wlink's idea of "internal" and the chiplet controller's idea
of "internal" disagree.

### 2.3 Coupling metric

A quick boundary-count, taking "distinct signal name" to mean a single
named wire-or-bus, plus the calibration/status APB region:

| Boundary | Today | Ideal |
|---|---|---|
| chiplet-controller ↔ PHY (signal count) | 15 groups, ~80 individual wires | 4 groups (pad, link_tx, link_rx, APB) |
| Wlink internal ports exposed to chiplet | 4 (`swi_bit_slip_in`, `swi_training_mode_in`, `swi_phase_offset_in`, `phy_link_rx_rx_link_data_o`) | 0 |
| FPGA-gate parameters threaded | 3 × 5 levels = 15 explicit ports | 1 × 2 levels = 2 explicit ports |
| SoC Labs edits in `WavD2DGpio*.v` | 23 distinct patches | 0 (vendor-frozen) |
| Files containing PHY structural logic | 6 (`axi_chiplet_controller.sv`, `tidelink_idelay_rx.sv`, `tidelink_rxclk_buf.sv`, `WavD2DGpioRx.v`, `WavD2DGpio.v`, `WlinkGPIOPHY.v`) | 3 (`tidelink_gpio_phy.sv`, `tidelink_gpio_rx_align.sv`, pristine `WavD2DGpio*.v`) |

### 2.4 Diagram — today's tangled boundary

```
  +-------------------------------------------------------------+
  | tidelink_top.sv                                             |
  |  defaults: USE_IDELAY=0  USE_CLKBUF=0  USE_T3A=0            |
  |  (fpga wrapper sets each to 1 via component.xml)            |
  |                                                             |
  |  +-------------------------------------------------------+  |
  |  | axi_chiplet_controller.sv                             |  |
  |  |   parameter AUTOCAL_ENABLE, USE_IDELAY,               |  |
  |  |             USE_CLKBUF, USE_T3A                       |  |
  |  |                                                       |  |
  |  |  +-----------+      +-------------+   +-----------+   |  |
  |  |  | lane_     |      | phy_align_  |   | Region 8  |   |  |
  |  |  | checker   |----->| calibrator  |---| status +  |   |  |
  |  |  | (link-rx  |      | (link-rx    |   | SW ctrl   |   |  |
  |  |  |  clock)   |      |  clock)     |   | regs      |   |  |
  |  |  +-----------+      +------+------+   +-----+-----+   |  |
  |  |                            |                |          |  |
  |  |       calibrator outputs   |   SW override  |          |  |
  |  |                            v                v          |  |
  |  |                       OR-MUX (line 1365-1372)          |  |
  |  |   swi_bit_slip_w,phase_offset_w,training_mode_w        |  |
  |  |                            |                          |  |
  |  |          +-----------------+--------------+           |  |
  |  |          |                                |           |  |
  |  |   +------v------+   +------+      +-------v--------+  |  |
  |  |   | tidelink_   |   | tide-|      | Wlink (Chisel) |  |  |
  |  |   | idelay_rx   |-->| link-|----->|   .swi_bit_   |  |  |
  |  |   | (USE_IDELAY)|   | rxclk|      |    slip_in    |  |  |
  |  |   +------^------+   | _buf |      |   .swi_phase_ |  |  |
  |  |          |          | (USE_|      |    offset_in  |  |  |
  |  |          |          | CLK- |      |   .swi_train_ |  |  |
  |  |          |          |  BUF)|      |    mode_in    |  |  |
  |  |          |          +---^--+      |  WlinkGPIOPHY |  |  |
  |  |          |              |         |   .USE_CLKBUF |  |  |
  |  |          |              |         |   .USE_T3A    |  |  |
  |  |          |              |         |  WavD2DGpio   |  |  |
  |  |          |              |         |   per-lane    |  |  |
  |  |          |              |         |   TRAINING_   |  |  |
  |  |          |              |         |   BYTE x8     |  |  |
  |  |          |              |         |  WavD2DGpioRx |  |  |
  |  |          |              |         |   io_phase_   |  |  |
  |  |          |              |         |   offset      |  |  |
  |  |          |              |         |   io_bit_slip |  |  |
  |  |          |              |         |   USE_CLKBUF  |  |  |
  |  |          |              |         |   USE_T3A     |  |  |
  |  |          |              |         |   T3a comma-  |  |  |
  |  |          |              |         |   hunt FSM    |  |  |
  |  |          |              |         |   in-PHY BUFG |  |  |
  |  |          |              |         +-------+-------+  |  |
  |  |          |              |                 |          |  |
  |  +----------|--------------|-----------------|----------+  |
  |             |              |                 |             |
  |        pad_rx[7:0]    pad_clk_rx       pad_clk_tx          |
  |                                        pad_tx[7:0]         |
  +-----------------------------------------------------------+
```

What's wrong is visible at a glance: the chiplet controller is the
common ancestor of the calibrator, the IDELAY wrapper, the BUFG
wrapper, the OR-mux, AND the Wlink instantiation, AND the Region 8
status registers. Three USE_* parameters thread independently from the
top through this module into Wlink's deep internals.

---

## 3. Proposed boundary

### 3.1 Module hierarchy

A new top-level PHY module is introduced:

```
  tidelink_gpio_phy.sv              <-- NEW; the clean PHY boundary
   |
   +--- WavD2DGpio (pristine)        <-- VENDOR-FROZEN
   |     +-- WavD2DGpioTx x8         <-- VENDOR-FROZEN
   |     +-- tidelink_gpio_rx_align  <-- NEW; per-lane wrapper, replaces
   |          x8                          WavD2DGpioRx instances
   |          +-- WavD2DGpioRx       <-- PRISTINE (T3a + io_phase_offset
   |                (pristine, but        + io_bit_slip + USE_CLKBUF moved
   |                 used inside         out into the wrapper above)
   |                 wrapper at
   |                 per-lane level)
   |
   +--- tidelink_idelay_rx           <-- IDELAYE2 + IDELAYCTRL (FPGA-only)
   +--- tidelink_rxclk_buf           <-- boundary BUFG (FPGA-only)
   +--- tidelink_phy_align_calibrator <-- sweep FSM
   +--- tidelink_lane_checker        <-- training-pattern detector
   +--- tidelink_gpio_phy_regs       <-- NEW; APB slave for Region 8
                                          (SWI_BIT_SLIP, SWI_PHASE_OFFSET,
                                           SWI_TRAINING_MODE, SWI_RECAL,
                                           SWI_LANE_STATUS, PHY_ALIGN_ID)
```

Note that the Chisel re-emit shape is preserved internally: `WavD2DGpio`
still exists, it still instantiates eight per-lane RX blocks, those
blocks are still `WavD2DGpioRx` underneath — but the in-PHY clean-clock
restructure (§5.3 of the architecture doc) and the T3a comma-hunt
(§5.4) and the `io_phase_offset` / `io_bit_slip` patches all move OUT
of `WavD2DGpioRx` into a new wrapper module that *contains* a pristine
`WavD2DGpioRx`. The Chisel-generated files are then byte-identical
to upstream.

### 3.2 PHY top-level interface (`tidelink_gpio_phy.sv`)

```
  module tidelink_gpio_phy #(
    parameter USE_FPGA_PRIMITIVES = 1'b0,   // <-- single boundary param
    parameter USE_IDELAY          = USE_FPGA_PRIMITIVES,  // sub-overridable
    parameter USE_CLKBUF          = USE_FPGA_PRIMITIVES,  // sub-overridable
    parameter USE_T3A             = USE_FPGA_PRIMITIVES,  // sub-overridable
    parameter AUTOCAL_ENABLE      = 1'b1,
    // calibrator tuning forwarded:
    parameter DWELL_CYCLES        = 64,
    parameter LOCK_THRESH         = 16,
    parameter HOLD_CYCLES         = 8 * 128 * DWELL_CYCLES,
    parameter EARLY_EXIT_ON_ALL_LOCKED = 1'b0
  ) (
    // --- Clocks, resets --------------------------------------------------
    input  wire        apb_clk,
    input  wire        user_hsclk,
    input  wire        poresetn,
    input  wire        hresetn,
    input  wire        role_locked,         // from link layer

    // --- Pads ------------------------------------------------------------
    output wire        pad_clk_tx,
    output wire [7:0]  pad_tx,
    input  wire        pad_clk_rx,
    input  wire [7:0]  pad_rx,

    // --- Link-side interface (to Wlink TX/RX link-layer) -----------------
    // RX side (PHY -> link)
    output wire        link_rx_link_clk,
    output wire [127:0] link_rx_link_data,
    input  wire [7:0]  link_rx_lane_mask,
    // TX side (link -> PHY)
    input  wire        link_tx_link_en,
    output wire        link_tx_link_ready,
    input  wire [127:0] link_tx_link_data,
    input  wire [7:0]  link_tx_lane_mask,
    output wire        link_tx_link_clk,

    // --- APB slave for calibration regs (Region 8) -----------------------
    input  wire        apb_psel,
    input  wire        apb_penable,
    input  wire        apb_pwrite,
    input  wire [11:0] apb_paddr,
    input  wire [31:0] apb_pwdata,
    input  wire [3:0]  apb_pstrb,
    output wire [31:0] apb_prdata,
    output wire        apb_pready,
    output wire        apb_pslverr,

    // --- IDELAYCTRL reference (FPGA only; tie to 0 in sim/ASIC) ----------
    input  wire        idelay_ref_clk,
    input  wire        idelay_rst,

    // --- Scan / DFT -----------------------------------------------------
    input  wire        scan_mode,
    input  wire        scan_asyncrst_ctrl,
    input  wire        scan_clk,
    input  wire        scan_shift,
    input  wire        scan_in,
    output wire        scan_out
  );
```

Exactly **four logical groups** cross the boundary: pads, RX link,
TX link, APB. (Plus the unavoidable clock/reset/DFT plumbing.) The
chiplet controller sees only these — it does NOT see `swi_bit_slip_w`,
it does NOT see `phy_link_rx_rx_link_data_w`, it does NOT see
`pad_clk_rx_buf` or `pad_rx_dly`. Those are PHY-internal nets.

### 3.3 Link-layer side: chiplet-controller becomes link-only

`axi_chiplet_controller.sv` retains:

* The Wlink instance (now with no `USE_CLKBUF` / `USE_T3A` params and
  no `swi_bit_slip_in / swi_phase_offset_in / swi_training_mode_in`
  ports — those Chisel-side ports are now driven by `tidelink_gpio_phy`
  from the PHY side because the OR-mux moves into the PHY).
* The FCSM, the AXI bridges, the AHB / FC adapter, the I2C cores.
* The role-register block.
* The role-strap evaluator and the peer-mask handshake.

It loses: the calibrator, the lane checker, the IDELAY wrapper, the
RX clock BUFG wrapper, the Region 8 status regs, the OR-mux, the
PHY parameter declarations, the pad bundle, the `idelay_ref_clk` /
`idelay_rst` ports.

Critically the chiplet controller no longer reaches the four Wlink
internal ports (`swi_bit_slip_in` etc., `phy_link_rx_rx_link_data_o`).
Those connect inside the PHY top now — the chiplet controller talks
to the PHY through the `link_tx_*` / `link_rx_*` interface, identical
to how the Wav PHY core already exposes them to the link layer.

### 3.4 Diagram — proposed clean boundary

```
  +-------------------------------------------------------------+
  | tidelink_top.sv                                             |
  |   parameter USE_FPGA_PRIMITIVES (default 0)                 |
  |                                                             |
  |  +--------------------------+   +------------------------+  |
  |  | axi_chiplet_controller   |   | tidelink_gpio_phy      |  |
  |  |   (link layer only)      |   |   USE_FPGA_PRIMITIVES  |  |
  |  |                          |   |   AUTOCAL_ENABLE       |  |
  |  |   +-------+              |   |   DWELL_CYCLES, ...    |  |
  |  |   | Wlink |              |   |                        |  |
  |  |   |  FCSM |   link-tx    |   |  +-----------------+   |  |
  |  |   |  AXI  |<------------>|<->|  | Wav PHY (FROZEN)|   |  |
  |  |   |  CRC  |   link-rx    |   |  |  +-------------+|   |  |
  |  |   |  ECC  |              |   |  |  | gpio_rx_     ||   |  |
  |  |   +-------+              |   |  |  | align x 8   ||   |  |
  |  |                          |   |  |  | (T3a, BUFGs,||   |  |
  |  |    role, FCSM, I2C, AXI, |   |  |  |  io_phase_  ||   |  |
  |  |    FC, AHB stay here     |   |  |  |  offset,    ||   |  |
  |  +-----------+--------------+   |  |  |  io_bit_slip||   |  |
  |              |  APB             |  |  | + WavGpioRx ||   |  |
  |              |  (Wlink slice +  |  |  +-------------+|   |  |
  |              |   Region 8 slice)|  +-----------------+   |  |
  |              v                  |    +----------------+  |  |
  |  (Region 8 APB peeled off       |    | tidelink_      |  |  |
  |   to PHY slave; rest of APB     +----| idelay_rx      |  |  |
  |   to Wlink slave)               |    | tidelink_      |  |  |
  |                                 |    | rxclk_buf      |  |  |
  |                                 |    | calibrator     |  |  |
  |                                 |    | lane_checker   |  |  |
  |                                 |    | gpio_phy_regs  |  |  |
  |                                 |    +----------------+  |  |
  |                                 |                        |  |
  |                                 +-----------+------------+  |
  |                                             |               |
  |                                pad_tx, pad_rx, pad_clk_*    |
  +-------------------------------------------------------------+
```

The chiplet controller and the PHY are siblings under `tidelink_top`,
connected by a four-group interface (link_tx, link_rx, APB, pads). No
internal signal of one module crosses into the other.

---

## 4. Migration plan — incremental, not big-bang

Five steps, each bit-exact, each independently CI-verifiable.

### Step 1 — create `tidelink_gpio_rx_align.sv` (per-lane wrapper)

**Goal:** move the four SoC Labs in-PHY patches out of `WavD2DGpioRx.v`
into a new wrapper that *contains* a pristine `WavD2DGpioRx`.

**New file:** `src/rtl/tidelink_gpio_rx_align.sv`. Module signature:

```
  module tidelink_gpio_rx_align #(
    parameter USE_CLKBUF = 1'b0,
    parameter USE_T3A    = 1'b0,
    parameter [7:0] TRAINING_BYTE = 8'h00
  ) (
    // matches the pristine WavD2DGpioRx port list:
    input  wire        io_scan_mode, io_scan_asyncrst_ctrl, io_scan_clk,
    output wire        io_scan_out,
    input  wire        io_por_reset, io_pol,
    output wire        io_link_clk,
    output wire [15:0] io_link_data,
    input  wire        io_pad_clk, io_pad,
    // SoC Labs alignment-side inputs that today live INSIDE WavD2DGpioRx
    // as ports — they remain as ports here, just promoted one level up:
    input  wire [3:0]  io_phase_offset,
    input  wire [2:0]  io_bit_slip
  );
```

**What moves into this wrapper:**

* The `adj_count = count + io_phase_offset` (today `WavD2DGpioRx.v:112`)
  — relocate to the wrapper: the wrapper now owns `count`, the
  `~adj_count[3]` divided word-clock derivation
  (`WavD2DGpioRx.v:206`), and feeds a pristine WavD2DGpioRx an
  *already-phase-adjusted* sample-clock.
* The `_link_data_rep` + `io_bit_slip` rotation
  (`WavD2DGpioRx.v:185–186`) — relocate to the wrapper, applied to the
  WavD2DGpioRx's `io_link_data` output.
* The T3a comma-hunt FSM (`WavD2DGpioRx.v:241–390`) — relocate as the
  per-lane wrapper FSM, with `count` slip applied as a phase shift on
  the wrapper-owned counter (the wrapper now provides the *effective*
  `io_pad_clk` to the pristine inner block).
* The in-PHY BUFG restructure (`WavD2DGpioRx.v:209–240`,
  `g_clkbuf`/`g_passthru`) — relocate to the wrapper: the wrapper
  provides BUFG'd capture and divided clocks to the inner pristine
  block.

**What stays in the (now-pristine) `WavD2DGpioRx`:** the original
`count`-based bit-position selector (lines 113–130), the 16-bit
`link_data_pad_clk` capture, the `link_data_reg` re-clock — the
deserialiser core, unchanged from Chisel emit.

**Pristine-restore validation.** After step 1 the wrapper-driven
ports + the original WavD2DGpioRx behaviour are functionally identical
to the patched WavD2DGpioRx, because: (a) the wrapper adds
`io_phase_offset` to the *effective* phase before driving the pristine
inner block, identical to the in-block `adj_count`; (b) the wrapper
applies the bit-slip rotation post-deserialisation; (c) the wrapper
runs the T3a comma-hunt and pre-aligns the bit stream — identical to
the in-block T3a slipping `count`.

**Risk class:** Medium. The wrapper-vs-in-block boundary on the
divided word-clock is the tricky bit (the wrapper's `count` must drive
the inner block's `io_pad_clk` in the right phase). Mitigation: keep
the in-block code as a `USE_T3A=0` cross-check during this step;
verify bit-exact link-rx-data on cocotb `wavd2d_gpiorx_t3a` and
`wavd2d_gpiorx_clkbuf` regressions, with the patched-inner-block path
as the golden reference. Once the wrapper passes byte-identical, in
step 2 we delete the in-block patches.

**Lines-of-code delta:** +~250 lines (new wrapper), −~180 lines (move
content out of WavD2DGpioRx in step 2). Net wrapper is a thin
re-skinning.

**Person-days:** 2.

### Step 2 — replace `WavD2DGpioRx` instances in `WavD2DGpio`

**Goal:** in `WavD2DGpio.v`, replace the 8 `WavD2DGpioRx` instances
with `tidelink_gpio_rx_align` instances; remove the SoC Labs patches
from `WavD2DGpioRx.v`.

Each of the 8 instantiations at lines 491, 505, 519, 533, 547, 561,
575, 589 of `WavD2DGpio.v` becomes:

```
  tidelink_gpio_rx_align #(
      .USE_CLKBUF    (USE_CLKBUF),
      .USE_T3A       (USE_T3A),
      .TRAINING_BYTE (8'hA3)              // per-lane, same as today
  ) gpiorx_0 (
      // SoC Labs ports become wrapper ports:
      .io_phase_offset (effective_phase_offset_lane0),
      .io_bit_slip     (effective_bit_slip[2:0]),
      // remainder identical to today
      ...
  );
```

This is still a SoC Labs edit inside `WavD2DGpio.v` — step 3 is the
one that vendor-freezes the file. The point of separating step 2 from
step 3 is that step 2 is a pure-mechanical instance rename (8 lines)
and the testbench impact is contained.

**Risk class:** Low. Bit-exact by construction (same wrapper as
step 1, just plumbed in).

**Lines-of-code delta:** −180 lines (removed in-block patches from
`WavD2DGpioRx.v`), 8 instance-name changes in `WavD2DGpio.v`. Net
file shrinkage.

**Person-days:** 1.

### Step 3 — vendor-freeze `WavD2DGpio*.v`

**Goal:** restore `WavD2DGpioTx.v`, `WavD2DGpioRx.v`, `WavD2DGpio.v`,
`WlinkGPIOPHY.v`, `Wlink.v` to byte-identical Chisel emitter output.
The remaining SoC Labs hooks move into the wrapper or sit one level
up.

This step turns out to be subtle because some of the patches in
`WavD2DGpio.v` are *port-level* additions:

* `io_swi_bit_slip_in` (line 59) — passes per-lane bit-slip into the
  RX deserialisers
* `io_swi_training_mode_in` (line 60) — passes the training-mode
  override into the TX serialisers
* `io_swi_phase_offset_in` (line 71) — passes per-lane phase offset
  into the RX deserialisers
* Per-lane `TRAINING_BYTE` overrides on the 8 RX instances

The vendor Chisel doesn't have these ports. Two paths:

**Path A: regenerate Chisel.** Modify the upstream Chisel source to
emit these ports, then re-emit. This is the cleanest but requires
Chisel toolchain access and is out of scope for this proposal.

**Path B: SoC Labs wraps `WavD2DGpio` instead of editing it.** Build a
thin `tidelink_gpio_wav_wrap.sv` that contains a pristine `WavD2DGpio`
and an additional muxing layer that injects the per-lane bit-slip,
phase, training-mode, and (via the wrapper-of-WavD2DGpioRx pattern
from step 1) the per-lane TRAINING_BYTE. The pristine `WavD2DGpio`
sees only its original Chisel-emit port set; everything SoC Labs
needs is multiplexed externally.

This proposal recommends **Path B**: it keeps the vendor file
byte-identical without Chisel access, and the wrapping pattern is
already established by `tidelink_gpio_rx_align`. The extra wrapping
costs one indirection level, no extra flops.

After step 3:

* `git diff` against the original Chisel emit on `WavD2DGpio.v`,
  `WavD2DGpioRx.v`, `WavD2DGpioTx.v`, `WlinkGPIOPHY.v`, `Wlink.v`
  shows zero lines changed.
* `sha256sum` of each file matches a golden checksum in
  `fpga/golden_checksums.txt`. CI gates re-emit drift.
* All SoC Labs edits live in `src/rtl/tidelink_gpio_phy.sv`,
  `src/rtl/tidelink_gpio_rx_align.sv`, and the existing
  `tidelink_idelay_rx.sv`, `tidelink_rxclk_buf.sv`,
  `tidelink_phy_align_calibrator.sv`, `tidelink_lane_checker.sv`.

**Risk class:** Medium. Path B introduces an extra muxing layer that
must be bit-exact on the existing cocotb hierarchical-force semantics
(the testbench reaches into `u_<side>.u_chiplet.u_wlink.phy.gpio` to
force `swi_bit_slip` directly). Mitigation: provide a hierarchical
alias module so the existing hierarchical paths resolve; verify the
cocotb `wlink_pair` regression unchanged.

**Lines-of-code delta:** +~150 lines (new `tidelink_gpio_wav_wrap`),
−~80 lines (revert patches in vendor files). Net +70 lines, but the
sloc that remains is structurally clean.

**Person-days:** 3.

### Step 4 — hoist calibrator + lane_checker + status regs into `tidelink_gpio_phy.sv`

**Goal:** remove the calibrator, lane checker, OR-mux, IDELAY
wrapper, RX clock buffer, and Region 8 registers from
`axi_chiplet_controller.sv`. Move them into a new
`tidelink_gpio_phy.sv` module. Re-route APB.

The chiplet controller after this step has none of the lines
referenced in §2.2 except the Wlink instantiation (now with no PHY
parameters and no SoC Labs `swi_*` ports — those move into the PHY).

The new `tidelink_gpio_phy.sv` instantiates:
* `tidelink_idelay_rx` (existing)
* `tidelink_rxclk_buf` (existing)
* `tidelink_phy_align_calibrator` (existing)
* `tidelink_lane_checker` (existing)
* `tidelink_gpio_phy_regs` (new — pulled out of Region 8 of the
  chiplet controller)
* `tidelink_gpio_wav_wrap` (new, from step 3) containing pristine
  `WavD2DGpio`

The APB decode in `tidelink_top.sv` carves Region 8 (offsets
0x100–0x11C inside the chiplet APB area) off to the PHY slave; the
remainder goes to the Wlink slave inside the chiplet controller. This
is the same decode the chiplet currently does internally — it just
moves up one level.

**Risk class:** Medium-low. The signal lift is mechanical (move
declarations, move instances). The APB re-decode is a 30-line change
in `tidelink_top.sv`. The MMIO address of `SWI_LANE_STATUS` is
unchanged: `0x4403_2108`.

**Lines-of-code delta:** Chiplet controller: −~350 lines. New
`tidelink_gpio_phy.sv`: +~400 lines (most of it is the existing
Region 8 code, re-homed). Net ~+50 lines for the wrapping ports.

**Person-days:** 2.

### Step 5 — collapse `USE_*` params to one `USE_FPGA_PRIMITIVES`

**Goal:** make `tidelink_gpio_phy.sv` accept one
`USE_FPGA_PRIMITIVES` parameter from `tidelink_top.sv`; expose
`USE_IDELAY`, `USE_CLKBUF`, `USE_T3A` as PHY-internal sub-parameters
that default to the boundary param but remain individually overridable
for A/B testing.

`tidelink_top.sv`:
```
  parameter USE_FPGA_PRIMITIVES = 1'b0;
  tidelink_gpio_phy #(.USE_FPGA_PRIMITIVES(USE_FPGA_PRIMITIVES))
                    u_phy (...);
```

`tidelink_gpio_phy.sv`:
```
  parameter USE_FPGA_PRIMITIVES = 1'b0;
  parameter USE_IDELAY = USE_FPGA_PRIMITIVES;
  parameter USE_CLKBUF = USE_FPGA_PRIMITIVES;
  parameter USE_T3A    = USE_FPGA_PRIMITIVES;
```

`tidelink_vivado_wrapper.v` sets `USE_FPGA_PRIMITIVES=1'b1` (one
declaration in `component.xml`).

The chiplet controller no longer carries USE_* parameters at all.
Inside the PHY, the existing per-feature sub-params let the
verification team A/B-test individual fixes (e.g. `USE_IDELAY=1,
USE_CLKBUF=0` for a controlled comparison).

**Risk class:** Low. Parameter aliasing is elaboration-time; no
synthesis change. The UVM tests that override individual `USE_*` still
work — they target the PHY sub-params directly.

**Lines-of-code delta:** −60 lines (collapsed parameter declarations
across 5 hierarchy levels), +6 lines (new sub-param block in
`tidelink_gpio_phy.sv`). Net cleanup.

**Person-days:** 1.

---

## 5. The single-param collapse, in detail

### 5.1 Today's five-deep threading

```
  tidelink_vivado_wrapper.v       USE_IDELAY=1, USE_CLKBUF=1, USE_T3A=1
       |                                |              |             |
       v                                v              v             v
  tidelink_top.sv                  USE_IDELAY     USE_CLKBUF      USE_T3A
       |                                |              |             |
       v                                v              v             v
  axi_chiplet_controller.sv        USE_IDELAY     USE_CLKBUF      USE_T3A
       |                                |              |             |
       |                          tidelink_      tidelink_     Wlink #(
       |                          idelay_rx       rxclk_buf      .USE_CLKBUF,
       |                                                         .USE_T3A
       |                                                       )
       v                                                              |
  Wlink.v                                                       USE_CLKBUF
                                                                USE_T3A
       |                                                              |
       v                                                              v
  WlinkGPIOPHY.v                                              USE_CLKBUF
                                                              USE_T3A
       |                                                              |
       v                                                              v
  WavD2DGpio.v                                                 USE_CLKBUF
                                                              USE_T3A
       |                                                              |
       v                                                              v
  WavD2DGpioRx.v (per-lane x8)                                 USE_CLKBUF
                                                              USE_T3A

  Each USE_* parameter is declared 5 times along its path, with a
  default of 0 at every level except the top wrapper.
```

Reading `tidelink_idelay_rx.sv:46–56`: the parameter-only approach was
hard-won. An earlier revision used a preprocessor `define
TIDELINK_USE_IDELAY` and it silently fell off in OOC synth (the define
didn't propagate from the packaging project into the IP's compile
units). The fix was to make each parameter declaration *visible at
elaboration time* — but that fix mandated explicit threading at every
level. The 5-deep threading is the price of the fix being robust.

### 5.2 Proposed two-level threading

```
  tidelink_vivado_wrapper.v       USE_FPGA_PRIMITIVES = 1'b1
       |                                       |
       v                                       v
  tidelink_top.sv                       USE_FPGA_PRIMITIVES
       |                                       |
       v                                       v
  tidelink_gpio_phy.sv          USE_FPGA_PRIMITIVES (with sub-aliases)
       |
       +--- USE_IDELAY = USE_FPGA_PRIMITIVES
       +--- USE_CLKBUF = USE_FPGA_PRIMITIVES        <-- internal,
       +--- USE_T3A    = USE_FPGA_PRIMITIVES            individually
                                                        overridable
       |
       +--> tidelink_idelay_rx #(.USE_IDELAY)
       +--> tidelink_rxclk_buf #(.USE_CLKBUF)
       +--> tidelink_gpio_rx_align #(.USE_CLKBUF, .USE_T3A) x 8

  Component.xml exposes USE_FPGA_PRIMITIVES at the IP boundary;
  default = 1 (FPGA) in the packaged IP, defaults to 0 elsewhere.
```

This drops parameter visibility from 15 explicit ports
(3 params × 5 levels) to 2 (1 param × 2 levels at the top, with
internal sub-aliases that are pure elaboration-time renames).

### 5.3 Why keep sub-params at all

A/B testing during silicon characterisation already requires this. The
HW results table in `GPIO_PHY_ARCHITECTURE.md:1020–1027` shows the
multi-build characterisation campaign (`b_clkbuf` had `USE_CLKBUF=1,
USE_IDELAY=1, USE_T3A=1`; `b_inphy` added the in-PHY restructure).
Future characterisation should be able to do the same with one-line
edits. Keeping the sub-params as PHY-internal aliases gives us
`USE_FPGA_PRIMITIVES=1; USE_T3A=0` for those A/B tests without
re-introducing the threading-depth problem at the top level.

### 5.4 Component.xml mechanism

Unchanged. `tidelink_vivado_wrapper.v` declares `parameter
USE_FPGA_PRIMITIVES = 1'b1`. The packaged IP's `component.xml`
exposes this parameter at the IP-XACT boundary. OOC synth picks it up
via the IP-XACT parameter mechanism — exactly the same path that today
carries `USE_IDELAY`/`USE_CLKBUF`/`USE_T3A`. Belt-and-braces opt-out
guards in the existing FPGA-only modules (e.g.
`TIDELINK_IDELAY_NO_PRIMITIVE` in `tidelink_idelay_rx.sv:125`,
`TIDELINK_RXCLK_NO_PRIMITIVE` in `tidelink_rxclk_buf.sv:65`) remain
in place for non-Vivado simulators.

---

## 6. Test reorganisation

Today the cocotb directory layout already separates PHY tests from
chiplet tests cleanly. The refactor lets us collapse and rename a
few:

### 6.1 Per-lane PHY tests

Move under `cocotb/tidelink_gpio_phy/`:

* `cocotb/wavd2d_gpiorx_clkbuf/` → `cocotb/tidelink_gpio_phy/rx_align_clkbuf/`
* `cocotb/wavd2d_gpiorx_t3a/` → `cocotb/tidelink_gpio_phy/rx_align_t3a/`
* `cocotb/wavd2d_gpiorx_t3a_off/` → `cocotb/tidelink_gpio_phy/rx_align_t3a_off/`
* `cocotb/wavd2d_gpiorx_t3a_timeout/` → `cocotb/tidelink_gpio_phy/rx_align_t3a_timeout/`
* `cocotb/tidelink_rxclk_buf/` → `cocotb/tidelink_gpio_phy/rxclk_buf/`
* `cocotb/tidelink_idelay_rx/` → `cocotb/tidelink_gpio_phy/idelay_rx/`
* `cocotb/tidelink_phy_align_calibrator/` → `cocotb/tidelink_gpio_phy/calibrator/`

All these tests instantiate the unit under test in isolation — they
do NOT elaborate the chiplet controller or Wlink today, and they
continue to work after the refactor. The rename is purely
directorial.

### 6.2 PHY integration tests

`cocotb/phy_align/` becomes the PHY integration suite. It already
contains:

* `test_pair_align.py` — master+slave pair, end-to-end FCSM=4
* `test_pair_align_asymmetric*.py` — asymmetric eye scenarios
* `test_pair_align_staggered_bringup.py` — SSH-staggered cold boot

After step 4 these tests instantiate two `tidelink_gpio_phy`
instances connected by a behavioural wire model — no chiplet
controller needed. (Today they have to elaborate the chiplet
controller because the calibrator lives inside it; this is a net win
in elaboration time.)

### 6.3 Vendor-freeze regression

New CI gate. A `cocotb/vendor_freeze/` Makefile that:

1. Reads `fpga/golden_checksums.txt`
2. Computes `sha256sum` of each Wav* file in
   `deps/axi-chiplet-controller/logical/wlink/`
3. Diffs; fails CI if any hash differs

`golden_checksums.txt` is committed alongside the refactor; updating
it requires explicit reviewer sign-off (the commit message must cite
the upstream Chisel re-emit version).

### 6.4 Bank-asymmetry behavioural test

`cocotb/bank_asymmetry/` is already PHY-only at the abstraction level
(it models `lane_locked[7:0]` directly). It stays where it is, but
the README cross-reference updates to point at `tidelink_gpio_phy`.

---

## 7. Risk analysis and mitigations

### 7.1 Risk: regenerated `Wlink.v` from Chisel re-injects behaviours

**Likelihood:** Low (Chisel re-emit is rare). **Impact:** High (would
silently overwrite SoC Labs hand-patches).

**Mitigation:** The vendor-freeze CI gate (§6.3). A re-emit produces
files with different hashes; CI fails. The patch set lives on a
separate file (`tidelink_gpio_wav_wrap.sv`) and is never touched by
Chisel re-emit. The wrap file's behaviour is regression-tested
against the (now pristine) Chisel files.

### 7.2 Risk: `USE_FPGA_PRIMITIVES` collapse breaks UVM/ASIC tests that override individual `USE_*`

**Likelihood:** Medium. There exist verification artifacts that set
individual params for A/B coverage.

**Mitigation:** The PHY-internal sub-params remain (`USE_IDELAY`,
`USE_CLKBUF`, `USE_T3A`) and remain individually overridable from a
testbench. The top-level boundary param `USE_FPGA_PRIMITIVES` is
*convenience* not *replacement*. Existing UVM tests that override
`u_<side>.u_top.USE_IDELAY = 1` change to
`u_<side>.u_top.u_phy.USE_IDELAY = 1` — a mechanical hierarchical-path
update. The ASIC flist need not change at all (defaults to 0 at
every level, identical to today).

### 7.3 Risk: chiplet controller still references PHY internals

**Likelihood:** Medium. Some incidental references (e.g. ILA
hierarchical paths in TCL scripts, debug column wirings) may persist.

**Mitigation:** Step 4 grep audit. The acceptance criterion is:
`grep -n -E 'swi_bit_slip|swi_phase_offset|swi_training_mode|phy_link_rx|pad_rx_dly|pad_clk_rx_buf' deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv` returns zero. All ILA TCL
references that today point at `u_chiplet.u_idelay_rx`, etc., move
to `u_phy.u_idelay_rx`.

### 7.4 Risk: existing HW-validated bitstream is on the current structure

**Likelihood:** Certain. The §9 silicon-validated build runs the
current entanglement.

**Mitigation:**
* Each refactor step is bit-exact in cocotb regression and in
  synthesised-netlist diff. Step 1 is golden-against the patched
  WavD2DGpioRx. Step 2 deletes the now-redundant patches.
* One farm-build + one PYNQ-Z2 lease cycle validates the post-refactor
  bitstream produces the same `bringup_health_probe` SWI_LANE_STATUS
  trajectory as the pre-refactor bitstream. Acceptance: identical
  FCSM=4 reach-time, identical lane lock latencies (within
  build-to-build variance, which is now characterised by §9.9
  best-of-sweep).
* If the post-refactor build does NOT match: revert per step. Each
  step is on its own branch (`refactor/step-1` through
  `refactor/step-5`) and is independently revertable.

### 7.5 Risk: refactor changes hierarchical-force paths used by tests

**Likelihood:** Certain. cocotb tests force into specific paths like
`u_chiplet.u_idelay_rx`. After step 4 the IDELAY wrapper lives at
`u_phy.u_idelay_rx`.

**Mitigation:** Path updates are mechanical sed across the cocotb
test set. They batch into the migration steps that change the
hierarchy — step 4 has a paired cocotb sed PR. The forcing convention
(register names, bit patterns, semantics) is unchanged.

### 7.6 Risk: hidden behavioural change in step 1 wrapper

**Likelihood:** Medium. The wrapper-vs-in-block separation on the
divided word-clock derivation is non-trivial.

**Mitigation:** Step 1 keeps both paths live (in-block patched +
wrapper-driving-pristine). The wrapper is gated by a new
`USE_WRAPPER_RX = 1'b0` parameter; the cocotb regression runs
side-by-side against both for the duration of step 1. Once
byte-identical lane-data is confirmed across `wavd2d_gpiorx_t3a` +
`wavd2d_gpiorx_clkbuf` + `wavd2d_gpiorx_t3a_off` + the pair-level
`test_pair_align`, step 2 deletes the in-block path and removes the
`USE_WRAPPER_RX` parameter.

---

## 8. What the change is NOT

To prevent scope creep when the actual refactor lands:

* **NOT a chance to rethink the calibration algorithm.** Best-of-sweep
  vs first-match-wins, T3 re-sweep timing, T3.2 S_HOLD duration, the
  128-point sweep shape — all unchanged. They land in the new module
  exactly as they exist today.

* **NOT a chance to switch to ISERDESE2.** The `WavD2DGpioRx`
  deserialiser core is preserved. The `tidelink_gpio_phy_v2` ISERDES
  proposal is a separate document (and a separate engineering
  budget).

* **NOT an opportunity to change pin assignments.** The bank-13 /
  bank-35 asymmetry (`GPIO_PHY_ARCHITECTURE.md` §7) is a separate
  problem to solve at the v2 layer or at the calibrator level
  (the per-bank-group calibrator in §10.2 of the architecture doc).
  This refactor does not touch XDC, clocking regions, or IODELAY
  group membership.

* **NOT a chance to change the calibration register map.** Region 8
  offsets, bit positions, MMIO addresses — all preserved.

* **NOT a chance to change cocotb test semantics.** The
  hierarchical-force convention, the `tb_early_exit_force_q` hook,
  the `autocal_force_enable_q` hook all exist in the new locations
  with identical semantics.

* **Strictly mechanical structural refactor.** Same RTL behaviour,
  cleaner module boundaries.

---

## 9. Effort estimate

### 9.1 Per-step

| Step | LoC delta | Person-days | Risk class |
|---|---|---|---|
| 1. `tidelink_gpio_rx_align` (new wrapper) | +250 / −0 (in-block still live) | 2 | Medium |
| 2. Replace `WavD2DGpioRx` instances; delete in-block patches | −180 / +0 | 1 | Low |
| 3. Vendor-freeze `WavD2DGpio*.v` (Path B wrap) | +150 / −80 | 3 | Medium |
| 4. Hoist calibrator/regs into `tidelink_gpio_phy` | +400 / −350 | 2 | Medium-low |
| 5. Collapse to `USE_FPGA_PRIMITIVES` | +6 / −60 | 1 | Low |
| **Total** | **+576 / −670 (net −94 lines)** | **9** | — |

### 9.2 Cycle time

Best case: 1 engineer-week of focused work, plus 1 farm-build cycle
(~6 h) + 1 PYNQ-Z2 lease cycle (~2 h bench, plus lease queue) to
validate bit-exactness vs the silicon-validated bitstream.

Worst case: 2 engineer-weeks if step 3 Path B muxing has a
hierarchical-force compatibility issue that requires reworking the
cocotb test harness (most likely affected: tests in `cocotb/tidelink/`
and the integrated cocotb pair-level autocal tests).

Total elapsed: 2–3 weeks including code review and silicon validation.

### 9.3 Validation budget

* Cocotb regression: zero-diff bit-exactness, all existing tests pass.
* Pair-level cocotb: `test_pair_align.py` and the
  asymmetric/staggered variants all pass without timing relaxation.
* Vendor-freeze CI: `sha256sum` golden gate is green.
* One farm-build (`make build_pair_farmed`).
* One PYNQ-Z2 pair lease + `bringup_pair_converge.sh` round. Compare
  SWI_LANE_STATUS trajectory to the pre-refactor silicon trace.
* Synthesised netlist diff via Vivado `report_utilization` and
  `report_clock_interaction` — must show identical resource usage
  (within tool noise).

---

## 10. Recommendation and decision

### 10.1 Should this be done now?

**No** — not in the window between current §9 silicon validation
(2026-05-19 RESOLVED entry in memory) and the v1 tape-out or chassis
build.

**Reasoning.** The refactor changes zero behaviour and zero on-wire
protocol. The current RTL works on silicon. A bit-exact structural
refactor *should* be safe, but "should" carries non-zero residual
risk — and v1 ship-window time is the worst possible time to absorb
that risk.

The current entanglement is a documentation problem and a maintenance
problem. It is not a correctness problem. The §9 fixes are all
*correct*; they're just structurally inconvenient. Documentation
(this proposal + `GPIO_PHY_ARCHITECTURE.md`) addresses the immediate
maintenance pain.

### 10.2 When should this be done?

**Post-v1 cleanup window**, before the next significant feature
addition. Specifically:

* Before any Wlink Chisel re-emit work (the refactor unblocks
  vendor-freeze).
* Before the per-bank-group calibrator (§10.2 of architecture doc) —
  the refactor's clean PHY boundary makes that fix structurally
  trivial.
* Before any v2 ISERDESE2 PHY exploration — the refactor's
  `tidelink_gpio_phy` becomes the v1 baseline, and
  `tidelink_gpio_phy_v2` is then a sibling module.

### 10.3 Honest engineering call

The 16-modification audit recorded the entanglement and the audit
itself is the documentation that buys time. If the refactor never
happens, the audit + this proposal + `GPIO_PHY_ARCHITECTURE.md` are
*sufficient* documentation for a new engineer to maintain the
current structure without rediscovering the entanglement.

If we have a 2–3 week post-v1 window, do the refactor. If we don't,
ship v1 as-is and let the next engineer who touches the PHY make the
call.

The architectural shape proposed here is correct regardless of when
it lands. Document it, plan for it, do it when the project allows.

---

## Appendix A — File tree comparison

### A.1 Today

```
  src/rtl/
   |
   +-- tidelink_top.sv                  (1620 lines; PHY params + decode)
   +-- tidelink_idelay_rx.sv            (213 lines; FPGA IDELAYE2 wrapper)
   +-- tidelink_rxclk_buf.sv            (93 lines; FPGA boundary BUFG)
   +-- tidelink_phy_align_calibrator.sv (718 lines)
   +-- tidelink_lane_checker.sv         (90 lines)
   +-- tidelink_phy_align_regs.sv       (141 lines; UNUSED in current
                                         flow — Region 8 superseded it,
                                         see axi_chiplet_controller.sv:1273)

  deps/axi-chiplet-controller/logical/top/
   |
   +-- axi_chiplet_controller.sv        (1632 lines; ~400 of them
                                          are PHY-related: calibrator
                                          instance, IDELAY instance,
                                          BUFG instance, Region 8 regs,
                                          OR-mux, calibrator-Wlink
                                          interconnect)

  deps/axi-chiplet-controller/logical/wlink/
   |
   +-- WavD2DGpio.v                     (888 lines; 23 SoC Labs patches
                                          documented in §2.1)
   +-- WavD2DGpioRx.v                   (463 lines after patches;
                                          original ~210 lines)
   +-- WavD2DGpioTx.v                   (174 lines; 2 SoC Labs patches)
   +-- WlinkGPIOPHY.v                   (~ + 6 SoC Labs patch lines)
   +-- Wlink.v                          (~ + 4 SoC Labs patch lines)
```

### A.2 Proposed

```
  src/rtl/
   |
   +-- tidelink_top.sv                  (~1580 lines; only
                                          USE_FPGA_PRIMITIVES param;
                                          APB decode carves Region 8
                                          to PHY slave, rest to chiplet)
   +-- tidelink_gpio_phy.sv             (NEW ~400 lines; contains
                                          calibrator + lane_checker +
                                          IDELAY + RXCLK + regs +
                                          gpio_wav_wrap)
   +-- tidelink_gpio_rx_align.sv        (NEW ~250 lines; per-lane RX
                                          alignment wrapper containing
                                          T3a + in-PHY BUFGs +
                                          io_phase_offset + io_bit_slip
                                          around pristine WavD2DGpioRx)
   +-- tidelink_gpio_wav_wrap.sv        (NEW ~150 lines; thin muxing
                                          layer around pristine
                                          WavD2DGpio + per-lane
                                          TRAINING_BYTE injection)
   +-- tidelink_gpio_phy_regs.sv        (NEW ~200 lines; APB slave for
                                          SWI_BIT_SLIP, SWI_PHASE_OFFSET,
                                          SWI_TRAINING_MODE, SWI_RECAL,
                                          SWI_LANE_STATUS — pulled out
                                          of axi_chiplet_controller's
                                          Region 8)
   +-- tidelink_idelay_rx.sv            (unchanged from today)
   +-- tidelink_rxclk_buf.sv            (unchanged from today)
   +-- tidelink_phy_align_calibrator.sv (unchanged from today)
   +-- tidelink_lane_checker.sv         (unchanged from today)
   +-- tidelink_phy_align_regs.sv       (REMOVED — superseded by
                                          tidelink_gpio_phy_regs)

  deps/axi-chiplet-controller/logical/top/
   |
   +-- axi_chiplet_controller.sv        (~1280 lines; ALL PHY logic
                                          removed; AXI/AHB/I2C/FCSM/
                                          role/auto-neg only)

  deps/axi-chiplet-controller/logical/wlink/
   |
   +-- WavD2DGpio.v                     (PRISTINE — Chisel re-emit
                                          byte-identical)
   +-- WavD2DGpioRx.v                   (PRISTINE)
   +-- WavD2DGpioTx.v                   (PRISTINE)
   +-- WlinkGPIOPHY.v                   (PRISTINE)
   +-- Wlink.v                          (PRISTINE)

  fpga/
   +-- golden_checksums.txt             (NEW — vendor-freeze CI gate)
```

---

## Appendix B — Boundary contract for `tidelink_gpio_phy`

The full module boundary contract once the refactor lands. This is
what a senior engineer reviewing the PHY in isolation would see:

```
  module tidelink_gpio_phy (
      // Clocks and resets
      input  wire        apb_clk,           // APB / app clock
      input  wire        user_hsclk,        // PHY hsclk (TX serialiser)
      input  wire        poresetn,          // power-on reset (active-low)
      input  wire        hresetn,           // system reset (active-low)
      input  wire        role_locked,       // link-up trigger from chiplet
      input  wire        idelay_ref_clk,    // 200 MHz IDELAYCTRL reference
      input  wire        idelay_rst,        // IDELAYCTRL reset

      // External pads (only thing tied to chip pins)
      output wire        pad_clk_tx,
      output wire [7:0]  pad_tx,
      input  wire        pad_clk_rx,
      input  wire [7:0]  pad_rx,

      // Link layer (PHY <-> Wlink core inside chiplet)
      // TX from link layer:
      input  wire        link_tx_link_en,
      output wire        link_tx_link_ready,
      input  wire [127:0] link_tx_link_data,
      input  wire [7:0]  link_tx_lane_mask,
      output wire        link_tx_link_clk,
      // RX to link layer:
      output wire [127:0] link_rx_link_data,
      input  wire [7:0]  link_rx_lane_mask,
      output wire        link_rx_link_clk,

      // APB slave (Region 8 calibration regs)
      input  wire        apb_psel,
      input  wire        apb_penable,
      input  wire        apb_pwrite,
      input  wire [11:0] apb_paddr,
      input  wire [31:0] apb_pwdata,
      input  wire [3:0]  apb_pstrb,
      output wire [31:0] apb_prdata,
      output wire        apb_pready,
      output wire        apb_pslverr,

      // DFT
      input  wire        scan_mode,
      input  wire        scan_asyncrst_ctrl,
      input  wire        scan_clk,
      input  wire        scan_shift,
      input  wire        scan_in,
      output wire        scan_out
  );
```

Four logical groups + clocks/resets + DFT. The full list of nets
crossing the boundary is what fits on one screen. Compare this to
the ~80 individual signals crossing the de-facto boundary today.

That's the win.

---

## Appendix C — Cross-references

* `docs/GPIO_PHY_ARCHITECTURE.md` — the comprehensive technical
  reference this proposal operationalises.
* `docs/SHORTCOMINGS.md` — captures the architectural debt; §10.3
  there points at this refactor.
* Commit `5933536` — the architecture-reference commit that grounds
  this proposal.
* Audit recommendation (memory): the top entry of
  `project_tidelink_fpga_bringup.md` (2026-05-19 RESOLVED).
* Parent commit history (the §9 RTL fixes this refactor preserves):
  `1b2e87e`, `0bfe16b`, `7011e78`, `98946ed`, `0d85843`, `c86f17b`,
  `fc6ce69`.

This document is intentionally repository-internal; it cites file
lines rather than abstracting them so HW engineers reviewing the
proposal can `grep -n` directly into the current entanglement and
verify the claims.
