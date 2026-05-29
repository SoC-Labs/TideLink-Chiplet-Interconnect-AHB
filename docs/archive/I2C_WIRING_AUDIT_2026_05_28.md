# I2C Wiring Audit — TideLink Pair PYNQ-Z2 (z2_02 ⇄ z2_03)

**Date:** 2026-05-28
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter`
**Branch:** `feat/i2c-wiring-audit` (off `feat/calibrator-prbs` @ 2fa7f0e)
**Author:** investigation triggered by `docs/BRINGUP_DETERMINISM_I2C_PLAN_2026_05_28.md`

## 1. Verdict

**I2C SDA + SCL are NOT wired between the two Pynq-Z2 boards** on the current pair targets (`pynq-z2-pair-all`, `pynq-z2-pair-flip-all`). The chiplet_controller's I2C tristate pins are not exposed at the FPGA top level; they are tied off **inside** the block design. Even with a physical jumper installed today, the bitstream cannot drive the package balls because no IOBUF is instantiated and no XDC pin assignment exists.

This is **confirmed in the RTL/BD/XDC** — no physical inspection of the boards was performed (and is not necessary; the bitstream wouldn't toggle a pad even if a wire were soldered to the pin).

## 2. Evidence (file paths + line numbers)

### 2a. The top-level wrapper has no I2C ports

`fpga/targets/pynq-z2-pair-all/tidelink_design_wrapper.v`

- Lines 40–85: `tidelink_design_wrapper` module port list. Only DDR, FIXED_IO, `pad_clk_tx`, `pad_tx[7:0]`, `pad_clk_rx`, `pad_rx[7:0]`, `led[0..3]`, and `pmod_b_trig` are declared. **No `i2c_*` / `scl` / `sda` ports.**
- Lines 23–24 (header comment): explicitly states the BD tie-offs:
  > `I2C sideband: scl_i/sda_i pulled high (open-drain idle state)`
  > `I2C AXI slave: all inputs tied 0 (not connected)`
- Lines 146–149 (footer comment): confirms `i2c_*` and `s_i2c_axi_*` "are driven INSIDE the block design via xlconstant cells … They are not exposed as BD external ports".

Same applies verbatim in `fpga/targets/pynq-z2-pair-flip-all/tidelink_design_wrapper.v` (lines 23–24, 146–149).

### 2b. The BD `tidelink_design.tcl` declares no I2C ports

`fpga/targets/pynq-z2-pair-all/tidelink_design.tcl`

- Lines 87–88: `### NOTE (I2C / scan ports): I2C sideband and DFT scan ports are tied off in the board wrapper.`
- Lines 119–136 contain every `create_bd_port` call. Inventory:
  - `pad_clk_tx` (out), `pad_tx[7:0]` (out), `pad_clk_rx` (in), `pad_rx[7:0]` (in)
  - `led0..led3` (out)
  - `pmod_b_trig_o` (out), `pmod_b_trig_i` (in)
  - **No `i2c_scl_*`, `i2c_sda_*`, or `s_i2c_axi_*` BD ports.**
- Lines 404–411 (comment block, slightly upstream of the `xlconst_mask_hs_bypass` cell): the source code itself documents the gap:
  > `the I2C sideband physically wired between the two boards. Until the I2C jumpers are in place, the link will hang waiting for the handshake.`

Same content in `fpga/targets/pynq-z2-pair-flip-all/tidelink_design.tcl` (lines 74–75, 384–393).

### 2c. The XDC pin map contains no I2C pins

`fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc` (19 `PACKAGE_PIN` lines total):

| Line | Pin   | Signal           |
|:----:|:-----:|:-----------------|
|  76  | Y9    | `pad_clk_tx`     |
| 79–85| F19, V10, V8, W10, B20, W8, V6 | `pad_tx[0..6]` |
|  90  | W9    | `pad_tx[7]`      |
|  99  | Y7    | `pad_clk_rx`     |
|102–109| U7, C20, Y8, A20, U8, W6, Y6, V7 | `pad_rx[0..7]` |
| 117  | Y16   | `pmod_b_trig` (PMOD-B JB1) |
|124–127| R14, P14, N16, M14 | `led0..led3` |

