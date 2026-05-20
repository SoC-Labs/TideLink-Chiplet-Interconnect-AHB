# TideLink v1 — ASIC Hard-IP Inventory

Author:    SoC Labs (David Mapstone, `d.a.mapstone@soton.ac.uk`)
Branch:    `feat/td-combined`
Date:      2026-05-20
Status:    Pre-NTO scoping document. Section 12 (decisions) contains
           remaining open items for the chip lead / silicon team.

| Date | Author | Change |
|------|--------|--------|
| 2026-05-20 | David Mapstone | Reconcile 100 MHz ASIC target per user constraint. §3 updated from TBD/25 Mb/s to 100 MHz; §2.6 ODT, §6.2/6.3 delay-cell plan, §11 effort, §12 action items, §15 conclusion all updated accordingly. |

---

## 1. Executive summary

This document inventories the foundry hard-IP, std-cell library, and analog
circuitry required to tapeout TideLink v1 as an ASIC chiplet. The RTL stack
that currently runs on the Pynq-Z2 GPIO-PHY bring-up pair (`feat/td-combined`
@ `accaeda`) is functionally complete but is **not** tapeout-ready: every
FPGA-specific primitive (`MMCM`/`PLLE2`, `IDELAYE2`, `IDELAYCTRL`, `BUFG`,
distributed/block RAM inference, `IOBUF`, `IBUF`, `OBUF`, scan-disabled
behavioural reset synchronisers, `cmsdk_fpga_sram` block-RAM inferences,
etc.) needs an ASIC-grade replacement that comes either from a foundry
hard-IP block, the chosen std-cell library, or hand-laid analog. This
document enumerates every such replacement, anchored to the existing RTL.

**Headline area estimate (22 nm-class node, conservative).** ~2.0 – 3.0 mm²
of die area, of which roughly **0.8 mm²** is digital std-cell + DFT overhead,
**0.4 mm²** is SRAM macros (the 16 KB RX FIFO dominates; everything else is
register-file or flop-based), **0.2 mm²** is the link PLL, and **~0.5 mm²**
is consumed by the I/O ring (18 high-speed pads + power/ground/JTAG/I²C).
These numbers are coarse — node, library, and pad pitch all move them
significantly. See §10 for the breakdown.

**Key risks.**

1. **v1 ASIC line rate is 100 MHz/lane** (§3). At 100 Mb/s single-ended
   LVCMOS signalling remains viable (no differential pad library change
   required), and matched-delay-cell or foundry-programmable-delay receive
   alignment is sufficient. ODT is borderline at 100 MHz — see §2.6. The
   receive-side delay calibration uses a foundry programmable delay
   element (PDE) with ~5–10 ps/tap resolution; at a 10 ns UI even a
   coarse 50–100 ps step centres the eye adequately without a DLL.
2. **The Wav PHY's "vendor cells" (`WavClockGate`, `WavResetSync`,
   `WavDemetReset`, `WavD2DGpio*`) are Chisel-generated behavioural** —
   they reference latch/AND/INV models that must be re-mapped to real
   std-cell ICGs (`CKLNQD*`/`CGLPP*`), reset synchronisers, and metastability
   hardened flops at synthesis time. There is no library mapping today.
3. **The 16 KB RX FIFO presently uses `cmsdk_fpga_sram` (FPGA) or the
   TSMC65 `rf_16k` register file (ASIC stub)**. For a production tapeout
   it needs a compiled-SRAM macro that matches the achievable cycle time
   and includes BIST hooks.
4. **No DFT infrastructure exists yet**: no scan stitching, no MBIST, no
   JTAG TAP, no boundary-scan cells on the PHY pads. Scan ports exist
   on `tidelink_top` and on `WavD2DGpio` but are hierarchically dangling.
5. **Power-domain partitioning is undefined**. There are no isolation
   cells, no level shifters, no UPF/IEEE-1801 description, and no
   always-on island in the current RTL.

This is not a fatal list — none of these are unsolved problems in industry
— but every one of them is a months-scale engineering task, and several
have multi-party dependencies (foundry NDA, SRAM compiler licence, JTAG IP
licence, pad-library cell selection). The v1 NTO date must allow for that.

---

## 2. I/O pads + analog

The TideLink chiplet exposes the following pad classes. All counts assume
the v1 reference pinout (`tidelink_top.sv` port list, lines 76–373):

### 2.1 PHY pads (clock + data, both directions)

| Pad             | Direction | Width | Cell type required                                      | Notes |
|-----------------|-----------|-------|---------------------------------------------------------|-------|
| `pad_clk_tx`    | OUT       | 1     | **Clock-capable output driver** with controlled slew + ESD | Forwarded source-synchronous clock. At 100 MHz (v1 ASIC target) slew must be matched to the data driver to preserve eye centre; a LVCMOS18 clock driver with matched drive strength is appropriate. |
| `pad_clk_rx`    | IN        | 1     | **Clock-capable input** with hysteresis input + ESD; routes onto a clock-tree root | At 100 MHz a LVCMOS18 input with controlled threshold is required. Standard LVCMOS33 is functional but the tighter threshold of a low-VT LVCMOS18 variant improves the setup/hold window at 10 ns UI. |
| `pad_tx[7:0]`   | OUT       | 8     | Data output driver, controlled slew, ESD                | At 100 MHz/lane an 8–12 mA LVCMOS18-equivalent driver with matched slew is required; see §3 (line rate). |
| `pad_rx[7:0]`   | IN        | 8     | Schmitt-trigger or comparator input, ESD                | RX is sampled in the receive-clock domain (calibrator-aligned). At 100 MHz LVCMOS18 single-ended input remains viable; differential (SLVS/SSTL) is not required until >500 Mb/s. |

That is 18 high-speed pads total per chiplet. Per-pad ESD requirement: an
**HBM 2 kV minimum** target is standard for chiplet edges, with diodes
between every signal pad and both `VDD_IO` and `VSS_IO`. A pad-level
**power clamp** (snapback NMOS or RC-triggered) must sit on the IO ring at
a ratio of approximately one clamp per 100 µm of IO ring; the foundry's pad
library typically provides this.

### 2.2 Sideband: I²C

| Pad         | Cell type required                                | Notes |
|-------------|---------------------------------------------------|-------|
| `i2c_scl`   | Open-drain bidirectional, fail-safe, ESD          | External pull-up to `VDD_IO`; tri-state driver. `tidelink_top.sv:322–327` exposes the standard `_i`/`_o`/`_t` triple — the integrator wraps these in the IOBUF cell. |
| `i2c_sda`   | Same as `i2c_scl`                                 | Same. |

