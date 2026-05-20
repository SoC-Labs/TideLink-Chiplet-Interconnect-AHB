# TideLink v1 GPIO-PHY ASIC — UPF / Power-Management Plan

Author:   SoC Labs (David Mapstone, `d.a.mapstone@soton.ac.uk`)
Branch:   `feat/td-combined`
Status:   **Plan — RTL has no power intent today.** This document scopes
          the work required to take the v1 chiplet from a purely
          single-supply, always-on RTL to a tapeout-ready IEEE 1801
          (UPF 3.0) power-intent specification with islands, isolation,
          retention, and an always-on (AON) wake-up domain reachable
          via I²C.
Audience: power-aware-flow engineer (UPF authoring, Design Compiler
          + IC Compiler low-power flow, formal CLP), DV (low-power sim
          / UPF static checks), DFT (retention scan, IR-drop sign-off).
Target:   ~22 nm CMOS, single-die chiplet, ~5 mm² area class, link
          rate 200 Mb/s aggregate (25 MHz forwarded clock, 8 lanes).

---

## 1. Goals + non-goals

### 1.1 Goals (v1 tapeout scope)

| # | Goal | Why |
|---|---|---|
| G1 | Produce a **complete IEEE 1801 (UPF 3.0)** file describing all power domains, supplies, switches, isolation cells, level shifters, retention strategy, and POR sequencing. The UPF file must pass static checks (Synopsys VC LP / UPF_CHECK in PrimeTime PX). | A modern foundry tapeout flow refuses to sign off without it; UPF is the contract between RTL, synthesis, P&R, and DFT. |
| G2 | Provide a **VDD\_AON island** that stays live whenever the chiplet has any external supply. AON contains I²C slave, POR, voltage detector, JTAG TAP, wake-decode FSM, and the power-controller FSM. | The peer chiplet wakes us by driving SDA low; that must work with the rest of the chiplet off. |
| G3 | **Power-gate the Wlink TX/RX banks** (PD\_PHY) and the bulk digital logic (PD\_CORE) when the link is idle for longer than a programmable threshold (default ≥1 ms). | Wlink PHY + 5877 LoC of digital is the bulk of dynamic + leakage. Gating gives an order-of-magnitude idle reduction. |
| G4 | **Retention flops** on the small set of state that must survive idle: role/lock latches, peer-mask state, IDELAY converged taps, address-translator CAM contents (subset), QoS configuration, PTP servo coefficients. | Reload from APB on every wake costs ~50 µs (PYNQ measurements on FPGA) and creates a dead window in which traffic is dropped; retention shrinks this to a clock-tree settle (~100 ns). |
| G5 | **<100 µs wake latency** from peer SDA-low → link\_active high. Breakdown: I²C decode (4-byte address phase at 400 kHz = ~80 µs ← dominant) + power-rail ramp (5–10 µs from PMIC) + reset deassertion + IDELAY recall (<5 µs) + Wlink re-train (<10 µs). | Latency budget for credit-return loops in the wider chiplet pair: <1 ms end-to-end, of which the link wake gets a tenth. |
| G6 | **Static UPF check pass** under VC LP / Conformal Low Power, including isolation completeness, level-shifter completeness, retention coverage, and supply-set consistency. | Sign-off gate before tapeout. |
| G7 | **Post-CTS UPF re-validation** after IC Compiler — confirm that physical PSO cells, switch cells, AON buffers, and retention-cell mapping match the UPF intent. | Required because IC Compiler can drop / re-route AON nets through gated cells if not constrained. |

### 1.2 Non-goals (deferred to v2)

- **DVFS (Dynamic Voltage and Frequency Scaling).** v1 runs a single 1.0 V core nominal. No frequency hopping, no AVS, no body-bias.
- **Multi-VDD optimisation.** No separate low-Vdd domain for the FIFO SRAMs; they share PD\_CORE.
- **Adaptive clock gating below module granularity.** Synthesis-inferred RTL clock gates are fine, but no SmartClocks / OCC for IR-droop.
- **Per-lane PHY power gating.** All 8 lanes go down together. Per-lane gating is appealing for narrow-link operation but requires Wlink modifications outside v1 scope.
- **Light-sleep state for the FIFO SRAM** (drowsy / retention). v1 either keeps SRAM in PD\_CORE active or fully shuts it (state lost). No partial retention.
- **Thermal management / power capping.** Deferred — die is small and chiplet TDP is single-digit milliwatts.

---

## 2. Power domains (proposed islands)

The chiplet contains four power domains. Three have distinct power
nets; PD\_CORE and PD\_PHY may share one externally-provided supply
(VDD\_CORE) but are independently switched on-die — this keeps PCB
complexity low while still giving us the option to gate the noisy
PHY independently of the bulk digital.

```
                    ┌──────────────────────────────────────────────────────────┐
                    │                 Chiplet Die (TideLink v1)                │
                    │                                                          │
   VDD_IO (3.3V) ──►│ PD_IO  ┌────────────────────────────────────────────┐    │
                    │        │   I/O ring: GPIO pads, LVCMOS33 PHY pads,  │    │
                    │        │   open-drain I²C pads (SDA / SCL).         │    │
                    │        │   Always-on.                               │    │
                    │        └────────────┬───────────────────────────────┘    │
                    │                     │ digital (1.0V) signals through LS  │
                    │                     ▼                                    │
   VDD_AON (1.0V) ─►│ PD_AON ┌────────────────────────────────────────────┐    │
                    │        │   I²C slave + master pad logic decode      │    │
                    │        │   POR cell + voltage detect on VDD_CORE    │    │
                    │        │   Wake-decode FSM, power-controller FSM    │    │
                    │        │   JTAG TAP (for off-state test access)     │    │
                    │        │   Ref-clock receiver / XO buffer (32 kHz)  │    │
                    │        │   Role-strap latch (poresetn-domain regs)  │    │
                    │        │   Peer-mask handshake state (small)        │    │
                    │        │   Always-on.                               │    │
                    │        └────────────┬───────────────────────────────┘    │
                    │                     │ AON↔CORE / AON↔PHY via ISO+LS      │
                    │                     ▼                                    │
   VDD_CORE (1.0V)─►│ PD_CORE┌────────────────────────────────────────────┐    │
   (switched on-die)│        │   AHB / AXI / APB bridges (XHB500 ×2)      │    │
                    │        │   tidelink_fifo + 16 KB FIFO SRAM           │    │
                    │        │   tidelink_fc_adapter, tidelink_ahb,        │    │
                    │        │   tidelink_addr_translator, tl_addr_*       │    │
                    │        │   tidelink_apb_regs, perf, phc_cdc,         │    │
                    │        │   ptp + servo, fifo_ctrl, returner,         │    │
                    │        │   axi_chiplet_controller (less I²C slave    │    │
                    │        │   + nego_train FSM — those move to AON).    │    │
                    │        │   Gateable via header switch SW_CORE.       │    │
                    │        └────────────┬───────────────────────────────┘    │
                    │                     │ CORE↔PHY via ISO (intra-1.0V — no LS)│
                    │                     ▼                                    │
   VDD_CORE_PHY ───►│ PD_PHY ┌────────────────────────────────────────────┐    │
   (switched on-die,│        │   Wlink (LL_TX, LL_RX, FCSM, FCs, PHY      │    │
    same external   │        │   wrapper, WavD2DGpio TX/RX banks),         │    │
    rail as CORE)   │        │   tidelink_phy_align_calibrator,            │    │
                    │        │   tidelink_idelay_rx, tidelink_rxclk_buf,   │    │
                    │        │   tidelink_lane_checker.                    │    │
                    │        │   Gateable via header switch SW_PHY.        │    │
                    │        └────────────────────────────────────────────┘    │
                    │                                                          │
   VSS ────────────►│ (common ground for all four domains)                     │
                    └──────────────────────────────────────────────────────────┘
```