No `get_ports i2c_*`, `get_ports sda`, or `get_ports scl`. The two occurrences of the string `I2C` in the XDC files (pair-all line 58, pair-flip-all line 36) are only comments warning that **`W18` / `Y17` are I2C-shared on the Pi header and therefore have on-board pull-up resistors** — these pins are deliberately *avoided* by the current pad map.

### 2d. The ribbon wiring documents 18 lanes + GND, no sideband

`fpga/targets/pynq-z2-pair-all/ribbon_wiring.md` lines 18–53:
- 18 conductors carry signals (`pad_clk_tx`, `pad_tx[0..7]`, `pad_clk_rx`, `pad_rx[0..7]`).
- Line 66: 4–8 GND conductors.
- Line 100: the only `ID_SC` mention is in the **"pins to cut"** list — J13 pin 28 (FPGA `Y17`) is one of 12 conductors that must be **removed** from the ribbon because it collides with the on-board SF3 QSPI flash. So the ID_SC line on the Pi header is explicitly *not present* in the ribbon.
- No SDA/SCL row in the wire chart at all.

## 3. Pi-header I2C-capable pins (FYI for the plan)

The PYNQ-Z2 RPi header maps the standard Pi ID-EEPROM I2C0 to **J13 pin 27 → `Y16` (ID_SD/SDA)** and **J13 pin 28 → `Y17` (ID_SC/SCL)** (per `ribbon_wiring.md` line 99–100 and `base.xdc` cross-reference). On the current pair targets:

- **`Y16` is in use** as `pmod_b_trig` (the cross-board PHC capture trigger, see `pynq_z2_tidelink.xdc:117`).
- **`Y17` is unassigned** in the bitstream but is in the "must cut from ribbon" list because it also routes to the on-board SF3 QSPI clock when PMODA is populated.

So even the obvious I2C pins on the Pi header are either (a) repurposed (`Y16` ↔ trigger) or (b) deliberately omitted from the cable. To add a sideband would require:

1. **An XDC patch** assigning `i2c_sda` and `i2c_scl` ports to two presently-unused J13 pins (candidates: pin 13/FPGA `Y14`? pin 37/`W14`? — verify against `base.xdc` and the "pins to cut" coexistence table at `fpga/docs/pynq_z2_connector_coexistence.md`).
2. **Top-level wrapper ports** `i2c_sda` and `i2c_scl` (inout, tristate) with **two new IOBUF instances** (like the existing `u_pmod_b_trig_iobuf` at lines 93–98).
3. **BD `create_bd_port` declarations** for `i2c_scl_i/o/t` and `i2c_sda_i/o/t`, and `connect_bd_net` plumbing from the existing `tidelink_0/i2c_scl_*` / `tidelink_0/i2c_sda_*` pins (currently `xlconstant`-tied — see the BD wrapper comments) out to the new BD ports.
4. **Two ribbon conductors uncut**, with appropriate pull-ups (3.3 kΩ to 3V3 on each line, on at least one board) since I2C is open-drain.

## 4. Chiplet-controller I2C port style

`src/rtl/local_overrides/axi_chiplet_controller.sv` lines 253–259:

```systemverilog
// ── I2C Pins (tristate, active-low drive) ────────────────────────────
input  wire             i2c_scl_i,
output wire             i2c_scl_o,
output wire             i2c_scl_t,
input  wire             i2c_sda_i,
output wire             i2c_sda_o,
output wire             i2c_sda_t,
```

The controller is **already wired for true open-drain tristate** (split `_i`/`_o`/`_t` triplet — the standard Xilinx IOBUF convention). RTL-side this is production-ready; the gap is purely board-level (XDC + BD + IOBUF + ribbon).