Open-drain pads with fail-safe input clamps are mandatory because I²C is
used during **AON wake-up** before main core power is up.

### 2.3 Host-side bus IO

The AHB/AXI/APB ports in `tidelink_top.sv` are **internal package ports**:
they are not chip-edge pads; they go to the parent SoC through the
package/interposer. For a standalone chiplet they are PHY-routed across the
chiplet boundary by the chiplet integrator (BoW/UCIe-Streaming-protocol/
parallel-bus). **For v1 we assume the AHB/AXI/APB interfaces are NOT pads
— they cross into the next chiplet over the in-package fabric** (or, for
a monolithic test chip, are stitched into the SoC fabric directly).

If the chiplet team chooses to expose these for bring-up debug, that is an
additional ~600 pads' worth of IO ring (32-bit address × 32-bit data × 3
buses); see §12.

### 2.4 JTAG (TAP controller)

| Pad     | Direction | Cell type required                       | Notes |
|---------|-----------|------------------------------------------|-------|
| `TCK`   | IN        | LVCMOS input with hysteresis, ESD        | Test clock. ≤50 MHz. |
| `TMS`   | IN        | LVCMOS input with hysteresis + pull-up   | TAP state input. |
| `TDI`   | IN        | LVCMOS input with hysteresis + pull-up   | Scan-in. |
| `TDO`   | OUT       | LVCMOS output, tri-statable              | Scan-out. Must be tri-state when not in shift state. |
| `nTRST` | IN        | LVCMOS input + pull-up                   | Async TAP reset (optional in 1149.1, but cheap insurance). |

There is no TAP in the current RTL — see §7.

### 2.5 Power and ground

| Net          | Pad type                                  | Notes |
|--------------|-------------------------------------------|-------|
| `VDD_CORE`   | Power pad, multiple per side              | 0.8 V or 0.9 V typical at 22 nm. Multiple instances on the ring (every ~150 µm) to satisfy IR-drop. |
| `VDD_IO`     | Power pad, multiple per side              | **1.8 V** (LVCMOS18 at 100 MHz v1 ASIC target). 3.3 V LVCMOS33 is functional but power-inefficient at 100 MHz; SSTL or SLVS not required until >500 Mb/s. |
| `VDD_AON`    | Power pad (always-on island)              | Separate rail for §8 AON island (I²C, POR, OTP). Powered before VDD_CORE; powered down only during full chip-off. |
| `VDD_PLL`    | Quiet analog supply                       | Clean rail for §4 PLL. Often 1.5 V – 1.8 V. Sized for ~5 mA. |
| `VSS_CORE`   | Ground pad                                | Many instances. |
| `VSS_IO`     | Ground pad, may share or be separate from `VSS_CORE` | If separate, requires a sub-substrate diode tie. |
| `VSS_PLL`    | Quiet analog ground                       | Separate from `VSS_CORE` to avoid digital switching noise. |

Estimated power-pad count: **24 supply pads** (6×VDD_CORE, 4×VDD_IO,
2×VDD_AON, 1×VDD_PLL, plus matching VSS). Plus the 18 PHY pads, 2 I²C, 5
JTAG, ≈10 misc test/debug pads. **Total IO ring: ~60 pads at v1**.

### 2.6 On-die termination

At the FPGA validation rig rate (25 Mb/s/lane) ODT is clearly not
required: ring oscillation lengths are well below one bit period and
unterminated LVCMOS33 drive is standard practice.

At the **v1 ASIC target of 100 MHz/lane** the situation is borderline.
The 10 ns UI at 100 Mb/s means the round-trip reflection time
(~0.1 ns/mm for on-chip wiring, longer for chiplet package traces) can
be comparable to the bit period on long inter-chiplet nets. The
practical rule: ODT is **optional but recommended** at 100 MHz for
inter-chiplet package or substrate traces longer than ~15 mm. For
on-die or very short package traces (<5 mm) ODT can be omitted; for
interposer or PCB-level chiplet integration it should be included. If
included: a weak on-die pull to `VDD_IO/2` (Hi-Z style, ~120–200 Ω
parallel pull) is sufficient at 100 MHz — strong ZQ-calibrated 40–50 Ω
termination is only mandatory above ~500 Mb/s. The chip lead must decide
based on the package/interposer trace length (§12 item 3). See §3.

---

## 3. Line-rate specification

The v1 ASIC chiplet targets **100 MHz/lane** (single-ended, source-synchronous,
GPIO PHY, parallel 8-lane). The FPGA validation rig operates at 25 MHz/lane
as a baseline artefact of Vivado timing-closure on LVCMOS33 RPi-header GPIO
— that rate is **not** the ASIC target. See `docs/SHORTCOMINGS.md §1.4`.

| Item                | FPGA validation rig | v1 ASIC target              |
|---------------------|---------------------|-----------------------------|
| Lane rate           | 25 Mb/s/lane        | **~100 Mb/s/lane**          |
| Aggregate           | 200 Mb/s            | **~800 Mb/s**               |
| UI                  | 40 ns               | **10 ns**                   |
| Pad standard        | LVCMOS33            | **LVCMOS18** (single-ended) |
| Termination         | None                | Optional weak pull (§2.6); mandatory only if package traces > 15 mm |
| Equalisation        | None                | **None required** at 100 Mb/s with short traces |
| Receive alignment   | 4-bit phase + 3-bit slip (calibrator FSM) + IDELAYE2 | Same calibrator FSM; IDELAYE2 replaced by **foundry PDE** (§6) |

### 3.1 100 MHz pad and analog requirements

**Pad library.** LVCMOS18 single-ended is the natural choice at 100 Mb/s.
It avoids the area and power overhead of differential pads while providing
adequate noise margin at 10 ns UI. LVCMOS33 is functional but wastes IO
power at 100 MHz; SLVS/SSTL are unnecessary at this rate.

**Eye budget.** UI = 10 ns. The calibrator's 4-bit phase offset provides
16 sub-UI steps (0.625 ns/step at 100 MHz — adequate for centring). The
foundry programmable delay element (§6.2) needs ~5–10 ps tap resolution
to resolve within a comfortable fraction of the eye; a 50–100 ps step is
workable. An analog DLL is **not required** — a matched std-cell delay
line characterised at tapeout is sufficient for 100 MHz.

**PLL.** The link PLL (§4.1) generates the application clock. At 100 MHz
the PLL output range must cover 100 MHz (or N × 100 MHz if the
architecture uses a multiple-of-bit-rate internal clock). The current RTL
uses `user_ref_clk` (25–50 MHz reference) to a PLL generating `apb_clk`
and `link_clk`; for 100 MHz operation the PLL output frequency must be
confirmed against the architectural clock multiplier. **Action: confirm
with RTL owner what the PLL-to-bit-rate ratio is (1:1 forwarded-clock
scheme or N:1 oversampling) before specifying PLL output range.**

