# Integration Guide

How to wire `tidelink_top` into a host SoC, build its dependencies, and take it
through the FPGA or ASIC flow.

This page is the *structural* half of integration — ports, clocks, apertures,
build entry points. The knob-by-knob detail lives in [Parameters](parameters.md);
the bit-level register detail lives in [Register Map](register_map.md); the
power-on ordering lives in [Bring-Up](bringup.md).

Every command below was checked against the Makefile or script that provides it.
Where a claim could not be verified from this checkout it is marked
**UNVERIFIED** rather than smoothed over.

---

## 1. Prerequisites

### 1.1 Environment

Everything — flists, cocotb, lint, CDC, FPGA packaging, ASIC synthesis — resolves
paths through environment variables set by one script at the repo root:

```bash
source ./set_env.sh
```

| Variable | Set by | What it points at |
|---|---|---|
| `TIDELINK_HOME` | `set_env.sh:16` | repo root (every flist interpolates it) |
| `CMSDK_DIR` | `set_env.sh:19` | `${ARM_IP_LIBRARY_PATH}/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0` |
| `CMSDK_FPGA_SRAM_V` | `set_env.sh:22-29` | `cmsdk_fpga_sram.v`, with a fallback to the standalone BP210 install (it is **missing** from some Corstone-101 installs) |
| `XHB500_IP_DIR` | `set_env.sh:32` | Arm XHB-500 generator root |
| `XHB500_GEN_DIR` / `XHB500_SLV_DIR` / `XHB500_MST_DIR` | `set_env.sh:35-37` | generated bridge output under `deps/xhb500/generated/` |
| `VCS_HOME`, `VERDI_HOME`, `VIP_HOME` | `set_env.sh:40-42` | Synopsys tool installs |

On **first run only**, `set_env.sh` also *generates* the two XHB500 bridges
(`xhb_chiplet_slv`, `xhb_chiplet_mst`) from `deps/xhb500/configs/*.cfg` by
invoking `${XHB500_IP_DIR}/logical/generate` (`set_env.sh:50-100`). Subsequent
runs print `[skip] … already generated`.

:::{danger}
**The 4-second trap.** Forgetting `source ./set_env.sh` makes *every*
simulation suite fail in 4–5 seconds, which looks exactly like broken RTL
(`docs/HANDOVER_Z2_PICKUP_2026_07_30.md:331`). Read one suite log before
theorising. `make sim_gate` now guards this with `sim_gate_env_check`
(`Makefile:305-309`), which refuses to run unless `vcs` and `cocotb-config` are
both on `PATH`.
:::

Most V2-PHY work additionally needs `export TIDELINK_PHY_V2=1` before building.

### 1.2 Submodules

```bash
git submodule update --init --recursive
```

`.gitmodules` declares **three** submodules:

| Path | Upstream | Provides |
|---|---|---|
| `deps/axi-chiplet-controller` | `https://git.soton.ac.uk/soclabs/chiplets/axi-chiplet-controller.git` | Wlink (link layer, FC nodes, GPIO PHY), `logical/top/axi_chiplet_controller.sv`, I²C master/slave cores, bridges, `apb4_if.sv` |
| `deps/tidelink-gpio-phy` | `git@github.com:SoC-Labs/TideLink-Chiplet-GPIO-PHY.git` | V1 lane checker / calibrator scoring RTL, `tidelink_gpio_phy_apb_regs.sv` |
| `deps/tidelink-phy` | same upstream, `branch = main` | V2 PHY — `WavD2DGpio*`, `tidelink_lane_deskew.sv`, calibrator, sync insert/detect, segmenter/mask, PHY-BIST |

:::{note}
`docs/reference/DEPENDENCIES.md` and `docs/INTEGRATION_GUIDE.md` §1.3 both still
say "only these two submodules". That is stale — `.gitmodules` in this checkout
lists three, and `deps/tidelink-gpio-phy` / `deps/tidelink-phy` point at the same
upstream URL (tracked as bug **TL-014**, *duplicate PHY submodule*, in
`docs/BUG_REGISTRY.yaml`).
:::

`deps/xhb500` is **not** a submodule — it is an in-tree directory of Arm XHB500
generator *configs*, whose `generated/` output `set_env.sh` produces.

### 1.3 Vendor IP is read-only

Arm CMSDK/BP210 and the XHB500 generator live under the shared lab IP library
(`${ARM_IP_LIBRARY_PATH}`, i.e. `/research/AAA/ip_library`). **Never edit,
chmod, move or copy over anything in that tree** — other engineers and CI
builds source it directly.

The sanctioned workaround when a fix appears to need a vendor or submodule
change is the `src/rtl/local_overrides/` convention:

1. Copy the affected file into `src/rtl/local_overrides/`.
2. Re-point the flist entry at the local copy.
3. Mark the deviation in-file with a comment block (search `SoC Labs §9` and
   `SoC Labs ILA` for existing examples) so a Chisel regen can re-apply it.

That directory is not an accident — it currently holds the Wlink/Wavious
patched sources (`Wlink.v`, `WlinkRxLinkLayer.v`, `WlinkGenericFCSM*.v`,
`WavD2DGpio*.v`, …) plus SoC-Labs-owned overrides of submodule files
(`axi_chiplet_controller.sv`, `tidelink_autoneg.sv`, `i2c_master_axil.v`). The
edit policy is spelled out in `docs/reference/DEPENDENCIES.md`
("Edit policy" under each submodule).

