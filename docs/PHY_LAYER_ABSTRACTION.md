# TideLink PHY Layer Abstraction — Separation and Swap-in Architecture

**Date:** 2026-05-22  
**Status:** Proposal — not yet implemented  
**Context:** v1 uses a GPIO PHY (WavD2DGpio). This document describes how to restructure the
repository so that the GPIO PHY, a SerDes PHY, or a behavioural model can be selected at
elaboration time, and so the PHY can be unit-tested independently.

---

## 1. Current architecture and the problem

```
tidelink_top.sv
  └── axi_chiplet_controller.sv  (deps/axi-chiplet-controller)
        ├── Wlink.v  (Chisel-generated link layer)
        │     └── WavD2DGpio.v  ← PHY is INSIDE the link layer
        │           ├── WavD2DGpioRx.v × 8  (bit-slip, phase, deserialization)
        │           └── WavD2DGpioTx.v × 8  (serialization)
        ├── tidelink_idelay_rx.sv  (FPGA IDELAYE2 — sits in front of GPIO PHY)
        ├── tidelink_phy_align_calibrator.sv  (drives bit_slip / phase_offset)
        └── tidelink_lane_checker.sv
```

The boundary between link layer and PHY is **implicit** inside `Wlink.v`. The signals that
naturally form this boundary already exist as named internal wires:

| Signal | Direction | Width | Meaning |
|---|---|---|---|
| `phy_link_tx_tx_link_data` | Link → PHY | 128 | Parallel TX data (8 lanes × 16 bits) |
| `phy_link_tx_tx_en` | Link → PHY | 1 | TX enable |
| `phy_link_tx_tx_lane_mask` | Link → PHY | 8 | Active lane mask |
| `phy_link_tx_tx_link_clk` | PHY → Link | 1 | TX link clock (recovered from serializer) |
| `phy_link_tx_tx_ready` | PHY → Link | 1 | PHY TX ready |
| `phy_link_rx_rx_link_data` | PHY → Link | 128 | Parallel RX data (8 lanes × 16 bits) |
| `phy_link_rx_rx_link_clk` | PHY → Link | 1 | RX recovered clock |
| `phy_link_rx_rx_lane_mask` | PHY → Link | 8 | Active RX lane mask |

SoC Labs has already exposed `phy_link_rx_rx_link_data` and `phy_link_rx_rx_link_clk` through the
`axi_chiplet_controller` top level to feed the calibrator and lane checker. The seam is
effectively identified — it just has not been turned into a formal module boundary.

**The core problems preventing PHY swap:**

1. `WavD2DGpio` is instantiated *inside* the Chisel-generated `Wlink.v`. To substitute a
   different PHY you currently have to modify the Chisel output, which is a generated file.

2. Calibration signals (`swi_bit_slip`, `swi_training_mode`, `swi_phase_offset`) and the
   associated calibrator/lane-checker modules are GPIO-PHY-specific. They are currently wired
   at the `axi_chiplet_controller` level, not inside a PHY wrapper. A SerDes PHY has CDR and
   equaliser adaptation instead — none of these signals exist.

3. The FPGA IDELAYE2 wrapper (`tidelink_idelay_rx.sv`) sits *between* the top-level pads and
   the PHY input, further fragmenting the abstraction.

4. There is no unit-testable PHY module — any simulation of PHY behaviour requires the full
   TideLink stack.

---

## 2. Proposed PHY interface

Define a canonical contract between the link layer and any PHY implementation. In SystemVerilog
this is cleanly expressed as an interface, but for maximum tool compatibility a flat parameter-
ised wrapper port list is also workable (see §4).

### 2.1 Link-layer ↔ PHY boundary signals

```
Parameter: NUM_LANES   (default 8)
Parameter: DATA_W      (default 16 — bits per lane per link clock cycle)
```

