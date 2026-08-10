# Architecture

This page describes the **structure** of TideLink: what modules exist, how they
nest, which clocks they run in, which files are vendor copies, and which RTL is
deliberately present but not instantiated. For *behaviour* — bring-up, credits,
error handling — see {doc}`functionality`.

Everything here is cited to a file and line in this checkout
(branch `fix/z2-drop-park-hook`, `9eaafb7`). Where a document in `docs/`
disagrees with the instantiated RTL, the RTL wins and the divergence is called
out.

:::{important}
**The canonical specification is out of date on hierarchy.** Both
`docs/ARCHITECTURE.md` §2 and `docs/reference/TIDELINK_SPECIFICATION.md`
describe TideLink as "six sub-components" built around a `tidelink_fifo_ahb` +
`fifo_mux_*` / `cfg_mux_*` arrangement. That arrangement no longer exists.
`tidelink_top` has **30 parameters and 13 direct child instances**, and
`tidelink_fifo_ahb` — while still compiled into several flists — is **not**
instantiated by `tidelink_top`. The tables below are read from the RTL.
:::

---

## 1. The top level

`tidelink_top` — `src/rtl/tidelink_top.sv`, 2786 lines.

| Region of the file | Lines |
|---|---|
| Header comment (design intent, APB decode plan) | 1–35 |
| Parameter block (**30** parameters, first declaration at 39) | 37–229 |
| Port list | 230–555 |
| Internal AXI wiring (XHB500 ↔ chiplet controller) | 556–645 |
| APB top decode + 2:1 transaction-atomic arbiter | 825–917 |
| Child instantiations | 1027–2480 |

Its own header states the intent plainly: RX FIFO + FC adapter + XHB500
AHB→AXI + XHB500 AXI→AHB + address translator + chiplet controller, with the
APB split `0x0000–0x1FFF` Wlink / `0x2000–0x3FFF` TideLink+PTP /
`0x4000–0x5FFF` address translator.

### Port surface at a glance

| Group | Ports |
|---|---|
| Clocks / resets | `hclk`, `hresetn`, `poresetn`, `phc_clk`, `phc_resetn`, `user_ref_clk`, `idelay_ref_clk` |
| DFT | `scan_mode`, `scan_asyncrst_ctrl`, `scan_clk`, `scan_shift`, `scan_in`, `scan_out` |
| AHB subordinates | `ahb_sub_*` (32-bit addr, transparent remote), `ahb_tx_*` (14-bit, TX aperture), `ahb_fifo_*` (14-bit, local RX window), `ahb_ptp_*` (4-bit) |
| AHB manager | `ahb_mng_*` — note `hready`/`hrdata`/`hresp` are **inputs** (`tidelink_top.sv:296-300`; a previous `output` declaration was flagged by Formality LEC as an undriven primary output) |
| APB subordinate | `apb_paddr[14:0]` + full APB4 handshake incl. `pstrb`/`pprot`/`pslverr` |
| PHY pads | `pad_clk_tx`, `pad_tx[7:0]`, `pad_clk_rx`, `pad_rx[7:0]` |
| PHC / PTP | `phc_hw_capture`, `phc_seconds[47:0]`, `phc_nanoseconds[29:0]`, `phc_hw_cap_*`, `phc_hw_set_*`, `phc_hw_adj_*`, `phc_locked_i`, `servo_locked`, `phc_pps` |
| Interrupts | `released_credits_irq`, `doorbell_irq`, `packet_committed_irq`, `ptp_irq`, `perf_irq`, `wlink_irq`, `nego_error_irq`, `train_fail_irq`, `i2c_nbsy_irq`, `i2c_nrd_empty_irq` |
| TideChart extension | `tc_axis_tx_*`, `tc_axis_rx_*` (48-bit), `tc_qos_priority[2:0]`, `tl_local_link_state_o[4:0]`, `tl_link_state_change_o`, `tl_ewma_credit_o[12:0]`, `tl_bcast_ack_i` |
| Status / role | `link_active`, `tl_data_mode_o`, `d2d_reset_o`, `role_strap_i`, `role_is_master_o`, `role_locked_o`, `apb_debug_unlock_i`, `mask_hs_bypass_i`, `nego_priority_i[15:0]`, `puf_seed[15:0]`, `puf_ready` |
| I²C sideband | `i2c_scl_i/o/t`, `i2c_sda_i/o/t`, plus a full `s_i2c_axi_*` AXI4 slave port |

:::{warning}
`link_active` is **not** a data-ready signal. `assign link_active =
role_locked_o` (`tidelink_top.sv:2784`), which asserts roughly 5 µs *before* the
link can carry anything (`tidelink_top.sv:459-471`). Downstream logic that must
wait for a usable link gates on **`tl_data_mode_o`** (FCSM state ≥ 4).
:::

---

## 2. Module hierarchy

### Diagram

```{mermaid}
flowchart TD
    TOP["tidelink_top<br/>src/rtl/tidelink_top.sv"]

    TOP --> TXGEN["tidelink_tx_gen<br/>:1027 · if TXGEN_PRESENT"]
    TOP --> EYE["tidelink_eye_regs<br/>:1124 · ifndef TIDELINK_PHY_V2"]
    TOP --> GPHY["tidelink_gpio_phy_apb_regs<br/>:1263 · submodule"]
    TOP --> FIFO["tidelink_fifo<br/>:1605"]
    TOP --> FCA["tidelink_fc_adapter<br/>:1725"]
    TOP --> PTP["tidelink_ptp<br/>:1831 · if !STUB_PTP"]
    TOP --> SERVO["tidelink_ptp_servo<br/>:1935 · if !STUB_SERVO"]
    TOP --> PHCCDC["tidelink_phc_cdc<br/>:2012"]
    TOP --> PERF["tidelink_perf<br/>:2077 · if !STUB_PERF"]
    TOP --> XHBS["xhb500_ahb_to_axi_..._slv<br/>:2147"]
    TOP --> XHBM["xhb500_axi_to_ahb_..._mst<br/>:2234"]
    TOP --> XLAT["tidelink_addr_translator<br/>:2329 · if !BYPASS_ADDR_XLAT"]
    TOP --> ACC["axi_chiplet_controller<br/>:2443"]

    FIFO --> FMEM["tidelink_fifo_mem"]
    FIFO --> AREG["tidelink_apb_regs"]
    FIFO --> RTN["tidelink_returner"]
    FMEM --> FCTRL["tidelink_fifo_ctrl"]
    FMEM --> A2S["cmsdk_ahb_to_sram"]
    FMEM --> SRAM["tidelink_sram<br/>fpga / asic / generic"]

    XLAT --> XREGS["tl_addr_trans_regs"]
    XLAT --> XCAM["tl_addr_trans_cam"]

    ACC --> OBS["tidelink_axinode_obs"]
    ACC --> I2CM["i2c_master_axil"]
    ACC --> I2CS["i2c_slave_axil_master"]
    ACC --> NEG["tidelink_autoneg"]
    ACC --> LCHK["tidelink_lane_checker"]
    ACC --> CAL["tidelink_phy_align_calibrator"]
    ACC --> IDLY["tidelink_idelay_rx / tidelink_rxclk_buf"]
    ACC --> WL["Wlink"]

    WL --> LLTX["WlinkTxLinkLayer lltx"]
    WL --> LLRX["WlinkRxLinkLayer llrx"]
    WL --> TL2WL["TideLinkToWlink tl2wl"]
    WL --> AXI2WL["AXI4ToWlink axi2wl"]
    WL --> SP2WL["ShortPacketToWlink sp2wl"]
    WL --> GB2WL["GeneralBusToWlink gb2wl<br/>(tied off)"]
    WL --> PHY["WlinkGPIOPHY phy"]

    TL2WL --> FCSM6["WlinkGenericFCSM_6"]
    FCSM6 --> RP13["WlinkGenericFCReplayV2_13<br/>a2l · REPLAYABLE"]
    FCSM6 --> RP12["WlinkGenericFCReplayV2_12<br/>l2a · no revert"]
    PHY --> D2D["WavD2DGpio(_v2)<br/>segmenter · mask · deskew · 8× Tx/Rx"]
```