**Power at 100 MHz.** Dynamic power scales approximately linearly with
frequency relative to the FPGA rig baseline. See §11 for updated estimates.

### 3.2 Rates outside the v1 scope

**25 Mb/s/lane.** Retained as the FPGA validation rig baseline. The
`USE_IDELAY`, `USE_CLKBUF`, and `USE_T3A` parameter-gated paths that
support the FPGA rig at 25 MHz must not be removed from the source tree;
they remain active for any future FPGA characterisation at sub-100 MHz.

**>500 Mb/s/lane.** Differential pad library (SLVS or SSTL) and strong ODT
become necessary. Not in v1 scope.

**>1 Gb/s/lane.** The GPIO PHY architecture breaks down — SerDes (CDR,
equaliser) required. The Wav GPIO PHY is not the right starting point above
~1 Gb/s. This is a v2+ concern.

---

## 4. Clocking hard-IP

The FPGA flow uses Xilinx `clk_wiz` (an MMCM hard-block) to generate
`apb_clk`, `link_clk`, etc., from a single board reference. For ASIC:

### 4.1 PLL

- **Hard-IP PLL** (foundry block). Generates `apb_clk` for digital, plus
  any PHY-internal oversample clock if line rate increases. Typical specs:
  - Reference input: 25–50 MHz from external crystal/oscillator.
  - Output: 100–250 MHz (digital), tunable.
  - Lock time: ≤ 100 µs.
  - Jitter: ≤ 5 ps RMS (cycle-to-cycle).
  - Includes lock-detect output, used as the `pll_locked` qualifier into
    the reset-deassertion FSM.
- **Reference clock pad + crystal interface**. A pad-level oscillator
  amplifier (3-terminal XTAL block, with feedback resistor) if the system
  takes a raw crystal; otherwise just a clock-capable input pad if the
  reference is a clean LVCMOS source.

### 4.2 Clock distribution

- **Post-PLL clock dividers**: pure digital, std-cell flop-based.
  Generate `phc_clk`, `hclk`, scan clock from the PLL output as required.
- **Clock muxes**: every clock that has a scan-shift alternative (i.e.
  almost every clock) needs a glitch-free std-cell clock-mux (`CKMUX`
  variant). Currently absent in RTL.
- **Integrated Clock Gating cells (ICGs)**. The Wav PHY's `WavClockGate.v`
  (`deps/.../wlink/WavClockGate.v:1–35`) is a behavioural model: a
  `WavClockInv` + `wav_latch_model` + `WavAnd`. This must be re-mapped to
  a real std-cell ICG (typical names: `CKLNQD8`, `CGLPP_X*`, `LNQD2`). The
  scan-enable input on the model (`io_test_en`) maps to the std-cell
  `TE` (test-enable) pin so scan shift forces the clock through.

### 4.3 Reset infrastructure

- **POR generator**. A power-on reset cell (often a VBG-comparator + RC
  delay) that holds the chip in reset until VDD_CORE crosses a threshold,
  releases on a ~10 µs delay. AON-island only — driven onto every
  power-domain's reset tree through isolation/level-shifter logic.
- **Reset synchronisers**. The Wav `WavResetSync.v` is two `WavDemetSet`
  flops gated by a `WavAnd` — that is structurally correct (async assert,
  sync deassert, scan-disable through `io_scan_ctrl`), but the cells are
  behavioural. Re-map `WavDemetSet` to a metastability-hardened
  std-cell flop (`SDFRSTPQ` or `MSDF_*` from the library).

### 4.4 Clock-domain crossings

The TideLink RTL has six clock domains today: `hclk` (host AHB),
`link_clk_tx`, `link_clk_rx` (forwarded RX clock), `apb_clk` (Wlink
config), `phc_clk` (PTP), and `i2c_clk` (sideband). Every CDC has
behavioural double-flop synchronisers (`WavMultibitSync`, `WavDemetReset`,
`tidelink_phc_cdc` does explicit `xpm_cdc`-shaped synchronisers).

For ASIC each of these:
- The double-flop has to be implemented with std-cell metastability flops
  (typically with longer setup/hold tested at characterisation).
- Each synchroniser instance must carry a `set_false_path` SDC constraint
  (or `set_max_delay` for bus crossings with handshake).
- Lint must confirm no combinational logic between the two synchroniser
  flops.

---

## 5. Memory macros

This section enumerates every memory in the RTL stack. The headline number
— **16 KB** for the RX FIFO — is set by `RAM_ADDR_W=14` × 32 bits =
4096×32 bit. Everything else is small enough to be flop-based.

### 5.1 TideLink RX FIFO data store

| Property         | Value                                       |
|------------------|---------------------------------------------|
| Module           | `tidelink_sram` (`src/rtl/asic/tidelink_sram.sv:23`) |
| Depth × width    | 4096 × 32 bit  = **16 KB**                  |
| Ports            | **Single-port** (read OR write per cycle)  |
| Read latency     | 1 cycle (pipelined; matches `cmsdk_fpga_sram`) |
| Byte enables     | Yes — `WREN[3:0]`                           |
| Macro instantiated | `rf_16k` (TSMC 65 nm register file)       |
| ECC required?    | **Not yet implemented**. Recommended for v1 — see §5.5. |
| BIST required?   | **Yes** — see §7.                           |

For a 22 nm target this becomes a single 4 KB-deep × 32-bit SRAM macro
(or two 2 KB instances if the SRAM compiler can't compile a 4 KB single-
port at the target frequency). It is the largest macro in the design.

### 5.2 Wlink replay FIFOs

The Wlink TX link layer's replay buffer is described in
`deps/.../wlink/WlinkGenericFCReplayV2*.v`. There are **15 instances**
(`WlinkGenericFCReplayV2_1.v` … `_15.v`), one per FC node. Each
replay buffer stores `2^DEPTH` link-data words × (data + ECC syndrome)
bits. Default `DEPTH=4` → 16 entries per replay buffer.

| Property         | Value (per buffer)                          |
|------------------|---------------------------------------------|
| Depth × width    | 16 × ≈48 bit                                |
| Ports            | Async dual-port (write-from-tx, read-on-NACK)|
| Total instances  | 15                                          |
| Total area cost  | 16 × 48 × 15 ≈ 11.5 kb of storage           |

These are **too small to be macro-worth**; they synthesise to flops and
RAM bits in the std-cell library (~3000 flops total across all 15). No
SRAM-compiler instance needed.

### 5.3 Wlink FC FIFOs