```
                    ┌─────────────────────┐
  Link Layer        │                     │         PHY
                    │   tl_phy_<type>.sv  │
  tx_en         ──►│                     │
  tx_data       ──►│  (serialisation,    │──► pad_clk_tx
  [N*DATA_W-1:0]   │   clocking,         │──► pad_tx[N-1:0]
  tx_lane_mask  ──►│   calibration,      │
                   │   CDR, lock)         │◄── pad_clk_rx
  tx_clk        ◄──│                     │◄── pad_rx[N-1:0]
  tx_ready      ◄──│                     │
  rx_clk        ◄──│                     │
  rx_data       ◄──│                     │
  [N*DATA_W-1:0]   │                     │
  rx_lane_mask  ◄──│                     │
  phy_ready     ◄──│                     │
                    └─────────────────────┘
```

**Interface port definitions:**

```systemverilog
// Link → PHY
input  logic                        tx_en,          // Link TX enable
input  logic [NUM_LANES*DATA_W-1:0] tx_data,        // Parallel TX data
input  logic [NUM_LANES-1:0]        tx_lane_mask,   // Active TX lanes

// PHY → Link (TX side)
output logic                        tx_clk,         // Link TX clock (from PHY serializer)
output logic                        tx_ready,       // PHY TX path ready

// PHY → Link (RX side)
output logic                        rx_clk,         // RX recovered clock
output logic [NUM_LANES*DATA_W-1:0] rx_data,        // Parallel RX data
output logic [NUM_LANES-1:0]        rx_lane_mask,   // Active RX lanes

// PHY status
output logic                        phy_ready,      // PHY has completed training/lock

// Physical pads (technology-specific names, but fixed for a given PHY type)
output logic                        pad_clk_tx,
output logic [NUM_LANES-1:0]        pad_tx,
input  logic                        pad_clk_rx,
input  logic [NUM_LANES-1:0]        pad_rx,

// Configuration / management
input  logic                        apb_clk,        // Management clock (for APB config)
input  logic                        apb_resetn,
// APB slave port for PHY-internal register access (lock status, calibration, CDR config)
input  logic                        apb_psel,
input  logic                        apb_penable,
input  logic                        apb_pwrite,
input  logic [11:0]                 apb_paddr,
input  logic [31:0]                 apb_pwdata,
output logic [31:0]                 apb_prdata,
output logic                        apb_pready
```

**Key design decision:** Calibration signals (`bit_slip`, `phase_offset`, `training_mode`) are
**PHY-internal**. The link layer and `tidelink_top` see only `phy_ready`. This is what makes
PHY swap clean — the link layer does not need to know whether training uses bit-slip, CDR lock,
or equaliser convergence.

---

## 3. Proposed directory structure

```
src/
├── rtl/
│   ├── phy/
│   │   ├── tl_phy_if.sv              # SystemVerilog interface (optional but recommended)
│   │   │
│   │   ├── gpio/                     # GPIO PHY — v1 implementation
│   │   │   ├── tl_phy_gpio.sv        # Wrapper: WavD2DGpio + calibrator + lane_checker
│   │   │   └── tl_phy_gpio_cal.sv    # Calibration FSM (refactored from tidelink_phy_align_calibrator)
│   │   │
│   │   ├── serdes/                   # SerDes PHY — future implementation
│   │   │   └── tl_phy_serdes.sv      # Wrapper: WavD2DSerdesRx/Tx + CDR status reporting
│   │   │
│   │   └── model/                    # Behavioural model — for unit testing
│   │       └── tl_phy_model.sv       # Loopback / stimulus model implementing the same interface
│   │
│   ├── link/
│   │   └── tl_link.sv                # Wlink wrapper with WavD2DGpio removed, PHY interface exposed
│   │
│   ├── tidelink_top.sv               # Unchanged top-level connectivity (gains PHY_TYPE parameter)
│   └── ...                           # All other modules unchanged
│
├── flist/
│   ├── tidelink_phy_gpio.flist       # Filelist for GPIO PHY variant
│   ├── tidelink_phy_serdes.flist     # Filelist for SerDes PHY variant
│   └── tidelink_phy_model.flist      # Filelist for model PHY variant
│
└── cocotb/
    ├── phy_gpio/                     # Unit tests for GPIO PHY in isolation
    ├── phy_serdes/                   # Unit tests for SerDes PHY in isolation
    └── tidelink/                     # Full-stack tests (unchanged, use model PHY by default)
```

