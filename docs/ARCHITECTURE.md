# TideLink — Architecture

TideLink is a chiplet-interconnect application-layer subsystem (SoC Labs,
University of Southampton). The single top module `tidelink_top` connects an AMBA
AHB SoC fabric (Cortex-M class) to a die-to-die serial link, giving two
complementary cross-chiplet paths over one shared PHY: a **transparent AHB
bridge** (AHB→AXI via XHB500 → Wlink → AXI→AHB, with APB-configurable address
translation) for control-plane access to remote memory, and a **mailbox / packet
FIFO** carried on a dedicated Wlink flow-control (FC) node for bulk, latency-
tolerant data movement that never stalls the host bus. The two paths are
independently flow-controlled so neither can starve the other. The reference
integration target is the SoC Labs nanosoc-chiplet-tech (Cortex-M0) project.

Companion docs: [REGISTER_MAP.md](REGISTER_MAP.md) (APB register addresses),
[FC_NODE_REGISTRY.md](archive/FC_NODE_REGISTRY.md) (`data_id` allocation),
[DEPENDENCIES.md](archive/DEPENDENCIES.md) (submodules + IP policy).

---

## 1. Why two paths

AHB is a blocking bus: a manager must receive the response before issuing the
next transaction. A transparent read over a chiplet link freezes `HREADY` for the
full round-trip — at ~10 ns one-way and 100 MHz that is tens of stalled cycles
per read, and Cortex-M bus matrices do not implement AHB SPLIT/RETRY to release
the bus. TideLink therefore keeps transparent bridging only for infrequent
control-plane access, and routes bulk traffic through the mailbox, where the CPU
writes a few words to a TX aperture and is immediately free.

---

## 2. Component map

```
                       tidelink_top.sv
 ┌──────────────────────────────────────────────────────────────────────┐
 │  ahb_sub_*  ─► addr_translator ─► XHB500 AHB→AXI ─┐                    │
 │  apb_*(0x4000) ─► translator config (APB)         │ s_axi_*           │
 │                                                   ▼                    │
 │  ahb_tx_*   ─► fc_adapter (TX aperture) ──tl_fc_a2l──►  chiplet        │
 │  ahb_fifo_* ─► tidelink_fifo (RX FIFO; FC RX via   )   controller      │
 │                internal fc_wr_* write port)           (Wlink + I2C     │
 │  apb_*      ─► Config mux (2:1) ─► tidelink_fifo regs  + role/APB)     │
 │  returner (intercepted) ─► fc_adapter (sideband) ──►                   │
 │  tc_axis_*  ◄─► fc_adapter (PKT_EXT ↔ TideChart)   ◄─tl_fc_l2a──┘      │
 │                                                   ▲ m_axi_*            │
 │  ahb_mng_*  ◄─ XHB500 AXI→AHB  ◄──────────────────┘                    │
 │                                       PHY: pad_clk_tx/rx, pad_tx/rx[7:0]│
 └──────────────────────────────────────────────────────────────────────┘
```

`tidelink_top` instantiates six sub-components:

| Instance | Module | Role |
|---|---|---|
| `u_tidelink_fifo` | `tidelink_fifo` | RX FIFO packet buffer + APB config regs + credit returner |
| `u_fc_adapter` | `tidelink_fc_adapter` | AHB TX aperture, returner interception, FC RX → AHB/APB masters, PKT_EXT/PUF |
| `u_xhb_sub` | `xhb500_ahb_to_axi_bridge_chiplet_slv` | AHB → AXI for the transparent subordinate path |
| `u_xhb_mng` | `xhb500_axi_to_ahb_bridge_chiplet_mst` | AXI → AHB for the transparent manager path |
| `u_addr_translator` | `tidelink_addr_translator` | APB-configurable address remap on `ahb_sub_haddr` |
| `u_chiplet_controller` | `axi_chiplet_controller` | Wlink core + GPIO PHY + I2C master/slave + role negotiation + APB mux |

`tidelink_fifo` instantiates `tidelink_fifo_mem` (which in turn wraps
`tidelink_fifo_ctrl`, `cmsdk_ahb_to_sram`, and `tidelink_sram` — 16 KB; FPGA BRAM,
ASIC macro, or generic variants), `tidelink_apb_regs`, and `tidelink_returner`.
(A separate `tidelink_fifo_ahb` wrapper that adds a `cmsdk_ahb_to_apb` bridge
exists in the tree but is **not** the variant instantiated by `tidelink_top`.)
The returner is a 3-channel priority AHB-Lite master (ch0 release-credits, ch1
doorbell, ch2 reset-doorbell); inside `tidelink_top` its AHB master is **not** on
the bus matrix — it is intercepted by the FC adapter and re-encoded as SIDEBAND
FC packets.