`deps/.../wlink/wlink_wlink_axi_*_a2l_*.v` and `_l2a_*.v` plus the
generalbus and tidelink variants. Each is an async two-clock FIFO
controlled by a Wav FIFOMem instance (`wlink_WavFIFOMem.v`).

| FC node              | Direction | Depth × width            |
|----------------------|-----------|--------------------------|
| AXI AR (axi_ar)      | a2l, l2a  | 8 × 101                  |
| AXI AW (axi_aw)      | a2l, l2a  | 8 × 101                  |
| AXI W                | a2l, l2a  | 8 × 37                   |
| AXI R                | a2l, l2a  | 8 × 47                   |
| AXI B                | a2l, l2a  | 8 × 14                   |
| GeneralBus           | a2l, l2a  | 4 × 32                   |
| **TideLink** (this)  | a2l, l2a  | 16 × 48                  |

These 14 FIFOs add up to ~5000 flop-equivalent bits. Below SRAM-macro
break-even (typically ~256 bits). All synthesise to flops.

### 5.4 Calibrator + lane checker

`tidelink_phy_align_calibrator.sv` and `tidelink_lane_checker.sv` have
**no memory at all** beyond per-lane registers (`slip[0..7]`, `phase[0..7]`,
`best_score[0..7]`, etc. — see calibrator file lines 330–344). All flop-
based. No SRAM compiler need.

### 5.5 ECC / parity

The Wlink link layer already computes a per-packet **ECC syndrome**
(`WlinkEccSyndrome.v` per the flist line 117) — i.e. the *link* is ECC-
protected end-to-end. The FIFO contents themselves are **not**
ECC-protected today; they live in a single SRAM macro and a soft error
on a stored word would corrupt the next packet read. Recommended for v1:
add a **SECDED ECC** wrapper around the RX FIFO macro (1 ECC byte per
32-bit word → 16 KB user-visible + 4 KB ECC overhead). This requires a
wider macro (40 bit) but is otherwise a transparent wrapper.

---

## 6. Programmable delay cells (FPGA `IDELAYE2` → ASIC equivalent)

### 6.1 What the FPGA build uses

`tidelink_idelay_rx.sv` (referenced from the flist, line 193) is a per-lane
IDELAYE2 wrapper: 32-tap Xilinx delay line, ~78 ps/tap, calibrated to a
200 MHz reference via the `IDELAYCTRL` block. The TideLink calibrator
drives a 4-bit phase per lane (i.e. 16 distinct delay points, mapped onto
the 32-tap line). Per-lane × 8 lanes = 8 IDELAYE2 instances per chiplet,
plus 1 `IDELAYCTRL` shared per bank.

### 6.2 ASIC replacement

| Line rate              | Replacement                                                                                                                                     |
|------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| 25 Mb/s/lane (FPGA rig baseline — not the ASIC target) | **Matched-cell delay chain in std-cells**. 16 taps × ~125 ps = 2 ns total (~half UI at 25 MHz). No calibration loop needed. Retained in source tree for FPGA characterisation builds. |
| **~100 Mb/s/lane (v1 ASIC target)** | **Foundry programmable delay element** (PDE) with ~5–10 ps/tap resolution. UI = 10 ns; 16 calibrator-driven taps cover ~80–160 ps — sufficient to centre the eye within a 10 ns window. A **matched-cell PDE array** (layout-constrained, characterised at tapeout corners) is preferred over a DLL for v1 because the required precision (~50–100 ps) is achievable with purely digital characterisation. A DLL hard-IP is **not required** at 100 MHz. |
| >500 Mb/s/lane         | DLL or PLL-locked delay reference required — tap resolution must track PVT. Out of v1 scope. |
| >1 Gb/s/lane           | Subsumed by SerDes IP (out of scope for the GPIO PHY architecture). |

### 6.3 Concrete v1 plan (100 MHz ASIC target)

- **No DLL**. Per-lane 16-tap foundry PDE array, driven by the
  calibrator's `phase_offset[4*N+3:4*N]` (4-bit, 16 taps). Tap
  resolution target: 5–10 ps/tap, giving 80–160 ps total range.
- **Layout discipline**: all 8 lanes' PDE arrays must be placed in a
  matched array under floorplan constraints. At 100 MHz a ±10 ps lane-to-lane
  mismatch corresponds to ±0.1% UI — negligible. PVT corner variation
  matters more: the foundry must characterise the PDE across SS/FF/TT corners
  and confirm monotonicity (no tap inversion across PVT).
- **Characterisation required**: unlike the 25 Mb/s matched-cell chain where
  std-cell timing models suffice, a 10 ps-resolution PDE at 100 MHz needs
  foundry characterisation of tap step size vs PVT. This is a 2–4 week
  additional effort compared to the 25 Mb/s plan but does not require a DLL.
- **No analog DLL hard-IP needed**: the ~5 ps quantum is meaningful at a
  10 ns UI (0.05% UI per tap) but centring only requires landing within
  ±2 taps (~10–20 ps) of the eye centre, which a static characterised PDE
  achieves across all practical PVT corners for a 22 nm-class node.

For rates ≥500 Mb/s a DLL hard-IP must be added to track PVT dynamically
and the calibration controller becomes equivalent to Xilinx `IDELAYCTRL`.

---

## 7. DFT infrastructure

The current RTL exposes **scan ports** at `tidelink_top.sv:169–174`
(`scan_mode`, `scan_asyncrst_ctrl`, `scan_clk`, `scan_shift`, `scan_in`,
`scan_out`) and at the `WavD2DGpio` boundary (`deps/.../WavD2DGpio.v:23–26`:
`io_scan_mode`, `io_scan_asyncrst_ctrl`, `io_scan_clk`, `io_scan_out`).
These are **dangling** — the scan-chain stitching that connects them is a
DFT tool's job, not a hand-RTL job, but the **infrastructure for that
stitching is not yet present**. Specifically:

### 7.1 JTAG TAP controller

- IEEE 1149.1 TAP controller (12-state FSM, instruction register, data
  registers). Typical sources: vendor-provided synthesisable TAP IP, or
  open-source equivalents.
- **Standard data registers**: BYPASS (1 bit), IDCODE (32 bit), USERCODE
  (32 bit), BOUNDARY (one per IO).
- **Custom data registers**:
  - Scan chains entry (instruction = `SCAN_EN_n`): connects to the
    `scan_*` ports on `tidelink_top`.
  - MBIST entry (`MBIST_RUN`): connects to the SRAM-macro BIST controllers.
  - PHY debug (`PHY_DEBUG`): allows pad-direct access to PHY samples for
    eye-margin tests.
- TAP runs on TCK (≤50 MHz independent clock), with its own pad isolation.