---

## 4. Changes required to each module

### 4.1 Wlink.v — expose the PHY interface instead of embedding WavD2DGpio

`Wlink.v` is a Chisel-generated file. The minimal change is to:

1. Remove the `WavD2DGpio` instantiation from `Wlink.v`
2. Expose `phy_link_tx_*` and `phy_link_rx_*` as top-level ports instead of internal wires

The resulting `Wlink.v` port additions (all already exist as internal wires — just promote them):

```verilog
// Promote to top-level ports (were internal wires):
output        phy_link_tx_tx_en,
output [127:0] phy_link_tx_tx_link_data,
output [7:0]   phy_link_tx_tx_lane_mask,
input         phy_link_tx_tx_link_clk,
input         phy_link_tx_tx_ready,
input  [127:0] phy_link_rx_rx_link_data,
input  [7:0]   phy_link_rx_rx_lane_mask,
input         phy_link_rx_rx_link_clk
// Remove: io_pad_*, io_hsclk, io_swi_*, io_por_reset (now PHY-internal)
```

Since `Wlink.v` is Chisel-generated, the cleanest approach is to create a **thin SV wrapper**
`tl_link.sv` that instantiates `Wlink.v` and manually reroutes the `phy_link_*` internal wires
to ports using hierarchical references or a structural shim. This avoids modifying the generated
file:

```systemverilog
// tl_link.sv — link layer wrapper exposing the PHY interface
module tl_link (
    // ... all existing Wlink ports minus io_pad_* and io_swi_* ...
    // Add explicit PHY interface ports:
    output logic [127:0] phy_tx_data,
    output logic         phy_tx_en,
    output logic [7:0]   phy_tx_lane_mask,
    input  logic         phy_tx_clk,
    input  logic         phy_tx_ready,
    input  logic [127:0] phy_rx_data,
    input  logic [7:0]   phy_rx_lane_mask,
    input  logic         phy_rx_clk
);
    Wlink u_wlink (
        // ... connect all existing ports ...
        // PHY boundary: connect phy_link_* to module ports
        // (Wlink.v must expose these — see note above)
    );
endmodule
```

### 4.2 tl_phy_gpio.sv — GPIO PHY wrapper

Collects everything that is currently scattered between `axi_chiplet_controller` and
`tidelink_top` that relates to the GPIO PHY:

```
Inputs from link layer:  phy_tx_data[127:0], phy_tx_en, phy_tx_lane_mask[7:0]
Outputs to link layer:   phy_tx_clk, phy_tx_ready, phy_rx_data[127:0], phy_rx_clk, phy_phy_ready
Physical pads:           pad_clk_tx, pad_tx[7:0], pad_clk_rx, pad_rx[7:0]
APB:                     PHY register access (WavD2DGpio APB port)
```

**Internals of `tl_phy_gpio.sv`:**

```
tl_phy_gpio.sv
  ├── tidelink_idelay_rx.sv       (FPGA: per-lane IDELAYE2; ASIC: passthrough)
  ├── WavD2DGpio.v                (GPIO PHY link interface + 8-lane serializer)
  ├── tidelink_lane_checker.sv    (per-lane lock detection on rx_clk domain)
  ├── tidelink_phy_align_calibrator.sv  (bit-slip/phase sweep FSM)
  └── tidelink_rxclk_buf.sv       (FPGA BUFG; ASIC: passthrough)
```

The calibrator's `phy_ready` equivalent is its `calibration_done` output — this maps directly to
the `phy_ready` output of `tl_phy_gpio.sv`. The link layer holds off sending until `phy_ready`
asserts, exactly as it currently does via `calibration_done` gating `swi_lltx_enable`.

The APB port exposes the WavD2DGpio register space (lock status, lane mask, per-lane eye
diagnostics). The calibrator registers are also exposed here rather than through the main
TideLink APB tree.