### 2.1 Per-domain summary

| Domain | Net | Switch | Voltage | Estd cells | Estd area | Estd power (active) |
|---|---|---|---|---|---|---|
| `PD_AON` | `VDD_AON` | none (always-on) | 1.0 V | ~12 k | 5–8 % | 30–50 µW |
| `PD_CORE` | `VDD_CORE` | header (`SW_CORE`, multi-stage) | 1.0 V | ~140 k | 55–65 % | 3–25 mW (data-dependent) |
| `PD_PHY` | `VDD_CORE_PHY` | header (`SW_PHY`, multi-stage) | 1.0 V | ~35 k | 15–20 % | 2–25 mW (link-rate-dependent) |
| `PD_IO` | `VDD_IO` | none (always-on) | 3.3 V | ~30 pads | 5–10 % (ring) | depends on pad activity |

Estimated cell counts derived from RTL LoC: `src/rtl/tidelink_top.sv`
1620 lines, `axi_chiplet_controller.sv` 1632 lines, `Wlink.v` 2324
lines, plus 16 KB FIFO SRAM and ~30 k cells of bridges/CDC/CAM. Final
counts arrive after synthesis.

### 2.2 Why a separate PHY island when it shares the same rail

PHY shares `VDD_CORE` externally for PCB simplicity but is **switched
separately on-die** for two reasons:

1. **Independent gating decisions.** The link spends most of its time
   idle. While the host SoC remains busy on local fabric, we can drop
   PD\_PHY independently. PD\_CORE only gates when host fabric is
   quiet *and* the link is idle.
2. **Noise isolation.** WavD2DGpio TX banks toggle at the line rate
   on dedicated pads; keeping PHY current in a separate on-die
   distribution lattice with its own header switches keeps the
   transient di/dt out of PD\_CORE's voltage domain. The flip side is
   that the two domains drift in voltage during PHY ramp; we mitigate
   with sequenced rail-up (PHY second, after CORE has settled).

### 2.3 Cross-domain isolation strategy summary

| Boundary | Direction | Strategy |
|---|---|---|
| PD\_AON → PD\_CORE | data / control out from AON | clamp at AON output to known value (typically 0) when PD\_CORE is off — receiver is in shutdown so clamp value irrelevant, but UPF demands it |
| PD\_CORE → PD\_AON | data / control out from CORE | **isolation cell on AON side** (clamp 0 for data, clamp 1 for ready/ack handshakes) |
| PD\_CORE → PD\_PHY | data / control | **isolation cell on PHY side** — clamp when PD\_PHY is off |
| PD\_PHY → PD\_CORE | data / control / RX recovered clock | **isolation cell on CORE side** — clamp when PD\_PHY is off, plus a gated path on the recovered-clock buffer to avoid metastable propagation into PD\_CORE clock tree |
| PD\_CORE → PD\_IO | digital out to pad cells | **level shifter LS\_L2H (1.0 V → 3.3 V)** at every CORE-driven pad |
| PD\_IO → PD\_CORE | digital in from pad cells | **level shifter LS\_H2L (3.3 V → 1.0 V)** at every CORE-receiving pad |
| PD\_AON → PD\_IO (I²C pads) | open-drain enable / data | **LS\_L2H** + isolation; SDA / SCL pad drivers must remain functional with all switched domains off |
| PD\_PHY → PD\_IO (Wlink pads) | digital out | **LS\_L2H** at every PHY-driven Wlink pad; pad cell must tristate clean when PD\_PHY is off |

---

## 3. Power states

```
                                    ┌──────────────┐
                                    │   COLD_BOOT  │  poresetn asserted, all rails
              ┌────────────────────►│   (POR)      │  ramping; AON wakes first
              │                     └──────┬───────┘
              │                            │ POR cell deasserts
              │                            ▼
   peer pulls SDA low                ┌──────────────┐  CORE switched OFF
   (open-drain) ──────────────►      │   AON_ONLY   │  PHY switched OFF
                ◄────────────────────│   (deep)     │  retention HOLD
              │                     └──────┬───────┘
              │                            │ wake_req from I²C decode
              │                            ▼
              │                     ┌──────────────┐  CORE rails up, then PHY
              │                     │   WAKE_SEQ   │  ISO de-asserted,
              │                     │              │  retention RESTORE,
              │                     │              │  reset deasserted in order
              │                     └──────┬───────┘
              │                            │ link_active = 1
              │                            ▼
              │                     ┌──────────────┐  all four domains on,
              │                     │   ACTIVE     │  Wlink up, traffic flowing
              │                     └──────┬───────┘
              │                            │ idle-timer expiry (>1 ms idle)
              │                            ▼
              │                     ┌──────────────┐  retention SAVE,
              │                     │  SLEEP_SEQ   │  ISO asserted in order,
              │                     │              │  CORE/PHY gated off
              │                     └──────┬───────┘
              │                            │
              └────────────────────────────┘
```

### 3.1 State table

| State | VDD\_AON | VDD\_CORE | VDD\_CORE\_PHY | VDD\_IO | Pads | Wlink | Retention | I²C slave | Wake source |
|---|---|---|---|---|---|---|---|---|---|
| `COLD_BOOT` | ramp→on | ramp | ramp | ramp | tri | reset | undef | reset | n/a |
| `AON_ONLY` (deep idle) | on | **off** | **off** | on | tri / open-drain SDA/SCL | off | HOLD | active | SDA low (peer) or local wake |
| `WAKE_SEQ` (~10 µs) | on | ramping | (waits for CORE settled) | on | tri→active | reset→training | RESTORE | active | n/a (transient) |
| `ACTIVE` | on | on | on | on | active | up, traffic | not used | active | n/a |
| `SLEEP_SEQ` (~1 µs) | on | gating | gating first | on | drain → tri | quiesce | SAVE | active | n/a (transient) |

### 3.2 Transition entry/exit conditions

- **`AON_ONLY → WAKE_SEQ`:** triggered by `wake_req` from the AON
  power-controller FSM. Sources of `wake_req`:
  1. I²C slave decode of the wake-byte register write
     (`u_i2c_slave` in `axi_chiplet_controller.sv:1003-1039`).
  2. Local SoC fabric asserts an external `local_wake_req_i` strap
     (TBD whether this is a port — see action item A4).
  3. JTAG TAP-controller write to the wake register (debug-only).