### Level 0 — the 13 direct children of `tidelink_top`

| # | Instance | Module | Instantiated at | Guard | Role |
|---|---|---|---|---|---|
| 1 | `u_tx_gen` | `tidelink_tx_gen` | `:1027` / `:1031` | `generate if (TXGEN_PRESENT)` `:1025-1026`; else-arm `g_no_txgen` `:1054-1066` | PL-side TX traffic generator; masters `ahb_tx` through a 2:1 mux so link throughput is measurable without the PS→PL round trip |
| 2 | `u_eye_regs` | `tidelink_eye_regs` | `:1124` / `:1127` | `` `ifndef TIDELINK_PHY_V2 `` `:1123` | APB Region 10 eye-sweep visibility window — **V1 builds only** |
| 3 | `u_gpio_phy_apb_regs` | `tidelink_gpio_phy_apb_regs` | `:1263` | none | APB Region 11 slave: per-lane lock threshold and noise statistics from the lane checker |
| 4 | `u_tidelink_fifo` | `tidelink_fifo` | `:1605` / `:1619` | none | RX FIFO data path + APB register block + credit returner |
| 5 | `u_fc_adapter` | `tidelink_fc_adapter` | `:1725` / `:1731` | none | AHB ↔ Wlink-app FC bridge: TX aperture, returner interception, RX replay, `PKT_EXT`/PUF |
| 6 | `u_ptp` | `tidelink_ptp` | `:1831` / `:1834` | `generate if (STUB_PTP == 1'b0) : gen_ptp_real` `:1830`; stub `:1895` | Single-phase PTP over Wlink short packets + PHC capture pulses |
| 7 | `u_servo` | `tidelink_ptp_servo` | `:1935` / `:1938` | `generate if (STUB_SERVO == 1'b0) : gen_servo_real` `:1934`; stub `:1985` | Autonomous hardware clock-sync servo (PI loop) |
| 8 | `u_phc_cdc` | `tidelink_phc_cdc` | `:2012` / `:2015` | none | 6-path CDC bridge between `hclk` and `phc_clk` |
| 9 | `u_perf` | `tidelink_perf` | `:2077` / `:2081` | `generate if (STUB_PERF == 1'b0) : gen_perf_real` `:2076`; stub `:2130` | Passive performance taps + congestion sideband |
| 10 | `u_xhb_sub` | `xhb500_ahb_to_axi_bridge_chiplet_slv` | `:2147` | none | Arm XHB500 AHB→AXI bridge on the `ahb_sub` path |
| 11 | `u_xhb_mng` | `xhb500_axi_to_ahb_bridge_chiplet_mst` | `:2234` | none | Arm XHB500 AXI→AHB bridge on the `ahb_mng` path |
| 12 | `u_addr_translator` | `tidelink_addr_translator` | `:2329` / `:2331` | `generate if (BYPASS_ADDR_XLAT == 1'b0) : gen_addr_xlat_real` `:2328`; bypass `:2355` | 8-rule CAM address remap on the `ahb_sub` path |
| 13 | `u_chiplet_controller` | `axi_chiplet_controller` | `:2443` / `:2480` | none | Wlink core + GPIO PHY + I²C + role block + autoneg + calibrator + APB mux |

There is a fourteenth generate arm, `g_phy_v2` at `tidelink_top.sv:2433`, which
is **intentionally empty** — see [§7 Dormant RTL](#7-intentionally-dormant-rtl).

### Level 1 — inside `tidelink_fifo`

`src/rtl/fifo/tidelink_fifo.sv`, 386 lines.

| Instance | Module | At | Size | Role |
|---|---|---|---|---|
| — | `tidelink_fifo_mem` | `:217` | 227 lines | SRAM-backed data path |
| — | `tidelink_apb_regs` | `:260` | 786 lines | TideLink config / status / credit / doorbell register block |
| — | `tidelink_returner` | `:349` | 250 lines | 3-channel priority AHB-Lite master |

`tidelink_fifo_mem` in turn instantiates `tidelink_fifo_ctrl` (`:135`, 535
lines — the credit accounting and packet framing), Arm's `cmsdk_ahb_to_sram`
(`:176`) and `tidelink_sram` (`:211`).

The **returner** is a single-beat AHB-Lite master with three fixed-priority
channels and pending registers so a short pulse is never lost
(`src/rtl/fifo/tidelink_returner.sv:1-14`):

| Channel | Priority | Purpose |
|---|---|---|
| 0 | highest | release credits |
| 1 | middle | doorbell |
| 2 | lowest | reset doorbell |

Its writes are intercepted by the FC adapter and converted into FC `SIDEBAND`
words, which is how credit gets back to the peer without a CPU.

### Level 1 — inside `axi_chiplet_controller`

`src/rtl/local_overrides/axi_chiplet_controller.sv`, 6482 lines — by a wide
margin the largest file in the design.

| Instance | Module | At | Role |
|---|---|---|---|
| `u_axinode_obs` | `tidelink_axinode_obs` | `:2890` | AXI data-node observability, APB Region F |
| `u_axi2axil` | `mkaxi2axil_bridge` | `:3001` | AXI4 → AXI4-Lite for the I²C block |
| `u_i2c_master` | `i2c_master_axil` | `:3145` | I²C master core (active when this die is master) |
| `u_i2c_slave` | `i2c_slave_axil_master` | `:3207` | I²C slave core (active when this die is slave) |
| `u_axil2apb` | `mkaxil2apb_bridge` | `:3267` | AXI4-Lite → APB |
| `u_autoneg` | `tidelink_autoneg` | `:3324` | Role negotiation + training-coordination FSM |
| `u_lane_checker` | `tidelink_lane_checker` | `:3830` | Per-lane training-pattern lock scoring |
| `u_calibrator` | `tidelink_phy_align_calibrator` | `:5824` (V2 arm) and `:5918` (V1 arm), selected by `` `ifdef TIDELINK_PHY_V2 `` at `:5800` | Bit-slip × phase sweep |
| `u_idelay_rx` | `tidelink_idelay_rx` | `:6099` | Per-lane Xilinx IDELAYE2 tap bank (FPGA) |
| `u_rxclk_buf` | `tidelink_rxclk_buf` | `:6147` | Recovered-RX-clock BUFG forward (FPGA) |
| `u_wlink` | `Wlink` | `:6157` | The link controller, parameterised `.USE_CLKBUF`, `.USE_T3A`, `.EPOCH_ANCHOR_EN` |

The two calibrator arms differ in constants, not in module: the V1 arm sets
`HOLD_CYCLES(32768)` and `VALIDATION_TIMEOUT(2_000_000)`
(`axi_chiplet_controller.sv:5918-5922`), the V2 arm sets
`VAL_TIMEOUT_TO_DONE(1'b1)` to break a measured `cal_done`/`lltx` circular
deadlock (`:5816-5826`).

### Level 2 — inside `Wlink`

`src/rtl/local_overrides/Wlink.v`, 2892 lines (Chisel-generated, hand-patched).

| Instance | At | Role |
|---|---|---|
| `txrouter` / `rxrouter` | `:1478` / `:1558` | Packet routing between the FC nodes and the link layer |
| `lltx` (`WlinkTxLinkLayer`) | `:1612` | Header ECC + CRC generation, 128-bit `io_link_data` out |
| `llrx` (`WlinkRxLinkLayer`) | `:1633` | Byte-count framer, header check, short/long classify |
| `axi2wl` (`AXI4ToWlink`) | `:1677` | The transparent AXI bridge path's five channel streams |
| `gb2wl` (`GeneralBusToWlink`) | `:1831` | Instantiated but **tied off** — `gb_in`/`gb_out` removed on branch `strip-generalbus-irq` (`docs/reference/FC_NODE_REGISTRY.md`) |
| `tl2wl` (`TideLinkToWlink`) | `:1865` | The TideLink mailbox path's single FC node |
| `sp2wl` (`ShortPacketToWlink`) | `:1925` | Short packets — PTP `0x50`/`0x51` |
| `phy` (`WlinkGPIOPHY`) | `:1380` (V2 arm, with `.EPOCH_ANCHOR_EN`) / `:1382` (V1 arm) | The GPIO PHY |

### Level 3 — the TideLink FC node

`TideLinkToWlink` (`src/rtl/local_overrides/TideLinkToWlink.v`) wraps one
`WlinkGenericFCSM_6` (`src/rtl/local_overrides/WlinkGenericFCSM_6.v`, 2041
lines) and flattens its 48-bit app streams into `bore_1` (in) and
`tl_bus_out_0` (out), which `tidelink_top` wires straight to
`tidelink_fc_adapter`.

Inside FCSM_6 there are two replay FIFOs and **they are not interchangeable**:

| FIFO | Direction | Revert on NACK? |
|---|---|---|
| `WlinkGenericFCReplayV2_13` | app → link (`a2l`) | **yes** — this is the replay buffer |
| `WlinkGenericFCReplayV2_12` | link → app (`l2a`) | no |

Six further `WlinkGenericFCSM{,_1,_2,_3,_4}` copies serve the five AXI channels
and GeneralBus, giving seven FCSMs in total — which is why a single careless
write to Wlink `0x0208` can reset all seven (see {doc}`register_map`).

---

## 3. Dataflow

```{mermaid}
flowchart LR
    subgraph MB["Mailbox path — posted, credited"]
        direction LR
        AHBTX["ahb_tx_*<br/>16 KB aperture"] --> ARB["arbiter +<br/>1-entry skid"]
        RTN2["returner<br/>credits/doorbells"] --> ARB
        SRV["ptp_servo<br/>timestamps"] --> ARB
        TC["tc_axis_tx<br/>PKT_EXT"] --> ARB
        ARB --> A2L["a2l replay FIFO<br/>hclk to link_clk"]
    end

    subgraph TR["Transparent path — blocking, address-forwarded"]
        direction LR
        AHBSUB["ahb_sub_*"] --> CAM["addr CAM"] --> XB1["XHB500<br/>AHB to AXI"] --> AX["AXI4ToWlink<br/>AW W B AR R"]
    end

    A2L --> FCSM["FCSM_6 send gate<br/>state 4 to 5"]
    AX --> FCSMS["5 x FCSM<br/>0x80..0x84"]
    FCSM --> LLTX2["lltx<br/>ECC + CRC"]
    FCSMS --> LLTX2
    LLTX2 --> PHYTX["segmenter 128b to 8x16b<br/>mask, training mux<br/>8x serialiser"]
    PHYTX --> WIRE(["pad_clk_tx + pad_tx[7:0]"])

    WIRE --> PHYRX["8x deserialiser<br/>phase / bit-slip<br/>cross-lane deskew"]
    PHYRX --> LLRX2["llrx framer<br/>classify + whitelist"]
    LLRX2 --> L2A["l2a replay FIFO<br/>link_clk to hclk"]
    L2A --> RXFSM["fc_adapter RX FSM"]
    RXFSM --> RXFIFO["RX FIFO SRAM<br/>ahb_fifo_* window"]
    RXFSM --> CFG["internal APB master<br/>SIDEBAND"]
    RXFSM --> TCRX["tc_axis_rx"]
    LLRX2 --> XB2["XHB500<br/>AXI to AHB"] --> AHBMNG["ahb_mng_*"]
```

The two paths share the PHY, the link layer, and one APB space; they are
otherwise independent. The mailbox path carries FC `data_id = 0xA1`; the
transparent path carries five **distinct** IDs `0x80`/`0x81`/`0x82`/`0x83`/`0x84`
(AW/W/B/AR/R) — see {doc}`register_map` for the full ID table.

---

## 4. Block-by-block

### `tidelink_top`

Besides holding the children together it owns three pieces of logic in its own
right:

1. **APB top decode** (`:825-827`)

   | Condition | Target | Window |
   |---|---|---|
   | `!paddr[14] && !paddr[13]` | chiplet controller / Wlink | `0x0000–0x1FFF` |
   | `!paddr[14] && paddr[13]` | TideLink + PTP + role registers | `0x2000–0x3FFF` |
   | `paddr[14] && !paddr[13]` | address translator | `0x4000–0x5FFF` |
   | `paddr[14:13] == 2'b11` | reserved — returns `prdata = 0`, `pready = 1`, `pslverr = 0` (`:845-853`) | `0x6000–0x7FFF` |

2. **The 2:1 transaction-atomic APB arbiter** (`:855-917`). Inside the TideLink
   region the FC adapter's RX config port and the external APB port share one
   bus. The arbiter guarantees the FC port can never preempt an external access
   that is already in its ACCESS phase:

   ```verilog
   wire ext_txn = apb_sel_tidelink && apb_penable;         // :884
   // ext_lock_q latches from the first stalled ACCESS cycle, releases on ack
   wire fc_cfg_apb_active = fc_cfg_apb_psel && !ext_txn && !ext_lock_q;  // :896
   ```

   :::{danger}
   This is a **PS-hang safety mechanism**, not an optimisation. A Zynq-7000
   `M_AXI_GP` has no bus timeout: a preempted access hangs the CPU permanently
   and every later access returns a bus error, requiring a physical power
   cycle. The RTL comment at `:861-868` records exactly this.
   :::

3. **The mailbox write-protect** (`:917`):
   `wire mbox_reg_write_fc_only = mbox_reg_write && fc_cfg_apb_active;`.
   `tidelink_apb_regs` computes `mbox_reg_write` from the raw shared-bus
   `psel && penable && pwrite` with no source qualifier, so before this gate an
   ordinary external APB write could overwrite the assembled cross-die PTP
   timestamp. Gated by `sim_gate_apb_preempt` and
   `sim_gate_v2_mbox_writeprotect`.

### `tidelink_tx_gen` — 412 lines

A PL-side AHB-Lite master that drives the *existing* `ahb_tx` port through a
2:1 mux, so the measured path keeps the held-NONSEQ transfer lock, the skid, the
honest back-pressure rule and the stall backstop. Only the Zynq PS→PL bridge is
removed.

Four safety properties are stated in the module header
(`src/rtl/tidelink_tx_gen.sv:11-46`) and are worth repeating because each
encodes a past defect:

- **POR-disarmed.** `TXGEN_CTRL[0]` resets to 0, so with `EN=0` the mux select
  is a constant-0 net and constant-folds; with `TXGEN_PRESENT=0` the block and
  its mux disappear entirely and the ASIC netlist is provably unchanged.
- **`EN` survives STOP and CLR** — only POR or an explicit `EN=0` clears it.
- **The hardware credit gate is mandatory.** The peer's RX FIFO write side has
  no back-pressure (see {doc}`functionality`, "Back-pressure semantics"),
  so a line-rate generator without a credit gate would destroy data at line
  rate. It gates on `pair_credit_count` (the local view of the *peer's* free
  credit), never on the local FIFO's credit and never on the Wlink `fe_*`
  credit.
- **Reserve-then-send, and packets are atomic** — the whole `(len+2)` is
  consumed at packet start, and a run never abandons a packet mid-flight.

### `tidelink_fc_adapter` — 720 lines

Three functional paths (`src/rtl/tidelink_fc_adapter.sv:1-31`): the TX aperture
(AHB slave), returner interception (AHB slave), and the RX path (a direct write
port plus an internal APB master).

**The 48-bit FC word** (header `:13-16`, localparams `:152-158`):

| Field | Bits | Meaning |
|---|---|---|
| `pkt_type` | `[47:46]` | `00` = `PKT_FIFO_DATA`, `01` = `PKT_SIDEBAND`, `10` = `PKT_EXT` |
| `addr_offset` | `[45:32]` | 14-bit byte address inside the 16 KB aperture, or a subtype for `PKT_EXT` |
| `payload` | `[31:0]` | 32-bit data word |

The encoding is **stateless on the RX side** — no packet-boundary tracking is
required. 48 bits is the minimum self-describing word (2 + 14 + 32) and must
match `WlinkGenericFCSM_6`; `FC_DATA_W` cannot be changed without regenerating
the Chisel.

Two `PKT_EXT` subtypes are handled locally and never cross the link
(`:157-158`): `SUB_PUF_READ_REQ = 14'h0020` and `SUB_PUF_READ_RSP = 14'h0021`.
The PUF request reads uninitialised FIFO SRAM and answers on `tc_axis_rx`.

**TX arbitration** (`:529-546`): returner sideband and PTP-servo sideband
outrank the TX aperture; the `PKT_EXT` tier is QoS-configurable —
`tc_qos_priority == 0` leaves the TX aperture ahead of `PKT_EXT`, any non-zero
value boosts `PKT_EXT` above it. A fairness cap
`localparam MAX_SIDEBAND_BURST = 4` (`:433`) forces a TX-aperture grant after
four consecutive sideband grants.

**The skid** (`:549-573`):

```verilog
assign skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready;   // :553
assign tl_fc_a2l_valid = skid_valid_r;                      // :572
```

**The stall backstop** (`:311-346`): `TX_STALL_TIMEOUT_LOG2 = 16` (`:44`),
`tx_stall_ctr_r` is 17 bits and `tx_stall_expired = tx_stall_ctr_r[16]`
(`:314`) ≈ 1.3 ms at 50 MHz. Past the timeout the adapter terminates the beat
with a standard two-cycle AHB **ERROR** rather than hanging the PS. The older
"wedge watchdog" that silently dropped burst beats by forcing `HREADY` is
removed; the comment at `:300-310` explains that dropping with OKAY was the
sin. `tx_dropped_cnt_r` is observability-only and reads 0 on a healthy link.

### The FIFO subsystem

`tidelink_fifo_ctrl` (`src/rtl/fifo/tidelink_fifo_ctrl.sv`) holds the credit
accounting:

```verilog
localparam MAX_CREDITS   = (1 << (RAM_ADDR_W - 2));            // :110  → 4096
localparam MAX_PACKET_LEN = RAM_ADDR_W'(MAX_CREDITS - 2);      // :242
wire rx_fifo_empty = (credit_count_r == MAX_CREDITS);          // :138
```

At `RAM_ADDR_W = 14` the 16 KB SRAM is credited in 32-bit words with a 2-word
header reserve. Two guards in this file are silicon-defect fixes, not
defensive style:

| Guard | Lines | What it prevents |
|---|---|---|
| Consume path clamps at 0 | `:386-389` | credit underflow |
| Mint path **saturates** at `MAX_CREDITS` | `:424-427` | minting credit *above* `MAX_CREDITS` — the 2026-07-15 phantom-pop chip-killer |
| Read path qualified with `&& !rx_fifo_empty` | `:321-331` | the 2026-07-14 empty-read phantom pop |

`tidelink_sram` has three implementations selected purely by flist, with an
identical port signature:

| Variant | File | Backing store | Selected by |
|---|---|---|---|
| FPGA | `src/rtl/fifo/fpga/tidelink_sram.sv` | Arm `cmsdk_fpga_sram`, BRAM-inferred | `flists/tidelink_fpga*.flist:56` |
| ASIC | `src/rtl/fifo/asic/tidelink_sram.sv` | TSMC 65 nm `rf_16k` compiled register file (active-low `CEN`/`WEN`/`GWEN`) | `flists/tidelink_asic.flist:4`, `flists/tidelink_top_full_asic_v2.flist:54` |
| Generic | `src/rtl/fifo/generic/tidelink_sram.sv` | behavioural register array matching `cmsdk_fpga_sram` timing | `flists/tidelink_generic.flist:4` |

### `tidelink_addr_translator` — 208 lines

CAM-based, **not** a segment table. Its own header
(`src/rtl/tidelink_addr_translator.sv:1-13`) gives the reason: 8 programmable
match/replace rules per channel cost ~169 flops against 2048 for a 256-entry
table. Decode: subtract `BASE_OFFSET`, compare `addr[31:24]` against each
enabled rule, lowest-index match replaces `addr[31:24]`; `addr[23:0]` always
passes through; with the global enable clear everything passes unchanged.
Register detail is in {doc}`register_map`.

Only channel 0 is instantiated (`NUM_CHANNELS = 1`); channel 1 returns
`pslverr`.

### The PHY: lane checker, calibrator, deskew

The PHY datapath lives inside `axi_chiplet_controller` → `Wlink` →
`WlinkGPIOPHY` → `WavD2DGpio`. The V2 chain is
(`src/rtl/local_overrides/WavD2DGpio_v2.v:577-740`):

```
lltx 128-bit word
  → tidelink_phy_sync_insert   (pure passthrough when the APB enable is 0)
  → tidelink_phy_tx_segmenter  (128b → 8×16b, lane i = [16*i +: 16])
  → tidelink_phy_tx_mask       (masked lane → 16'h0000)
  → 8× WavD2DGpioTx serialisers
  → pad_clk_tx + pad_tx[7:0]
    ═══ wire ═══
  → pad_clk_rx + pad_rx[7:0]
  → (optional tidelink_idelay_rx)
  → 8× WavD2DGpioRx  (phase / bit-slip / word-pin)
  → tidelink_phy_rx_demask
  → tidelink_lane_deskew       (re-align 8 lanes into one coherent 128-bit word)
  → llrx framer
```

:::{note}
The TX mask is applied **before** the per-lane training mux, so a masked lane
still transmits its training pattern; the mask zeroes data words only
(`WavD2DGpio_v2.v:577-581`).
:::

**Constants worth quoting** (all read from RTL):

| Constant | Value | Source |
|---|---|---|
| `TIDELINK_SYNC_WORD` | `128'hF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00` | `deps/tidelink-phy/rtl/tidelink_sync_word.svh:37-38` |
| `TIDELINK_SYNC_PERIOD` | 32 words (≈ 3 % throughput tax in continuous payload) | `tidelink_sync_word.svh:41-42` |
| Per-lane training bytes | `0xA3 0xB5 0xC9 0xD3 0x65 0x4B 0x59 0x2D` (lanes 0–7) | `WavD2DGpio_v2.v:1333`, instance params `:1764-1911` |
| V2 `TRAINING_WORD16` | `0x12EB` even lanes, `0xED14` odd lanes | `WavD2DGpio_v2.v:1764-1911` |
| Calibrator `DWELL_CYCLES` | 64 | `tidelink_phy_align_calibrator.sv:215` |
| Calibrator `LOCK_THRESH` | 16 | `:218` |
| Calibrator `HOLD_CYCLES` | `8 × 128 × DWELL_CYCLES` | `:237` |
| Calibrator `NUM_LANES` | 8 (elaboration `$fatal` if not 8, `:454-455`) | `:220` |
| Calibrator `CLK_MHZ` | 250 | `:278` |
| Deskew geometry | `LANES=8, WIDTH=16, DEPTH_LOG=5` (32 entries) | `WavD2DGpio_v2.v:851` |
| `SYNC_REANCHOR_TOL` | 5 | `WavD2DGpio_v2.v:871` |
| `EPOCH_MATCH_THRESH` | 5 | `WavD2DGpio_v2.v:880` |

The calibrator FSM states (`tidelink_phy_align_calibrator.sv:468-477`) are
`S_IDLE`, `S_ARM`, `S_SWEEP`, `S_FINISH`, `S_DONE`, `S_CANCEL`, `S_HOLD`, plus
the advisory `S_PROBE` and `S_FINALIZE`/`S_VALIDATE` states — readable at
`OBS_CAL` `0x2198[3:0]`.

:::{caution}
**The two whole-word correctors are mutually exclusive by construction.**
`WavD2DGpio_v2.v:851` drives `.SYNC_REANCHOR_EN(!EPOCH_ANCHOR_EN)`, so one knob
picks the corrector and the deskew's own `$fatal` mutual-exclusion assertion is
satisfied automatically. Before this fix the parameter reached
`WlinkGPIOPHY`→`WavD2DGpio` and was then **dropped** — `u_deskew` was hard-wired,
making it a dead knob (`WavD2DGpio_v2.v:842-850`). That is the same failure class
as the `NEGO_CFG_RESET` plumbing bug.
:::

### `tidelink_autoneg` — 2418 lines

Resolves master/slave between two identical dies over the I²C sideband
**before** role lock, using priority-based backoff with SDA early-exit
detection (`src/rtl/local_overrides/tidelink_autoneg.sv:1-13`). The FSM has 20
states (`:256-317`): `ST_IDLE`, `ST_NEGO_INIT/WAIT/CLAIM/POLL/DONE`,
`ST_BYPASS`, `ST_ERROR`, the mask-handshake states
`ST_NEGO_MASK_RES_TX/RD_ADDR/RD_DATA`, `ST_NEGO_DONE_PRE`, the training states
`ST_TRAIN_ENTER/RUN/POLL_PEER/EXIT/DONE/FAIL`, and the finalise rendezvous
`ST_FIN_RDV`/`ST_FIN_GO`.

:::{note}
**`docs/reference/AUTONEG_PROTOCOL.md` still says "RTL not yet implemented".**
It is implemented — 2418 lines of it, instantiated at
`axi_chiplet_controller.sv:3324`. Treat that document as protocol description
only.
:::

### PTP: `tidelink_ptp`, `tidelink_ptp_servo`, `tidelink_phc_cdc`

| Module | Lines | Role |
|---|---|---|
| `tidelink_ptp` | 568 | Single-phase (2-message) PTP over Wlink short packets; pulses `phc_hw_capture` at the exact handshake cycle. Contains **no counter** — the timestamps live in the external PHC. |
| `tidelink_ptp_servo` | 669 | Grandmaster/subordinate PI servo closing the loop in hardware. Default gains `KP = 32'h0000_B333` (~0.7) and `KI = 32'h0000_4CCC` (~0.3), `STEP_THRESH = 1000` ns (`:35-37`). |
| `tidelink_phc_cdc` | 504 | Six-path bridge between `hclk` and `phc_clk`; ~526 flops with `BYPASS_CDC=0`, ~20 with `BYPASS_CDC=1` (`:14-16`). |

The six CDC paths (`tidelink_phc_cdc.sv:5-12`): HW-capture timestamps
(phc→hclk, 110-bit quasi-static snapshot), free-running PHC time (phc→hclk,
78-bit handshake), PPS pulse (phc→hclk toggle), HW-capture trigger (hclk→phc
toggle), phase-step command (hclk→phc, 79-bit), frequency adjust (hclk→phc,
33-bit).

### `tidelink_apb_regs` — 786 lines

The TideLink register block. Region select is `paddr[8:5]`
(`src/rtl/fifo/tidelink_apb_regs.sv:210`) and the slot within a region is
`paddr[4:2]`. `tidelink_top` decodes three regions itself before the block
sees them:

| `paddr[8:5]` | Region | Owner | Site |
|---|---|---|---|
| `4'b1010` | 10 | `tidelink_eye_regs` (V1 only) | `tidelink_top.sv:1069` |
| `4'b1011` | 11 | `tidelink_gpio_phy_apb_regs` | `tidelink_top.sv:1242`/`:1245` |
| `4'b1110` | E | `tidelink_tx_gen` | `tidelink_top.sv:991` |

Full register content is in {doc}`register_map`.

### `tidelink_perf` — 524 lines

Passive taps only — it never affects the datapath
(`src/rtl/tidelink_perf.sv:1-19`). Provides packet TX/RX timestamps from the
free-running PHC snapshot (CDC path 2, ~4 cycles stale — a constant offset that
cancels in differential measurements), a software-writable origin timestamp for
Ethernet-MAC pipeline tracing, 8 saturating counters, live debug registers and
a freeze mode. It occupies APB Regions 5–7.

It also drives the congestion sideband (`tidelink_top.sv:434-445`):
`tl_local_link_state_o[4:0] = {starve, trend[1:0], level[1:0]}`,
`tl_link_state_change_o` is a one-cycle pulse on a quantised transition,
`tl_ewma_credit_o[12:0]` is the EWMA credit, and `tl_bcast_ack_i` is
level-sensitive and clears the starve-sticky. Pure combinational, `hclk`
domain; tie off if unused.

### XHB500 bridges

Arm-generated. They are **not** a git submodule: `deps/xhb500` is an in-tree
directory of generator *configs*, and the RTL under `deps/xhb500/generated/` is
produced on the first `source set_env.sh`. The internal AXI geometry between
the bridges and the controller is 12-bit ID, 36-bit address (upper 4 bits tied
0) and 32-bit data (`tidelink_top.sv:556-645`).

---

## 5. Clock and reset domains

### Clocks

| Domain | Source | Consumers | Notes |
|---|---|---|---|
| `hclk` | SoC AHB clock (top-level input) | every AHB/APB port, FIFO, FC adapter, perf, PTP front end — and, in every current integration, the chiplet controller's `apb_clk` **and** `app_clk` | `docs/ARCHITECTURE.md:187` |
| `user_ref_clk` | dedicated top-level input | Wlink PLL reference → `user_hsclk`, the PHY high-speed reference | **not** `hclk`; a common integration mistake |
| `pad_clk_rx` | the peer's forwarded clock, recovered | all 8 lanes' RX capture | one shared `IBUFG`→`BUFG` on FPGA |
| `link_clk` | `io_hsclk ÷ 16` on the TX side; `gpiorx_0_io_link_clk = ~count[3]` on the RX side | lane checker, calibrator FSM, link layer | free-running ÷16, phase-independent |
| `phc_clk` | PTP hardware clock (top-level input) | PTP servo / PHC only | bridged by `tidelink_phc_cdc` |
| `idelay_ref_clk` | 200 MHz IDELAYCTRL reference | `tidelink_idelay_rx` | tie `1'b0` in sim and ASIC |
| `scan_clk` | DFT | scan chains | held inactive functionally (`cdc/tidelink_top.sgdc:132`) |

:::{warning}
**On the FPGA one `clk_wiz` output feeds `hclk`, `user_ref_clk` *and*
`scan_clk`**, so the link/pad rate is 1:1 with `hclk` on that target. That is
materially different from the ASIC model (250 MHz reference ÷ 16). `docs/`
carries two different figures for the FPGA bit-cell rate — `~4.7–25 MHz`
(`docs/ARCHITECTURE_PHY_LINK.md:9`) and `6.25 MHz`
(`docs/ARCHITECTURE.md:190,199`). Both are describing bring-up experiments at
different link speeds; neither is a specification. Measure your own target.
:::

### Resets

| Reset | Polarity | Scope |
|---|---|---|
| `hresetn` | active-low sync | all AHB/APB/FC-adapter RTL |
| `poresetn` | active-low POR | the Wlink `por_resetn` sequence; **must be held longer than `hresetn`** so the PHY survives a fabric warm reset |
| `phc_resetn` | active-low | PHC domain |

Two derived resets matter, both in `axi_chiplet_controller`:

```verilog
wire wlink_por_reset = ~poresetn | ~role_locked;   // :2921
assign app_clk_reset = ~hresetn  | ~role_locked;   // :2926
```

The `~role_locked` term in **both** is the 2026-06-21 coherent-release fix: it
makes the two sides of the a2l replay FIFO's Gray-pointer CDC deassert on the
*same* event, eliminating an asymmetric reset-release skew
(`tidelink_top.sv:512-518`). `role_locked` is therefore best understood as a
**mutual clock enable** for the link, not as a status bit.

The role registers are reset **only** by `poresetn`, so a warm reset preserves
the negotiated role.

:::{danger}
**On the FPGA board designs `poresetn == hresetn == phc_resetn`** — all three are
tied to `peripheral_aresetn`. The warm/POR distinction collapses and
`role_lock` clears on *any* reset. Do not rely on warm-reset role retention on
those targets.
:::

### CDC crossings

SpyGlass sign-off is recorded in `docs/reference/SPYGLASS_CDC_SIGNOFF.md`:
re-run 2026-05-28 at integration SHA `6666c1be` with `deps/tidelink-gpio-phy`
@ `d00dd88` and `deps/axi-chiplet-controller` @ `c0a69ff` —
**0 fatals, 0 errors, 4 warnings (none CDC), 0 unsynchronized crossings,
0 convergences. Verdict: GO.** Tool: SpyGlass `vT-2022.06-SP2`, goal
`cdc/cdc_verify`, flow `make -C cdc cdc MODULE=tidelink_top`.

The constraint file `cdc/tidelink_top.sgdc` declares five clocks
(`hclk` 4.0 ns, `phc_clk` 10.0 ns, `user_ref_clk` 8.0 ns, `pad_clk_rx` 4.0 ns,
`idelay_ref_clk` 5.0 ns), four resets (`hresetn`, `poresetn`, `phc_resetn`, and
`role_locked_o` used as a functional reset for the Region-11 synchronisers), and
declares `role_strap_i`, `puf_seed*`, `nego_priority_i*`, `mask_hs_bypass_i`,
`i2c_scl_i` and `i2c_sda_i` **quasi-static**.

Two real data crossings exist, both carrying the quasi-static 32-bit
`phase_offset` calibration word into `pad_clk_rx`:

| Crossing | Status |
|---|---|
| `swi_phase_offset_r`: `hclk` → `pad_clk_rx` | waived by `set_clock_groups -asynchronous` in both the FPGA XDC and the ASIC SDC |
| `cal_phase_offset_w`: `link_clk` → `pad_clk_rx` | de-facto safe on FPGA (÷16, 15-cycle margin) but **still needs an explicit `set_multicycle_path -setup 16 / -hold 15` for ASIC** |

`role_locked → wlink_por_reset` is subsumed by the same clock-groups waiver.
Wlink-internal crossings use `WavFIFO`, `WavDemetReset` and `WavResetSync` and
are already correctly synchronised.

:::{note}
The sign-off report itself flags a residual hole (`SPYGLASS_CDC_SIGNOFF.md`,
"Finding #2"): the `link_clk → pad_clk_rx` crossing does **not** surface in the
SpyGlass run because `axi_chiplet_controller` is black-boxed and Wlink is
waived. A synthesis-level CDC run on the integrated chiplet IP is still
required.
:::

---

## 6. `src/rtl/local_overrides/` — the override convention

### The rule

Vendor and submodule RTL is **never edited in place**. Two trees are strictly
read-only for everyone in the lab:

- `/research/AAA/ip_library/**` (Arm CMSDK BP210, XHB500 generator)
- `/research/AAA/phys_ip_library/**` (TSMC memory compilers)

Git submodules under `deps/` are treated the same way — editing them creates a
pin that nobody else can reproduce.

**The convention:** copy the file into `src/rtl/local_overrides/`, re-point the
flist at the local copy (commenting out the original line so the substitution is
visible in a diff), and document the deviation in the file's own header. The
flists carry the substitution explicitly, e.g.
`flists/tidelink_fpga_v2.flist:152`:

```
// # Comment-out original: ${TIDELINK_HOME}/deps/tidelink-phy/rtl/tidelink_lane_deskew.sv
```

`+incdir+${TIDELINK_HOME}/src/rtl/local_overrides` appears near the top of every
build flist (`flists/tidelink_fpga_v2.flist:43`) so the overrides win.

### What is there and why

**Wavious/Wlink-derived** (Apache-2.0, SPDX header, "MODIFIED by SoC Labs"):

| File | Override reason |
|---|---|
| `Wlink.v` (2892 lines) | Adds `USE_CLKBUF` / `USE_T3A` / `EPOCH_ANCHOR_EN` parameter pass-through to `WlinkGPIOPHY` (`:56-76`), plus observability ports. **Also changes the POR value of `swi_delay_cycles` from `16'h6a4` (1700) to `16'h0`** (`:2621`, vs upstream `deps/.../Wlink.v:2082`) — the tdif-04 fix for a TX P-state deadlock. |
| `WlinkRxLinkLayer.v` (2229 lines) | tdif-08 post-reset **hunt-holdoff** (a 6-bit counter reset to 63 that gates the `is_long_pkt → state 1` transition) plus the tdif-10 **short-packet `data_id` whitelist** `{0x44, 0x45, 0x46, 0x47}`, so the framer cannot latch a phony long packet on training filler (`:1-46`). Also adds observability ports and V2 SYNC re-align. |
| `TideLinkToWlink.v` | Adds `io_obs_fe_rx_is_full`, `io_obs_fe_rx_credit_max`, `io_obs_a2l_replay_link_valid` for ILA and APB observability |
| `WlinkGenericFCSM*.v` | SoC Labs L6/L7/L9 fixes: `SOCL_L6_MIN_CR_EMITS = 32`, `SOCL_L7_MIN_CRACK_EMITS = 32`, `SOCL_L7_WDOG_THRESHOLD = 16'h4000`, `SOCL_REACK_THRESHOLD = 16'h0100` (`WlinkGenericFCSM_6.v:189-208`), plus the L7 "bring-up forgive" gate for a sticky NACK wedge |
| `WlinkGenericFCReplay*.v` | Replay-FIFO fixes |
| `WlinkGPIOPHY{,_v2}.v`, `WavD2DGpio{,_v2}.v`, `WavD2DGpioRx{,_v2}.v`, `WavD2DGpioTx.v`, `WavMultibitSync_18.v` | Bug-FC1 `post_train_hold_ctr_r`; tdif-04 `T3A_CONTINUOUS` re-arm; tdif-03 word-aligned training/data mux latch at `count == 4'hf` so a mid-word switch cannot corrupt a beat |
| `ShortPacketToWlink.v` | PTP short-packet path |

**SoC-Labs-owned files that override a submodule copy:**

| File | Override reason |
|---|---|
| `axi_chiplet_controller.sv` | Adds the runtime `MIN_LOCK_DWELLS` APB knob and instantiates `tidelink_axinode_obs` |
| `tidelink_autoneg.sv` | Adds `obs_*_o` ports for the APB Region C readback — no functional change |
| `tidelink_lane_deskew{,_v2}.sv`, `tidelink_phy_align_calibrator_v2.sv` | V2 PHY development line |
| `i2c_master_axil.v`, `i2c_master.v` | Adds `status_o[3:0]` for Bug N7/N8 |

:::{tip}
If a fix appears to require an IP-library change, that is the signal to make an
override — never to touch the upstream. Copy in, re-point the flist, write the
reason in the header. Every file in `local_overrides/` follows that shape, and
the headers are the best available changelog.
:::

---

## 7. Intentionally dormant RTL

None of the following is dead code to be swept up. Each has a stated reason to
stay.

| File / construct | Status | Why it must stay |
|---|---|---|
| `src/rtl/tidelink_addr_translation.sv` | "ALTERNATIVE IMPLEMENTATION — NOT INSTANTIATED IN THE ACTIVE DESIGN" (`:1-11`) | The segment-table translator, kept for integrations needing more than 8 simultaneous ranges. At `NUM_SEGS=256` it synthesises to ~1500 cells against the CAM's ~80. |
| `src/rtl/tidelink_apb_addr_ctrl.sv` | dormant | The register bank for the segment translator above |
| `src/rtl/tidelink.sv` (192 lines), `src/rtl/tidelink_ahb.sv` (188 lines) | legacy thin wrappers | Back-compat for `cocotb/tidelink_ahb`. `tidelink_ahb.sv` still uses the old port name `released_tokens_irq` where everything else uses `released_credits_irq`. |
| `src/rtl/fifo/tidelink_fifo_ahb.sv` (256 lines) | compiled, not instantiated | A `tidelink_fifo` + `cmsdk_ahb_to_apb` wrapper. It appears in `tidelink_fpga.flist`, `tidelink_fpga_v2.flist` and both full-ASIC flists, but `tidelink_top` instantiates `tidelink_fifo` directly (`:1605`). |
| `src/rtl/tidelink_idelay_rx.sv`, `src/rtl/tidelink_rxclk_buf.sv` | parameter-gated to bit-exact passthrough at `USE_IDELAY = 0` / `USE_CLKBUF = 0` | FPGA-essential. `INTEGRATION_GUIDE` §4.3: do not delete the `USE_*` paths. |
| `USE_PHY_V2` and the `g_phy_v2` generate arm (`tidelink_top.sv:2433`) | empty S2 scaffold | Marks where the shared PHY component will drop in. The header says plainly: **"Do NOT set to 1 yet — the arm is a placeholder, not a functional PHY."** (`:93-94`) |
| `src/rtl/asic/tidelink_dft_wrapper.sv` (768 lines) | explicit SKELETON | See [§8](#8-asic-versus-fpga) |
| `gb2wl` (`GeneralBusToWlink`) inside `Wlink` | instantiated, tied off | `gb_in`/`gb_out` removed on branch `strip-generalbus-irq` |

:::{note}
**`tidelink.sv`'s own header is stale.** It says "Live FPGA / ASIC builds use
`tidelink_top.sv` → `tidelink_fifo_ahb.sv` directly" (`src/rtl/tidelink.sv:14`).
They do not — `tidelink_top.sv:1605` instantiates `tidelink_fifo`. The statement
about `tidelink.sv` itself being unreachable from live builds is correct; only
the named intermediate is wrong.
:::

---

## 8. ASIC versus FPGA

The same `tidelink_top` source serves both. The differences are in
**parameters**, **flists** and **one wrapper file** — never in `#ifdef`s inside
the functional RTL.

### Parameter differences

| Parameter | `tidelink_top` default | FPGA IP wrapper default | Why |
|---|---|---|---|
| `USE_IDELAY` | `1'b0` (`:65`) | `1'b1` (`tidelink_vivado_wrapper.v:73`) | Xilinx IDELAYE2 tap bank exists only on FPGA |
| `USE_CLKBUF` | `1'b0` (`:68`) | `1'b1` (`:77`) | Global BUFG forward of the recovered RX clock |
| `USE_T3A` | `1'b0` (`:74`) | `1'b1` (`:83`) | Per-lane self-aligning RX comma hunt |
| `TIDELINK_PAIR_BASE` | `'0` (`:54`) | `32'h44032000` (`:61`) | The FPGA APB base, so the returner POR-initialises correctly |
| `HONEST_MASK_HS` | `1'b1` (`:168`) | `1'b0` (`:168`) | See the warning below |
| `NEGO_CFG_RESET` | `7'h00` (`:141`) | `7'h61` (`:147`) | Autonomy opt-in |

The full 30-parameter table with per-target overrides is in {doc}`parameters`.

:::{important}
**A `+define+` never reaches a packaged IP's out-of-context synthesis; a wrapper
parameter default recorded in `component.xml` does.** This is why every knob
that must be settable on FPGA appears on the `tidelink_vivado_wrapper.v` face,
and why `src/rtl/v2shims/` exists at all.
:::

:::{warning}
**`HONEST_MASK_HS` has a self-contradicting comment.** The block at
`tidelink_top.sv:147-167` repeatedly describes "0 (default)"; the declaration on
line 168 is `1'b1`. The **declaration** is what elaborates. At
`HONEST_MASK_HS = 1'b0` the controller's `mask_hs_bypass_i` is tied `1'b1`
(`tidelink_top.sv:2512`), forcing the peer-mask gate permanently open — the
"sham handshake". The FPGA wrapper ships `1'b0`.
:::

### V1 versus V2 PHY selection

Both PHY generations use the **same module names**, so selection is entirely by
flist and by one `define`:

| | V1 | V2 |
|---|---|---|
| Build flist | `flists/tidelink_fpga.flist`, `flists/tidelink_top_full_asic.flist` | `flists/tidelink_fpga_v2.flist`, `flists/tidelink_top_full_asic_v2.flist` |
| PHY sources | `deps/tidelink-gpio-phy/rtl` + V1 `local_overrides` | `deps/tidelink-phy/rtl` + V2 `local_overrides` |
| `TIDELINK_PHY_V2` | undefined | defined |
| `tidelink_eye_regs` | present (Region 10) | absent (`` `ifndef `` at `tidelink_top.sv:1123`) |

`src/rtl/v2shims/` holds three three-to-five-line files (`v2_Wlink.v`,
`v2_axi_chiplet_controller.sv`, `v2_tidelink_top.sv`) that each do
`` `define TIDELINK_PHY_V2 `` followed by an `` `include `` of the shared source.
Their header states the reason:

> Per-file defines survive IP packaging where fileset/global mechanisms do not
> (3 failed attempts logged on `feat/phy-v2-integration`, 2026-06-11).

That is the mechanism by which V2 selection reaches Vivado OOC synthesis.

:::{caution}
`deps/tidelink-gpio-phy` and `deps/tidelink-phy` point at the **same upstream
repository** and contain **identically named modules**
(`tidelink_lane_checker.sv`, `tidelink_phy_align_calibrator.sv`,
`tidelink_gpio_phy_apb_regs.sv`, …). If both `+incdir+` paths ever appear in one
flist, which file wins is a compile-order accident. This is tracked as
**TL-014** in `docs/BUG_REGISTRY.yaml` (severity low, status deferred) — see
{doc}`known_issues`.
:::

### The DFT wrapper

`src/rtl/asic/tidelink_dft_wrapper.sv` (768 lines) is labelled **SKELETON** in
its own first line. It:

- adds a multi-bit scan-chain bus (8 chains by default) alongside the legacy
  1-bit `scan_in`/`scan_out` stub inherited from Wlink, which stays wired so
  existing LEC pin-down flows keep working;
- adds a `test_mode` qualifier separate from `scan_en` so MBIST and TAP can each
  signal without colliding with ATPG shift;
- tunnels `mbist_en` / `mbist_done` / `mbist_pass` ports — but **does not
  instantiate a BIST controller**: `assign mbist_done = 1'b0; assign mbist_pass
  = 1'b0;` (`:478-479`);
- gates optional JTAG TAP pads on `parameter INCLUDE_TAP = 0` (`:170`), whose
  zero arm `g_no_tap` (`:495`) is the only one that elaborates today.

Both closure tasks are documented in `docs/reference/DFT_PLAN_2026_05_28.md`
§4/§5, and the missing BIST is tracked as **TL-011** (F19 PHY BIST, severity
high, status deferred) in the bug registry. Elaboration of the wrapper is
gated by the `dft_wrapper_elab` suite in `make sim_gate`.

---

## 9. Doc-versus-RTL corrections made on this page

| Claim in `docs/` | What the RTL says |
|---|---|
| "six sub-components", `tidelink_fifo_ahb` + `fifo_mux_*`/`cfg_mux_*` hierarchy (`docs/ARCHITECTURE.md` §2, `docs/reference/TIDELINK_SPECIFICATION.md`) | 13 direct children; `tidelink_fifo_ahb` compiled but not instantiated |
| `tidelink.sv:14` — "live builds use `tidelink_top.sv` → `tidelink_fifo_ahb.sv`" | `tidelink_top.sv:1605` instantiates `tidelink_fifo` |
| `docs/reference/AUTONEG_PROTOCOL.md` — "RTL not yet implemented" | 2418 lines, instantiated at `axi_chiplet_controller.sv:3324` |
| `HONEST_MASK_HS` comment — "0 (default)" (`tidelink_top.sv:148`) | Declaration is `1'b1` (`:168`) |
| `mask_hs_gate_open = mask_hs_match \| mask_hs_bypass_i \| apb_debug_unlock_i` (widely repeated) | `apb_debug_unlock_i` was **removed** from that OR on 2026-07-24; the current expression is `mask_hs_match \| mask_hs_bypass_i` (`axi_chiplet_controller.sv:711`) |
| Wlink P-state `Delay cycles` reset = 1700 | The local override PORs it to `16'h0` (`local_overrides/Wlink.v:2621`) |
| `NEGO_CFG_RESET = 7'h61` | `7'h00` in both `tidelink_top.sv:141` and `axi_chiplet_controller.sv:84`; only the FPGA IP wrapper is `7'h61` (`tidelink_vivado_wrapper.v:147`) |

---

## See also

- {doc}`functionality` — bring-up, credits, error handling, recovery
- {doc}`register_map` — every register in every region
- {doc}`parameters` — all 30 parameters with per-target overrides
- {doc}`integration` — instantiating `tidelink_top` in a host SoC
- {doc}`known_issues` — the bug registry and the two-trees-diverge warning