The I2C AXI master + slave AXI sockets (`s_i2c_axi_*`, lines 209–247 of the chiplet_controller, lines 357–390 of `tidelink_vivado_wrapper.v`) are similarly fully wired in RTL; in the current build they are tied off by `xlconstant` cells in the BD (per the wrapper header comment) so the I2C engine is **physically idle** in the deployed bitstream — `scl_i` and `sda_i` see `1'b1` (BD-injected idle), `scl_o`/`sda_o`/`scl_t`/`sda_t` go nowhere.

## 5. State of I2C in the existing build (summary table)

| Layer                              | I2C status                                  |
|:-----------------------------------|:--------------------------------------------|
| `axi_chiplet_controller.sv` RTL    | **Functional** (tristate triplet + IRQs)    |
| `tidelink_vivado_wrapper.v` IP-port| **Exposed** at IP boundary                  |
| `tidelink_design.tcl` (BD)         | **Tied off** via xlconstant (no BD ports)   |
| `tidelink_design_wrapper.v`        | **Not in port list** (no top-level inout)   |
| `pynq_z2_tidelink.xdc`             | **No pin assignment**                       |
| Ribbon cable                       | **No SDA/SCL conductor**; ID_SC explicitly cut |

**Bottom line:** the current bitstream **cannot transmit a single I2C edge between the two boards.** The `BRINGUP_DETERMINISM_I2C_PLAN` cannot use the I2C path without an FPGA rebuild plus a cable revision.

## 6. Recommendation — repurpose a TX data lane as a 1-bit sync channel

Per the plan's "Alternative if I2C wiring is unavailable" branch, the cheapest path is to **steal a TX data lane** for a sync edge:

**Best candidate: `pad_tx[7]`** (FPGA `W9`, line 90 of `pynq_z2_tidelink.xdc`).

Rationale:
- It is the **highest-numbered lane**, so it is the natural lane to drop when the link goes `link_lane_mask = 0x7F` (one inactive lane already absorbs the loss).
- It already crosses the ribbon in both directions on both pair targets (no cable change needed — the sync bit travels on an existing conductor).
- It is **not** one of the lanes that PRBS-7 training pinned down as a hot-spot for eye-corner failures (those are typically `pad_tx[0..2]` per the calibrator log).
- The corresponding RX-side ball on the partner board (`Y8` = `pad_rx[7]` on this target's xdc line 109 — note the cross-strap inverts the index) is already an input, so no IOBUF surgery is required.

The deterministic ribbon swap means: drive `pad_tx[7]` from a free-running 1-bit register inside `tidelink_top` (gated by an APB-controlled enable so it stays in the link in normal operation), capture on `pad_rx[7]` via a 2-FF synchronizer, and the calibrator/handshake FSM can use the resulting edge as a sync mark. RTL change is local (no BD or XDC edit, no IOBUF).

If the sync channel must be *bidirectional* (the plan's protocol may require this — verify against §3 of the plan), use **`pad_tx[7]` on the local TX and `pad_rx[7]` on the local RX** — the cross-strap delivers each board's TX[7] to the peer's RX[7], so each direction gets its own dedicated wire automatically.

## 7. Files referenced

- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc`
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/fpga/targets/pynq-z2-pair-all/tidelink_design.tcl`
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/fpga/targets/pynq-z2-pair-all/tidelink_design_wrapper.v`
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/fpga/targets/pynq-z2-pair-all/ribbon_wiring.md`
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/fpga/targets/pynq-z2-pair-flip-all/pynq_z2_tidelink.xdc`
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/fpga/targets/pynq-z2-pair-flip-all/tidelink_design.tcl`
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/fpga/targets/pynq-z2-pair-flip-all/tidelink_design_wrapper.v`
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/fpga/targets/pynq-z2-pair-flip-all/ribbon_wiring.md`
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/fpga/vivado_ip/tidelink_vivado_wrapper.v`
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/src/rtl/local_overrides/axi_chiplet_controller.sv`
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/docs/BRINGUP_DETERMINISM_I2C_PLAN_2026_05_28.md` (the plan triggering this audit)