- **`ACTIVE → SLEEP_SEQ`:** triggered by all three idleness conditions
  holding simultaneously for ≥`SLEEP_THRESHOLD` (default 1 ms, APB
  register-programmable, TBD register placement):
  1. `tx_link_idle == 1` (driven from `Wlink.v:1637`,
     `lltx_io_link_idle` → `tx_router_idle` in
     `tidelink_top.sv:490`).
  2. `obs_llrx_valid_o == 0` for `SLEEP_THRESHOLD` (Wlink RX-side
     idle, from `Wlink.v:179`).
  3. Local AHB managers/subordinates all idle (no outstanding
     transactions on `ahb_sub`, `ahb_tx`, `ahb_fifo`, `ahb_mng`,
     `ahb_ptp` ports of `tidelink_top`).
- **`SLEEP_SEQ → AON_ONLY`:** completes when retention SAVE finishes
  and all ISO clamps assert. Power-controller drives switch enables.

### 3.3 Power-state table (UPF `add_power_state`)

Sketch of UPF object (full text in §10):

```
add_power_state PD_AON.primary -state {ON  -supply_expr {power == FULL_ON 1.00 && ground == FULL_ON 0.00}}
add_power_state PD_CORE.primary -state {ON  -supply_expr {power == FULL_ON 1.00}}
add_power_state PD_CORE.primary -state {OFF -supply_expr {power == OFF}}      -simstate CORRUPT
add_power_state PD_PHY.primary  -state {ON  -supply_expr {power == FULL_ON 1.00}}
add_power_state PD_PHY.primary  -state {OFF -supply_expr {power == OFF}}      -simstate CORRUPT
add_power_state PD_IO.primary   -state {ON  -supply_expr {power == FULL_ON 3.30}}

# Composite chiplet state (4-tuple, allowed combinations)
add_power_state CHIPLET -state {S_COLD_BOOT  -logic_expr {PD_AON==OFF}}
add_power_state CHIPLET -state {S_AON_ONLY   -logic_expr {PD_AON==ON && PD_CORE==OFF && PD_PHY==OFF}}
add_power_state CHIPLET -state {S_ACTIVE     -logic_expr {PD_AON==ON && PD_CORE==ON  && PD_PHY==ON}}
```

---

## 4. Wake-up path

### 4.1 Sequence diagram

```
  Time(µs) │ Peer chiplet           │ I/O pad ring  │ AON island        │ Power ctrl │ CORE/PHY       │ Wlink
  ─────────┼────────────────────────┼───────────────┼───────────────────┼────────────┼────────────────┼──────────
       0.0 │ drives SDA low         │ SDA = 0 (OD)  │ pad RX → I²C slv  │   idle     │   off          │  off
           │ START + 4-byte addr +  │   ⋮           │   ⋮               │            │                │
      80.0 │   wake-byte data       │ SDA bits      │ slave AXIL write  │            │                │
      82.0 │ STOP                   │               │ addr decode →     │            │                │
           │                        │               │   wake_req = 1    │ wake_req↑  │                │
      82.5 │                        │               │                   │ assert ISO_OFF clamps      │
      82.7 │                        │               │                   │ SW_CORE.en │ SW_CORE ramps  │
           │                        │               │                   │            │   on, CORE V↑  │
      87.7 │                        │               │                   │ wait V≥0.9 │ CORE settled   │
      87.8 │                        │               │                   │ SW_PHY.en  │ SW_PHY ramps   │
      92.8 │                        │               │                   │ wait V≥0.9 │ PHY settled    │
      92.9 │                        │               │                   │ retention  │   regs restore │
      93.0 │                        │               │                   │ RESTORE   →│   from RET     │
      93.5 │                        │               │                   │ deassert ISO clamps         │
      93.6 │                        │               │                   │ hresetn↑   │ reset deasserts│
      94.0 │                        │               │                   │            │                │ calibrator
      94.5 │                        │               │                   │            │                │  starts
      99.0 │                        │               │                   │            │                │ training
      99.5 │                        │               │                   │            │                │ converged
      99.7 │                        │               │                   │ link_active│                │ link_active↑
```

Total: ~100 µs from SDA-low to `link_active`. The dominant cost is
the I²C transaction itself at 400 kHz (~80 µs for a 4-byte address +
1-byte data + ACK overhead). Everything after I²C completion is
~20 µs.

### 4.2 Wake-byte protocol

Re-using the existing I²C slave (`u_i2c_slave` in
`axi_chiplet_controller.sv:1003`) plus the bridge to internal APB
(`u_axil2apb_slv`, called downstream of the slave). The peer writes
a single byte to a dedicated wake-register address in AON address
space. The AON wake-decode FSM watches APB writes to that single
address and sets `wake_req` for one cycle.

Wake-byte register layout (TBD address — likely Region 0, offset 0xFF
in AON sub-decode):

| Bits | Field | RW | Semantics |
|---|---|---|---|
| [7:4] | reserved | R | reads as 0 |
| [3] | `WAKE_PHY_ONLY` | W | wake only PD\_PHY, not PD\_CORE (TBD: useful?) |
| [2] | `RETAIN_BYPASS` | W | bypass retention restore (cold-restart RTL) |
| [1] | `WAKE_REQ` | W | 1 = enter WAKE\_SEQ |
| [0] | `WAKE_ACK` | R | 1 = WAKE_SEQ complete |

### 4.3 Wake protocol from peer mask handshake

The existing `mask_hs_bypass_i` strap and peer-mask state (the
`role_locked` latch in `axi_chiplet_controller.sv:295-300`) live in
PD\_AON in this plan; peer-mask handshake must complete before
PD\_CORE/PD\_PHY are released. This means the peer-mask handshake
moves from the existing `hresetn` reset domain to a new
`aon_resetn` (derived from `poresetn`) — see §9.

---

## 5. Isolation cells

### 5.1 General rules

- Every signal that **exits a gateable domain** to an always-on or
  separately-gated domain must pass through an isolation cell.
- Clamp value chosen so the receiver remains in a quiescent /
  recoverable state:
  - **Data buses** → clamp `0`.
  - **valid / req / vld** signals → clamp `0` (recipient sees no
    transaction).
  - **ready / accept / ack** signals → clamp `1` (sender does not
    stall waiting for an off-domain consumer; data is dropped, which
    is fine because the sender is also being prepared for shutdown
    in `SLEEP_SEQ` and will have been quiesced first).
  - **Interrupt outputs** to host SoC → clamp `0` so a falling edge
    of supply does not look like an asserted IRQ.
  - **Reset outputs** to host (`d2d_reset_o` in `tidelink_top.sv:300`)
    → clamp `1` (active-low → look held in reset).
- Isolation cells are placed in the **receiving** domain wherever
  possible (P&R requirement: the cell's enable signal lives in an
  always-on domain).

### 5.2 Cross-domain signal inventory

#### 5.2.1 PD\_CORE → PD\_AON (CORE outputs into AON)

These are signals that the AON power-controller FSM and I²C slave
need from the active CORE during ACTIVE state. Most are status /
acknowledgement signals.