### 7.2 Scan stitching

This is a tool-driven flow (Synopsys DFT-MAX, Cadence Encounter Test, or
Tessent — **TBD**, see §12). Every flop in the digital RTL is converted
to a scan-flop variant; the tool selects the chain length and ordering
based on top-level scan-port count.

Estimated scan-chain count: 16–32 chains, balanced for ~10 000 flops
each. Total flop count (rough): 100–150 k flops across the whole chiplet.

### 7.3 MBIST

Every SRAM macro in §5.1 needs a BIST controller (March-C test minimum,
ideally March-CL or programmable). The macro typically provides:
- A BIST-mode pin set (test mode, test data in, test result out).
- A diagnostic shift register for failed-bit logging.

The BIST controllers themselves are auto-generated by the SRAM compiler
or by a separate MBIST tool. **Not present in RTL today** — must be
inserted post-synthesis.

### 7.4 Boundary scan

Every IO pad (§2) needs a boundary-scan cell on the digital side of the
pad cell. Foundry pad libraries include these as a variant of the basic
pad. The cells are chained together (independently of the internal scan
chains) and accessed via the TAP `BOUNDARY` instruction.

### 7.5 PHY scan integration

The Wav PHY exposes a scan path (`io_scan_*`) which must be:
- Stitched into one of the top-level scan chains.
- Have its async resets re-routed through scan-disable: `WavResetSync.v`
  already supports `io_scan_ctrl` for this. The TAP must hold this high
  during scan-shift so the resets are squelched.
- The behavioural reset synchroniser (`WavDemetSet`) must be re-mapped
  to a scan-replaceable flop variant (e.g. `MSDFCT_X*`).

### 7.6 Estimated area / timing overhead

- Scan flops vs non-scan flops: ~7% area increase per flop, plus extra
  routing.
- Top-level DFT muxing: ~1% additional area.
- MBIST controllers + BIST shifters: ~3% of SRAM macro area.
- Boundary-scan cells: ~1% additional pad-ring area.
- **Total digital DFT overhead: 5–10%**, consistent with industry norms.

---

## 8. Power management (UPF / IEEE-1801)

There is **no UPF in the current RTL**. This section is a proposal.

### 8.1 Power island candidates

| Island      | Voltage      | Always-on? | Contents                                              |
|-------------|--------------|------------|-------------------------------------------------------|
| `PD_AON`    | VDD_AON (1.8V) | **Yes**  | I²C slave, POR, OTP/eFuse, role strap latch, AON-clock |
| `PD_CORE`   | VDD_CORE (0.9V) | No      | Wlink digital, FCSM, FC nodes, calibrator, FIFO     |
| `PD_PHY_TX` | VDD_CORE (0.9V) | No      | TX serialisers, forwarded-clock gating              |
| `PD_PHY_RX` | VDD_CORE (0.9V) | No      | RX deserialisers, receive-clock recovery            |
| `PD_PLL`    | VDD_PLL (1.5V)  | No      | PLL hard-IP (gated when CORE is gated)              |
| `PD_FIFO`   | VDD_CORE (0.9V) | No      | RX FIFO SRAM (with retention option — see below)    |

The simplest v1 partitioning is **two islands**: `PD_AON` and everything
else. More aggressive partitioning (separate `PD_PHY_TX`/`PD_PHY_RX` for
half-duplex idle power) is a v1.5 / v2 optimisation.

### 8.2 Isolation cells

Every cross-domain signal needs an isolation cell that clamps to a safe
value (typically `0`) when the originating domain is off. Foundry std-cell
libraries provide these as `ISOL_*` or `LSCL_*` variants. The synthesis
tool inserts them automatically from a UPF file.

### 8.3 Level shifters

If VDD_AON (1.8 V) ≠ VDD_CORE (0.9 V), every signal crossing the AON/CORE
boundary needs a level-shifter cell (`LSU_*` for up, `LSD_*` for down).
The same UPF flow inserts them. Approximate count: 30–60 signals on the
AON↔CORE boundary (I²C ↔ APB bridge, role-strap, POR, scan).

### 8.4 Retention flops

If the chiplet must wake from a low-power state with link state preserved,
selected flops in the Wlink link layer need to be retention-capable
(`SDFRCNQD*` etc.). Identifying which flops need retention is non-trivial
— the Wlink link layer has many state flops, but only a few (link state,
FC-window counters, key register-bank contents) are mandatory to preserve
across a power-down. **Recommendation**: defer retention to v2; v1
power-down is full-reboot.

### 8.5 AON island contents (concrete)

- I²C slave RTL (`deps/.../i2c/rtl/i2c_slave.v` + AXIL master).
- POR generator (hard-IP).
- Role-strap latch + auto-negotiation seed register (small, ~30 flops).
- An "AON clock" generated from a low-frequency RC oscillator (~1 MHz,
  pure analog, no PLL).
- A wake-up controller that sequences VDD_CORE / VDD_PLL power-up after
  an I²C wake command.

Estimated AON island area: 0.05 mm² (mostly the I²C slave + sequencer).

### 8.6 Power gates

Each non-AON island needs a header-cell array (`PGT_*`) controlled by the
AON wake-up FSM. Power-up sequencing:

```
  T0     I²C wake command received.
  T0+1µs AON FSM asserts VDD_CORE power-gate enable.
  T0+50µs VDD_CORE settled. POR for CORE deasserted.
  T0+60µs VDD_PLL power-gate enable.
  T0+150µs PLL locked. Clock-mux switches to PLL output.
  T0+200µs Scan/test mode released; CORE FSM begins.
```

---

## 9. Security / boot infrastructure

This section is scoped to what TideLink **needs**, not a full security
fabric. The full security story is a TideChart-level concern (see the
peer repo `~/SoCLabs/tidechart`).

### 9.1 eFuse

The TideChart protocol uses dynamic chiplet IDs derived from a SRAM PUF
during boot (see `puf_seed` and `puf_ready` ports at `tidelink_top.sv:315–
316`). The PUF is read out of the 16 KB FIFO SRAM during the first cycles
after power-up — i.e. there is no dedicated PUF macro, the existing
SRAM's power-up state is the entropy source.

For chiplet **identity fallback** (when PUF read fails or for production
test), TideLink needs ~64 bits of eFuse storage on the AON island:
- 16 bit chiplet serial number (assigned at packaging).
- 16 bit revision/feature flags.
- 32 bit reserved (security key, future use).

The foundry's standard eFuse macro is typically a single-port read-once
NVM block. ~64 bits is ~0.01 mm².

### 9.2 Boot ROM

**Not required**. TideLink has no embedded CPU; configuration is by APB
writes from the host SoC. The Wlink and PHY register defaults are baked
in by reset values.