### 4.3 tl_phy_serdes.sv — SerDes PHY wrapper

Wraps `WavD2DSerdesRx.v` and `WavD2DSerdesTx.v` (already present in
`deps/axi-chiplet-controller/logical/PHY/serdes/`):

```
tl_phy_serdes.sv
  ├── WavD2DSerdesTx.v × NUM_LANES  (1:16 serializer per lane)
  ├── WavD2DSerdesRx.v × NUM_LANES  (1:16 deserializer + clock recovery per lane)
  └── tl_serdes_lock_mon.sv          (lock monitoring — replaces lane_checker for SerDes)
```

The SerDes `link_clk` output from `WavD2DSerdesRx` directly provides `rx_clk`. CDR lock is
reported via `phy_ready`. No `bit_slip` or `phase_offset` signals are needed — the SerDes CDR
handles sample-point alignment internally.

**Data-width note:** `WavD2DSerdesRx` currently produces 16 bits per lane per `link_clk`. The
GPIO PHY also produces 16 bits per lane (8-cycle oversampled at link clock = pad\_clk/8). The
`tx_data[127:0]` / `rx_data[127:0]` interface is therefore compatible with both PHYs at 8 lanes
× 16 bits, with no data-width changes needed at the link layer.

### 4.4 tl_phy_model.sv — behavioural model for unit testing

A pure SystemVerilog model implementing the same interface. Useful for:

- Unit-testing the link layer (`tl_link.sv`) in isolation without a physical PHY
- Testing `tidelink_top.sv` without bringing up a full FPGA or ASIC flow
- Fast cocotb simulations where the PHY delay model is not the subject of the test

```systemverilog
module tl_phy_model #(
    parameter NUM_LANES = 8,
    parameter DATA_W    = 16,
    parameter LOOPBACK  = 1  // 1 = local TX→RX loopback; 0 = external stimulus
)(
    // ... tl_phy_if ports ...
);
    // Immediate phy_ready assertion (no calibration needed)
    assign phy_ready = 1'b1;

    // TX→RX loopback with configurable latency
    // Useful for verifying link layer packet framing end-to-end
    // without involving a second TideLink instance
    generate
        if (LOOPBACK) begin
            // Parametric delay line: rx_data = tx_data delayed by LINK_LATENCY cycles
        end
    endgenerate
endmodule
```

### 4.5 tidelink_top.sv — gains a PHY_TYPE parameter

```systemverilog
module tidelink_top #(
    // ...
    parameter PHY_TYPE = "GPIO",  // "GPIO", "SERDES", "MODEL"
    // ...
)(
    // ...
);

    // PHY instance — selected by PHY_TYPE
    generate
        if (PHY_TYPE == "GPIO") begin : gen_phy_gpio
            tl_phy_gpio #(...) u_phy (...);
        end else if (PHY_TYPE == "SERDES") begin : gen_phy_serdes
            tl_phy_serdes #(...) u_phy (...);
        end else begin : gen_phy_model
            tl_phy_model #(...) u_phy (...);
        end
    endgenerate

    // Link layer — same instance regardless of PHY_TYPE
    tl_link u_link (
        // ... APB, AXI, FC ...
        .phy_tx_data    (u_phy.phy_tx_data),   // or named wire
        .phy_rx_clk     (u_phy.rx_clk),
        // ...
    );
endmodule
```

---

## 5. PHY unit testing

Once the PHY wrapper exists as a standalone module it can be tested independently:

### 5.1 GPIO PHY standalone test (`cocotb/phy_gpio/`)

```
tl_phy_gpio_tb.sv
  ├── tl_phy_gpio.sv         (DUT)
  └── tl_phy_gpio_loopback   (wire pad_tx → pad_rx of a second instance)
```

Tests to write:
- **Calibration convergence:** Assert `role_locked`, verify `phy_ready` asserts within
  calibration timeout. Verify `bit_slip` and `phase_offset` settle.
- **Lane fault handling:** Inject a lane with no valid training pattern; verify `lane_fault`
  asserts and the other lanes still lock.