| Signal | Clamp | Source (file:line) | Notes |
|---|---|---|---|
| `link_active` | 0 | `tidelink_top.sv:295` | tells AON the link is up; clamp 0 during sleep |
| `tx_router_idle` (`tx_link_idle`) | 1 | `Wlink.v:1637` | clamp idle=1 during sleep |
| `nego_error_irq` | 0 | `tidelink_top.sv:317` | clamp inactive |
| Interrupt outputs back to power FSM (ack from CORE that retention save is done) | 0 | new wire | new wire from CORE→AON retention controller |

Count estimate: ~10 cells.

#### 5.2.2 PD\_AON → PD\_CORE

| Signal | Clamp (receiver-side) | Source | Notes |
|---|---|---|---|
| `wake_req`, `ret_save_req`, `ret_restore_req`, `iso_en_*`, `sw_*_en` | n/a | AON FSM | sourced from AON; ISO cell sits at the **CORE input** so the wire entering CORE is clean when CORE is off — but since CORE is OFF the clamp value is irrelevant; UPF still demands one |
| `role_strap_i` (latched in AON regs) → CORE consumers | 0 | `axi_chiplet_controller.sv:295` (today in hresetn-domain — move to AON) | restored by retention if needed |
| `role_locked`, `role_is_master` from AON-latched POR-domain regs to CORE | 0 | `axi_chiplet_controller.sv:295-300` | clamp 0 during CORE shutdown |
| `apb_debug_unlock_i`, `mask_hs_bypass_i` straps | strap value | `axi_chiplet_controller.sv:71,79` | static, treated as input straps, no clamp issue |

Count estimate: ~25 cells.

#### 5.2.3 PD\_CORE → PD\_PHY

Wlink is on the PHY side; the rest of the digital is on CORE. This
boundary is heavy.

| Signal class | Clamp | Approx count | Notes |
|---|---|---|---|
| LL\_TX feeder data | 0 | 128 + 16 | `phy_link_tx_tx_link_data` (Wlink.v:307) + valid + framing |
| APB to PHY region (Region 4/8 → calibrator) | 0 | 64 | `ctrl_reg_*` (`axi_chiplet_controller.sv:90-93`) |
| Calibrator → IDELAY taps | 0 | 8 × 5 = 40 | per-lane delay-tap |
| Reset/clock distribution control | 1 (held-reset clamp) | 8 | reset signals into PHY |
| FC node packed words (tl\_fc\_a2l\_*) | 0 | 48 + 1 | `tidelink_top.sv:469-475` |
| FCSM observability ports | 0 | 16 | `Wlink.v:179` |

Count estimate: ~265 cells on this boundary.

#### 5.2.4 PD\_PHY → PD\_CORE

| Signal | Clamp | Source (file:line) | Notes |
|---|---|---|---|
| LL\_RX received words → FC adapter (`tl_fc_l2a_*`) | 0 | `tidelink_top.sv:472-475` | clamp 0 — FC adapter rejects |
| `tx_link_idle` | 1 | `Wlink.v:1637` | already counted in §5.2.1 — this is the same wire when PHY is the source |
| `obs_llrx_valid_o`, observability | 0 | `Wlink.v:179` | |
| Recovered RX clock (`pad_clk_rx` derived) | gated | `tidelink_rxclk_buf.sv` | **clock signal — needs gating + ISO, not a plain clamp.** The CORE clock tree must not see the recovered clock when PHY is off. Use a clock-gate cell (LCG) controlled by `iso_en_phy` and clamp the gated output to 0. |
| `wlink_irq` | 0 | `tidelink_top.sv:257` | |
| FC sideband valid/data | 0 | inside `tidelink_top.sv` | |

Count estimate: ~80 cells.

#### 5.2.5 PD\_CORE → PD\_IO (digital → pad)

Every output pad in CORE drives through an LS\_L2H. Also each is
held in the pad's last-known driven state during sleep, since the
pad cells themselves are in PD\_IO.

| Pad class | Count | Clamp / hold |
|---|---|---|
| AHB master out (`ahb_mng_*` in `tidelink_top.sv:134-149`) | ~75 | tri-state during sleep |
| Interrupt outputs (`*_irq` in `tidelink_top.sv:252-257`) | 6 | 0 |
| Status outputs (`link_active`, `role_locked_o`, `servo_locked`, `d2d_reset_o`) | 4 | 0 (reset clamp 1) |
| TideChart AXI-stream (`tc_axis_*`) | 49+1 | 0 |
| Congestion sideband (`tl_local_link_state_o`, etc.) | 5+1+13 | 0 |

Count estimate: ~155 cells (LS + ISO combined where pad cell supports both).

#### 5.2.6 PD\_IO → PD\_CORE / PD\_AON

Inputs use LS\_H2L. I²C SDA/SCL inputs land in PD\_AON. Everything
else lands in PD\_CORE.

Count estimate: ~210 cells (most pads are inputs in this chiplet).

#### 5.2.7 Total isolation/level-shifter footprint estimate

| Boundary | Direction | Cells | Notes |
|---|---|---|---|
| PD\_CORE ↔ PD\_AON | both | ~35 | small |
| PD\_CORE ↔ PD\_PHY | both | ~345 | heavy |
| PD\_CORE / PD\_PHY / PD\_AON ↔ PD\_IO | both | ~365 | most are LS, some are LS+ISO combo cells |
| **Total** | | **~745 cells** | first-pass — refined post-synth |

---

## 6. Level shifters

### 6.1 Where they go

- **PD\_CORE / PD\_PHY (1.0 V) ↔ PD\_IO (3.3 V)** — every pad boundary.
  Vendor-specific cells (e.g. Synopsys DesignWare or foundry-provided
  `LS_H2L_X1` / `LS_L2H_X1`).
- **PD\_AON (1.0 V) ↔ PD\_IO (3.3 V)** — I²C pad logic and POR/JTAG
  pads.

There are **no level shifters between PD\_AON and PD\_CORE/PD\_PHY**
because all three internal domains run at 1.0 V nominal. (If a v2
multi-VDD optimisation adds a 0.8 V CORE for low-power mode, this
boundary becomes another LS site.)

### 6.2 Cell-type inventory (estimated)

| Cell type | Count | Where |
|---|---|---|
| `LS_L2H_X1` (1.0 → 3.3 V drive) | ~140 | every CORE/PHY/AON pad output |
| `LS_H2L_X1` (3.3 → 1.0 V receive) | ~210 | every CORE/AON pad input |
| `ISO_LSL2H_X1` combo (LS + ISO) | ~75 | CORE/PHY outputs where pad is in switched domain |
| `ENLATCH_L_X1` (enable retainer on AON) | ~20 | AON FSM control outputs to ISO/SW |

---

## 7. Retention flops

### 7.1 Strategy

Retention flops survive an `OFF` state of their parent domain by
keeping their internal latch live on an always-on supply rail (the
cell has both `VDD` and `VDDR` inputs; the cell's clock and reset
network is in the gateable domain, the latch back-end is on AON).

Three classes of state:

1. **Must retain** (loss is unacceptable / very expensive to re-learn)
   — get retention cells.
2. **Should retain** (faster wake, but lossy reload is also OK) —
   v1 reloads from APB; revisit in v2.
3. **Never retain** (state is naturally re-built / re-filled on every
   ACTIVE entry) — let it clear.

