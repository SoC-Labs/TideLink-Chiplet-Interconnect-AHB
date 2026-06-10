# I2C Pin Analysis — P15/P16 (Arduino I2C) — td-autonomy v6

- **Branch / HEAD:** `feat/td-autonomy` @ `d385349`
- **Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-autonomy/`
- **Targets analysed:** `pynq-z2-pair-all` (BD/Tcl/XDC/wrapper) and `pynq-z2-pair-flip-all`
- **Scope:** Read-only confirmation that P15/P16 reach the chiplet `i2c_master/i2c_slave` without contention, double-driving, or PS-side IIC EMIO interference.

## Verdict summary

| Check | Result | Evidence |
|---|---|---|
| 1. XDC: P15/P16 only on `i2c_scl_io`/`i2c_sda_io` | **PASS** | `pynq_z2_tidelink.xdc:159-160` (pair-all), `:83-84` (flip-all) — sole `PACKAGE_PIN P15/P16` lines in *.xdc |
| 2. PS-side IIC EMIO **not** routed to P15/P16 | **PASS** | PS7 config block `tidelink_design.tcl:167-181` enables only UART0; zero `PCW_I2C*`/`PCW_IIC*`/`EMIO_I2C*` properties; no `axi_iic` IP cell |
| 3. No other XDC constraint touches P15/P16 | **PASS** | `grep -rEi "PACKAGE_PIN P1[56]"` over all `*.xdc` returns 4 hits — the two source XDCs + their auto-generated propImpl mirror. `_drc.xdc`/`_idelay.xdc`/`_timing.xdc` clean. |
| 4. BD IOBUF wiring reaches chiplet `i2c_*` | **PASS** | BD ports `i2c_{scl,sda}_{i,o,t}` declared at `tidelink_design.tcl:130-135`; `connect_bd_net` to `tidelink_0/i2c_*` at `:579-584` (pair-all) / `:560-565` (flip-all); wrapper IOBUF idiom at `tidelink_design_wrapper.v:110-115`. Tristate is canonical `_t=1 -> Hi-Z`; `_i` is read straight off the pad. |
| 5. board.xml Arduino I2C matches XDC | **PASS** | `part0_pins.xml:31-32` (TUL PYNQ-Z2 A.0/1.0): `i2c_scl_i loc="P15"`, `i2c_sda_i loc="P16"`. Same as our XDC. |

## Detailed findings

### 1. XDC ownership of P15/P16 (PASS)
Only two `set_property PACKAGE_PIN P15/P16` lines exist per target, both LVCMOS33, both on the `i2c_{scl,sda}_io` ports created by BD Edit 1. The auto-generated `tidelink_design_wrapper_propImpl.xdc` in `imp/fpga/project/.../synth_1/.Xil/` is a Vivado-emitted mirror of the same two constraints (lines 41, 43) — not a duplicate source.

### 2. PS-side IIC routing (PASS — clean)
The single `processing_system7_0` instance (`tidelink_design.tcl:167`) is configured with only:
- `PCW_FPGA0_PERIPHERAL_FREQMHZ {100}`, `PCW_EN_CLK0_PORT/RST0_PORT`, `PCW_USE_M_AXI_GP0`, `PCW_USE_FABRIC_INTERRUPT`, `PCW_IRQ_F2P_INTR`
- `PCW_UART0_PERIPHERAL_ENABLE {1}` on `MIO 14..15`
- DDR sizing.

Zero `PCW_I2C*`, `PCW_IIC*`, `EMIO_I2C*`, `I2C_PERIPHERAL_*`, or MIO I2C properties. No `axi_iic` IP cell is instantiated. PS-side IIC0/IIC1 are therefore disabled — they cannot be EMIO-routed to P15/P16 or any other pin. Same in pair-flip-all.

### 3. Other XDC files (PASS)
`pynq_z2_tidelink_drc.xdc`, `_idelay.xdc`, `_timing.xdc` for both targets contain zero references to P15, P16, `i2c`, `iic`, `scl`, `sda`.

### 4. BD IOBUF + wrapper wiring (PASS)
- BD declares six ports (`i2c_scl_i`, `i2c_scl_o`, `i2c_scl_t`, `i2c_sda_i`, `i2c_sda_o`, `i2c_sda_t`) at `tidelink_design.tcl:130-135`.
- `connect_bd_net` wires each to `tidelink_0/i2c_*` 1:1 at `:579-584` (pair-all) / `:560-565` (flip-all). No `xlconstant` ties — verified.
- Wrapper open-drain emulation at `tidelink_design_wrapper.v:110-115` is the canonical Vivado pattern (`assign io = t ? 1'bz : o; assign i = io;`). Symmetric for SCL and SDA. No double-drive: `o_int` only sourced from BD, `io` only sourced from the ternary, `i_int` only consumed.
- Identical idiom in flip-all wrapper (`:111-116`).

### 5. Incidental P15/P16 references
Comment-only hits (non-constraint):
- `pynq_z2_tidelink.xdc` (pair-flip-all) line 36 — historical note about pad_clk_rx previously on W18 (a "Pmod-A-shared, I2C-pulled-up" pin); pad_clk_rx is no longer on W18, no current conflict.
- Documentation strings in BD tcl `:577-579` / `:558-560` and wrapper `:87-89` describing the Arduino I2C repin — comments only.

## Side-effect / risk review
- **Voltage domain:** P15/P16 are bank 35 on xc7z020-1clg400; LVCMOS33 matches the Arduino shield 3V3 rail. OK.
- **Pull-ups:** TUL PYNQ-Z2 has on-board pull-ups on the Arduino dedicated I2C pads (per board.xml `i2c on J3`). No external pull-up needed on the Dupont harness. OK.
- **Bank conflict:** No other port in the BD lands on P15/P16 (sole owners are `i2c_{scl,sda}_io`).
- **Open-drain semantics:** Both sides drive `_o=0` only when transmitting; idle = `_t=1` (Hi-Z) so the pull-ups float SCL/SDA high. Two boards on the same harness will arbitrate cleanly — no contention path.

## Conclusion
**No HW-side conflict found.** P15/P16 are exclusively owned by the chiplet I2C sideband, properly IOBUF'd, and not aliased to any PS peripheral. If `NEGO_STATUS=0x027` / `ST_ERROR` / `sda_start=0` persists on silicon despite the Dupont harness, the cause is **not** a pin-routing or constraint problem in this bitstream — investigation should move to (a) chiplet-side `i2c_master/i2c_slave` clock/reset, (b) `i2c_prescale` value, (c) bus-detector/state-machine logic, or (d) electrical (pull-up strength, harness length, GND continuity).