- **Re-calibration:** Assert `swreset`, verify the FSM re-sweeps and re-converges.
- **APB register access:** Read lock status, phase values, lane mask through the PHY APB port.

These tests run completely without `tidelink_top`, `tl_link`, or any AXI/AHB infrastructure.
They are much faster to elaborate and simulate than full-stack tests.

### 5.2 Link-layer standalone test (`cocotb/link_layer/`)

```
tl_link_tb.sv
  ├── tl_link.sv          (DUT)
  └── tl_phy_model.sv     (LOOPBACK=1 model — provides immediate phy_ready)
```

Tests to write:
- **Packet framing / CRC:** Inject data at the TX AXI port; verify it appears correctly at
  the RX AXI port via the loopback model.
- **Credit path:** Verify FCSM credit exchange works without needing a physical PHY.
- **FC node traffic:** Test FC SIDEBAND and CREDIT_RETURN packet paths.

### 5.3 Full-stack integration test (unchanged)

The existing `cocotb/tidelink/` tests continue to use `PHY_TYPE="GPIO"` (or the model) and test
the full system. No changes needed to existing tests.

---

## 6. Calibration signal migration

The calibration signals currently scattered across `axi_chiplet_controller.sv` that need to move
into `tl_phy_gpio.sv`:

| Signal | Current location | Moves to |
|---|---|---|
| `swi_bit_slip_w` | `axi_chiplet_controller.sv:700` | `tl_phy_gpio.sv` internal |
| `swi_training_mode_w` | `axi_chiplet_controller.sv:698` | `tl_phy_gpio.sv` internal |
| `swi_phase_offset_w` | `axi_chiplet_controller.sv:706` | `tl_phy_gpio.sv` internal |
| `cal_calibration_done_w` | `axi_chiplet_controller.sv:471` | → `phy_ready` output of `tl_phy_gpio.sv` |
| `cal_lane_fault_w` | `axi_chiplet_controller.sv:465` | `tl_phy_gpio.sv` internal (or APB-exposed) |
| `phy_link_rx_rx_link_data_w` | `axi_chiplet_controller.sv:476` | `tl_phy_gpio.sv` internal |
| `phy_link_rx_rx_link_clk_w` | `axi_chiplet_controller.sv:477` | → `rx_clk` output of `tl_phy_gpio.sv` |
| Region 8 SW override registers | `axi_chiplet_controller.sv:553–706` | `tl_phy_gpio.sv` APB regs |

After migration, `axi_chiplet_controller.sv` no longer contains any GPIO-specific logic — it
becomes purely a link-layer wrapper.

---

## 7. Migration path (incremental)

This refactor can be done without breaking existing tests if done in the following order:

**Phase 1 — Define the interface (no functional change)**
1. Create `src/rtl/phy/tl_phy_if.sv` (or a flat port list header)
2. Create `src/rtl/phy/gpio/tl_phy_gpio.sv` as a pass-through wrapper around the existing
   `axi_chiplet_controller` GPIO path — identical ports to what is there now, just re-packaged
3. Verify existing cocotb tests still pass

**Phase 2 — Create the model PHY and link-layer tests**
1. Create `tl_phy_model.sv`
2. Create `cocotb/link_layer/` test suite using the model
3. This proves the link-layer interface is correct before any PHY swap

**Phase 3 — Expose Wlink's internal PHY boundary**
1. Modify `Wlink.v` (or create `tl_link.sv` shim) to expose `phy_link_*` as top-level ports
2. Move `WavD2DGpio` instantiation from inside `Wlink.v` into `tl_phy_gpio.sv`
3. Verify all existing tests still pass — functional behaviour is unchanged

**Phase 4 — Move calibration registers into the GPIO PHY wrapper**
1. Move Region 8 SW override registers from `axi_chiplet_controller.sv` into `tl_phy_gpio.sv`
2. Expose them via the `tl_phy_gpio` APB port
3. Update cocotb tests that access these registers (address offsets may change)