---

## 3. The AHB ports + APB

TideLink exposes four subordinate AHB ports plus one manager AHB port and a
unified APB. Two further FC-RX masters are internal to `tidelink_top` and need no
bus-matrix slots.

| Port | Dir | Addr width | Purpose |
|---|---|---|---|
| `ahb_sub_*` | subordinate | `SYS_ADDR_W`=32 | Transparent remote AHB access (addr-translated → XHB500 → AXI → Wlink) |
| `ahb_tx_*` | subordinate | `RAM_ADDR_W`=14 | TX aperture (write-only); each word → one FIFO_DATA FC packet |
| `ahb_fifo_*` | subordinate | `RAM_ADDR_W`=14 | Local RX FIFO data window (CPU reads; FC RX writes via internal port) |
| `ahb_ptp_*` | subordinate | 4 | PTP TX write port (PTP servo); stubbable via `STUB_PTP` |
| `ahb_mng_*` | manager | `SYS_ADDR_W`=32 | Inbound remote AHB (Wlink → XHB500 AXI→AHB) toward local slaves |
| `apb_*` | subordinate | 15 | Unified config: `0x0000–0x1FFF` → Wlink, `0x2000–0x3FFF` → TideLink/PTP regs, `0x4000–` → address translator |

There is **no** dedicated `ahb_adr_*` port: the address translator is configured
through the unified APB port in the `0x4000` aperture (`apb_paddr[14]=1`), which
the RTL decodes as `apb_sel_addr_xlat` and drives onto the translator's `chp_adr_p*`
APB slave; the translator otherwise only taps/remaps `ahb_sub_haddr`
combinationally.

The FC-RX path replays incoming FC words on two internal masters selected by
packet type: `fc_rx_fifo_*` writes FIFO_DATA payloads into the RX FIFO via a
dedicated `fc_wr_*` write port inside `tidelink_fifo` (not a top-level AHB mux),
and `fc_rx_cfg_*` (APB, `APB_ADDR_W`=12) writes SIDEBAND payloads (credit deltas,
doorbells) through a **2:1 Config (APB) mux** in `tidelink_top` that grants the
FC adapter priority over the CPU (external APB `pready` held low on collision).
The `addr_offset` field of each FC word is used directly as the local address —
there are no `RX_FIFO_BASE`/`RX_CFG_BASE` parameters.

Role selection is via `role_strap_i` / `role_is_master_o` / `role_locked_o`: after
`poresetn` release Wlink is held in reset until SW writes `role_lock=1` (ROLE_CFG,
see REGISTER_MAP.md); once locked only `poresetn` changes the role. I2C
(`i2c_scl/sda_*`, `s_i2c_axi_*`) is the out-of-band sideband for role negotiation
and link bring-up. Interrupts: `released_credits_irq`, `doorbell_irq`,
`packet_committed_irq`, `wlink_irq`. `d2d_reset_o` (Wlink `sb_reset_out`)
coordinates cross-chiplet reset.

---

## 4. FC adapter and packet formats

Every FC transaction is a single self-describing 48-bit word:

```
[47:46] pkt_type  (00=FIFO_DATA, 01=SIDEBAND, 10=PKT_EXT)
[45:32] addr_offset (14b — byte addr in 16 KB aperture, or subtype for PKT_EXT)
[31:0]  payload   (32b)
```

The encoding is stateless on the RX side, so no packet-boundary tracking is
needed. **FIFO_DATA** carries one 32-bit word into the remote RX FIFO.
**SIDEBAND** carries a returner credit-delta or doorbell write. **PKT_EXT**
carries extension-protocol payloads to/from an external TideChart controller over
the `tc_axis_*` AXI-Stream interface; the PUF_READ_REQ subtype (0x0020) is
intercepted locally (reads uninitialised FIFO SRAM, returns PUF_READ_RSP 0x0021)
and never crosses the link. The FC-TX arbiter has fixed priority returner
sideband > PTP servo sideband, then a QoS-configurable tier between PKT_EXT and
the TX aperture: by default (`tc_qos_priority`=0) TX-aperture FIFO_DATA outranks
PKT_EXT; setting `tc_qos_priority`>0 boosts PKT_EXT above the TX aperture. (A
`MAX_SIDEBAND_BURST`=4 fairness cap forces a TX-aperture grant after four
consecutive sideband grants.) The application-layer TideLink mailbox packet (2-word
header + payload, `length`/`pkt_type`/`src_id`/`dest_id`/`tag`) is a software
convention layered on the FIFO word stream — hardware transports each word
independently. See `archive/TIDELINK_SPECIFICATION.md` §4, §7 for the full FSMs
and credit/doorbell flows.