---

## 2. Top-level interface

Module: `tidelink_top` (`src/rtl/tidelink_top.sv`). Parameters at lines 37–229,
ports at lines 230–555. Widths below use the parameter defaults
(`SYS_ADDR_W = SYS_DATA_W = 32`, `RAM_ADDR_W = 14`, `FC_DATA_W = 48`,
`NUM_PHY_LANES = 8`).

### 2.1 Clocks, resets and DFT

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `hclk` | in | 1 | AHB / application clock. Also feeds the chiplet controller's `apb_clk` **and** `app_clk` (`tidelink_top.sv:2481-2482`). |
| `hresetn` | in | 1 | Active-low synchronous reset for all AHB/APB/FC-adapter logic. |
| `poresetn` | in | 1 | Active-low power-on reset. Drives the Wlink POR and the role registers. |
| `phc_clk` | in | 1 | PTP hardware-clock domain (may differ from `hclk`). |
| `phc_resetn` | in | 1 | Active-low reset for the PHC domain. |
| `user_ref_clk` | in | 1 | **Dedicated** Wlink PLL / PHY high-speed reference. Not `hclk`. |
| `idelay_ref_clk` | in | 1 | 200 MHz `IDELAYCTRL` reference. Used only when `USE_IDELAY=1`; **tie `1'b0` in sim/ASIC** (`tidelink_top.sv:344-347`). |
| `scan_mode`, `scan_asyncrst_ctrl`, `scan_clk`, `scan_shift`, `scan_in` | in | 1 each | DFT controls (1-bit legacy chain stub). |
| `scan_out` | out | 1 | DFT chain output. |

### 2.2 AHB ports

Four AHB-Lite subordinates and one AHB-Lite manager.

| Port group | Role | Address width | Function |
|---|---|---|---|
| `ahb_sub_*` | subordinate | `SYS_ADDR_W` (32) | **Transparent bridge.** Address-translated → XHB500 AHB→AXI → Wlink → peer's `ahb_mng_*`. Remote memory looks local. |
| `ahb_tx_*` | subordinate | `RAM_ADDR_W` (14) | **TX aperture.** Straight into the TideLink FC node; no address translation. ⚠ wedge hazard, see below. |
| `ahb_fifo_*` | subordinate | `RAM_ADDR_W` (14) | **Local RX FIFO window.** Read received packets. |
| `ahb_ptp_*` | subordinate | 4 | PTP TX write port — a CPU write here triggers a PTP FC message. |
| `ahb_mng_*` | **manager** | `SYS_ADDR_W` (32) | Incoming traffic from the peer, via XHB500 AXI→AHB. Connect as a manager on the host matrix. |

Each subordinate carries the usual `hsel / haddr / htrans / hsize / hwrite /
hwdata / hready` inputs and `hrdata / hresp / hreadyout` outputs; `ahb_sub_*`
additionally has `hburst[2:0]` and `hprot[3:0]` (`tidelink_top.sv:246-247`).

:::{warning}
**`ahb_mng_hready`, `ahb_mng_hrdata` and `ahb_mng_hresp` are INPUTS**
(`tidelink_top.sv:301-303`). HREADY flows slave→manager in AHB, and TideLink is
the manager on that bus. A previous `output` declaration was caught by Formality
LEC as a directly-undriven primary output. Do not "fix" the direction.
:::