### 7.2 Inventory of retention candidates (v1)

| Module | State | Class | Flop count (est) | Rationale |
|---|---|---|---|---|
| `axi_chiplet_controller` role/lock regs (`role_locked`, `role_is_master`, `peer_mask`) | **Must retain** | 1 | ~8 | Re-running the auto-neg / peer-mask handshake at every wake costs >100 µs and the peer may already be assuming we know our role |
| `axi_chiplet_controller` swi\_lane\_status / SWI\_* config (Region 8, `:485` block) | **Must retain** | 1 | ~32 | Saved per-lane IDELAY values + lane-enable masks from calibrator; reload from APB is slow |
| `tidelink_phy_align_calibrator` converged taps (per-lane phase, count slip) | **Must retain** | 1 | 8 × 5 + 8 × 4 = ~72 | Recalibrating costs the entire training sequence (~10 ms in worst case) — biggest single win |
| `tidelink_addr_translator` segment-mux configuration regs (256 segments × `pair_base_addr`) | **Must retain** | 1 | ~32 (only programmed entries) | TBD: full CAM is large; retain only the "valid" bit per entry and the small base-address pointer, reload the rest from APB |
| `tl_addr_trans_cam` (`tl_addr_trans_regs.sv`) | Should retain | 2 | ~256 | TBD whether to retain or restore from CAM-shadow APB regs |
| `tidelink_ptp_servo` servo coefficients (Kp, Ki, accumulated drift integrator) | **Must retain** | 1 | ~64 | Re-locking PTP costs seconds — unacceptable |
| `tidelink_apb_regs` configuration (FIFO enable, flush masks, IRQ enables) | **Must retain** | 1 | ~48 | Otherwise host SoC sees IRQs disabled after wake |
| `tidelink_perf` counters | Never retain | — | — | Counters reset on wake is fine (or document as expected) |
| `tidelink_fifo` SRAM contents + control pointers (`write_ptr`, `read_ptr`) | Never retain | — | — | Packet buffers — peer must retransmit |
| Wlink internal flops (LL\_TX, LL\_RX, FCSM, FCs) | Never retain | — | — | Wlink re-trains on every wake; state is naturally rebuilt |
| WavD2DGpio shift registers, training-byte slip counters | Never retain | — | — | Re-acquired by calibrator |
| AHB / AXI bridge state machines (XHB500 ×2) | Never retain | — | — | Quiesce before sleep; protocols start from idle |

### 7.3 Retention totals

- **Total retention flops:** ~520 (out of ~12 000 flops total in CORE
  domain → ~4 %)
- **Total area overhead:** ~520 × 1.6 (retention cell vs regular FF
  area ratio) × ~10 µm² ≈ 8 320 µm² (~0.008 mm² — negligible).
- **Retention save / restore time:** 4 cycles at 25 MHz = 160 ns SAVE,
  same for RESTORE — well inside the 10 µs ramp-window budget.

### 7.4 UPF retention strategy (per-domain)

```
set_retention PD_CORE_retention -domain PD_CORE -retention_supply_set PD_AON.primary \
  -save_signal {tidelink_top_inst/u_pwrctrl/ret_save_req posedge} \
  -restore_signal {tidelink_top_inst/u_pwrctrl/ret_restore_req posedge} \
  -elements {u_chiplet_ctrl/role_locked_reg \
             u_chiplet_ctrl/swi_lane_status_reg* \
             u_calibrator/phase_reg* \
             u_calibrator/slip_reg* \
             u_addr_xlat/pair_base_addr_reg \
             u_servo/coeff_*_reg \
             u_apb_regs/cfg_*_reg}
```

`PD_PHY` has no retention — every PHY flop re-trains on wake.

---

## 8. AON island contents

Detail of every block that must move to (or be added in) PD\_AON.

| Block | Source | What moves | Why AON |
|---|---|---|---|
| **I²C slave** (`u_i2c_slave`) | `axi_chiplet_controller.sv:1003-1039` | entire instance | wake path needs it live with CORE off |
| **I²C slave AXIL→APB bridge** | `axi_chiplet_controller.sv` (downstream of slave) | the bridge + its address decode | so AON-side writes work into PD\_AON sub-APB region |
| **POR cell** | new — vendor IP | dedicated rail-voltage detector that drives `poresetn` | must be live at the earliest moment any rail is up |
| **Voltage detector** | new — vendor IP | monitors VDD\_CORE during wake to gate retention RESTORE | safe wake sequencing |
| **JTAG TAP controller** | new — wraps existing scan ports (`tidelink_top.sv:169-174`) into an AON TAP | full TAP FSM + IR/DR shift, BSCAN | post-shutdown debug access (e.g. tester can read out registers without waking) |
| **Wake-decode FSM** | new | decodes the wake-byte register write, drives `wake_req` and routes to power-controller FSM | the actual wake trigger |
| **Power-controller FSM** | new | sequences SW\_CORE → SW\_PHY → ISO → retention RESTORE → reset deassertion; reverse for SLEEP | central state machine |
| **Reference-clock buffer** | new | 32 kHz / low-rate clock for AON; could be RC oscillator + XO option | gives the FSM a clock with PD\_CORE off |
| **Role-strap latch** (`role_locked`, `role_is_master`, `i2c_slv_addr_reg`, etc.) | `axi_chiplet_controller.sv:295-313` (currently `poresetn` domain) | move from CORE-instantiated POR-reset regs to AON | needed for wake decisions; also natural fit for POR-only reset domain |
| **Peer-mask handshake state** | `axi_chiplet_controller.sv:74-79` and the SWI_* regs | move the small state (mask\_hs\_done, sb\_reset\_in synchroniser) | needed during WAKE\_SEQ before PD\_CORE is up |
| **Power island enable outputs** | new | `sw_core_en`, `sw_phy_en`, `iso_en_core`, `iso_en_phy`, `ret_save_req`, `ret_restore_req`, `core_resetn`, `phy_resetn` | drive the on-die header switches and ISO/RET cells |
| **Wake-byte APB register** | new | small APB sub-decode in AON for the wake-byte register | host SoC and I²C peer both reach it via the same address |
| **AON test mode straps** | new | DFT mode, BIST start (TBD) | AON-side BIST is optional, leave a hook |

### 8.1 AON ↔ I²C topology

`u_i2c_slave` already drives an internal AXIL master that goes
through `mkaxil2apb_bridge` to an internal APB (see
`axi_chiplet_controller.sv:1003-1039`). In v1 power plan:

1. `u_i2c_slave` and the AXIL→APB bridge stay together and **both move
   to PD\_AON**.
2. The internal APB fans out two ways:
   - **To AON wake-decode register** (always reachable). New AON-side
     register block sits behind the AON APB.
   - **To PD\_CORE Wlink APB** (Region 0 / Region 4 / Region 8 from
     `axi_chiplet_controller.sv`). This path crosses PD\_AON →
     PD\_CORE: every signal in the APB protocol gets an ISO cell on
     the CORE side. When PD\_CORE is off, the I²C slave can still
     write the AON wake register, but writes to the CORE-side APB
     region simply stall (paddr decode in AON sees the address is
     in the CORE map → asserts `pready` with `pslverr` = 1, so the
     I²C transaction completes cleanly with an error response).