---

## 5. Traffic planes and FC nodes

Traffic splits into four independently flow-controlled planes by the FC node /
`data_id` carrying it:

| Plane | Local interface | Link carrier (`data_id`) |
|---|---|---|
| **Data** | `ahb_sub_*`, `ahb_tx_*`, `ahb_fifo_*`, `ahb_mng_*`, `tc_axis_*` | TideLink FC `0xa1` (FIFO_DATA/EXT) + AXI FC `0x80–0x84` |
| **Control** | returner / fc_adapter (credits, doorbells); bring-up FSM | TideLink FC `0xa1` (SIDEBAND); short pkts `0x44–0x47` (CR/CRACK/ACK/NACK) |
| **Management** | `apb_*`, role straps / nego / PUF, I2C | does **not** cross the data link; APB-local + I2C OOB |
| **Time** | `ahb_ptp_*`, `phc_*` (PHC capture/servo) | PTP short pkts `0x50/0x51` (SYNC/DELAY_REQ) + TideLink SIDEBAND servo |

The Wlink instance actually generated for `tidelink_top` (config
`WithWlinkTideLinkAXIConfig` in `WlinkConfigs.scala`; the generated `Wlink.v`
contains exactly three FC converters — `axi2wl`, `gb2wl`, `tl2wl`) carries:
**5× AXI long `data_id`s `0x80,0x81,0x82,0x83,0x84`** (AW/W/B/AR/R data — distinct,
not shared) plus their short CR/CRACK/ACK/NACK IDs at `0x08–0x27`; **1× GeneralBus
(`0xa0`)** — present in the config (still instantiated) but with TideLink's
`gb_in/gb_out` ports removed in `strip-generalbus-irq` so it is tied off; and
**TideLink's single dedicated 48-bit FC node `0xa1`** (`WlinkGenericFCSM_6` /
`TideLinkToWlink`, short IDs `0x44–0x47`). PTP does **not** have its own long FC
node on this branch — it rides Wlink **short packets `0x50/0x51`** (per the `ptp`
`shortPacketParams`) plus TideLink SIDEBAND servo words. The APB-initiator node
(`0x90`) and a separate PTP long node (`0xa2`) appear in the registry/spec docs
but are **not** in this config. The Chiplet IRQC node (`0xa3`, 64-bit) is a
separate IP, not instantiated here.

> Source-of-truth note: the AXI channels each have a **distinct** long `data_id`
> (`0x80`/`0x81`/`0x82`/`0x83`/`0x84` for AW/W/B/AR/R, set by
> `startingLongDataId=0x80` in `AXI.scala`) — they do **not** share a single
> `0x80`. The per-channel short credit/ack IDs are likewise sequential from
> `startingShortDataId=0x8` (AW `0x08–0x0B`, W `0x0C–0x0F`, B `0x10–0x13`,
> AR `0x14–0x17`, R `0x18–0x1B`). See [REGISTER_MAP.md](REGISTER_MAP.md) for the
> full FC-node ID table.

---

## 6. Clock, reset, and CDC

### Clock domains

| Clock | Source | Nominal (ASIC v1) | Consumers |
|---|---|---|---|
| `hclk` | SoC AHB bus | SoC-dependent | All AHB/APB/FC-adapter logic; also drives the chiplet controller's `apb_clk` and `app_clk` today |
| `user_ref_clk` | SoC reference clock | ~100 MHz | Chiplet controller `user_hsclk` (PHY high-speed reference) — a dedicated top-level input, not `hclk` |
| `pad_clk_rx` | recovered RX pad clock | ~100 MHz | PHY RX capture (all 8 lanes single-domain) |
| `link_clk` | `pad_clk_rx ÷ 16` (BUFG / `~adj_count[3]`) | ~6.25 MHz | lane checker, calibrator FSM |
| `phc_clk` | PTP hardware clock | TBD | PTP servo only |