### 9.3 Cryptographic primitives

**Not required at v1**. TideChart-level security (chiplet authentication,
key exchange) is a host-SoC concern; TideLink is a pure transport.

If/when TideChart needs an AES/SHA accelerator, it sits in the host
fabric, not in this chiplet.

---

## 10. Estimated area budget at 22 nm

These are scoping numbers — uncertain by ~2×. They assume a 22 nm-class
node (Globalfoundries 22FDX or equivalent), a moderate-density std-cell
library, and a single-port SRAM compiler with reasonable bit cell area.

| Block                              | Area (mm²)      | Source / rationale                                          |
|------------------------------------|-----------------|-------------------------------------------------------------|
| **Digital std-cell**               |                 |                                                             |
|   Wlink (link layer + FCSM + ECC)  | 0.30 – 0.50     | ~70 k flop-equivalent, dominated by replay FIFOs + FCSM     |
|   PHY (calibrator, lane checker, idelay) | 0.05 – 0.10 | ~5 k flop, mostly the calibrator best-of-sweep state         |
|   TideLink fabric (FC adapter, FIFO ctrl, APB regs, addr xlat, PTP, perf) | 0.20 – 0.30 | ~30 k flop, register-rich    |
|   XHB500 AHB↔AXI bridges            | 0.05 – 0.10     | Two bridge instances, modest                                |
|   I²C master/slave + AXIL bridges  | 0.02 – 0.05     | Small                                                       |
|   DFT overhead (5-10% of above)    | 0.04 – 0.10     | Scan flops + MBIST controllers                              |
| **Memory macros**                  |                 |                                                             |
|   RX FIFO 16 KB SRAM macro          | 0.25 – 0.40     | Single-port, ~25 µm² per bit at 22 nm                      |
|   ECC bits (optional)               | 0.05            | If §5.5 ECC is included                                     |
| **Analog / hard-IP**               |                 |                                                             |
|   PLL (link)                        | 0.15 – 0.25     | Standard foundry hard-IP                                   |
|   POR generator                     | 0.01            | Tiny                                                        |
|   AON oscillator                    | 0.02            | Low-frequency RC                                            |
|   eFuse                             | 0.01            | ~64 bits                                                    |
| **IO ring**                        |                 |                                                             |
|   18 PHY pads + ESD                 | 0.20            | Pad-pitch dominated                                         |
|   2 I²C pads                        | 0.02            |                                                             |
|   5 JTAG pads                       | 0.05            |                                                             |
|   24 power/ground pads              | 0.20            |                                                             |
|   ~10 misc test/debug pads          | 0.10            |                                                             |
| **Total chiplet**                   | **2.0 – 3.0**   |                                                             |

The IO ring **dominates** the chiplet at v1: ~30% of total area. A
denser pad library (e.g. wirebond → flip-chip) cuts this significantly.

---

## 11. Engineering effort / risk

Order-of-magnitude estimates. All assume one senior IC engineer per
workstream, plus the existing SoC Labs team for RTL work.

| Workstream                            | Effort       | Comments                                                                                  |
|---------------------------------------|--------------|-------------------------------------------------------------------------------------------|
| **Library bring-up**                  | 4–6 weeks    | Get the chosen std-cell library characterised, .lib/.lef into the flow, gate-level sim.   |
| **Hard-IP integration** (PLL, SRAM)   | 6–8 weeks    | Vendor IP delivery, RTL wrappers, behavioural-model substitution, SDC integration.        |
| **DFT integration**                   | 4–8 weeks    | TAP controller selection, scan stitching, MBIST insertion, boundary-scan integration.     |
| **UPF / power-domain implementation** | 4–6 weeks    | UPF file, isolation/level-shifter insertion, AON island design, retention selection.       |
| **PHY PDE characterisation at 100 MHz** | **2–4 weeks** | No DLL required at 100 MHz (see §6.3). Characterise foundry PDE tap resolution vs PVT corners; confirm monotonicity. ODT optional (§2.6). No eye-monitor required at this rate. |
| **Synthesis + P&R**                   | 6–10 weeks   | Iterative; depends on convergence of timing/area/power.                                   |
| **STA at corners (sign-off)**         | 3–4 weeks    | All PVT corners, all modes (functional, scan, BIST).                                      |
| **DRC / LVS / Antenna sign-off**      | 2–3 weeks    | Standard.                                                                                 |
| **Tapeout sign-off + handoff**        | 2 weeks      | Buffer for last-minute fixes.                                                             |
| **Total (calendar)**                  | **9–11 months** | Many of the above run in parallel; critical path is now the DFT flow and SRAM compiler, not PHY analog (100 MHz does not require DLL or differential pads). |

Key risk gates (where a misstep costs months, not weeks):
1. **PHY PDE characterisation** (§3, §6.3). 100 MHz target requires a
   characterised foundry PDE; this is 2–4 weeks, not months. If the
   foundry's PDE does not meet monotonicity at SS corner, escalate to
   a DLL-based solution — that adds ~3 months.
2. **SRAM compiler availability**. If the foundry's compiler can't hit
   the cycle time at the chosen node, the FIFO has to be redesigned
   (multi-bank, multi-cycle, or wider).
3. **DFT methodology lock-in**. Each tool (DFT-MAX vs Encounter Test vs
   Tessent) has a different netlist/test-protocol output. Late changes
   are expensive.

---

## 12. Action items / open questions

The chip lead must resolve these before NTO. Items are ordered roughly
by deadline urgency.

1. **Line rate = 100 MHz/lane** (§3). **Resolved**. Drives:
   - Pad library choice: LVCMOS18 (single-ended). LVCMOS33 functional
     but power-inefficient; SLVS/SSTL not required at 100 Mb/s.
   - Foundry PDE characterisation required (§6.3): 2–4 weeks, no DLL.
   - ODT: optional, package-trace-length dependent (§2.6). Chip lead
     to confirm based on package/interposer trace length.
   - **25 Mb/s FPGA rig paths (`USE_IDELAY`, `USE_CLKBUF`, `USE_T3A`) must
     be preserved** — do not remove from source tree.

2. **Foundry / node selection**. The area numbers above assume
   22 nm-class. Other candidates: 28 nm (cheaper, ~1.5× area), 16 nm
   (denser, more expensive). Drives every downstream IP selection.

3. **Pad library choice**. Three sub-decisions:
   - LVCMOS18 vs LVCMOS33 for digital.
   - Differential vs single-ended for PHY.
   - Number of supply rails (1, 2, or 3).

4. **PLL hard-IP source**. Foundry-bundled, or third-party (Synopsys,
   Cadence, Silicon Creations)? Drives:
   - Schedule (foundry block is faster but less flexible).
   - Jitter performance.
   - Power.