**Phase 5 — Implement SerDes PHY wrapper (when needed)**
1. Create `tl_phy_serdes.sv` wrapping the existing `WavD2DSerdesRx/Tx` modules
2. Add `cocotb/phy_serdes/` unit tests
3. Set `PHY_TYPE="SERDES"` in the appropriate ASIC synthesis flist

---

## 8. Impact on existing flists

New flist structure:

```
flist/
├── tidelink_common.flist       # All RTL except PHY
├── tidelink_phy_gpio.flist     # GPIO PHY specific files
├── tidelink_phy_serdes.flist   # SerDes PHY specific files
├── tidelink_phy_model.flist    # Model PHY specific files (sim only)
├── tidelink_fpga.flist         # FPGA build = common + phy_gpio + fpga prims
└── tidelink_asic.flist         # ASIC build = common + phy_serdes (or phy_gpio for v1)
```

The existing `tidelink_fpga.flist` becomes a composition of `tidelink_common.flist` and
`tidelink_phy_gpio.flist`. For the v1 ASIC the GPIO PHY is retained; future ASIC builds use
`tidelink_phy_serdes.flist` without any changes to the link-layer RTL.

---

## 9. Does this work still need doing? (evaluation as of 2026-05-23)

**Yes — but Phase 1 and 2 are the highest-value steps; Phases 3–5 are medium-term.**

### Why this matters now

The CDC audit (`docs/CDC_AUDIT_REPORT.md`) found that `swi_phase_offset` crosses
from hclk and link_clk into pad_clk_rx without synchronization. This is
structurally caused by the calibration signals being wired at the controller level
rather than inside a PHY wrapper. Phases 1–4 of this plan would move those signals
into `tl_phy_gpio.sv`, making the CDC crossing local to the PHY wrapper and
easier to close with a constrained synchronizer.

Similarly, the reset distribution analysis (`docs/RESET_DISTRIBUTION_PLAN.md`)
notes that the reset fan-out is difficult to audit because the reset tree fans out
to all RTL including the GPIO PHY internals. Wrapping the PHY behind a formal
boundary isolates the reset tree analysis.

### Priority assessment

| Phase | Blocks v1 tapeout? | Value | Effort |
|---|---|---|---|
| Phase 1 — Define interface (pass-through wrapper) | No | High (enables unit tests) | 1–2 days |
| Phase 2 — Model PHY + link-layer tests | No | High (test coverage) | 3–5 days |
| Phase 3 — Expose Wlink PHY boundary | No | High (CDC cleanup) | 3–5 days |
| Phase 4 — Move calibration registers into PHY wrapper | No | Medium (cleaner CDC boundary) | 2–3 days |
| Phase 5 — SerDes PHY wrapper | No (v1 uses GPIO) | Medium (required for v2) | 5–10 days |

**Recommended sequencing:**
1. Do Phase 1 and 2 before the next ASIC synthesis run — the model PHY enables
   link-layer tests that do not depend on real GPIO timing, which speeds up
   regression cycles significantly.
2. Do Phase 3 and 4 alongside the CDC fix (CDC_AUDIT_REPORT.md §6), because
   they share the same code region and a combined change is cleaner than two
   separate patches.
3. Defer Phase 5 until SerDes PHY integration is scheduled.

### What is already in place

- `phy_link_rx_rx_link_data[127:0]` and `phy_link_rx_rx_link_clk` are already
  exposed through `axi_chiplet_controller.sv` to the calibrator and lane checker.
  Phase 1 wraps what already exists — no new signal routing needed.
- `WavD2DSerdesRx/Tx` modules exist in `deps/axi-chiplet-controller/logical/PHY/serdes/`.
  Phase 5 only needs the wrapper; the underlying HDL is present.

### What must not be disturbed

- `USE_CLKBUF`, `USE_IDELAY`, `USE_T3A` parameter guards on FPGA-specific cells
  must remain intact through all phases — they control which physical cells are
  instantiated and must not be collapsed into the PHY wrapper without verifying
  FPGA and ASIC build equivalence.
- The existing cocotb regression suite must pass bit-for-bit after each phase
  before the next phase begins.