In the current integration the application side runs in a single domain (`hclk`
feeds the controller's `apb_clk`/`app_clk`; the PHY high-speed reference
`user_hsclk` comes from the dedicated `user_ref_clk` input), trading flexibility
for simpler CDC; the PHY's
recovered clocks are internal to Wlink and bridged by Wlink's own CDC FIFOs and
demetastabilisation (`WavFIFO`, `WavDemetReset`, `WavResetSync`). v1 ASIC targets
100 MHz GPIO; FPGA bring-up runs the bit cell slower (6.25 MHz) to open the
per-lane eye.

### Reset domains

`hresetn` (active-low sync) resets all AHB/APB/FC-adapter RTL (→ `apb_resetn`,
`app_clk_resetn`). `poresetn` (active-low POR) drives Wlink `por_resetn` for the
PHY/link reset sequence and is held longer than `hresetn` so the PHY survives
fabric warm reset. The lane checker / calibrator arm on the `role_locked` level,
not POR.

### CDC crossings

Per `archive/CDC_AUDIT_REPORT.md`, two real crossings exist, both carrying the
quasi-static `phase_offset` calibration word into `pad_clk_rx` (written only at
bring-up, then held):

| # | Signal | Crossing | `main` handling |
|---|---|---|---|
| 1 | `swi_phase_offset_r` [31:0] | `hclk` → `pad_clk_rx` | Waiver: `set_clock_groups -asynchronous` (FPGA XDC + ASIC SDC) |
| 2 | `cal_phase_offset_w` [31:0] | `link_clk` → `pad_clk_rx` | FPGA de-facto safe (÷16, 15-cyc margin); ASIC still needs explicit `set_multicycle_path -setup 16/-hold 15` |
| — | role_locked → wlink_por_reset | `hclk` → `pad_clk_rx` | Subsumed by the same `set_clock_groups` waiver |

Wlink-internal crossings (tx/rx/app link-clk resets, FIFO AHB↔link_clk) are
already correctly synchronised. A structural fix (`tl_calibration_cdc`) exists on
the parked `feat/cdc-fix-wip` branch but is **not** on `main` (it broke timing
without the MCP constraints) and is not a v1 sign-off gate. Outstanding for ASIC
tape-out: add the link_clk→pad_clk_rx MCP constraints, the
`no_phase_change_while_active` SVA, and a full SpyGlass CDC run.

---

## 7. Key data widths and parameters

| Quantity | Width | Notes |
|---|---|---|
| System address / data | 32 / 32 | `SYS_ADDR_W` / `SYS_DATA_W` |
| FIFO SRAM address | `RAM_ADDR_W`=14 | 2^14 = 16 KB; also the TX aperture width |
| APB register address | `APB_ADDR_W`=12 | TideLink config regs |
| FC node data | `FC_DATA_W`=48 | must match `WlinkGenericFCSM_6`; do not change without Chisel regen |
| Internal AXI | 12b ID / 36b addr / 32b data | upper 4 addr bits tied 0 |
| Mailbox header `length` | 12 | data-payload word count (excl. 2-word header) |

`TIDELINK_PAIR_BASE` sets the returner's default remote APB base (runtime
overridable). 48 bits is the minimum self-describing FC word
(2 + 14 + 32). The earlier `RX_FIFO_BASE`/`RX_CFG_BASE` parameters were removed
when the RX path split into the two narrowed internal masters.

---

## 8. The GPIO PHY

The 8-lane source-synchronous GPIO PHY (`pad_clk_tx`, `pad_tx[7:0]`,
`pad_clk_rx`, `pad_rx[7:0]`) lives inside `axi_chiplet_controller` and is shared
by all four planes. On each die it comprises the Wavious GPIO D2D SerDes
(`WavD2DGpio.v` + 8× `WavD2DGpioTx/Rx.v`, a SoC Labs creation, not real Wavious
upstream), a per-lane 4-bit sub-bit sample-point selector (`io_phase_offset`, an
IDELAY tap on ASIC) plus a per-lane 3-bit right-rotation of the 16-bit
deserialised word (`io_bit_slip`), the SoC Labs **calibrator FSM**
(`src/rtl/tidelink_phy_align_calibrator.sv`) walking an 8(slip)×16(phase)×DWELL
per-lane search, and the **lane checker** (`tidelink_lane_checker.sv`, in the
`deps/tidelink-gpio-phy` submodule) that locks on a known training pattern.
FPGA-only auxiliaries
(`tidelink_idelay_rx.sv`, `tidelink_rxclk_buf.sv`) are parameter-gated
(`USE_IDELAY`, `USE_CLKBUF`, `USE_T3A`).