5. **SRAM compiler version**. The flist currently references the TSMC65
   `rf_16k` register file as a stub. For 22 nm we need the foundry's
   own compiler. Drives:
   - Available depth/width combinations.
   - Cycle time.
   - BIST tool flow.

6. **DFT methodology**. Synopsys DFT-MAX, Cadence Encounter Test, or
   Mentor (Siemens) Tessent? Drives:
   - Scan chain insertion flow.
   - MBIST tool.
   - JTAG TAP IP (each vendor has a preferred TAP).

7. **AON island scope**. Just I²C + POR + role-strap, or include the
   eFuse / wake-FSM? Drives UPF complexity.

8. **Retention flops**. Defer to v2, or include in v1? Recommendation:
   defer.

9. **ECC on RX FIFO**. Include SECDED, or defer? Recommendation: include —
   the area cost is small (~15% on the macro) and silent FIFO bit-flips
   in a chiplet link are extremely hard to debug post-tapeout.

10. **Package / interposer**. Wirebond + standard QFN, or flip-chip on
    interposer? Drives pad-pitch and per-pad cost.

---

## 13. Diagrams

### 13.1 Chiplet die floorplan sketch (annotated)

```
          ╔════════════════════════════════════════════════════════════════╗
          ║                       IO ring (60 pads)                         ║
          ║  ┌──────────────────────────────────────────────────────────┐  ║
          ║  │ PHY pads top:    pad_clk_tx + pad_tx[7:0]                 │  ║
          ║  └──────────────────────────────────────────────────────────┘  ║
          ║                                                                  ║
          ║  ┌─────────────────────────────┐    ┌─────────────────────┐    ║
          ║  │  PHY analog ring             │    │   PLL hard-IP        │    ║
JTAG─►   ║  │  - per-lane delay cells      │    │   (0.2 mm²)          │    ║   ◄─VDD_CORE
          ║  │  - matched-cell array        │    │                      │    ║
          ║  │  - clock-recovery muxes      │    └─────────────────────┘    ║
          ║  │  (0.10 mm²)                  │                                ║
          ║  └─────────────────────────────┘                                ║
          ║                                                                  ║
          ║  ┌─────────────────────────────────────────────────────────┐    ║
          ║  │ Digital core (~0.7 mm²)                                  │    ║
          ║  │                                                          │    ║
          ║  │  ┌──────────┐ ┌────────────┐ ┌─────────────────────────┐│    ║
I²C─►    ║  │  │ Wlink TX │ │ Wlink RX   │ │ TideLink fabric         ││    ║   ◄─VDD_AON
          ║  │  │ + replay │ │ + LL_RX    │ │ - FC adapter            ││    ║
          ║  │  └──────────┘ └────────────┘ │ - FIFO controller       ││    ║
          ║  │                              │ - APB regs              ││    ║
          ║  │  ┌──────────┐ ┌────────────┐ │ - addr translator       ││    ║
          ║  │  │ FCSM     │ │ Calibrator │ │ - PTP + servo           ││    ║
          ║  │  └──────────┘ └────────────┘ │ - perf                  ││    ║
          ║  │                              └─────────────────────────┘│    ║
          ║  │  ┌──────────┐ ┌────────────┐ ┌─────────────────────────┐│    ║
          ║  │  │ XHB500   │ │ XHB500     │ │ I²C master/slave        ││    ║
          ║  │  │ AHB→AXI  │ │ AXI→AHB    │ │ + AXIL bridges          ││    ║
          ║  │  └──────────┘ └────────────┘ └─────────────────────────┘│    ║
          ║  └─────────────────────────────────────────────────────────┘    ║
          ║                                                                  ║
          ║  ┌──────────────────────────────┐  ┌────────────────────────┐  ║
          ║  │  RX FIFO SRAM macro          │  │ AON island (0.05 mm²)  │  ║
          ║  │  4096 × 32 bit (16 KB)        │  │ - I²C slave             │  ║
          ║  │  + ECC (4 KB)                 │  │ - POR generator         │  ║
          ║  │  + BIST controller           │  │ - eFuse (64b)           │  ║
          ║  │  (~0.30 – 0.45 mm²)          │  │ - AON-clk RC osc        │  ║
          ║  └──────────────────────────────┘  └────────────────────────┘  ║
          ║                                                                  ║
          ║  ┌──────────────────────────────────────────────────────────┐  ║
          ║  │ PHY pads bottom: pad_clk_rx + pad_rx[7:0]                 │  ║
          ║  └──────────────────────────────────────────────────────────┘  ║
          ║                                                                  ║
          ╚════════════════════════════════════════════════════════════════╝

          Die size envelope: ≈ 1.5 mm × 1.7 mm (rough; depends on aspect
          ratio + pad pitch).  PHY pads grouped at top/bottom edge to keep
          forwarded-clock + data routes short and matched.
```

### 13.2 Power-island hierarchy

```
                                   VDD_AON (1.8 V) — always-on, sequenced first
                                       │
                                       │   (POR + I²C wake control)
                                       │
                                       ▼
                                ┌────────────────┐
                                │  PD_AON        │
                                │  - I²C slave    │
                                │  - POR / VBG    │
                                │  - role strap   │
                                │  - eFuse        │
                                │  - AON osc      │
                                │  - wake FSM     │
                                └────────┬────────┘
                                         │ (asserts power-gate
                                         │  enables in order)
                                         ▼
                  ┌────────────────────────────────────────────┐
                  │  PD_PLL  (VDD_PLL 1.5 V, qualified by PD_AON)│
                  │  - link PLL hard-IP                          │
                  └────────────────────────────────────────────┘
                                         │
                                         │ (once locked → clock-mux switches)
                                         ▼
                  ┌────────────────────────────────────────────┐
                  │  PD_CORE  (VDD_CORE 0.9 V, qualified by PD_PLL)│
                  │  - Wlink TX/RX/FCSM/replay                   │
                  │  - calibrator + lane checker                 │
                  │  - TideLink fabric (FC adapter, FIFO, APB)   │
                  │  - XHB500 bridges                             │
                  │  - PTP + servo                                │
                  │  - I²C bridge to AXIL                         │
                  └────────────────────────────────────────────┘
                                         │
                                         │ (RX FIFO can be in retention
                                         │  while CORE is gated — v2)
                                         ▼
                  ┌────────────────────────────────────────────┐
                  │  PD_FIFO  (VDD_CORE 0.9 V; retention v2)     │
                  │  - 16 KB SRAM macro                           │
                  └────────────────────────────────────────────┘

  Isolation cells:        every PD_CORE→PD_AON signal (≈10 signals).
                          every PD_PLL→PD_CORE clock (1 signal, glitch-free mux).
                          every PD_FIFO→PD_CORE data (≈40 signals; bus-isolated).
  Level shifters:         PD_AON ↔ PD_CORE if VDD_AON ≠ VDD_CORE.
  Power gates:            PD_PLL header array (≈100 cells).
                          PD_CORE header array (≈500 cells, distributed).
                          PD_FIFO header array if separate from PD_CORE.
```