3. **`u_i2c_master`** stays in PD\_CORE (it's only needed when the
   host SoC is up driving outgoing I²C transactions).

### 8.2 AON area + power budget

- ~12 k cells (small): I²C slave (~3.5 k), AXIL→APB bridge (~2 k),
  power FSM (~1 k), wake-decode + register (~0.5 k), POR + VD
  (~0.5 k), TAP (~3 k), small misc (~1.5 k).
- ~5–8 % of die area.
- Static (leakage) power at 22 nm, 1.0 V, 25 °C: ~5–15 µW.
- Active power (I²C only, 400 kHz): ~30–40 µW including switching.

---

## 9. POR + reset architecture

### 9.1 Reset domains in v1 (current RTL)

Today (`tidelink_top.sv:79-83`):

- `hresetn` — system / warm reset, synchronous-deassert
- `poresetn` — power-on reset, latches role / locks
- `phc_resetn` — PHC clock-domain reset

`Wlink.v` adds:

- `wlink_por_reset` (`axi_chiplet_controller.sv:751` — active-high,
  `= ~poresetn | ~role_locked`) — gates Wlink off until role is
  locked.

### 9.2 Reset domains in v1 power plan

```
   VDD_AON rises ──► POR cell ──► aon_poresetn (async)
                                      │
                                      ├──► AON registers (role, mask, swi_*)
                                      ├──► AON power-controller FSM
                                      ├──► JTAG TAP
                                      └──► aon_resetn  (sync deassert in AON)

   power FSM asserts SW_CORE.en + waits + asserts core_resetn  (active-low)
                                      │
                                      └──► PD_CORE flops (including all of the
                                            previously-hresetn domain).
                                            sync deassert on hclk.

   power FSM asserts SW_PHY.en + waits + asserts phy_resetn   (active-low)
                                      │
                                      └──► PD_PHY (Wlink) flops.
                                            sync deassert on user_hsclk.

   PHC clock external; phc_resetn re-synchronised in tidelink_phc_cdc
   under either hclk or phc_clk depending on direction (already in RTL).
```

### 9.3 Replacement for `WavResetSync` in ASIC

The FPGA build uses Xilinx-specific reset synchronisers
(`WavResetSync` Chisel-generated). For ASIC, replace with a standard
two-flop async-assert / sync-deassert synchroniser per clock domain:

```
  module aon_rst_sync (
    input  wire clk,
    input  wire arst_n,       // async assert from POR / power FSM
    output wire srst_n        // sync deassert on clk
  );
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_q;
    always @(posedge clk or negedge arst_n)
      if (!arst_n) sync_q <= 2'b00;
      else         sync_q <= {sync_q[0], 1'b1};
    assign srst_n = sync_q[1];
  endmodule
```

Used at:

- `aon_resetn` for AON clock (32 kHz or chosen ref).
- `core_resetn` for `hclk`.
- `phy_resetn` for `user_hsclk` (Wlink high-speed clock).
- `phc_resetn` for `phc_clk` (existing; no change).
- Scan reset path (`scan_asyncrst_ctrl`, `tidelink_top.sv:170`) must
  cross into AON correctly — typically scan reset is OR-ed with
  `core_resetn` so the tester can hold scan in reset regardless of
  power state.

### 9.4 POR sequence

1. `VDD_IO` ramps first (board / PMIC sequencing).
2. `VDD_AON` ramps.
3. POR cell on `VDD_AON` releases — `aon_poresetn` deasserts after
   delay (~1 ms — vendor IP).
4. AON FSM enters `COLD_BOOT` state.
5. AON FSM asserts `SW_CORE.en`, waits VD, then `core_resetn`
   deasserts.
6. AON FSM asserts `SW_PHY.en`, waits VD, then `phy_resetn`
   deasserts.
7. Wlink role-strap latches; peer-mask handshake; `role_locked` →
   AON FSM enters `ACTIVE`.

Any subsequent `AON_ONLY → WAKE_SEQ` skips steps 1–4 (those rails
stay up) but follows steps 5–7 plus retention RESTORE between
SW\_ramp and reset-deassert.

---

## 10. UPF file structure (sketch)

