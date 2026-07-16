# KR260 on-chip TideLink pair — authoritative implementation plan

Target: **`kr260-pair-onchip`** — one Kria KR260 (`xck26-sfvc784-2LV-c`) bitstream carrying **two complete
TideLink instances** cross-connected **entirely through the FPGA fabric** (no PHY signal reaches a pin), with the
I2C autoneg sideband also fabric-cross-connected so **genuine hardware role negotiation runs**.

This document is the single source of truth. It supersedes the eight independently-authored design sections
(`bd`, `addrmap`, `clocking`, `xdc`, `i2c`, `skew`, `host`, `gates`) wherever they disagree, adopting the
inter-section resolutions and the correctness/integration verdicts. It is written for engineers **and** for a fleet of
implementation agents executing the workstreams (§6) in parallel.

> **MISSING SECTIONS — READ FIRST.** Input A contained no standalone section for three subsystems that are on the
> critical path. They are called out here and given owners in §6:
> - **RTL + IP-repackaging** (the `tidelink_top.sv:2054-2055` un-hack + `NEGO_CFG_RESET`/`HONEST_MASK_HS` plumbing +
>   `package_ip`). The `i2c` section proposed the edit but nobody owned the packaging/re-validation end to end
>   (Input C, gap **G3**). → **W1**.
> - **Target wrapper** (the LED-only `tidelink_design_wrapper.v` for this target). Touched in passing by `bd`/`i2c`/`gates`,
>   owned by none. → **W4**.
> - **Reset topology / POR-skew** (single vs staggered `proc_sys_reset`). Undesigned (Input C, gap **G5**). Phase-1
>   accepts a shared reset; the staggered-reset lever is → **W12 (phase-2)**.

---

## 1. Goal and non-goals

### 1.1 What this target proves (the deliverable)
A cable-free on-chip pair that separates **"above the pad"** (protocol, flow-control, autoneg, calibrator, deskew,
CDC) from **"the channel"**. Concretely it proves, on real KR260 silicon, with **zero manual bring-up pokes**:

1. **Genuine autoneg** — two identical chiplets negotiate master/slave over a fabric-wired I2C bus, complete the
   **real peer-mask handshake** (not the bypass), and latch `role_lock` bilaterally.
2. **Bilateral data delivery** — byte-exact packets A→B and B→A through the FC/credit path.
3. **Lane-health regression detection** — all 8 lanes report SYNC (`sync_seen_vec == 0xFF`) on both dies.
4. **A clean timing closure** — deleting the pads deletes the source-synchronous WHS-hold class entirely
   (the loopback target closes at WHS +0.017 / 0 failing endpoints; the pinned kr260 pair had −22.4 ns / 8 hold).

### 1.2 What this target does NOT prove (do not overclaim)
- **The analog eye** — no ribbon, no real channel, no SI/crosstalk/reflections.
- **IDELAY per-lane trim** — `USE_IDELAY=0` is mandatory (no delay primitive on an internal net); there is no
  physical per-lane trim, only bit-slip × phase.
- **Bit-slip under real channel skew** — the fabric net has no eye to center against a real edge.
- **Metastability statistics / bit-level synchronizer margin** — both hclk and the recovered RX clock are synchronous
  children of one MMCM (`clk_out1`), so the CDC sample point is phase-static, not sliding.
- **Oscillator ppm drift** — one MMCM ⇒ **0 ppm** relative frequency offset between the two dies. The credit/elastic
  CDC (the exact layer of the last silicon bug, `fe_tx_credit_max`) is exercised only mesochronously at a static phase.
  A green FC result here does **not** re-validate that layer under the drift a real 2-crystal pair sees. (Input C **G6**.)
- **Inter-die POR skew** — one shared `proc_sys_reset` ⇒ 0 reset skew. The a2l ACK-ptr reset-skew (`sack=31`) class is
  **not** reproduced in phase-1. (Input C **G5**.)

It is **complementary** to the bench pair, not a replacement. Phase-2 workstreams (W11–W14) add the levers (skew
injector, staggered reset, second MMCM, XHB window) that push into the "not proven" list on demand.

---

## 2. Why now

- **Dead physical conductor.** die_a `pad_rx[7]` is a dead conductor on the bench pair; `sync_seen_vec = 0x64` vs golden
  `0xE4`. The eye is uncharacterised and lane-7 lottery entangles every result.
- **The last "CDC/SI" bug was flow control.** `fe_tx_credit_max` re-zeroed by the post-CR `swi_enable` dip blocked
  sustained A→B for weeks; **five sim-green fixes hardened an unbroken layer** (a2l/mailbox) while the real defect was
  above the pad. A cable-free pair isolates that class.
- **Autonomy is entangled with the eye.** Loop-14 anchor re-latch convergence and die_a RX SYNC-detect are gated by the
  channel; an on-chip pair lets autoneg genuineness be proven without the eye lottery.
- **No KR260 on the rig.** No board, no ribbon exists yet. This target needs **one** board and **no** cable — the fastest
  path to exercising the KR260 port at all.
- **Measured timing motivation.**

  | build | WNS | WHS | failing hold | note |
  |---|---|---|---|---|
  | pynq-z2-loopback | +1.505 | **+0.017** | **0** of 54,084 | XDC has **no** I/O-delay constraints |
  | pynq-z2-pair-all | +0.424 | −26.630 | 16 | source-sync pad class |
  | kr260-pair-nptp | +0.659 | −22.364 | 8 | source-sync pad class |

  Removing the pads deletes the failing-hold class (loopback proves it). This target inherits that.

---

## 3. Architecture (final, resolved)

### 3.1 Topology
- Two IP cells of the **same** packaged `soclabs.org:user:tidelink_vivado_wrapper:1.0`: `tidelink_0` (die_a, role-strap 0,
  master-by-priority) and `tidelink_1` (die_b, role-strap 1, slave-by-priority).
- **Data + forwarded clock cross-connect: direct `connect_bd_net` inside the BD** (phase-1). No pads, no wrapper wires,
  no new module file. (Resolution of Input C **G1**; supersedes `bd`'s `pad_skid` and `skew`'s injector-in-path for
  phase-1.)