### 13.3 DFT data flow

```
                         ┌──────────────────────────────┐
                         │   JTAG pads (5)              │
                         │   TCK / TMS / TDI / TDO /    │
                         │   nTRST                       │
                         └──────────────┬───────────────┘
                                        │
                                        ▼
                         ┌──────────────────────────────┐
                         │   TAP Controller (1149.1)    │
                         │   - 16-bit IR                 │
                         │   - BYPASS / IDCODE / USERCODE│
                         │   - SCAN_EN / MBIST_RUN /    │
                         │     BOUNDARY / PHY_DEBUG     │
                         └─────┬──────────┬─────────────┘
                               │          │
                ┌──────────────┘          └──────────────┐
                ▼                                         ▼
   ┌──────────────────────┐                  ┌──────────────────────┐
   │ Boundary Scan Chain  │                  │ Internal Scan Chains │
   │  (≈60 pad cells)     │                  │   (16–32 chains,     │
   │   Cycle: TCK         │                  │    ≈10 k flops each) │
   └──────────────────────┘                  │   Cycle: scan_clk    │
                                              └──────────┬───────────┘
                                                         │
                                  ┌──────────────────────┼──────────────────────┐
                                  ▼                      ▼                      ▼
                       ┌────────────────────┐ ┌────────────────────┐ ┌────────────────────┐
                       │  PHY scan          │ │  Wlink scan        │ │  TideLink fabric   │
                       │  (via io_scan_*)   │ │  (calibrator,      │ │  scan (FC, FIFO,   │
                       │  WavResetSync     │ │   LL_TX/RX, FCSM, │ │   APB regs, etc.)  │
                       │  squelched via    │ │   replay flops)    │ │                    │
                       │  io_scan_ctrl     │ │                    │ │                    │
                       └────────────────────┘ └────────────────────┘ └────────────────────┘

                          MBIST path (separate from scan):
                                  TAP MBIST_RUN
                                       │
                                       ▼
                         ┌──────────────────────────────┐
                         │  RX FIFO SRAM BIST controller │
                         │  - March-CL pattern generator │
                         │  - Failed-bit log (8 entries) │
                         │  - Done/PassFail status to TAP│
                         └──────────────────────────────┘

   Test modes:
   (a) Normal:         scan_mode=0, all functional clocks live, no resets squelched.
   (b) Scan-shift:     scan_mode=1, scan_clk drives all flops, async resets gated.
   (c) Scan-capture:   one cycle of functional clock to capture, then back to shift.
   (d) MBIST:          MBIST_RUN asserted, FIFO clocked by scan_clk or BIST clock.
   (e) Boundary scan:  BOUNDARY in IR, IO ring cells in shift mode.
   (f) PHY debug:      PHY_DEBUG in IR, raw pad samples readable from TDR.
```

---

## 14. Cross-reference: FPGA primitives → ASIC replacements

A summary table for the integrator. Every FPGA-flow primitive used in
this codebase has an ASIC counterpart:

| FPGA primitive (Xilinx 7-series)  | TideLink role                              | ASIC replacement                                              |
|-----------------------------------|--------------------------------------------|---------------------------------------------------------------|
| `MMCM` / `PLLE2` (`clk_wiz`)      | Generate `apb_clk`, `phc_clk` from board ref | Foundry PLL hard-IP (§4.1)                                 |
| `IDELAYE2` / `IDELAYCTRL`         | Per-lane RX bit-position adjustment        | **Foundry PDE at 100 MHz (v1 ASIC target)** — matched-cell PDE array, characterised at tapeout corners (§6.3). DLL not required at 100 MHz. |
| `BUFG`                            | Recovered-RX-clock distribution            | Std-cell clock-tree synthesis                                 |
| `BUFGCE` (clock gating)           | Wlink `WavClockGate` (FPGA mapping)        | Std-cell ICG (e.g. `CKLNQD8`)                                 |
| `IBUF` / `OBUF`                   | LVCMOS33 I/O                               | Foundry pad cells (§2)                                        |
| `IOBUF`                           | I²C bidirectional                          | Foundry open-drain bidirectional pad                          |
| Distributed RAM (small FIFOs)     | Wlink replay buffers, FC FIFOs (§5.2/5.3)  | Flop-based — no replacement needed                            |
| Block RAM (`cmsdk_fpga_sram`)     | RX FIFO 16 KB (§5.1)                       | Compiled SRAM macro (foundry compiler)                        |
| `STARTUPE2` / config flash        | (Not used — chiplet is config-by-host)     | (n/a)                                                         |
| `ILA` / `VIO`                     | Bring-up debug (FPGA only)                 | Discarded for ASIC — replaced by JTAG TAP debug regs (§7.1)   |

---

## 15. Conclusion

TideLink v1 is functionally complete in RTL but not tapeout-ready. The
gap is squarely in the **foundation layer**: pad cells, hard-IP blocks,
DFT infrastructure, and the UPF/power-management description. None of
these are research problems; they are well-understood, but each is a
months-scale engineering task with vendor and tool dependencies.

For an aggressive v1 tapeout we recommend:

1. **Target 100 MHz/lane** with LVCMOS18 single-ended pads and a
   characterised foundry PDE (no DLL, no differential signalling, no
   eye-monitor required at this rate). The 25 Mb/s FPGA rig paths must
   be preserved in source and are not in scope for removal.
2. **Two power islands** (PD_AON + everything else), no retention.
3. **Foundry's bundled PLL + SRAM compiler**, single TSMC65-compatible
   reg-file substitute already in place as a stub. PLL output range
   must be confirmed against the 100 MHz bit-rate architecture.
4. **Standard DFT methodology** (DFT-MAX or equivalent), JTAG TAP from
   any reputable IP source.
5. **SECDED ECC on the 16 KB RX FIFO** (cheap insurance).

This gets the chiplet protocol stack — Wlink + GPIO PHY + TideLink FC
fabric + PTP — into silicon at 100 MHz, validates the architecture, and
provides the platform from which a v2 with a real SerDes can be planned.

The chip lead's decisions (§12) gate everything that follows.

---

*Document version: v1.0 (2026-05-20). Generated from `feat/td-combined`
@ `accaeda`.*