```
##############################################################################
# tidelink_v1.upf  — TideLink v1 GPIO-PHY chiplet, IEEE 1801-2018 (UPF 3.0)
##############################################################################

set_design_top tidelink_top
set search_path [list . $::env(UPF_LIB_PATH)]

##############################################################################
# 1. Supplies
##############################################################################
create_supply_port VDD_IO            -direction in
create_supply_port VDD_CORE_EXT      -direction in
create_supply_port VDD_AON           -direction in
create_supply_port VSS               -direction in

create_supply_net  VDD_IO            -domain PD_IO
create_supply_net  VDD_AON           -domain PD_AON
create_supply_net  VDD_CORE          -domain PD_CORE
create_supply_net  VDD_CORE_PHY      -domain PD_PHY
create_supply_net  VSS               -domain PD_AON  -reuse
create_supply_net  VSS               -domain PD_CORE -reuse
create_supply_net  VSS               -domain PD_PHY  -reuse
create_supply_net  VSS               -domain PD_IO   -reuse

connect_supply_net VDD_IO       -ports VDD_IO
connect_supply_net VDD_AON      -ports VDD_AON
# VDD_CORE and VDD_CORE_PHY originate from the external VDD_CORE_EXT
# through on-die header switches SW_CORE / SW_PHY (see §3 below).

##############################################################################
# 2. Power domains
##############################################################################
create_power_domain PD_IO   -elements {u_pad_ring} -include_scope
create_power_domain PD_AON  -elements {u_aon}
create_power_domain PD_CORE -elements {u_tidelink_fifo u_fc_adapter u_xhb500_s u_xhb500_m \
                                       u_addr_xlat u_apb_regs u_ptp u_servo u_phc_cdc \
                                       u_perf u_chiplet_ctrl_core_part}
create_power_domain PD_PHY  -elements {u_chiplet_ctrl_phy_part u_wlink u_calibrator \
                                       u_idelay_rx u_rxclk_buf u_lane_checker}

##############################################################################
# 3. Supply sets + power switches
##############################################################################
create_supply_set PD_AON.primary  -function {power VDD_AON}      -function {ground VSS}
create_supply_set PD_CORE.primary -function {power VDD_CORE}     -function {ground VSS}
create_supply_set PD_PHY.primary  -function {power VDD_CORE_PHY} -function {ground VSS}
create_supply_set PD_IO.primary   -function {power VDD_IO}       -function {ground VSS}

create_power_switch SW_CORE \
    -domain PD_CORE \
    -input_supply_port  {vin  VDD_CORE_EXT} \
    -output_supply_port {vout VDD_CORE} \
    -control_port {sw_core_en u_aon/u_pwrctrl/sw_core_en} \
    -on_state  {ON  vin {sw_core_en}} \
    -off_state {OFF     {!sw_core_en}}

create_power_switch SW_PHY \
    -domain PD_PHY \
    -input_supply_port  {vin  VDD_CORE_EXT} \
    -output_supply_port {vout VDD_CORE_PHY} \
    -control_port {sw_phy_en u_aon/u_pwrctrl/sw_phy_en} \
    -on_state  {ON  vin {sw_phy_en}} \
    -off_state {OFF     {!sw_phy_en}}

##############################################################################
# 4. Power states
##############################################################################
add_power_state PD_AON.primary  -state {ON  -supply_expr {power == FULL_ON 1.00}}
add_power_state PD_CORE.primary -state {ON  -supply_expr {power == FULL_ON 1.00}}
add_power_state PD_CORE.primary -state {OFF -supply_expr {power == OFF}} -simstate CORRUPT
add_power_state PD_PHY.primary  -state {ON  -supply_expr {power == FULL_ON 1.00}}
add_power_state PD_PHY.primary  -state {OFF -supply_expr {power == OFF}} -simstate CORRUPT
add_power_state PD_IO.primary   -state {ON  -supply_expr {power == FULL_ON 3.30}}

##############################################################################
# 5. Isolation
##############################################################################
# CORE → AON outputs (clamp 0 by default; ack/ready get clamp 1)
set_isolation PD_CORE_ISO_OUT_TO_AON \
    -domain PD_CORE \
    -isolation_supply_set PD_AON.primary \
    -clamp_value 0 \
    -isolation_signal u_aon/u_pwrctrl/iso_en_core \
    -isolation_sense high \
    -location parent \
    -applies_to outputs

# CORE → PHY outputs
set_isolation PD_CORE_ISO_OUT_TO_PHY \
    -domain PD_CORE \
    -isolation_supply_set PD_AON.primary \
    -clamp_value 0 \
    -isolation_signal u_aon/u_pwrctrl/iso_en_phy \
    -isolation_sense high \
    -location parent \
    -applies_to outputs

# PHY → CORE outputs (clamp recovered-clock-gated)
set_isolation PD_PHY_ISO_OUT_TO_CORE \
    -domain PD_PHY \
    -isolation_supply_set PD_AON.primary \
    -clamp_value 0 \
    -isolation_signal u_aon/u_pwrctrl/iso_en_phy \
    -isolation_sense high \
    -location parent \
    -applies_to outputs

##############################################################################
# 6. Level shifters (auto across every {1.0V ↔ 3.3V} boundary)
##############################################################################
set_level_shifter PD_CORE_LS_TO_IO  -domain PD_CORE -applies_to outputs \
    -rule low_to_high -location parent
set_level_shifter PD_IO_LS_TO_CORE  -domain PD_CORE -applies_to inputs \
    -rule high_to_low -location parent
set_level_shifter PD_AON_LS_TO_IO   -domain PD_AON  -applies_to outputs \
    -rule low_to_high -location parent
set_level_shifter PD_IO_LS_TO_AON   -domain PD_AON  -applies_to inputs \
    -rule high_to_low -location parent
set_level_shifter PD_PHY_LS_TO_IO   -domain PD_PHY  -applies_to outputs \
    -rule low_to_high -location parent

##############################################################################
# 7. Retention (CORE-side only)
##############################################################################
set_retention PD_CORE_RET \
    -domain PD_CORE \
    -retention_supply_set PD_AON.primary \
    -save_signal    {u_aon/u_pwrctrl/ret_save_req    posedge} \
    -restore_signal {u_aon/u_pwrctrl/ret_restore_req posedge}

set_retention_elements PD_CORE_RET \
    -elements {u_chiplet_ctrl_core_part/role_locked_reg \
               u_chiplet_ctrl_core_part/swi_lane_status_reg* \
               u_chiplet_ctrl_core_part/swi_*_reg \
               u_addr_xlat/pair_base_addr_reg \
               u_servo/coeff_*_reg \
               u_servo/integrator_*_reg \
               u_apb_regs/cfg_*_reg \
               u_apb_regs/irq_en_*_reg}

# PD_PHY-side retention for calibrator-converged taps (small set on PHY but
# retention supplied from PD_AON):
set_retention PD_PHY_RET \
    -domain PD_PHY \
    -retention_supply_set PD_AON.primary \
    -save_signal    {u_aon/u_pwrctrl/ret_save_req    posedge} \
    -restore_signal {u_aon/u_pwrctrl/ret_restore_req posedge}
set_retention_elements PD_PHY_RET \
    -elements {u_calibrator/phase_reg* u_calibrator/slip_reg* \
               u_calibrator/converged_reg*}

##############################################################################
# 8. Static checks
##############################################################################
bind_checker -checker iso_completeness   -domain {PD_CORE PD_PHY}
bind_checker -checker ls_completeness    -domain {PD_CORE PD_PHY PD_AON PD_IO}
bind_checker -checker retention_coverage -domain {PD_CORE PD_PHY}
```

---

## 11. Power numbers (estimated, 22 nm, 25 °C, typical corner)

These are pre-synthesis estimates; refine after a first synthesis
pass with PrimeTime PX.

| State | Dynamic | Leakage | Total | Notes |
|---|---|---|---|---|
| `ACTIVE` (link saturated 200 Mb/s) | 4–8 mW (PD\_CORE) + 6–15 mW (PD\_PHY) + 0.05 mW (AON) | 0.4 mW (CORE+PHY+AON) | **~10–25 mW** | Worst case at 25 MHz hclk with all bridges running concurrently. PHY pad ring + LVCMOS33 drive is a large fraction. |
| `ACTIVE` (link idle but on, no traffic) | 1–2 mW (CORE clock distribution + idle Wlink) + 0.05 mW (AON) | 0.4 mW | **~2 mW** | Mostly clock distribution and Wlink idle-state TX of training bytes. |
| `AON_ONLY` (deep idle) | ~0 | **~30 µW (AON) + ~50 µW (PD\_CORE/PD\_PHY leakage through gated switches)** | **~80 µW** | I²C bus quiescent; AON FSM clock-gated, ref-osc running. |
| AON-only with I²C transaction in flight | ~10 µW switching | ~30 µW | **~40–60 µW transient** | 400 kHz I²C activity dominates briefly. |

Pad ring leakage is **not** included — that depends on board
termination and is bounded by 3.3 V open-drain pull-ups.

---

## 12. Effort + risk

### 12.1 Effort breakdown

| Phase | Duration | Owner | Deliverable |
|---|---|---|---|
| UPF authoring (full file, this doc as input) | 2–3 weeks | power-aware-flow eng | `tidelink_v1.upf` |
| RTL refactor for AON / power-controller / wake-decode FSM | 2 weeks | RTL eng (TideLink) | RTL changes on a `feat/td-power-aon` branch |
| Tool integration into Design Compiler + IC Compiler UPF flow (scripts, library setup, MV library characterisation) | 1–2 weeks | flow eng | updated synth + P&R scripts |
| Static UPF checking (Synopsys VC LP, Conformal LP — iso/ls/retention completeness, supply-set consistency) | 1–2 weeks | DV / power-aware-flow eng | clean static-check report |
| Low-power simulation (UPF-aware sim with PSON/PSOFF events, retention SAVE/RESTORE coverage) | 2 weeks | DV | regression suite + coverage |
| Post-CTS UPF re-validation, IR-drop sign-off | 1 week | P&R / sign-off | re-validation report |
| Formal CLP (Conformal Low Power) — equivalence between RTL + UPF and post-synth netlist | 1 week | formal eng | LP-equiv report |
| **Total** | **~6–8 weeks** elapsed (some phases overlap) | | |