:::{danger}
**`ahb_tx_*` is the wedge-hazard port.** A write into the TX aperture while the
link is not fully up hangs the bus — bench-confirmed on z2_02, physical
power-cycle required (`pynq_host/scripts/hwtest/README.md`, "Safety
constraints"). Gate every host-side access behind a verified-link check; the
hardware test suite does exactly this with `tt_gate_ahb_tx()` and wraps each
write in `timeout`. `ahb_sub_*`, `ahb_fifo_*` and `ahb_mng_*` are safe with the
link down.
:::

The adapter does have a backstop: `TX_STALL_TIMEOUT_LOG2 = 16`
(`src/rtl/tidelink_fc_adapter.sv:44`, ≈1.3 ms at 50 MHz) terminates a stalled
beat with a bounded 2-cycle AHB ERROR rather than hanging forever. That protects
the *bus*, not the *board* — the gate is still required.

### 2.3 APB configuration port

One unified 15-bit APB subordinate for the whole subsystem.

| Port | Dir | Width |
|---|---|---|
| `apb_paddr` | in | 15 |
| `apb_psel`, `apb_penable`, `apb_pwrite` | in | 1 each |
| `apb_pwdata` | in | `SYS_DATA_W` (32) |
| `apb_pstrb` | in | 4 |
| `apb_pprot` | in | 3 |
| `apb_prdata` | out | `SYS_DATA_W` (32) |
| `apb_pready`, `apb_pslverr` | out | 1 each |

Decode is on `paddr[14:13]` (`tidelink_top.sv:825-827`) — see
[§4 Address map](#4-address-map-and-placing-the-apertures).

### 2.4 PHY pads

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `pad_clk_tx` | out | 1 | Forwarded transmit clock. **This die's `pad_clk_tx` is the peer's `pad_clk_rx`.** |
| `pad_tx` | out | `NUM_PHY_LANES` (8) | Transmit lanes. |
| `pad_clk_rx` | in | 1 | Peer's forwarded clock — recovered, used to capture all 8 lanes. |
| `pad_rx` | in | `NUM_PHY_LANES` (8) | Receive lanes. |

### 2.5 PTP / PHC interface

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `phc_hw_capture` | out | 1 | Capture strobe to the external PHC, pulsed at the PTP short-packet handshake. |
| `phc_nanoseconds` | in | 30 | Free-running PHC nanoseconds. |
| `phc_seconds` | in | 48 | Free-running PHC seconds. |
| `phc_pps` | in | 1 | PHC pulse-per-second. |
| `phc_hw_cap_seconds` | in | 48 | Captured timestamp — seconds. |
| `phc_hw_cap_nanoseconds` | in | 30 | Captured timestamp — nanoseconds. |
| `phc_hw_cap_sub_nanoseconds` | in | 32 | Captured timestamp — sub-nanoseconds. |
| `phc_hw_set_time` | out | 1 | Servo step-set strobe. |
| `phc_hw_set_seconds` | out | 48 | Servo step-set value — seconds. |
| `phc_hw_set_nanoseconds` | out | 30 | Servo step-set value — nanoseconds. |
| `phc_hw_adj_valid` | out | 1 | Servo frequency-adjust valid. |
| `phc_hw_adj_ns_incr_frac` | out | 32 | Servo frequency-adjust increment (fractional ns). |
| `phc_locked_i` | in | 1 | External PHC lock. **Tie `1'b1` for single-link deployments**; only gates anything when `PHC_LOCK_GATE_EN=1` (`tidelink_top.sv:391-397`). |
| `servo_locked` | out | 1 | Hardware servo has converged. |

The PHC itself is a separate IP (`ptp-hardware-clock-ahb`) with its own APB
port — it is not inside `tidelink_top`.

### 2.6 Interrupts

All active-high level outputs: `released_credits_irq`, `doorbell_irq`,
`packet_committed_irq`, `ptp_irq`, `perf_irq`, `wlink_irq`, `nego_error_irq`,
`train_fail_irq`, `i2c_nbsy_irq`, `i2c_nrd_empty_irq`.

### 2.7 TideChart AXI-Stream and congestion sideband

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `tc_axis_tx_tvalid` / `tc_axis_tx_tdata` / `tc_axis_tx_tready` | in / in / out | 1 / 48 / 1 | External module → link (FC `pkt_type = 2'b10`, PKT_EXT). |
| `tc_axis_rx_tvalid` / `tc_axis_rx_tdata` / `tc_axis_rx_tready` | out / out / in | 1 / 48 / 1 | Link → external module. |
| `tc_qos_priority` | in | 3 | `0` = TX-aperture FIFO data outranks PKT_EXT; `>0` boosts PKT_EXT above the TX aperture. |
| `tl_local_link_state_o` | out | 5 | `{starve, trend[1:0], level[1:0]}`, combinational, `hclk` domain. |
| `tl_link_state_change_o` | out | 1 | One-cycle pulse on any quantised transition. |
| `tl_ewma_credit_o` | out | 13 | EWMA credit estimate. |
| `tl_bcast_ack_i` | in | 1 | Level-sensitive; clears the starve-sticky after a broadcast. |

Tie off if unused (`tidelink_top.sv:434-445`).

### 2.8 Status, role, autoneg and I²C

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `link_active` | out | 1 | **Literally `role_locked_o`** (`tidelink_top.sv:2784`). Asserts ≈5 µs *before* the link can carry anything. |
| `tl_data_mode_o` | out | 1 | FCSM state ≥ 4 — the link genuinely carries FC/EXT words. **Gate downstream consumers on this, not on `link_active`** (`tidelink_top.sv:452-471`, sourced from the controller's `data_mode_o` at `:2770-2771`). |
| `d2d_reset_o` | out | 1 | Sideband reset out. |
| `role_strap_i` | in | 1 | Role strap pin (`0` = master-by-priority, `1` = slave-by-priority on the FPGA pair targets). |
| `role_is_master_o`, `role_locked_o` | out | 1 each | Resolved role and lock status. |
| `apb_debug_unlock_i`, `mask_hs_bypass_i` | in | 1 each | ⚠ **Discarded at the default parameter settings** — see [Parameters](parameters.md#65-honest_mask_hs-and-debug_unlock_default). |
| `nego_priority_i` | in | 16 | External negotiation priority (OTP/UID). |
| `puf_seed`, `puf_ready` | in | 16 / 1 | From an external PUF sampler. |
| `i2c_scl_i/o/t`, `i2c_sda_i/o/t` | in/out/out | 1 each | Open-drain tristate I²C sideband — connect through IOBUFs. |
| `s_i2c_axi_*` | AXI4 slave | 4-bit addr, 2-bit ID, 32-bit data | CPU-driven I²C master path (`tidelink_top.sv:514-548`). |

### 2.9 What to tie off if you do not use a feature

| Unused feature | Tie-off |
|---|---|
| PTP / PHC | `phc_locked_i = 1'b1`; all `phc_*` inputs to `0`; leave outputs unconnected. Optionally set `STUB_PTP=1` **with** `STUB_SERVO=1`. |
| TideChart AXIS | `tc_axis_tx_tvalid = 0`, `tc_axis_rx_tready = 1`, `tc_qos_priority = 0`, `tl_bcast_ack_i = 0`. |
| IDELAY (sim/ASIC) | `idelay_ref_clk = 1'b0` and `USE_IDELAY = 1'b0`. |
| Address translation | `BYPASS_ADDR_XLAT = 1'b1` (replaces the translator with a passthrough, `tidelink_top.sv:2355`). |
| PUF | `puf_seed = 16'h0`, `puf_ready = 1'b0`. |
| DFT | `scan_mode = scan_shift = scan_asyncrst_ctrl = 0`, `scan_clk = 0`, `scan_in = 0`. |

---

## 3. Clocking and reset

### 3.1 Domains

| Domain | Source | Consumers |
|---|---|---|
| `hclk` | host SoC | All AHB/APB logic, FC adapter, FIFO, perf, and — in every current integration — the controller's `apb_clk` and `app_clk`. |
| `user_hsclk` | `user_ref_clk` | PHY high-speed reference. |
| `link_clk` | `io_hsclk / 16` (TX side); RX side is a free-running `/16` derived from the recovered clock | Wlink link layer. |
| `pad_clk_rx` | **the peer's `pad_clk_tx`** | All 8 lanes' capture. |
| `phc_clk` | external PHC | PTP/servo only; bridged to `hclk` by `tidelink_phc_cdc`. |

:::{important}
**The forwarded-clock relationship is the whole PHY contract.** This die's
`pad_clk_tx` becomes the peer's `pad_clk_rx`. It is source-synchronous: the
transmit clock and its 8 data lanes must be routed as a matched bundle, and the
receive capture is hold-sensitive. The ASIC constraint methodology (TX eye, RX
eye, `set_bus_skew` across the lane bundle, per-lane programmable delay) is
written up in `docs/reference/ASIC_TIMING_CONSTRAINTS.md` Part B.
:::

:::{important}
**`role_locked` is a mutual clock enable, not a protocol event.** The Wlink is
held in reset by `wlink_por_reset = ~poresetn | ~role_locked`, so until *this*
die locks its role it does not forward `pad_clk_tx` — which means the *peer*
never sees a `pad_clk_rx` and can never train. Never make `role_lock` wait on
anything that itself depends on the link being up: that is a deadlock by
construction.
:::

:::{note}
**`user_ref_clk` sets the FPGA link rate, and it is not `hclk`.** On the current
pair targets the PHY pad clock is 1:1 with `user_ref_clk`
(`fpga/targets/kr260-pair-nptp/tidelink_design.tcl:219-220`), and `user_ref_clk`
+ `scan_clk` are taken off a **post-MMCM divider**, not off the same net as
`hclk`: ÷2 via `tidelink_phy_clk_div2` on the Z2/KR260 pair targets
(`:263-279`, `:633-634`), and a per-instance ÷8 on `kr260-pair-onchip`
(`fpga/targets/kr260-pair-onchip/tidelink_design.tcl:487-493`, deliberately
distinct nets/BUFGs/power-up phase). `hclk` and every AXI ACLK stay on
`clk_wiz_0/clk_out1`. The `hclk` ↔ PHY paths are 2-flop CDC'd in RTL and
declared asynchronous in the timing XDC, so the split domain is safe.

The header comment in some target tcl files still says "clk_out1 = hclk +
user_ref_clk + scan_clk" (e.g. `kr260-pair-nptp:217`); that predates the divider
block further down the same file and is stale. Read the `connect_bd_net` calls,
not the header.
:::

### 3.2 Reset requirements

| Reset | Scope | Requirement |
|---|---|---|
| `hresetn` | AHB/APB/FC adapter/FIFO | Active-low, synchronous to `hclk`. |
| `poresetn` | Wlink POR, role registers | Active-low. **Hold longer than `hresetn`** so the PHY survives a fabric warm reset. Role registers (Region 4) are reset by `poresetn` only, so a warm reset preserves the negotiated role. |
| `phc_resetn` | PHC domain | Active-low, synchronous to `phc_clk`. |

:::{warning}
**On the FPGA block designs `poresetn`, `hresetn` and `phc_resetn` are all tied
to the same reset net** (e.g. `hresetn`, `poresetn` and `phc_resetn` of both
dies appear in one `connect_bd_net`,
`fpga/targets/kr260-pair-onchip/tidelink_design.tcl:522-527`).
The warm-vs-POR distinction therefore collapses on those boards and `role_lock`
clears on *any* reset. If your host SoC wants the warm-reset role-retention
behaviour, drive `poresetn` from a genuinely separate POR.
:::

### 3.3 CDC status

Two real crossings, both carrying the quasi-static 32-bit `phase_offset`
calibration word into the `pad_clk_rx` domain:

| Crossing | FPGA treatment | ASIC treatment |
|---|---|---|
| `swi_phase_offset_r`: `hclk` → `pad_clk_rx` | `set_clock_groups -asynchronous` in the target XDC | same waiver in the SDC (`syn/asic/fusion-compiler/outputs/tidelink_top.sdc:50`) |
| `cal_phase_offset_w`: `link_clk` → `pad_clk_rx` | de-facto safe (÷16, ~15-cycle margin) | **still needs an explicit `set_multicycle_path -setup 16 / -hold 15`** |

`role_locked → wlink_por_reset` is covered by the same clock-groups waiver.
Wlink-internal crossings use the qualified Wavious synchroniser cells
(`WavFIFO`, `WavDemetReset`, `WavResetSync`).

Sign-off of record (`docs/reference/SPYGLASS_CDC_SIGNOFF.md`): SpyGlass
vT-2022.06-SP2, re-run 2026-05-28 at integration SHA `6666c1be` —
**0 fatals, 0 errors, 4 warnings (none CDC), 0 unsynchronised crossings,
0 convergences, verdict GO**. Re-run with:

```bash
make -C cdc cdc MODULE=tidelink_top
```

---

## 4. Address map and placing the apertures

### 4.1 The one APB port

`tidelink_top.sv:825-827` decodes `paddr[14:13]`:

| `paddr[14:13]` | Range | Region |
|---|---|---|
| `00` | `0x0000`–`0x1FFF` | Wlink chiplet controller (`paddr[12:0]`) |
| `01` | `0x2000`–`0x3FFF` | TideLink core / PTP / role / extended |
| `10` | `0x4000`–`0x5FFF` | Address translator (`paddr[12:0]`) |
| `11` | `0x6000`–`0x7FFF` | Reserved — returns `prdata='0, pready=1, pslverr=0` (`:845-853`), safe to touch |

Full bit-level detail: [Register Map](register_map.md).

### 4.2 The four data apertures

A host SoC must place four windows, in addition to the APB config window:

| Window | Port | Size | Notes |
|---|---|---|---|
| Peer transparent window | `ahb_sub_*` | your choice | The **full address is forwarded over the link** and decoded by the peer. |
| TX aperture | `ahb_tx_*` | `2**RAM_ADDR_W` = 16 KB | Same size as the peer's RX FIFO. Wedge hazard. |
| RX FIFO window | `ahb_fifo_*` | `2**RAM_ADDR_W` = 16 KB | Also a plain local SRAM — a write-then-read here is the cheapest aperture-identification probe. |
| PTP TX port | `ahb_ptp_*` | 16 B | Optional. |

Reference placements actually in use:

| Platform | APB config | Peer window | TX aperture | RX FIFO |
|---|---|---|---|---|
| PYNQ-Z2 GP1-split BDs (`pair-all`, `pair-flip-all`) | `0x4403_0000` (TideLink at `0x4403_2000`) on GP0 | `0x4000_0000` on **GP0** | `0x8400_0000` on **GP1** | `0x8401_0000` on **GP1** |
| KR260 (`kr260-pair-*`) | `0x8403_0000` | — | see caution below | see caution below |
| KR260 on-chip pair | die_a `0x8403_0000`, die_b `0x8C03_0000` | — | — | — |

:::{warning}
**KR260 data-aperture ambiguity is unresolved in this repo.** The target tcl
header lists `ahb_tx = 0x8400_0000` / `ahb_fifo = 0x8401_0000`, while
`docs/KR260_FIRST_SESSION_RUNBOOK.md` §5 documents the FPD data window as
`0xA000_0000` and the validated data-crossing note uses `0xA400_0000` /
`0xA401_0000` — with "writing the wrong base (`0x8400_0000`) wedges the PS".
Do not assume. The runbook's disambiguation: write-then-read one word into the
RX FIFO window locally on the slave; whichever base round-trips is the real one.
:::

:::{danger}
**Never probe these.** On ZynqMP an access to an *undecoded* `0x4403_xxxx`
hangs the PS. Offsets `0x21AC`, `0x21B0`, `0x21B4` hard-stall the CPU. Several
Region-1 accumulators are read-to-clear and the FIFO aperture pops on read — a
"sweep the range and see what's there" loop will break a live link. The full
list is in [Register Map](register_map.md).
:::

### 4.3 Address translation on the peer path

`ahb_sub_*` passes through `tidelink_addr_translator` before XHB500. It is
**CAM-based**, not a segment table:

- Subtract `BASE_OFFSET` from the incoming address.
- Compare `addr[31:24]` against each enabled rule's match byte; the
  lowest-index match replaces `addr[31:24]` with its replace byte.
- `addr[23:0]` always passes through. With `CTRL.global_enable = 0`, everything
  passes unchanged.

Registers (`src/rtl/tl_addr_trans_regs.sv:8-15`), at APB `0x4000` + offset:
`0x000` `BASE_OFFSET`, `0x004` `CTRL[0] = global_enable`, `0x010`–`0x02C`
`RULE[0..7]` (`[0]` enable, `[15:8]` match, `[23:16]` replace), plus PrimeCell
PIDR/CIDR at `0xFD0`–`0xFFC`. Unmapped reads in the `0x030`–`0xFCC` gap return
`0xCAFECAFE` (`tl_addr_trans_regs.sv:190`).

`tidelink_top` instantiates it with `NUM_CHANNELS = 1` and feeds
`chp_adr_paddr = {3'b000, apb_paddr[12:0]}` (`tidelink_top.sv:2329-2336`), so
the channel-select field `paddr[15:12]` (`tidelink_addr_translator.sv:89`) is
always `4'h0` — only channel 0 is reachable.

Set `BYPASS_ADDR_XLAT = 1'b1` to remove the block entirely; the APB region then
returns zero-data OKAY.

---

## 5. FPGA integration path

### 5.1 The packaged IP

The FPGA face is `tidelink_vivado_wrapper` (`fpga/vivado_ip/tidelink_vivado_wrapper.v`,
787 lines), packaged by `ipx::package_project` as
`soclabs.org:user:tidelink_vivado_wrapper:1.0`. It exposes the AHB-Lite slaves
and master, the APB slave, the two AXI-Streams, the PHY pads, PHC signals, IRQs,
I²C, and the misc status/role/scan pins.

:::{warning}
**HSEL and HREADY_IN are deliberately internal.** Xilinx's
`axi_ahblite_bridge:3.0` master omits both from its bus interface, so exporting
them via `X_INTERFACE_INFO` leaves them unconnected (tied 0) → slave never
selected → bus hangs. The wrapper hardwires `hsel = 1'b1` and loops each
slave's `HREADYOUT` back into its `HREADY`
(`tidelink_vivado_wrapper.v:525-535, 596-619`); only `HREADYOUT` is exported,
under the sub-signal name `HREADY`. If you re-package the IP, preserve this.
:::

### 5.2 Targets

`VALID_TARGETS` (`fpga/Makefile:56`) — 22 targets, each with a directory
`fpga/targets/<TARGET>/` holding `tidelink_design.tcl` plus XDC files.

| Target | What it is for |
|---|---|
| `pynq-z2-single` | Single Z2 board, no peer. |
| `pynq-z2-pair`, `pynq-z2-pair-flip` | Two-board Z2 pair (die_a / die_b images). `USE_IDELAY=0`. |
| `pynq-z2-pair-slow`, `pynq-z2-pair-flip-slow` | Slower bit-cell variant to open the eye. |
| `pynq-z2-pair-ila`, `pynq-z2-pair-flip-ila` | ILA-instrumented debug images. |
| `pynq-z2-pair-all`, `pynq-z2-pair-flip-all` | The full-feature Z2 pair (PHC/PTP included). The only targets with the `TL_TRAIN_ENTRY_FALLBACK` / `TL_EPOCH_ANCHOR_EN` env opt-ins. |
| `pynq-z2-pair-mmcmbypass-all`, `…-flip-all` | MMCM-bypass clocking experiment. |
| `pynq-z2-pair-mmcmbypass-oddr-all`, `…-flip-all` | MMCM-bypass + ODDR forwarding; set `USE_CLKBUF=1'b0`. |
| `pynq-z2-loopback` | Single board, TX looped to RX. `USE_IDELAY=0`. |
| `kr260-pair-ptp`, `kr260-pair-nptp`, `kr260-pair-flip-ptp`, `kr260-pair-flip-nptp` | KR260 two-board pair, with/without PTP. |
| `kr260-pair-onchip` | **Two dies, one bitstream, no ribbon** — the lottery-free vehicle. Instantiates `tidelink_0` and `tidelink_1`. |
| `kr260-eth-chiplet`, `kr260-eth-chiplet-flip` | Package the whole `nanosoc_eth_chiplet` as one IP; set **no** TideLink `CONFIG.*`. |
| `mps3` | MPS3 / AN552 (Kintex UltraScale). Sets `TIDELINK_PAIR_BASE = 0x00000000`. |

Per-target parameter overrides are tabulated in
[Parameters](parameters.md#4-per-target-overrides).

### 5.3 Build commands

All verified against `fpga/Makefile`.

```bash
source ./set_env.sh
export TIDELINK_PHY_V2=1          # for a V2 image

# Full flow for one target: package_ip -> package_phc_ip -> build_design
make -C fpga all TARGET=kr260-pair-nptp

# Or the steps individually
make -C fpga package_ip                    # depends on check-wrapper-params
make -C fpga package_phc_ip                # needs PHC_REPO_DIR (default ~/SoCLabs/ptp-hardware-clock-ahb)
make -C fpga build_design TARGET=<target>

# Both halves of a pair in parallel on this host
make -C fpga build_pair_concurrent PAIR_SOC=kr260 PAIR_PTP=0

# Fan out across build hosts
make -C fpga farm_check FARM_HOST=<host>
make -C fpga farm_build FARM_JOBS="pynq-z2-pair-all@local pynq-z2-pair-flip-all@farm-host-a"
```

:::{note}
`EXTREFCLK=1` and `EPOCH_ANCHOR=1` are **not** forwarded by `build_farm.sh`
(`fpga/Makefile:497-498`), so those variants need a direct
`make -C fpga build_design`.
:::

Outputs land at `imp/fpga/output/<TARGET>/tidelink.bit` (+ `.hwh`, `.ltx`).
Each Vivado run is roughly 40–60 minutes.

:::{note}
`make -C fpga package_ip` has a hard dependency on `check-wrapper-params`
(`fpga/Makefile:358`), which runs `fpga/scripts/check_wrapper_params.sh`. That
guard is the subject of [§7](#7-the-define-trap-and-how-to-verify-a-parameter-structurally)
— it is the single most important pre-flight in the FPGA flow.
:::

For the deploy and bring-up half of the FPGA story see
[Boards](boards.md) and [Bring-Up](bringup.md).

---

## 6. ASIC integration path

### 6.1 Picking a flist

Flists live in `flists/` and interpolate `${TIDELINK_HOME}` / `${CMSDK_DIR}`, so
`set_env.sh` must be sourced first.

| Flist | Use |
|---|---|
| `tidelink_fpga.flist` | V1 FPGA `tidelink_top` — BRAM-inferred `cmsdk_fpga_sram`, pre-generated Wlink, ASIC-only cells stripped. |
| `tidelink_fpga_v2.flist` | V2 FPGA — `deps/tidelink-phy` + `src/rtl/v2shims/`, defines `TIDELINK_PHY_V2`. |
| `tidelink_asic.flist` | ASIC `tidelink_top` — TSMC65 `rf_16k` macro (`src/rtl/fifo/asic/tidelink_sram.sv`), stdcell/DFT collateral. |
| `tidelink_top_full_asic.flist` | Full-chiplet ASIC partition, V1 PHY. |
| `tidelink_top_full_asic_v2.flist` | Full-chiplet ASIC partition, **V2 PHY — the synthesis default** (`ASIC_PHY?=_v2`). |
| `tidelink_generic.flist` | Behavioural SRAM (`src/rtl/fifo/generic/tidelink_sram.sv`) — sim / lint only. |
| `tidelink_top.flist` | `tidelink_top` sim integration. |
| `tidelink_netlist.flist` | Post-synthesis netlist. |

The remaining 22 of the 30 flists are per-module and drive their own unit sim/lint
targets (`tidelink_fifo`, `tidelink_apb_regs`, `tidelink_returner`,
`tidelink_perf`, `tidelink_phc_cdc`, `tl_addr_trans_cam`, …).

:::{warning}
**V1 and V2 cannot co-compile.** The V2 sources share module names with the V1
ones (`WavD2DGpio`, `WavD2DGpioRx/Tx`, `WlinkGPIOPHY`, `tidelink_lane_deskew`,
`tidelink_phy_align_calibrator`, `tidelink_lane_checker*`). Selection is *by
compiling the right flist*, which also `+define+TIDELINK_PHY_V2`
(`flists/tidelink_top_full_asic_v2.flist:1-40`). Never edit the V1 flist as part
of a V2 change.
:::

:::{tip}
**Apply every RTL addition to BOTH the FPGA and ASIC flists** — the split-brain
where a module exists in one and not the other is a recurring failure mode
(`docs/INTEGRATION_GUIDE.md` §3). Bug **TL-013** in `docs/BUG_REGISTRY.yaml`
("V1 flist `tidelink_fpga.flist` no longer elaborates — missing obs modules") is
exactly this class.

Note the two-tree divergence: TL-013's fix is commit `5be494b` on branch
`integ/axirec-on-chiplet`, not on this one. On `fix/z2-drop-park-hook` neither
`tidelink_fcemit_obs` nor `tidelink_winscan_obs` exists in `src/rtl/` or in
either FPGA flist, and `src/rtl/local_overrides/Wlink.v` does not instantiate
them — so the specific breakage is not reproducible *here*, but the flist you
edit is branch-dependent. See [Known Issues](known_issues.md).
:::

### 6.2 Synthesis and place-and-route entry points

Root-level targets come from `flows/makefile.asic`, included at `Makefile:1393`.
The partition defaults to `tidelink_top_full` and is overridden with
`ASIC_MODULE=<name>`:

```bash
make fc                       # Fusion Compiler through abstract
make gdsii                    # GDSII
make fc_lec                   # Formality LEC
make fc_etm                   # extracted timing model
make fc_calibre_drc
make fc_calibre_lvs
make fc_all                   # fc + fc_lec
make asic_stage               # stage deliverables into imp/ASIC/<module>/
make flist_synopsys           # emit a Synopsys-format flist
make fc ASIC_MODULE=tidelink_fifo
```

Design Compiler lives under `syn/asic/design-compiler/`:

```bash
make -C syn/asic/design-compiler syn                 # MODULE default from common.mk
make -C syn/asic/design-compiler syn MODULE=tidelink_fc_adapter
make -C syn/asic/design-compiler syn_asic            # uses flists/tidelink_asic.flist
make -C syn/asic/design-compiler syn_saif SAIF_FILE=<path>
make -C syn/asic/design-compiler help
```

`syn/asic/common.mk` carries the technology bindings: `MODULE ?= tidelink_top`;
a module→elaboration-top map (`TOP_tidelink = tidelink_fifo`,
`TOP_tidelink_fifo = tidelink_fifo_mem`, `TOP_tidelink_top_full = tidelink_top`);
the TSMC 65 nm 12-track library `tcbn65lpbwp12t`; and the compiled register file
`rf_16k` under `/research/precompiled_mems/TSMC65/rf_16k`
(SS/TT/FF `.db` corners). Other flow directories: `syn/asic/fusion-compiler/`,
`syn/asic/formality/`, `syn/asic/primetime/`, `syn/asic/dft/`,
`syn/asic/calibre/`, `syn/asic/rtl-architect/`.

### 6.3 The DFT wrapper

`src/rtl/asic/tidelink_dft_wrapper.sv` (768 lines) wraps `tidelink_top` and
lifts the test-mode signals to one boundary so TestMAX/Tessent can identify them
and the SDC can constrain them uniformly. It adds:

- a multi-bit scan-chain bus (`SCAN_CHAINS`, default 8) alongside the legacy
  1-bit `scan_in`/`scan_out` stub, which stays wired for LEC pin-down;
- a `test_mode` qualifier separate from `scan_en` (== shift);
- MBIST tunnels `mbist_en` / `mbist_done` / `mbist_pass`;
- optional JTAG TAP pads behind `INCLUDE_TAP` (default 0).

:::{caution}
It is explicitly a **SKELETON**: no BIST controller and no TAP are instantiated.
Both are closure tasks in `docs/reference/DFT_PLAN_2026_05_28.md` §4–§5. Do not
plan a tape-out schedule on the assumption that DFT is closed here. The bug
registry tracks the related PHY-BIST gap as **TL-011** (`deferred`).
:::

The wrapper's elaboration is gated in simulation by `make sim_gate_dftelab`.

---

## 7. The `+define+` trap, and how to verify a parameter structurally

:::{danger}
**A `+define+` / `-verilog_define` never reaches a packaged IP's out-of-context
synthesis. A wrapper *parameter default* recorded in `component.xml` does.**

This has bitten this project repeatedly (the wrapper file documents it three
separate times, e.g. `tidelink_vivado_wrapper.v:119-141`). Any knob that must be
settable on FPGA has to appear as a **parameter on the
`tidelink_vivado_wrapper` face** — not as a define, and not only as a
`tidelink_top` parameter.
:::

Corollaries that follow from it:

1. **Structural verification, not checksums.** An md5 of the bitstream proves
   nothing about which parameter value elaborated. Check the packaged
   `component.xml` and the elaborated netlist.
2. **`check_wrapper_params.sh` is the pre-flight.** It greps
   `fpga/vivado_ip/tidelink_vivado_wrapper.v` and refuses the build if
   `USE_IDELAY` / `USE_CLKBUF` / `USE_T3A` are not `1'b1`, or if
   `EPOCH_ANCHOR_EN` is not `1'b0`. It then cross-checks
   `imp/fpga/tidelink_ip/component.xml` under `resolve="user"`.

   ```bash
   bash fpga/scripts/check_wrapper_params.sh
   # exit 0 = all four at intended value; 1 = drift; 2 = usage/file-not-found
   ```

   :::{note}
   The `component.xml` half of that script was **silently blind** until
   2026-07-30: Vivado writes IP-XACT bitStrings XML-escaped
   (`&quot;1&quot;`), and the old pattern expected a bare digit, so neither the
   OK nor the FAIL branch ever fired. It now parses `&quot;[01]&quot;`. This is
   the standing lesson — *verify the instrument before theorising about the
   DUT.*
   :::

3. **Per-instance overrides can be silently coerced.** `NEGO_CFG_RESET`,
   `HONEST_MASK_HS` and friends are packaged as `spirit:format="bitString"`.
   `kr260-pair-onchip` therefore writes them in `{N'b…}` form *and asserts they
   took* with a helper (`_tl_assert_bitcfg`,
   `fpga/targets/kr260-pair-onchip/tidelink_design.tcl:96-112, 347-350`) — a
   silent `0000000` coercion would leave autoneg off with no error anywhere.
   Copy that pattern in any new target.

Full guidance in [Parameters](parameters.md#9-verifying-a-parameter-reached-the-netlist).

---

## 8. Integration checklist

Structural work:

- [ ] `git submodule update --init --recursive` — all **three** submodules present.
- [ ] `source ./set_env.sh`; confirm the XHB500 bridges exist under `deps/xhb500/generated/`.
- [ ] No file under `/research/AAA/ip_library` or `/research/AAA/phys_ip_library` modified; any vendor fix lives in `src/rtl/local_overrides/` with the flist re-pointed.
- [ ] `ahb_sub_*`, `ahb_tx_*`, `ahb_fifo_*`, `ahb_ptp_*` connected as **subordinates**; `ahb_mng_*` connected as a **manager**, with `hready`/`hrdata`/`hresp` driven **into** TideLink.
- [ ] APB config window placed; `paddr[14:13]` decode understood.
- [ ] Peer window, TX aperture (16 KB) and RX FIFO window (16 KB) placed and documented for the firmware team.
- [ ] `ahb_tx_*` accesses gated behind a link-up check in host software.
- [ ] `user_ref_clk` driven from a **dedicated** reference, not tied to `hclk` by accident.
- [ ] `idelay_ref_clk` = 200 MHz on FPGA with `USE_IDELAY=1`; tied `1'b0` otherwise.
- [ ] `poresetn` held longer than `hresetn` (or the collapse documented as accepted).
- [ ] `phc_locked_i` tied `1'b1` for a single-link deployment.
- [ ] Unused TideChart / PTP / PUF / DFT ports tied off per [§2.9](#29-what-to-tie-off-if-you-do-not-use-a-feature).
- [ ] `pad_clk_tx` + `pad_tx[7:0]` routed as a matched source-synchronous bundle to the peer's `pad_clk_rx` + `pad_rx[7:0]`.

Parameters and build:

- [ ] Every parameter you rely on is set where it actually elaborates — the wrapper face for FPGA, the module instantiation for ASIC (see [Parameters](parameters.md)).
- [ ] `bash fpga/scripts/check_wrapper_params.sh` passes before packaging.
- [ ] New RTL added to **both** the FPGA and the ASIC flist.
- [ ] V1 vs V2 chosen by flist, not by ad-hoc defines.
- [ ] `make -C cdc cdc MODULE=tidelink_top` re-run if you touched anything crossing `hclk` ↔ `pad_clk_rx`.

Before hardware:

- [ ] `source ./set_env.sh && make sim_gate` green. A sim-discoverable bug has previously burned 75 minutes of farm + deploy time; see [Verification](verification.md).
- [ ] Downstream consumers gate on `tl_data_mode_o`, not `link_active`.
- [ ] The never-probe register list has been given to whoever writes the host scripts.