- **I2C sideband: two `util_vector_logic:2.0` AND cells** (open-drain wired-AND) inside the BD. No pins, no new file.
  (Adopts `i2c` §2 over `bd`'s `tidelink_i2c_bus.v`.)
- Per instance: its own `/8` `phy_clk_div`, its own `ahb_mng` BRAM terminus, its own AXI4L→AHB/APB bridges, its own
  strap + debug-unlock GPIO. One shared PS, one `clk_wiz` MMCM, one `proc_sys_reset`.
- The two PS master ports fan out through the two existing SmartConnects widened in place: control `axi_smc`
  `NUM_MI 4→8`, data `axi_smc_data` `NUM_MI 2→4` (both ≤ the 16-MI PG247 limit). Do **not** add a second SmartConnect.
- PTP **off** (`FPGA_TIDELINK_PTP=0`) for phase-1 (two PHCs would double PHC area for no on-chip-pair benefit).
- Only external ports: `led0..led3` (2 per die: link_active + role_is_master).
- The four external pad ports (`pad_clk_tx/pad_tx/pad_clk_rx/pad_rx`, kr260-pair-ptp tcl:140-143) and six I2C ports
  (:151-156) are **not created**.

### 3.2 Canonical address map (THE table — bd, addrmap, host all consume this)
Uniform **inst1 = inst0 + 0x0800_0000** on every aperture (control and data). This is the only scheme under which the
host convention `inst1_addr = inst0_addr | 0x0800_0000` holds for every base (all inst0 bases have bit-27 clear).
inst0 rows are byte-identical to `kr260-pair-ptp/tidelink_design.tcl:900-920`.

| aperture | inst0 (die_a) | inst1 (die_b) | range | PS window |
|---|---|---|---|---|
| ahb_sub | `0x8000_0000` | `0x8800_0000` | `0x0400_0000` (64 MB) | HPM0_LPD |
| apb | `0x8403_0000` | `0x8C03_0000` | `0x0000_8000` | HPM0_LPD |
| strap GPIO | `0x8404_0000` | `0x8C04_0000` | `0x0000_1000` | HPM0_LPD |
| debug-unlock GPIO | `0x8404_1000` | `0x8C04_1000` | `0x0000_1000` | HPM0_LPD |
| ahb_tx | `0xA400_0000` | `0xAC00_0000` | `0x0001_0000` | HPM0_FPD |
| ahb_fifo | `0xA401_0000` | `0xAC01_0000` | `0x0001_0000` | HPM0_FPD |
| **PAIR_BASE bake** | **`0x8C03_2000`** | **`0x8403_2000`** | (register default) | — |

- Control all inside HPM0_LPD (`0x8000_0000–0x9FFF_FFFF`, 512 MB); data all inside HPM0_FPD
  (`0xA000_0000–0xAFFF_FFFF`, 256 MB). No overlap, above DDR (`<0x8000_0000`), below PS regs (`≥0xFD00_0000`).
- `ahb_mng` BRAM termini have **no** `assign_bd_address` (discretely wired). Their 4 KB (`AW=12`) decode ignores the
  base, so the asymmetric `0x80.../0x88...` ahb_sub bases are harmless at the terminus.
- **PAIR_BASE is correct and safe**: `fc_adapter.sv:347` ships only `rtn_haddr[13:0]`; both bakes share `[13:0]=0x2000`
  which selects APB region 01 (TideLink config), landing `+0x14/0x20/0x24` in the peer credit/doorbell regs. Distinct
  per-instance values are kept for host clarity; even a wrong high byte would deliver credits (fc `[13:0]`-only).

**`assign_bd_address` block (verbatim for W5):**
```tcl
# ---- Control plane (M_AXI_HPM0_LPD) ----
assign_bd_address -offset 0x80000000 -range 0x04000000 [get_bd_addr_segs {tidelink_0/ahb_sub/Reg}]
assign_bd_address -offset 0x84030000 -range 0x00008000 [get_bd_addr_segs {tidelink_0/apb/Reg}]
assign_bd_address -offset 0x84040000 -range 0x00001000 [get_bd_addr_segs {axi_gpio_strap/S_AXI/Reg}]
assign_bd_address -offset 0x84041000 -range 0x00001000 [get_bd_addr_segs {axi_gpio_debug_unlock/S_AXI/Reg}]
assign_bd_address -offset 0x88000000 -range 0x04000000 [get_bd_addr_segs {tidelink_1/ahb_sub/Reg}]
assign_bd_address -offset 0x8C030000 -range 0x00008000 [get_bd_addr_segs {tidelink_1/apb/Reg}]
assign_bd_address -offset 0x8C040000 -range 0x00001000 [get_bd_addr_segs {axi_gpio_strap_1/S_AXI/Reg}]
assign_bd_address -offset 0x8C041000 -range 0x00001000 [get_bd_addr_segs {axi_gpio_debug_unlock_1/S_AXI/Reg}]
# ---- Data plane (M_AXI_HPM0_FPD) ----
assign_bd_address -offset 0xA4000000 -range 0x00010000 [get_bd_addr_segs {tidelink_0/ahb_tx/Reg}]
assign_bd_address -offset 0xA4010000 -range 0x00010000 [get_bd_addr_segs {tidelink_0/ahb_fifo/Reg}]
assign_bd_address -offset 0xAC000000 -range 0x00010000 [get_bd_addr_segs {tidelink_1/ahb_tx/Reg}]
assign_bd_address -offset 0xAC010000 -range 0x00010000 [get_bd_addr_segs {tidelink_1/ahb_fifo/Reg}]
```
> nptp ⇒ **12** assigned segments (6/instance). With PTP it would be 16. `ahb_mng` BRAM has no segment.

### 3.3 IP configuration (both cells)
```tcl
set_property -dict [list \
    CONFIG.TIDELINK_PAIR_BASE {0x8C032000} \
    CONFIG.USE_IDELAY         {0}          \
    CONFIG.NEGO_CFG_RESET     {0x61}       \
    CONFIG.HONEST_MASK_HS     {1}          \
] [get_bd_cells tidelink_0]
set_property -dict [list \
    CONFIG.TIDELINK_PAIR_BASE {0x84032000} \
    CONFIG.USE_IDELAY         {0}          \
    CONFIG.NEGO_CFG_RESET     {0x61}       \
    CONFIG.HONEST_MASK_HS     {1}          \
] [get_bd_cells tidelink_1]
# USE_CLKBUF / USE_T3A left at packaged default 1 (real rxclk BUFG per recovered clock).
```
`NEGO_CFG_RESET` and `HONEST_MASK_HS` are **new** CONFIG params that W1 must add to the packaged IP (they do not exist
today). `USE_IDELAY` default is 1 (component.xml:3812) so the override to 0 is required.

### 3.4 Clocking (the definitive divider-phase answer)
- One `clk_wiz` MMCM: `clk_out1 = 25 MHz` (hclk + all AXI + both `phy_clk_div` inputs), `clk_out2 = 25 MHz` (phc, unused
  in nptp), `clk_out3 = 200 MHz` (**kept dormant** — the phase-2 injector clock; deleting it is a low-value optimisation
  that conflicts with W11, so we keep it. Resolution of Input C **G7**).
- **Two `/8` dividers, own BUFGs, both fed from `clk_out1`.** Each instance's recovered clock is a separate global route.
- **DEFINITIVE: two INIT=0 dividers are phase-IDENTICAL on FPGA, not "arbitrary static phase".** `tidelink_phy_clk_div2.v:51`
  is `reg [2:0] div_cnt = 3'b000` — a real FF INIT loaded by GSR. Two identical-INIT copies off one `clk_out1` run
  bit-identical forever ⇒ **zero relative skew**. The "own divider per instance" decision **alone does not defeat the
  zero-skew trap** (`clocking`/`skew` correct; `xdc` §0's "arbitrary static phase" premise is FALSE and is deleted).
- **Mitigation: give the two dividers different INIT_PHASE** (inst0 `3'b000`, inst1 `3'b011`). Because both are GSR-loaded
  and clocked identically, their outputs differ by a constant `((INIT1−INIT0) mod 8) × 40 ns = 120 ns` (of the 320 ns UI).
  This **decorrelates the two dies' clock domains** so the intra-die RX↔TX deskew/CDC runs with real static skew.
  It does **not** open the A→B/B→A capture eye (clock and data both launch from the same divider in a given direction —
  Input B #4) — see §4.

### 3.5 Where the capture eye comes from (phase-1: no injector)
**EVIDENCE-backed decision: phase-1 ships NO skew injector.** `WavD2DGpioRx.v:385-396` states static skew up to ±half a
word period is absorbed by construction ("no timing-constraint lottery remains"), and the existing V2 pair sim delivers
byte-exact data with **both dies on one shared zero-skew `ref_clk`**. So the PHY tolerates edge-aligned capture on a clean
fabric net. `set_bus_skew 2.0` bounds inter-lane skew so one calibrator setting locks all 8 lanes. (Resolution of Input C
**G4**; the `skew` section's "injector default opens the phase-1 eye" is demoted to phase-2.)

The **skew injector + `tidelink_skew_regs` AXI block is phase-2** (W11): programmable clk-to-data skew for eye
characterisation + stuck-lane/bit-error fault injection to validate `lane_health_preflight` on-chip.

### 3.6 I2C wired-AND (open-drain, fabric)
Both cores drive open-drain with `scl_o == scl_t == scl_o_reg` (release=1, drive-low=0) and register their inputs, so
`(t?1:o)` collapses to `o`, there is no `z`, and no zero-delay combinational loop. Model the pull-up as the AND's implicit
constant:
```tcl
foreach nm {scl sda} {
  set c [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 i2c_${nm}_wand]
  set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {and}] $c
  connect_bd_net [get_bd_pins tidelink_0/i2c_${nm}_o] [get_bd_pins i2c_${nm}_wand/Op1]
  connect_bd_net [get_bd_pins tidelink_1/i2c_${nm}_o] [get_bd_pins i2c_${nm}_wand/Op2]
  connect_bd_net [get_bd_pins i2c_${nm}_wand/Res]     [get_bd_pins tidelink_0/i2c_${nm}_i]
  connect_bd_net [get_bd_pins i2c_${nm}_wand/Res]     [get_bd_pins tidelink_1/i2c_${nm}_i]
}
# tidelink_{0,1}/i2c_{scl,sda}_t: left unconnected (o==t duplicate). Harmless lint, not a DRC error.
```
The wired-AND preserves slave clock-stretch (the SHORTCOMINGS-14a fix passes the slave open-drain SCL onto the bus). The
autoneg/I2C engines run on `apb_clk = hclk = clk_out1 = 25 MHz`, shared by both instances ⇒ the bus is a fully
synchronous same-clock net (~49 kHz), needs no `create_clock`/`false_path`. This is **not** the zero-skew trap (that trap
is the PHY forwarded clock, not the low-speed I2C sideband).

### 3.7 Data + forwarded-clock cross-connect (phase-1)
```tcl
connect_bd_net [get_bd_pins tidelink_0/pad_clk_tx] [get_bd_pins tidelink_1/pad_clk_rx]
connect_bd_net [get_bd_pins tidelink_0/pad_tx]     [get_bd_pins tidelink_1/pad_rx]
connect_bd_net [get_bd_pins tidelink_1/pad_clk_tx] [get_bd_pins tidelink_0/pad_clk_rx]
connect_bd_net [get_bd_pins tidelink_1/pad_tx]     [get_bd_pins tidelink_0/pad_rx]
```
The forwarded clock is a **direct** `phy_clk_div BUFG → wire → rxclk_buf BUFG` cascade (no IBUF, no injector in the clock
path). This is handled by `CLOCK_DEDICATED_ROUTE` in the XDC (§8/W6). In phase-2 the **data** lanes route through the
injector on `clk_out3`; the **clock** stays a direct wire (never resample the forwarded clock through `clk_sr[0]` — that
is not a passthrough).

---

## 4. The zero-skew trap (first-class)

**The trap.** If both instances shared one `phy_clk_div` net, `inst0.pad_clk_tx == inst1.pad_clk_rx` would be literally
one net — fully synchronous, zero skew, exercising neither deskew nor calibrator nor CDC. It would pass for the wrong
reason: the exact failure mode that produced five sim-green / silicon-red fixes.

**Why "own divider per instance" is not enough.** On FPGA, `div_cnt = 3'b000` is a GSR-loaded INIT. Two identical dividers
off one `clk_out1` are bit-identical forever ⇒ zero relative skew even though they are separate nets. (Verified:
`tidelink_phy_clk_div2.v:51`.)

**The agreed mitigation.** Give the two dividers **different INIT_PHASE** (inst0 `3'b000`, inst1 `3'b011` = +3 counts =
120 ns of the 320 ns UI), plus `dont_touch` on the counter so `opt_design` cannot merge them. This makes the two recovered
clock domains genuinely phase-offset, so the intra-die RX↔TX deskew/CDC runs with real static skew.

```verilog
`default_nettype none
module tidelink_phy_clk_div2 #(parameter [2:0] INIT_PHASE = 3'b000)
                             (input wire clk_in, output wire clk_out);
    (* keep = "true", dont_touch = "true" *) reg [2:0] div_cnt = INIT_PHASE;
    always @(posedge clk_in) div_cnt <= div_cnt + 3'b001;
    BUFG u_div_bufg (.I(div_cnt[2]), .O(clk_out));
endmodule
`default_nettype wire
```

**How we PROVE the offset is non-zero.** No host runtime read can catch a zero-skew collapse (autonomy, lanehealth, and
data all pass under zero skew). The proof must live in two places:
1. **Sim (blocking gate, W7):** `test_00_phase_is_nonzero` — probe the DUT's actual slave clock
   (`dut.u_slave.user_ref_clk`) and assert it differs from `dut.u_master.user_ref_clk` over a window (not two dangling
   testbench nets — see the anti-trap correction in the risk register).
2. **Synth netlist (W5/W6 exit gate):** `write_verilog`/`report_property` shows two distinct `div_cnt_reg` with INIT
   `000` and `011`, **not merged into one FF**.

**Honesty caveat (accepted risk).** One MMCM ⇒ 0 ppm drift, one reset ⇒ 0 POR skew. This mitigation exercises a fixed
mesochronous skew + the deskew FIFO + everything above the pad. It does **not** exercise drift, bit-level synchronizer
metastability, or reset skew. Phase-2 W12/W13 add those levers.

---

## 5. Hardware autonomy contract

Autonomy is a hard requirement: **a firmware recipe is not a deliverable** (David, 2026-07-06). The proof MUST NOT rely on
either bypass strap.

### 5.1 The autonomy blocker (BLOCKER — must be fixed in RTL)
`tidelink_top.sv:2054-2055` hardwires `.apb_debug_unlock_i(1'b1)` and `.mask_hs_bypass_i(1'b1)`, **discarding the module
ports at :357-358**. So `mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i | apb_debug_unlock_i`
(`local_overrides/axi_chiplet_controller.sv:614`) is permanently forced open — the BD baking `mask_hs_bypass=0` is a
**semantic no-op** and the "genuine handshake" cannot run. Fix (parameter-gated to protect the live Z2/ASIC single-die
campaign):
```verilog
// near NEGO_CFG_RESET param (tidelink_top.sv:123)
parameter bit HONEST_MASK_HS = 1'b0;      // 0 = legacy bench tie (single-die unchanged); 1 = drive from ports
// at u_chiplet_controller (replace the two 1'b1 ties at :2054-2055):
.apb_debug_unlock_i (HONEST_MASK_HS ? apb_debug_unlock_i : 1'b1),
.mask_hs_bypass_i   (HONEST_MASK_HS ? mask_hs_bypass_i   : 1'b1),
```
Single-die targets leave `HONEST_MASK_HS=0` (byte-identical behaviour). Only the two on-chip IP instances set it to 1.

### 5.2 Priority / NEGO_CFG — use 0x61, not 0x65
The **compiled** RTL already derives distinct priorities from the strap:
`local_overrides/axi_chiplet_controller.sv:657` = `nego_priority_reg <= role_strap_i ? 16'h0002 : 16'h0001`
(die_a strap 0 → 0x0001 = lower = master; die_b strap 1 → 0x0002 = slave). Therefore:
- Bake `NEGO_CFG_RESET = 0x61` = `nego_en | nego_force_lock | mask_hs_auto_en`, `pri_sel = 0` (selects
  `nego_priority_reg`, the strap-derived value). Autoneg is ON at POR ⇒ **true zero-poke**.
- **Drop** the `i2c` §4 Route-A scheme (`0x65` / `pri_sel=1` / `nego_priority_i` xlconstants). It is built on the stale
  `deps` copy (flat `0xFFFF`) and picks an unproven mux arm (Input C **G9**, `i2c` INTEGRATION verdict). The BD's baked
  `nego_priority_i = 0x8000/0x7FFF` becomes a harmless dead input under `pri_sel=0`.

### 5.3 The zero-poke bring-up sequence (host + sim)
With `NEGO_CFG_RESET=0x61` baked, bring-up is a **pure poll — zero writes**:
1. POR. Both dies read straps (0/1), derive priorities (0x0001/0x0002), enable autoneg.
2. Master (die_a) claims the I2C bus, writes the claim byte; die_b sees the SDA START, adopts slave.
3. Master runs the peer-mask read (`0x0214`) + crossover compare (all masks `0xFF` ⇒ MATCH) + verdict write (`0x021C`).
   Both dies reach `mask_hs_match = 1` **genuinely** (`HONEST_MASK_HS=1`, both bypass/unlock = 0).
4. `force_lock` latches `role_lock` bilaterally; Wlink leaves reset; link comes up.

### 5.4 Pass criteria (any deviation = FAIL, root-cause, do not paper over)
- Both instances: `STATUS(0x2108)` `[19:17] fcsm == 4` AND `[16] cal == 1`.
- `ROLE(0x2080)[0]` **complementary** between the two dies (exactly one master).
- **Positive handshake proof:** read `OBS_MASK_HS (apb+0x2194)` — `[19] mask_hs_match == 1` on both, and gate opened via
  match (`[20] gate_open == [19]`), **not** via a strap. (Host + sim both assert this. Without it, a vacuous pass hides a
  sham handshake — the `bd`/`gates` blocker.)
- `apb_debug_unlock` must be **0** throughout. If the link only comes up after a debug-unlock write, that is a RED FLAG
  (the handshake did not complete) — a bug to fix, not a workaround.

---

## 6. Workstreams (parallel-execution DAG)

Legend: **[RTL/tcl]** = no Vivado; **[Vivado]** = needs a Vivado/cocotb run; **[py]** = Python only.
Grouped by file to avoid write conflicts between parallel agents.

### W0 — Repo hygiene & branch [git]
- **Brief:** Land the untracked KR260 port so a fresh checkout builds; kill the phantom target; branch off **HEAD's
  lineage — NOT `origin/main`**.

> **CORRECTION (verified 2026-07-09, supersedes the original W0 text).** `origin/main` does **not** contain
> `fpga/farm_gate.sh`, `cocotb/tidelink_top_pair_v2/tb_top.sv`, or `cocotb/tidelink_top_pair_v2/pair_v2_common.py` —
> the exact tracked files W1/W7/W9 edit. HEAD is 118 commits ahead. `git checkout -b … origin/main` from this tree would
> **delete those files from the working tree** (they are committed-on-HEAD content, not uncommitted diffs). Base off the
> current branch lineage instead.
>
> **Isolation is mandatory, not advisory.** Six-plus sessions share this checkout, and at the time of writing another
> session is mid-edit on `cocotb/tidelink_top_pair_v2/Makefile` and `deps/tidelink-phy` — files W7/W9 also touch. Cut an
> isolated worktree; `imp/*` is gitignored (`.gitignore:98`), so the worktree gets its own `package_ip` state and W1
> cannot collide with a concurrent build.
>
> ```bash
> BASE=$(git rev-parse HEAD)          # must contain farm_gate.sh + the v2 pair harness
> git worktree add -b feat/kr260-pair-onchip ~/SoCLabs/td-bisect/kr260-onchip "$BASE"
> # sanity, before any agent runs:
> git -C ~/SoCLabs/td-bisect/kr260-onchip cat-file -e HEAD:fpga/farm_gate.sh
> git -C ~/SoCLabs/td-bisect/kr260-onchip cat-file -e HEAD:cocotb/tidelink_top_pair_v2/tb_top.sv
> ```
> (Never `/tmp` for worktrees — it fills with Vivado trees.)

- **Files:** commit `fpga/targets/kr260-pair-{ptp,nptp,flip-ptp,flip-nptp}/`, `fpga/targets/kr260_resync.sh`,
  `fpga/docs/KR260_PORT.md`, `pynq_host/scripts/kr260_smoke.py`, and the kr260 hunks of `fpga/Makefile` /
  `fpga/build_design.tcl` / `pynq_host/overlay.py`. Delete phantom `pynq-z2-loopback-ext` from `fpga/Makefile:51`
  (VALID_TARGETS), `:116-117` (XILINX_PART clause), and its help line (`:718`).
- **NEEDS OWNER CONFIRMATION — do not auto-delete.** `phy_clk_div2_FULL_DIFF.txt` is an untracked file this plan did not
  create, and `imp/fpga/{output,project}/pynq-z2-loopback-ext/` are build artefacts of a target that was never committed.
  Removing them is unrecoverable. Ask David before `rm`.
- **Deps:** none (Wave 0).
- **DoD:** worktree created off `$BASE`; `fpga/farm_gate.sh` and `cocotb/tidelink_top_pair_v2/tb_top.sv` both present in
  it; `grep -c loopback-ext fpga/Makefile == 0`; `git ls-files | grep -c targets/kr260-pair-ptp > 0`.
- **Verify:** `make -C fpga TARGET=pynq-z2-loopback-ext build_design 2>&1 | grep 'Unknown TARGET'`.

### W1 — RTL un-hack + IP repackage (**critical path, shared RTL**) [Vivado: package_ip]
- **Brief:** Make the mask handshake honest and autoneg-on-at-POR, without regressing single-die targets. Owner of the
  missing "rtl+packaging" subsystem (Input C **G3**).
- **Files:**
  - `src/rtl/tidelink_top.sv`: add `parameter bit HONEST_MASK_HS = 1'b0`; replace the `:2054-2055` ties per §5.1.
  - `fpga/vivado_ip/tidelink_vivado_wrapper.v`: add params `NEGO_CFG_RESET` (7-bit) and `HONEST_MASK_HS`; pass both into
    the `u_tidelink_top` instantiation (currently neither is plumbed → IP defaults `NEGO_CFG_RESET` to `7'h00`).
  - ~~`imp/fpga/tidelink_ip/component.xml`~~ — **DO NOT hand-edit.** Verified 2026-07-09: `imp/*` is gitignored
    (`.gitignore:98`) and `component.xml` is **untracked** — it is an *output* of `package_ip`
    (`fpga/vivado_ip/package_tidelink_ip.tcl`, whose header `:70-71` notes that `ipx::package_project` records the
    wrapper's parameter defaults automatically). Adding the two `parameter`s to the wrapper is sufficient; a hand-edit
    is regenerated away. Treat `component.xml` as a **post-condition to assert**, never a file to author.
  - Re-run `make -C fpga package_ip` with **`TIDELINK_PHY_V2=1` exported**. `package_ip` is gated by
    `check-wrapper-params` → `fpga/scripts/check_wrapper_params.sh`, which iterates only
    `USE_IDELAY USE_CLKBUF USE_T3A` (`:55`, `:92`) asserting each defaults to `1'b1`. The two new parameters are not in
    that list, so the guard will not trip — but do not perturb those three.
- **Deps:** none (Wave 1). Blocks W5 (needs the CONFIG params), W7 (sim needs the un-hack for the honest gate).
- **DoD:** `grep -c NEGO_CFG_RESET imp/fpga/tidelink_ip/component.xml > 0`; `grep -c HONEST_MASK_HS ...component.xml > 0`;
  single-die default (`HONEST_MASK_HS=0`) is byte-behaviour-identical (both ports still tie to `1'b1`).
- **Verify:** `export TIDELINK_PHY_V2=1 && make -C fpga package_ip && grep -rl 'tidelink_lane_deskew\|TIDELINK_PHY_V2'
  imp/fpga/tidelink_ip/src/ | head` (non-empty).
- **HARD RULE:** re-validate single-die Z2 behaviour before merging to any branch that feeds the live campaign (see Open
  Question OQ2).

### W2 — Canonical address spec [doc/tcl]
- **Brief:** Own the single address table (§3.2). Produce the `assign_bd_address` block (already written in §3.2) as the
  authoritative artifact both W5 and W8 copy verbatim.
- **Files:** none new; this is the §3.2 table + block. (Kept as a workstream so there is one owner and one review point.)
- **Deps:** none (Wave 1).
- **DoD:** every address in W5's `assign_bd_address` and W8's `INST` map is traceable to this table.
- **Verify:** a diff/assert that W5 offsets and W8 `INST[*]` values match the table (host step 6 assertion).

### W3 — Divider module (INIT_PHASE) [RTL, target-local]
- **Brief:** Author `fpga/targets/kr260-pair-onchip/tidelink_phy_clk_div2.v` per §4 (parameter `INIT_PHASE`, `keep`+
  `dont_touch`). Target-local copy only — no shared-RTL risk (6 per-target copies already exist).
- **Files:** create `fpga/targets/kr260-pair-onchip/tidelink_phy_clk_div2.v`.
- **Deps:** none (Wave 1).
- **DoD:** `xvlog -sv` elaborates; port list unchanged (`clk_in`/`clk_out`); default `INIT_PHASE=3'b000`.
- **Verify:** `grep -n INIT_PHASE fpga/targets/kr260-pair-onchip/tidelink_phy_clk_div2.v`.
- **Fallback (OQ3):** if a `-type module` BD cell cannot expose `CONFIG.INIT_PHASE` in Vivado 2024.1, ship a second file
  `tidelink_phy_clk_div2_b.v` with hard-coded `INIT_PHASE=3'b011` and add a guarded `add_files` block (see W9). The
  netlist DoD (two distinct un-merged INITs) is the real gate.

### W4 — Target wrapper (LED-only) [RTL, target-local]
- **Brief:** Author `fpga/targets/kr260-pair-onchip/tidelink_design_wrapper.v` exposing only `led0..led3`; no pad/I2C
  ports (the cross-connect is entirely in the BD). Owner of the missing "wrapper" subsystem.
- **Files:** create the wrapper (a trivial BD-instance + 4 LED ports). Also copy `tidelink_ahb_mng_bram.v` into the
  target dir (globbed at `build_design.tcl:274`).
- **Deps:** none (Wave 1).
- **DoD:** wrapper declares exactly `led0..led3`; no `pad_*`, no `i2c_*_io`.
- **Verify:** `grep -cE 'pad_|i2c_.*_io' fpga/targets/kr260-pair-onchip/tidelink_design_wrapper.v == 0`.

### W5 — BD tcl (the big integration file) [Vivado: validate_bd_design]

> **WAVE-1 EXIT GATE: GREEN (verified 2026-07-09, `package_ip` run in the worktree with `TIDELINK_PHY_V2=1`).**
> Verified structurally, not by "the build passed":
> - packaged `imp/fpga/tidelink_ip/src/tidelink_top.sv` contains `HONEST_MASK_HS` (×5) ⇒ **not a stale IP**;
> - `md5sum` of packaged `src/WavD2DGpio.v` **equals** `deps/tidelink-phy/rtl/wav/WavD2DGpio.v` (V2) and **differs from**
>   `src/rtl/local_overrides/WavD2DGpio.v` (V1) ⇒ **silent-V1 trap avoided**;
> - `NEGO_CFG_RESET` default `"0000000"`, `HONEST_MASK_HS` default `"0"` ⇒ **every existing target byte-unchanged**;
> - both carry `spirit:resolve="user"` ⇒ BD-overridable via `CONFIG.*`.
>
> **W5 LANDMINE — both new params are packaged as `spirit:format="bitString"`, not integers.**
> `component.xml:3852` (`bitStringLength="7"`) and `:3857` (`bitStringLength="1"`). A `CONFIG.NEGO_CFG_RESET {0x61}`
> override will not do what you mean. Use the bitString form, and note `0x61 == 7'b1100001` (bit0 `nego_en`=1;
> **bits[3:2] `pri_sel`=00**, which selects the strap-derived `nego_priority_reg`, NOT the `nego_priority_i` port):
> ```tcl
> set_property -dict [list \
>     CONFIG.NEGO_CFG_RESET {7'b1100001} \
>     CONFIG.HONEST_MASK_HS {1'b1}       \
>     CONFIG.USE_IDELAY     {0}          \
>     CONFIG.TIDELINK_PAIR_BASE {0x8C032000} \
> ] [get_bd_cells tidelink_0]
> ```
> (`tidelink_1` identical except `CONFIG.TIDELINK_PAIR_BASE {0x84032000}`.) After `validate_bd_design`, **assert** the
> values actually took: `get_property CONFIG.NEGO_CFG_RESET [get_bd_cells tidelink_0]`. A silently-coerced bitString
> that lands as `0000000` leaves autoneg OFF at POR and the pair simply never links — with no error anywhere.
>
> **And do NOT tie `apb_debug_unlock_i` / `mask_hs_bypass_i` high with an xlconstant.** With `HONEST_MASK_HS=1` those
> pins are live for the first time ever; strapping them re-opens `mask_hs_gate_open` and silently voids the autonomy
> proof (§5.4). The fork inherits an `axi_gpio_debug_unlock` cell — its GPIO defaults to 0 at reset, which is now
> *correct and load-bearing*, not a placebo.
- **Brief:** Author `fpga/targets/kr260-pair-onchip/tidelink_design.tcl`, forked from `kr260-pair-nptp`. Adds `tidelink_1`
  + `_1`-suffixed bridges/GPIOs/BRAM/divider/consts; widens SmartConnects (control 8, data 4); deletes the 4 pad + 6 I2C
  external ports; wires §3.7 data cross-connect + §3.6 I2C wired-AND; two dividers `phy_clk_div_0` (INIT 0) /
  `phy_clk_div_1` (INIT 3); §3.3 IP config; §3.2 `assign_bd_address`; §3.4 clocking; LEDs (led2/led3 **replace** the
  fork's inherited `tidelink_0/*_irq` LED nets — delete those first to avoid double-drive); PTP off.
- **Files:** create `fpga/targets/kr260-pair-onchip/tidelink_design.tcl`.
- **Deps:** **W1** (CONFIG param names), **W2** (addresses), **W3** (divider file), **W4** (wrapper). → Wave 2.
- **DoD:** `validate_bd_design` 0 criticals; `report_bd_address` lists all 12 segments, no overlap; `get_bd_ports` shows
  only `led0..led3`; `phy_clk_div_0/clk_out` and `phy_clk_div_1/clk_out` are **distinct** single-BUFG nets;
  `tidelink_0/pad_tx → tidelink_1/pad_rx` (no direct external port).
- **Verify:** run the BD tcl in `vivado -mode batch`; assert `validate_bd_design` returns 0 and the 12-segment address
  report.

### W6 — XDC trio [Vivado: build; xdc_lint: no Vivado]
> **STATUS 2026-07-16: OUTSTANDING — this is what blocks `kr260-pair-onchip`.**
> W1-W5/W8 landed (target dir has the BD tcl, wrapper, dividers, BRAM, addrmap;
> the cocotb test and the host runners exist), but the target dir contains **zero
> .xdc files** while every buildable target ships 3-4. `build_design.tcl` only
> *warns* on a missing pin/timing XDC and carries on, so the target is
> deliberately **kept out of `VALID_TARGETS`** and `fpga/Makefile` raises an
> explicit "NOT BUILDABLE — W6 outstanding" error for it rather than a generic
> "Unknown TARGET". Do W6, then W9, then delete that guard clause.

- **Brief:** Author `kr260_tidelink.xdc` (LEDs-only), `kr260_tidelink_timing.xdc` (§8 clock defs + groups + CDR),
  `kr260_tidelink_drc.xdc` (comb-loop waiver, header only). **Exact filenames** required by
  `build_design.tcl:310/318/333` globs — `*_onchip*.xdc` would be silently dropped.
- **Files:** create the three XDC in `fpga/targets/kr260-pair-onchip/`.
- **Deps:** **W5** (BD cell names `tidelink_0/1`, `phy_clk_div_0/1`, `u_rxclk_bufg`). → Wave 3.
- **DoD:** `grep -c 'get_ports pad_\|get_ports i2c\|set_input_delay\|set_output_delay\|IOB FALSE' == 0`;
  `grep -c create_generated_clock == 6`; `grep -c set_bus_skew == 2`; xdc_lint exits 0 (0 new findings vs baseline).
- **Verify:** `python3 cocotb/lint/xdc_lint.py fpga/targets/kr260-pair-onchip/` (exit 0). Post-synth: `report_clocks`
  lists `phy_clk_i0/i1 rxcap_clk_i0/i1 word_clk_i0/i1 clk_out1 clk_out2 clk_out3`; `check_timing` reports no
  unconstrained RX-capture endpoints; `report_bus_skew` met.

### W7 — Sim harness + blocking onchip test [cocotb: no Vivado]
- **Brief:** Add the honest-gate paired sim variant and the new blocking test. Co-owned with the harness.
- **Files:**
  - `cocotb/tidelink_top_pair_v2/tb_top.sv`: add `s_ref_clk` net + gate the slave `.user_ref_clk` on
    `TB_TOP_ONCHIP_REFCLK`; gate `m/s_mask_hs_bypass` **and** `m/s_apb_debug_unlock` to `1'b0` on `TB_TOP_MASK_HS`
    (both, not just bypass — else the gate is vacuous). Legacy (defines unset) is bit-identical; **guard the second-clock
    start so existing stages are truly unchanged** (declare `s_ref_clk` inside the `ifdef` so `hasattr` is false).
  - `cocotb/tidelink_top_pair_v2/pair_v2_common.py`: start `s_ref_clk` with a static phase offset (only when the define
    is set); add `run_bringup_zeropoke()` = **zero APB writes** (rely on `NEGO_CFG_RESET=0x61` baked). Base it on the
    existing V1 `test_10_autonomous_train_post_por.py` (Input C **G12**).
  - `cocotb/tidelink_top_pair_v2/Makefile`: add `ONCHIP_PHASE`/`BYPASS_AUTONEG`/`MASK_HS` → `+define+` passthroughs;
    extend the **actual** `SIM_BUILD` line (`:134`, preserving the existing `_anchor` term) with `_oc$(ONCHIP_PHASE)` and
    a `MASK_HS`/`BYPASS_AUTONEG` discriminator (or the toggles reuse a stale binary). Add the stage to `v2_gate` (`:147-152`).
  - `cocotb/tidelink_top_pair_v2/test_v2_onchip_pair.py`: `test_00` anti-trap (probe `dut.u_slave.user_ref_clk` vs
    `dut.u_master.user_ref_clk`, must differ); `test_01` zero-poke autoneg → complementary roles + `mask_hs_match`
    positively asserted (0x2194) + bilateral cal_done + CR/CRACK + FCSM=LINK_IDLE; assert the mask handshake **completes
    post-`role_lock`** (Bug-N1 non-recurrence, `local_overrides:2266-2288`, Input C **G13**); `test_02/03` byte-exact
    M↔S packets under the static phase.
- **Deps:** **W1** (the un-hack must be in the compiled sim RTL for the honest gate). → Wave 2.
- **DoD:** `EPOCH_PROFILE=zero ONCHIP_PHASE=3 BYPASS_AUTONEG=0 MASK_HS=1 MODULE=test_v2_onchip_pair make` → 0 failures;
  `test_00` fails if the two ref clocks are phase-locked.
- **Verify:** `cd cocotb/tidelink_top_pair_v2 && ... make 2>&1 | tail; grep -c '<failure\|<error' results.xml == 0`.

### W8 — Host runners [py: no Vivado]
- **Brief:** One ctypes `/dev/mem` runner for the dual-instance bitstream + a strictly-additive `overlay.py` change.
- **Files:**
  - `pynq_host/overlay.py`: **strictly additive** — add a `TidelinkRegs(bases, mmio, paired)` accessor + `_map_for(soc)`
    + `open_onchip_pair()` **without touching** the existing `TidelinkOverlay` class or module globals (protects the live
    Z2 campaign; avoid the multiple-inheritance MRO risk). The onchip host ahb_sub range must be **64 MB**, not the
    existing 256 MB (`overlay.py:61`), or inst0's window overlaps inst1's control apertures.
  - `pynq_host/scripts/kr260_onchip.py`: ctypes single-store `rd/wr` (per `kr260_smoke.py:70-77`; **no** `struct.pack_into`).
    Two-block `INST` map (§3.2). Subcommands: `smoke` (both apb/strap/debug only, ZynqMP undecoded-read gate, `--ptp`
    gate), `autonomy` (pure poll, §5.4, positive `mask_hs_match` read), `lanehealth` (force-SYNC both, read `0x215C`,
    golden `0xFF` both, regression verdict), `data` (gated behind `autonomy` + link-safe; **port the occupancy math from
    `link_delivery_proof.sh`**: `occupancy = 4096 − rd(0x200C)`, snapshot **before** send, **poll until it rises by N**,
    then pop — the host section's own inverted math is the correctness bug being fixed here, Input C **G11**). Read
    `pair_base` (apb+0x000) and assert it points at the peer before trusting delivery.
  - `pynq_host/scripts/kr260_onchip_smoke.py`: 3-line shim → `kr260_onchip.main(['smoke', ...])`.
- **Deps:** **W2** (addresses). → Wave 2.
- **DoD:** `python3 -m py_compile` passes; `grep -c pack_into kr260_onchip.py == 0`; `overlay.py` with `TIDELINK_SOC` unset
  still yields `APB_BASE==0x44030000` (Z2 unchanged).
- **Verify (hardware, later):** `sudo python3 kr260_onchip.py autonomy` → both fcsm==4/cal==1, roles complementary,
  `mask_hs_match==1`, **zero writes**.

### W9 — Makefile / farm_gate / build_design wiring [make: no Vivado to author]
- **Brief:** Register the target and the blocking sim stage.
- **Files:**
  - `fpga/Makefile`: add `kr260-pair-onchip` to VALID_TARGETS (`:51`); new clause after the `kr260-pair-flip-nptp` block
    (`:140-143`, before `mps3` at `:144`) with `XILINX_PART=xck26-sfvc784-2LV-c`,
    `FPGA_BOARD_PART=xilinx.com:kr260_som:part0:1.1`, `FPGA_TIDELINK_PTP=0`; add help lines for all 5 kr260 targets. **No**
    DEPLOY_STYLE/TIDELINK_SOC/artefact change — the `kr260-%` filter (**actual lines `:392-400`**, not `:357-365`) already
    routes to `pynq_overlay` / `kr260` / bit+hwh (no `tidelink.bin`).
  - `fpga/farm_gate.sh`: add `SIM_STAGE[onchip_pair]="EPOCH_PROFILE=zero ONCHIP_PHASE=3 BYPASS_AUTONEG=0 MASK_HS=1
    MODULE=test_v2_onchip_pair"` (`:321-329`) and append `onchip_pair` to `FUNCTIONAL_STAGES` (`:330`) — a new **blocking**
    stage, not a new tier.
  - `fpga/build_design.tcl`: **no base-case edit** (dividers/BRAM are same-named module-refs added once; cross-connect is
    `connect_bd_net` + `util_vector_logic`). **Phase-2 only:** the injector files (W11) require a **guarded** `add_files`
    block mirroring `:255-262`.
- **Deps:** **W5** (target dir), **W7** (test exists). → Wave 4.
- **DoD:** `make -C fpga TARGET=kr260-pair-onchip -pn deploy | grep DEPLOY_ARTEFACTS | grep -v tidelink.bin`;
  `grep -n onchip_pair fpga/farm_gate.sh` in both arrays.
- **Verify:** `make -C fpga TARGET=kr260-pair-onchip -n build_design` prints the target dir; `make farm_gate` green
  (after W1 package_ip).

### Phase-2 workstreams (deferred; do not block first link-up)
- **W11 — Skew injector** [RTL+tcl]: `tidelink_skew_inject.sv` (64-tap SRL on `clk_out3`, stuck-mask, eye_fault engine)
  + `tidelink_skew_regs.sv` (AXI4-Lite, base `0x8404_2000`; **data-delay reset default 0x20 lives in the reg block, not a
  dead module param**). Requires the guarded `add_files` in `build_design.tcl`. **Fix the eye_fault burst width** to whole
  bit-periods (4-bit `err_burst` on `clk_out3` = 1/64 UI, cannot flip a bit — Input C/`skew` verdict). Clock path stays a
  direct wire. Reproduces die_a `pad_rx[7]` (stuck-mask s2m bit 7 → `sync_seen_vec=0x64`) to validate
  `lane_health_preflight` with zero hardware.
- **W12 — Reset stagger** [tcl]: second `proc_sys_reset` or a reset-delay counter on inst_b to inject POR skew (Input C
  **G5**).
- **W13 — Frequency offset** [tcl]: clock inst_b's divider from a second MMCM/PLL at a slightly offset frequency to
  exercise drift/elastic-buffer (Input C **G6**).
- **W14 — XHB500 window host subcommand** [py]: `window` subcommand — write/read-back through inst_a `ahb_sub`
  (`0x8000_0000`), gated behind the link-safe check (Input C **G8**).

### DAG (compact)
```
W0
W1 ─┬─► W5 ─┬─► W6 ─┐
W2 ─┤       │       ├─► W9 ─► [SIM GATE W7] ─► package_ip verify ─► first Vivado build
W3 ─┤       │       │
W4 ─┘       │       │
W1 ─────────┴─► W7 ─┘        (W7 also feeds the sim gate)
W2 ─► W8 (independent of W5/W6; joins at the build wave)
Phase-2: W11,W12,W13,W14  (after first link-up)
```
Concurrent within a wave: {W1,W2,W3,W4} (Wave 1); {W5,W7,W8} (Wave 2); {W6} (Wave 3); {W9 + gates} (Wave 4).

---

## 7. Execution order (waves + exit gates)

- **Wave 0 — Hygiene.** W0. **Exit gate:** isolated worktree at `~/SoCLabs/td-bisect/kr260-onchip` on
  `feat/kr260-pair-onchip`, based on **HEAD's lineage, never `origin/main`** (see the W0 correction); `fpga/farm_gate.sh`
  + `cocotb/tidelink_top_pair_v2/tb_top.sv` present in it; `grep -c loopback-ext fpga/Makefile == 0`; kr260 scaffolding
  tracked.
- **Wave 1 — No-dependency authoring (parallel).** W1 (RTL+package_ip), W2 (addr spec), W3 (divider), W4 (wrapper).
  **Exit gate:** `package_ip` succeeds with `TIDELINK_PHY_V2=1` and the two new CONFIG params present; divider + wrapper
  elaborate; address table frozen.
- **Wave 2 — Integration authoring (parallel).** W5 (BD, needs W1/W2/W3/W4), W7 (sim, needs W1), W8 (host, needs W2).
  **Exit gate:** `validate_bd_design` 0 criticals + 12-segment address report; **sim gate `test_v2_onchip_pair` PASSES**
  (this is the blocking policy gate — no farm build kicks before it); host runners `py_compile` + `grep pack_into == 0`.
- **Wave 3 — Constraints.** W6 (XDC, needs W5). **Exit gate:** `xdc_lint` 0 new findings; post-synth `report_clocks`
  shows the 6 generated clocks; netlist shows two un-merged `div_cnt_reg` (INIT 000/011) — the **zero-skew proof**.
- **Wave 4 — Gate wiring + build.** W9. **Exit gate:** `make farm_gate` green (Tier-0.a marker check with
  `TIDELINK_PHY_V2=1`; `onchip_pair` stage passes); then the first `vivado` build — WHS ≥ 0, failing-hold class gone,
  manifest `phy_marker == V2`.
- **Wave 5 — Hardware (once a KR260 exists).** Deploy via `pynq.Overlay`; run W8 `smoke → autonomy → lanehealth → data`
  in order.
- **Phase-2 — On demand.** W11–W14.

---

## 8. Gates

### 8.1 Sim gate (blocking, policy)
Integrated paired-die cocotb sim MUST pass before any farm/bitstream build. The **new** blocking stage `onchip_pair`
runs `test_v2_onchip_pair.py` (W7) with `mask_hs_bypass=0 AND apb_debug_unlock=0` and a **static ref-clk phase offset** —
closing the shared-ref_clk zero-skew trap the existing v2 pair sim has. It is a new **stage** in `FUNCTIONAL_STAGES`, not
a new tier; it blocks every farm build (escape hatch for an emergency unrelated build:
`FARM_GATE_SIM_STAGES="data_zero reduced_lane bridge_bfm"`).

### 8.2 `TIDELINK_PHY_V2` package_ip sequence (silent-V1 trap)
```bash
export TIDELINK_PHY_V2=1                              # MUST precede package_ip
make -C fpga package_ip                               # bakes V2 RTL + new CONFIG params into imp/fpga/tidelink_ip/src/
make -C fpga TARGET=kr260-pair-onchip build_design    # re-verifies
```
- The V1/V2 split is carried **solely** by env `TIDELINK_PHY_V2`; fileset `verilog_define` does **not** persist into the
  packaged IP. If `package_ip` ran with the flag unset, V2 files are simply absent and no synth define recovers them.
- **The "md5" check is actually sha256** (`tl_verify_packaged_ip`, `build_provenance.tcl`). It sha256-compares each flist
  source vs its packaged copy and hard-fails on a **present-but-different** file (stale-edit trap). It does **NOT** fail on
  a *missing/absent* source (that is skipped/WARN) — **so a silent-V1 package PASSES `tl_verify_packaged_ip`.** The real
  catch is **`farm_gate.sh:233-273` Tier-0.a** (fails if `TIDELINK_PHY_V2` unset; greps packaged src for
  `tidelink_lane_deskew.sv`/`TIDELINK_PHY_V2`) + the manifest `phy_marker` stamp. Always run `make farm_gate`; never bypass
  it (the one prior KR260 build that shipped V1 had bypassed it).
- Manual check: `python3 -c "import json;print(json.load(open('imp/fpga/output/kr260-pair-onchip/tidelink_manifest.json'))['phy_marker'])"` → `V2`.

### 8.3 farm_gate + xdc_lint
- Tier-0.b runs `xdc_lint.py fpga/targets/` ratcheted vs `fpga/farm_gate_xdc_baseline.txt`; the onchip dir is linted
  automatically. Target: **zero** new findings (the stripped-pad XDC should introduce none).
- A residual `[get_ports pad_*]` also hard-fails the build via the Vivado message-gate promotions **12-4739** and
  **12-1411** (`build_design.tcl`). This is the gate working as intended.

---

## 9. Risk register

### 9.1 Blockers (must land; no build ships without them)

| # | Blocker | Lens that raised it | Resolution |
|---|---|---|---|
| B1 | `tidelink_top.sv:2054-2055` hardwires `apb_debug_unlock_i`/`mask_hs_bypass_i` to `1'b1` → BD `mask_hs_bypass=0` is a no-op; the "genuine handshake" cannot run (the autonomy deliverable). | bd CORRECTNESS; i2c CORRECTNESS | **W1** un-hack, parameter-gated `HONEST_MASK_HS` (default 0 = single-die unchanged; 1 on onchip cells). |
| B2 | inst1 **data-plane** aperture disagreed 3 ways (bd 0xA800, addrmap 0xAC00, host 0xA402) → host reads a wedged/undecoded ZynqMP aperture (no-timeout AXI hang). | Input B #1 | **addrmap wins**: uniform +0x0800_0000 → inst1 ahb_tx `0xAC00_0000`, ahb_fifo `0xAC01_0000`. bd + host **W2/W5/W8** adopt verbatim. |
| B3 | Two INIT=0 dividers are phase-IDENTICAL on FPGA (zero skew) — "own divider" alone does NOT defeat the trap; `xdc`'s "arbitrary static phase" premise is FALSE. | clocking CORRECTNESS; Input B #3 | **Different INIT_PHASE** (0 vs 3) via W3 + `dont_touch`; PROVE non-zero in sim (`test_00`, probe DUT slave clock) and netlist (two un-merged `div_cnt_reg` INIT 000/011). |
| B4 | Cross-connect designed 3 incompatible ways (`pad_skid` / `skew_inject` / `util_vector_logic`); `build_design.tcl` has **no wildcard glob**, so any un-added module-ref elaborates as a black box → BD generation dies. | bd INTEGRATION; Input C G1 | **Phase-1: no new .v** — direct `connect_bd_net` (data) + `util_vector_logic` (I2C). Phase-2 injector requires the guarded `add_files` (W11). |
| B5 | gates sim stage left `apb_debug_unlock=1` (only drove `mask_hs_bypass=0`) → the blocking gate passes for the wrong reason (vacuous). | gates INTEGRATION | **W7** drives **both** to 0 and asserts `mask_hs_match` (0x2194) positively. |
| B6 | With `NEGO_CFG_RESET=7'h00` (packaged default) the FPGA FSM sits in bypass at POR and never self-negotiates without a poke → "firmware recipe, not a deliverable". | gates INTEGRATION | **W1** bakes `NEGO_CFG_RESET=0x61` → autoneg-on-at-POR → **true zero-poke**. |
| B7 | Host `data` occupancy math inverted (`0x200C` is FREE credits, not occupancy) and pops before arrival → the primary delivery metric never reads `+N`. | host CORRECTNESS/INTEGRATION | **W8** ports `link_delivery_proof.sh`: `occupancy = 4096 − rd(0x200C)`, snapshot before, poll-until-rise-by-N, then pop. |

### 9.2 Medium risks

| # | Risk | Lens | Handling |
|---|---|---|---|
| M1 | Un-hacking `tidelink_top.sv` makes the (currently vestigial) `apb_debug_unlock` GPIO poke load-bearing for single-die bring-up → live Z2/KR260 deploys that relied on the free `1'b1` silently lose `role_lock`. | i2c INTEGRATION | Parameter-gate (`HONEST_MASK_HS=0` default) keeps single-die byte-identical; **re-validate single-die HW before merge** (OQ2). |
| M2 | BUFGCE clock-region pressure (~30–37 BUFGCE for two instances; 24/region limit) + `BUFG→wire→BUFG` cascade CDR. | bd/clocking/xdc (all flagged) | `CLOCK_DEDICATED_ROUTE ANY` on both `u_rxclk_bufg/I` (W6); pblock each instance into its own clock region — **query the real xck26 grid first** (OQ4/`get_clock_regions`); post-place gate: BUFGCE/region < 24. |
| M3 | `set_max_delay -datapath_only` does NOT survive a `set_clock_groups -asynchronous` cut (clock-groups outrank max_delay). | xdc CORRECTNESS | Do **not** async-group the source-sync launch↔capture pair. Group by net-channel: `{phy_clk_i0,word_clk_i0,rxcap_clk_i1}` (A→B), `{phy_clk_i1,word_clk_i1,rxcap_clk_i0}` (B→A), `hclk` alone, `clk_out3` alone. `set_bus_skew` (immune to clock-groups) is the load-bearing inter-lane bound. |
| M4 | RX capture clock relies on generated-clock propagation across the fabric clock gate → RX flops could be unconstrained (vacuous green). | xdc INTEGRATION | Define `rxcap_clk_i0/i1` **explicitly** on the `u_rxclk_bufg/O` pins (W6); add `check_timing` no-unconstrained-endpoint gate. |
| M5 | `tl_verify_packaged_ip` passes a silent-V1 package (missing files = skip, not fail). | gates | Always `make farm_gate` (Tier-0.a) with `TIDELINK_PHY_V2=1`; confirm manifest `phy_marker==V2`. |
| M6 | ctypes `.value=` store may not be a single 32-bit store on the AHB_TX path (the 5-store credit-ceiling bug's actual site); `kr260_smoke` idiom was only proven on config regs. | host INTEGRATION | Use the `tl39.py`/`tl_poke.py` cast-to-`POINTER(c_uint32)` idiom for the AHB_TX path in W8. |
| M7 | Stale sim doc: `tb_top.sv:938-989` describes Bug-N1 as unfixed, but it IS fixed (`local_overrides:2266-2288`); the genuine handshake with `force_lock=1` walks exactly those post-lock states. | Input C G13 | W7 asserts the FSM completes the mask handshake post-`role_lock` (no hang in `AXL_WR_RESP`). |
| M8 | `SIM_BUILD` edit could drop the existing `_anchor` term → anchor-on/off builds collide (stale recompile). | gates CORRECTNESS | Append `_oc$(ONCHIP_PHASE)` to the **actual** line 134, preserving `_anchor`; add `MASK_HS`/`BYPASS_AUTONEG` to the key. |

### 9.3 Accepted risks (phase-1)
- **AR1 — 0 ppm drift (one MMCM).** The FC/credit CDC is exercised only mesochronously. ACCEPTED for phase-1; the exact
  layer of the last silicon bug is not re-validated under drift. Phase-2 **W13**. (Input C G6.)
- **AR2 — 0 POR skew (one reset).** The a2l ACK-ptr reset-skew (`sack=31`) class is not reproduced. ACCEPTED; phase-2 **W12**. (Input C G5.)
- **AR3 — No eye characterisation / no injector in phase-1.** Rely on the PHY's ±half-word zero-skew tolerance
  (`WavD2DGpioRx.v:385-396`) + `set_bus_skew`. ACCEPTED; phase-2 **W11**. (Input C G4.)
- **AR4 — INIT_PHASE CONFIG override on a `-type module` cell may be unsupported in Vivado 2024.1.** Mitigated by the
  two-file fallback (W3); the netlist DoD (two un-merged INITs) is the real gate.

---

## 10. Open questions (need David)

1. **OQ1 — Phase-1 scope of the skew injector.** Recommendation: **defer** the programmable injector + `tidelink_skew_regs`
   to phase-2 (the PHY tolerates zero-skew capture by construction; the injector is for eye characterisation + fault
   injection, not first link-up). Confirm we ship the first bitstream **without** it. *(Changes W5/W9/W11 scope.)*
2. **OQ2 — Un-hack blast radius.** The `HONEST_MASK_HS` param-gate keeps single-die byte-identical, but the change lands in
   `src/rtl/tidelink_top.sv` (compiled by every target) and re-packages the shared IP. **Do we require a single-die Z2
   hardware re-validation before merging to any branch feeding the live campaign?** *(Gates the merge; affects schedule.)*
3. **OQ3 — Divider INIT via CONFIG param vs two files.** Accept the `-type module` `CONFIG.INIT_PHASE` override, or mandate
   the two-file (`_a`/`_b`) fallback up-front to avoid a mid-build Vivado surprise? *(Changes W3 + possibly W9's
   `build_design.tcl`.)*
4. **OQ4 — Floorplan.** The pblock region names are placeholders until we query the real xck26 clock-region grid. Do we
   pre-emptively pblock each instance into its own clock region, or build once un-floorplanned and only pblock if
   place_design hits the 24-BUFGCE/region limit? *(Changes W6.)*

---

## 11. Appendix: evidence (file:line, grouped by claim)

**Autonomy blocker / mask handshake**
- `src/rtl/tidelink_top.sv:357-358` (ports), `:2054-2055` (hardwired `1'b1`), `:123` (`NEGO_CFG_RESET=7'h00`),
  `:2030` (plumbed to controller).
- `src/rtl/local_overrides/axi_chiplet_controller.sv:614` (`mask_hs_gate_open`), `:603` (`mask_hs_match`),
  `:2492-2496,:2546` (NEGO_CFG decode), `:645` (`nego_cfg_reg<=NEGO_CFG_RESET`), `:657`
  (`nego_priority_reg <= role_strap_i ? 16'h0002 : 16'h0001`), `:2266-2288` (Bug-N1 fix `mask_hs_in_progress`),
  `:2025` (gate_open obs), `:1843` (`0x215C` sync_seen_vec decode).
- `fpga/vivado_ip/tidelink_vivado_wrapper.v` — `NEGO_CFG_RESET`/`HONEST_MASK_HS` absent (grep → 0).

**Zero-skew / clocking**
- `fpga/targets/kr260-pair-ptp/tidelink_phy_clk_div2.v:51` (`div_cnt = 3'b000`), `:53-61` (counter + `BUFG u_div_bufg`),
  `:39-40` (single-divider "phase don't-care" comment — ASIC-only).
- `fpga/targets/kr260-pair-ptp/tidelink_design.tcl:602-635` (one clk_wiz; `clk_out1` feeds hclk + both dividers;
  `clk_out3=200 MHz` idelay), `:279-280` (phy_clk_div module-ref), `:621-623` (divider→user_ref_clk+scan_clk).
- `src/rtl/tidelink_rxclk_buf.sv:53` (`USE_CLKBUF`), `:64-72` (BUFG on USE_CLKBUF=1).
- `deps/tidelink-phy/rtl/wav/WavD2DGpioRx.v:385-396` (zero-skew tolerated by construction).
- `deps/tidelink-phy/rtl/wav/WavD2DGpioTx.v:503` (combinational `io_pad_clk` forward via WavClockGate — fabric, not BUFG).

**Address map / PAIR_BASE / FC**
- `fpga/targets/kr260-pair-ptp/tidelink_design.tcl:900-920` (inst0 assign_bd_address), `:883-885` (HPM0_LPD 512 MB /
  HPM0_FPD 256 MB), `:431-434` (CONFIG pattern).
- `src/rtl/fifo/tidelink_apb_regs.sv:226` (pair_base reset default), `:236` (RW while !ctrl_lock), `:214-219` (ctrl_lock
  write-once).
- `src/rtl/fifo/tidelink_fifo.sv:194-196` (`PAIR_* = pair_base + 0x20/0x24/0x14`).
- `src/rtl/tidelink_fc_adapter.sv:347` (`rtn_addr_offset = rtn_haddr[13:0]`), `:651` (`fc_rx_cfg_paddr`).
- `fpga/targets/kr260-pair-ptp/tidelink_ahb_mng_bram.v:19,:48` (`AW=12`, low-12-bit decode).
- `imp/fpga/tidelink_ip/component.xml:3812` (USE_IDELAY default 1), `:3817` (USE_CLKBUF 1), `:3822` (USE_T3A 1),
  `:3847` (BYPASS_ADDR_XLAT 0).

**I2C wired-AND**
- `deps/axi-chiplet-controller/logical/i2c/rtl/i2c_master.v:283-286` (`scl_o==scl_t==scl_o_reg`), `:264` (reset 1'b1),
  `:865-866` (registered inputs), `:162-167` (interconnect example), `:180-181` ("do not connect scl_o to scl_i directly").
- `i2c_slave.v:230-233,:202-206`.
- `local_overrides/axi_chiplet_controller.sv` I2C pin mux (`~:2474-2483`), `:614` gate.

**XDC / pads to delete**
- `fpga/targets/kr260-pair-ptp/kr260_tidelink_timing.xdc:141` (create_clock pad_clk_rx), `:181` (pad_clk_tx_fwd),
  `:200-201` (set_output_delay pad_tx), `:221-222` (set_input_delay pad_rx), `:241` (set_bus_skew), `:273` (IOB FALSE),
  `:312-314` (`user_ref_clk_div2` /8), `:328-330` (word clk /16), `:351-355` (4-group set_clock_groups).
- `fpga/targets/kr260-pair-ptp/kr260_tidelink.xdc:39-59` (18 link LOCs), `:65-66` (2 I2C LOCs), `:71-74` (4 LED LOCs).
- `fpga/targets/pynq-z2-loopback/pynq_z2_tidelink.xdc:33-36` (LEDs-only shape).

**Build / gates**
- `fpga/build_design.tcl:255,:274,:305` (exact-filename globs — no wildcard), `:310/:318/:333` (XDC suffix globs),
  `:71/:75/:101` (msg-gate ERROR promotions 18-359 / 12-4739 / 12-1411), `:385` (tl_verify_packaged_ip),
  `:402-418` (synth `-verilog_define`), `:540` (tl_write_manifest).
- `fpga/scripts/build_provenance.tcl:164-247` (sha256 content-match; missing=skip/WARN), `:253-302` (manifest phy_marker).
- `fpga/farm_gate.sh:233-273` (Tier-0.a silent-V1), `:288-289` (xdc_lint ratchet), `:321-330` (SIM_STAGE +
  FUNCTIONAL_STAGES).
- `fpga/Makefile:51` (VALID_TARGETS), `:116-117` (phantom loopback-ext clause), `:128-146` (kr260 blocks),
  `:392-400` (kr260-% deploy filter), `:718` (loopback-ext help line).
- `cocotb/tidelink_top_pair_v2/Makefile:134` (SIM_BUILD), `:147-152` (v2_gate); `tb_top.sv:153/:728` (shared ref_clk),
  `:174-175` (apb_debug_unlock=1), `:178-179` (mask_hs_bypass=1), `:938-989` (force-autoneg + stale Bug-N1 comment).

**Host**
- `pynq_host/overlay.py:42-57` (single-instance globals), `:61` (AHB_SUB_RANGE 0x1000_0000 = 256 MB), `:124-134`
  (six MMIOs), `:365-395` (assert_link_safe_for_tx).
- `pynq_host/scripts/kr260_smoke.py:16-21` (undecoded-read AXI hang), `:70-77` (ctypes store).
- `pynq_host/scripts/tl39.py:66` (0x200C = free credits, NOT occupancy), `:87-88` (cal/fcsm decode).
- `pynq_host/scripts/link_delivery_proof.sh:68,:74,:92-93,:132-142` (occupancy = MAX_CREDITS − credit_count; poll-before-pop).
- `pynq_host/scripts/tl_poke.py:53-73` (5-store vs single-store), `tl39.py:38-46` (cast-to-POINTER store).
- `src/rtl/local_overrides/WlinkGenericFCSM_6.v:2064-2071` (FCSMCAP packing), `:2069` (`[19:16]` reserved on this branch).

**Timing (measured, established facts)**
- pynq-z2-loopback WHS +0.017 / 0 failing; kr260-pair-nptp WHS −22.364 / 8 hold; pynq-z2-pair-all WHS −26.630 / 16 hold.