### 12.2 Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `WavD2DGpioRx` recovered clock crossing into PD\_CORE clock tree is harder to gate cleanly than expected | M | H | Early CTS check; if it bites, add explicit clock-mux at CORE entry with a deglitcher (already in v0 RTL: `tidelink_rxclk_buf.sv`). Worst case, force PD\_PHY to stay on whenever the recovered RX clock fans into CORE. |
| Retention cell library not available at 22 nm | L | H | Get foundry confirmation before committing to retention; fall back to APB-replay (slower wake) if absent |
| AON I²C slave at 400 kHz becomes wake-latency bottleneck for credit-return loops | M | M | Document the 80 µs cost; offer a "skip-I²C" wake-on-strap mechanism (action item A4) |
| Peer-mask handshake migration from `hresetn` domain to AON breaks existing cocotb/UVM tests | M | M | Stage the refactor — keep `hresetn`-domain copy of the same regs for sim until the power-aware flow is silicon-validated; bridge via a strap |
| AON island leakage exceeds 50 µW budget at hot corner | L | M | Use high-Vt cells everywhere in AON; power-gate the JTAG TAP behind a sub-switch (`SW_TAP`) controlled by a strap |
| `set_retention` element list goes stale as RTL evolves | H | M | Use wildcard patterns (`*_reg*`) and pin them to a documented golden file; require Conformal-LP equivalence on every CI run |
| ISO cell on combinational logic boundary creates timing pinch | M | M | Re-floorplan during P&R; pre-budget timing with 5 % overhead per ISO insertion |
| Wlink Chisel-generated reset wiring (`WavResetSync`) does not synth cleanly with our standard-cell sync replacement | M | M | Replace at the Chisel level (vendor turnaround) or wrap in a SystemVerilog shim; either fits in the existing Wlink build flow |

---

## 13. Action items / open decisions

| # | Decision | Owner | Required by |
|---|---|---|---|
| A1 | **Single VDD vs split VDD\_CORE / VDD\_CORE\_PHY**: do we accept the PCB cost of two regulators for cleaner PHY-side noise, or keep one rail and rely solely on on-die header switches? Plan defaults to one external rail + on-die split. | systems / PCB | before package pin-out freeze |
| A2 | **PMU integration**: do we have an external PMIC driving sequenced rails, or is rail sequencing the SoC's job? Assumed external PMIC for v1. | systems | TBD |
| A3 | **Wake-byte address allocation**: pick a specific AON-side APB offset (0xFF in AON sub-decode by default). Confirm peer chiplet software follows the same convention. | RTL + SW | before silicon-validation tests are written |
| A4 | **External wake strap (`local_wake_req_i`)**: include as a chiplet port for host SoC to drive directly without I²C? Default plan: yes — costs one pad, saves 80 µs in latency-critical wake. | RTL | before package pin-out freeze |
| A5 | **JTAG TAP scope**: include all CORE / PHY scan chains via boundary scan, or keep TAP debug-only (no scan path in AON)? Default: include `scan_*` ports of `tidelink_top` in a bypass path. | DFT | before scan insertion |
| A6 | **Retention coverage on `addr_translator` CAM**: full retention vs replay-from-APB? Full retention adds ~256 retention flops; replay adds ~50 µs wake. Default: replay, with retention reserved for `pair_base_addr` only. | RTL + SW | before UPF freeze |
| A7 | **Idle-detect threshold default**: 1 ms recommended. Should this be APB-programmable per the existing register map (Region 2)? Default: yes, plus a register hook. | RTL + SW | before silicon-validation |
| A8 | **AON clock source**: on-die RC oscillator (cheap, ±20 % accuracy) or board-supplied 32 kHz XO? Default: on-die RC for v1 (≤20 % accuracy is fine for I²C decode timing). | RTL | before AON synthesis |
| A9 | **Library: foundry-provided AON / retention / ISO cells available?** Confirm cell list with foundry POC. Default assumption: standard 22 nm low-power kit. | flow eng | before UPF authoring begins |
| A10 | **DFT impact**: retention scan requires `_RET` cell types in scan chain; can our DFT signoff handle that? Confirm with DFT eng. Default assumption: yes (standard for any modern flow). | DFT | before retention element list freeze |

---

## 14. Cross-references

- `src/rtl/tidelink_top.sv` — top-level hierarchy and port list
  (1620 lines). The four domains map roughly to:
  - PD\_AON: derived from currently `poresetn`-domain registers
    (`axi_chiplet_controller.sv:295-313`) plus new AON instances.
  - PD\_CORE: `u_tidelink_fifo`, `u_fc_adapter`, `u_ptp`, `u_servo`,
    `u_phc_cdc`, plus XHB500 bridges and address translator.
  - PD\_PHY: `u_chiplet_ctrl/u_wlink` and the alignment infrastructure
    (`tidelink_phy_align_calibrator.sv`, `tidelink_idelay_rx.sv`,
    `tidelink_rxclk_buf.sv`).
  - PD\_IO: the pad ring (not in `tidelink_top.sv` — assumed in the
    chiplet-top pad-ring wrapper).
- `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:751`
  — current `wlink_por_reset = ~poresetn | ~role_locked` is the
  natural starting point for PD\_PHY's reset; in the power plan we
  add `phy_resetn` from the AON power-controller in parallel.
- `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:1003`
  — I²C slave instance, moves wholesale to PD\_AON.
- `deps/axi-chiplet-controller/logical/wlink/Wlink.v:1636-1637` —
  `sb_wake` (already exported) is the natural input to the power
  FSM "link traffic ahead" predictor (could trigger PRE-WAKE), and
  `tx_link_idle` is the link-idle source for the SLEEP\_SEQ entry
  condition.
- `docs/GPIO_PHY_ARCHITECTURE.md` — single-read reference for the
  GPIO PHY (forwarded-clock source-synchronous, 8 lanes, LVCMOS33,
  bank 13 / bank 35 pin map). Informs the PD\_PHY pad ring sizing
  (9 pads TX + 9 pads RX + IDELAYE2 ref-clock).

---

## 15. Glossary

| Term | Meaning |
|---|---|
| AON | Always-On (power domain) |
| ISO | Isolation cell (clamps domain-crossing signal during off-state) |
| LS | Level Shifter (translates between voltage domains) |
| LCG | Latch-based Clock Gate (here, used to gate the recovered RX clock at the PD\_PHY → PD\_CORE boundary) |
| MV | Multi-Voltage (synthesis library variants) |
| OD | Open-Drain (I²C pad style) |
| PSO | Power Shut-Off (UPF event in simulation) |
| PD | Power Domain |
| POR | Power-On Reset |
| RET | Retention cell (flop that survives PSO via separate VDDR) |
| UPF | Unified Power Format (IEEE 1801) |
| VD | Voltage Detector (rail-monitor IP that gates retention RESTORE) |
| XO | Crystal Oscillator (board-supplied reference clock) |

---

*End of plan.*