The calibrator's architectural contract: static + PVT clk-to-data skew **spread**
must be bounded by constraints + matched routing to within roughly one phase step
(~`T_UI/16`), so the runtime (bit_slip, phase) solution stays valid across
corners — the calibrator centres the eye, the constraints bound the variance.
bit_slip [0..7] is the whole-UI search window; phase [0..15] is the sub-UI skew
window. Full PHY mechanics, calibrator FSM states, the M→S/S→M asymmetry analysis,
and the ASIC constraint rationale are in `archive/PHY_ARCHITECTURE_REFERENCE.md`
and `archive/ASIC_TIMING_CONSTRAINTS.md`.

> The v1 calibrator/checker stack is being **replaced** at integration time by
> the standalone, independently-verified PHY now vendored at
> `deps/tidelink-gpio-phy` (Hamming-threshold checker via `tidelink_popcount16` +
> PHY-owned cross-lane deskew `tidelink_lane_deskew.sv` + SYNC beacon). The
> old in-tree calibrator's M-series fixes are **not** to be ported forward.

---

## 9. Silicon bring-up status

**v1 (current) GPIO PHY autocal is CLOSED.** On the bridge1 PYNQ-Z2 die-pair
(z2_02 / z2_03), the calibrator + lane checker + lane deskew + SW bootstrap
achieve autonomous bilateral link bring-up and a verified application data
crossing (`archive/AUTOCAL_CLOSURE_2026_06_10.md`):

- **Bilateral 16/16 cal + lane lock**, FCSM=4 LINK_IDLE both dies, CR/CRACK
  exchanged — reproduced across multiple converge runs (M12 bootstrap path).
- **M→S data crossing byte-perfect** (v33 `e2fefd4` + deskew `c5f24b6` + M12
  `7702f07`): a 4-packet AHB_TX burst, and separately `0xc0ffee00/01`, landed
  intact in the slave RX FIFO. Single-word and small-burst M→S traffic is solid.
- **Zero-poke first silicon (V4, 2026-06-11)** — flash-only, APB reads only:
  autonomous role resolution, role lock, and bilateral `cal_done=1` with **no
  software anywhere**. The L3 autonomy stack is silicon-proven end-to-end.

Known residuals deliberately **not** fixed in the old stack (all targeted by the
new PHY): S→M credit decode is intermittent (~97%, marginal die_a RX eye + exact-
match checker); `lk=0` after `training_mode=0` is expected (checker only matches
training patterns); sustained M→S storms back-pressure into the Bug-A wedge once
the ~4-word initial credit budget is spent; doorbell sideband goes quiet after the
bring-up window (HW-only, sim green); and the v33 master WNS=-1.16 ns is a phantom
XDC double-count (deskew path has +9.46 ns slack). The remaining blocker to full
zero-poke bilateral link-up is the old PHY's marginal RX eye — the trigger to
land the new PHY rather than harden this stack further.

---

## Sources

The following docs were folded into this overview and are retained under
`docs/archive/` for depth but are **not maintained** going forward:

- [`archive/TIDELINK_SPECIFICATION.md`](archive/TIDELINK_SPECIFICATION.md) — canonical spec: component map, hierarchy, full port/FSM/flow detail, design justification.
- [`archive/PHY_ARCHITECTURE_REFERENCE.md`](archive/PHY_ARCHITECTURE_REFERENCE.md) — GPIO PHY internals, calibrator/lane mechanics, M→S asymmetry analysis.
- [`archive/DEPENDENCIES.md`](archive/DEPENDENCIES.md) — submodules (Wlink/axi-chiplet-controller, XHB500), vendor IP, and edit policy.
- [`archive/FC_NODE_REGISTRY.md`](archive/FC_NODE_REGISTRY.md) — Wlink `data_id` allocation table.
- [`archive/ASIC_TIMING_CONSTRAINTS.md`](archive/ASIC_TIMING_CONSTRAINTS.md) — source-sync PHY timing rationale + constraint listing.
- [`archive/CDC_AUDIT_REPORT.md`](archive/CDC_AUDIT_REPORT.md) — CDC crossing audit and waiver/sign-off status.
- [`archive/AUTOCAL_CLOSURE_2026_06_10.md`](archive/AUTOCAL_CLOSURE_2026_06_10.md) / [`archive/V4_ZERO_POKE_FIRST_SILICON_2026_06_11.md`](archive/V4_ZERO_POKE_FIRST_SILICON_2026_06_11.md) — current silicon bring-up status.
