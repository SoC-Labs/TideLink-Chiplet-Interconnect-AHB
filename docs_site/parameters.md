# Parameters

The complete parameter reference for `tidelink_top`, the packaged Vivado IP
wrapper, and the ASIC DFT wrapper — extracted from the RTL in this checkout
(branch `fix/z2-drop-park-hook` @ `9eaafb7`), not from prose.

For where these parameters sit in a build, see [Integration](integration.md).

:::{important}
**Counts, verified.** `tidelink_top` (`src/rtl/tidelink_top.sv`) declares
**30** parameters between `module tidelink_top #(` at line 37 and the port list
at line 230. `tidelink_vivado_wrapper` (`fpga/vivado_ip/tidelink_vivado_wrapper.v`)
declares **22**. Older material — including some in-repo docs — quotes 43; that
number does not match this RTL.
:::

---

## 1. How a parameter reaches the netlist

This is the single rule the rest of the page hangs off:

:::{danger}
**A `+define+` / `-verilog_define` never reaches a packaged IP's out-of-context
synthesis. A wrapper *parameter default*, recorded in `component.xml` by
`ipx::package_project`, does.**

So a knob that must be settable on FPGA has to appear as a **parameter on the
`tidelink_vivado_wrapper` face**. It is not enough for it to exist on
`tidelink_top`. The wrapper file documents this failure three separate times
(`tidelink_vivado_wrapper.v:64-72`, `:119-141`, `:169-201`) because it has
happened three separate times.
:::

The consequence chain, in the order the value travels:

```text
BD instance  set_property CONFIG.<PARAM>   (per-target, per-instance override)
   └─> packaged IP component.xml           (resolve="user" entry)
        └─> tidelink_vivado_wrapper param
             └─> tidelink_top param
                  └─> axi_chiplet_controller / Wlink / WlinkGPIOPHY_v2 / …
```

Break any link and the value silently reverts to the default below it — with no
error, no warning, and a bitstream that looks fine.

---

## 2. `tidelink_top` — complete parameter table

Source: `src/rtl/tidelink_top.sv:39-229`. "IP face" = whether the parameter is
exposed on `tidelink_vivado_wrapper` and therefore settable per BD instance.

| # | Parameter | Line | Default | Legal values | IP face | Effect |
|---|---|---|---|---|---|---|
| 1 | `SYS_ADDR_W` | 39 | `32` | 32 | ✅ | System address width (`ahb_sub`, `ahb_mng`). |
| 2 | `SYS_DATA_W` | 40 | `32` | 32 | ✅ | System data width. |
| 3 | `RAM_ADDR_W` | 43 | `14` | ≥ 4 | ✅ | FIFO SRAM address width. 14 ⇒ 16 KB FIFO **and** 16 KB TX aperture. Sets the credit depth — see [§7](#7-depth-and-geometry-parameters-are-not-free). |
| 4 | `RAM_DATA_W` | 44 | `32` | 32 | ❌ (wrapper hardwires `SYS_DATA_W`) | FIFO SRAM data width. |
| 5 | `APB_ADDR_W` | 45 | `12` | 12 | ❌ (wrapper hardwires `12`) | APB register address width inside the TideLink region. |
| 6 | `FC_DATA_W` | 48 | `48` | 48 | ✅ | FC-node word width. **Must match `WlinkGenericFCSM_6`** — changing it needs a Chisel regen. |
| 7 | `NUM_PHY_LANES` | 51 | `8` | 1 or 8 | ✅ | GPIO PHY lane count; sets `pad_tx`/`pad_rx` width. |
| 8 | `TIDELINK_PAIR_BASE` | 54 | `'0` | any 32-bit address | ✅ (wrapper default `32'h44032000`) | POR value of `PAIR_BASE_ADDR` @ `0x2000`; the returner derives peer targets from it. Runtime-overridable. |
| 9 | `PHC_LOCK_GATE_EN` | 58 | `0` | 0 / 1 | ✅ | 1 gates the PTP HW-sync initiator on `phc_locked_i` (multi-hop chaining). 0 = no gating. |
| 10 | `USE_IDELAY` | 65 | `1'b0` | 0 / 1 | ✅ (wrapper default `1'b1`) | Per-lane Xilinx `IDELAYE2` RX delay driven by the calibrator. 0 = bit-exact passthrough (sim/ASIC). |
| 11 | `USE_CLKBUF` | 68 | `1'b0` | 0 / 1 | ✅ (wrapper default `1'b1`) | Forward the recovered RX clock through a global BUFG instead of a fabric LUT path. |
| 12 | `USE_T3A` | 74 | `1'b0` | 0 / 1 | ✅ (wrapper default `1'b1`) | Per-lane self-aligning RX comma hunt — each `WavD2DGpioRx` slips `count` once per `io_por_reset`, killing the per-deploy 16-cycle phase lottery. |
| 13 | `EPOCH_ANCHOR_EN` | 84 | `1'b0` | 0 / 1 | ✅ (wrapper default `1'b0`) | Selects **which cross-lane deskew corrector is compiled** (V2 only). See [§6.1](#61-epoch_anchor_en-and-the-auto_anchor_en-naming-correction). |
| 14 | `USE_PHY_V2` | 94 | `1'b0` | **0 only** | ❌ | S2 scaffold. The `g_phy_v2` generate arm is an empty placeholder. **Do not set to 1.** |
| 15 | `HARDEN_SWI_ENABLE` | 103 | `1'b1` | 0 / 1 | ✅ | Forces `swi_enable=1` on any APB write asserting `swi_swreset=1` to Wlink `0x208`, protecting the 7 FCSMs from a `{swreset=1, swi_enable=0}` write that would return them all to IDLE and lose CR/CRACK sticky state. |
| 16 | `STUB_SERVO` | 114 | `1'b0` | 0 / 1 | ✅ | Replace `u_servo` (`tidelink_ptp_servo`) with tie-offs. |
| 17 | `STUB_PERF` | 115 | `1'b0` | 0 / 1 | ✅ | Replace `u_perf` (`tidelink_perf`) with tie-offs. |
| 18 | `STUB_PTP` | 116 | `1'b0` | 0 / 1 | ✅ | Replace `u_ptp` with tie-offs. **Requires `STUB_SERVO=1`** — the servo waits on `dreq_tx_done` from PTP. |
| 19 | `BYPASS_ADDR_XLAT` | 117 | `1'b0` | 0 / 1 | ✅ | Replace `u_addr_translator` with a passthrough. |
| 20 | `TXGEN_PRESENT` | 122 | `1'b1` | 0 / 1 | ❌ | Instantiate the PL-side TX traffic generator (`tidelink_tx_gen`). At 0 the block **and** its ownership mux are removed by the generate, so the netlist is provably unchanged. Set 0 for tape-out. |
| 21 | `TXGEN_CREDIT_GATE_DIS` | 125 | `1'b0` | 0 / 1 | ❌ | **SIM-ONLY negative control.** Defeats the hardware credit gate so a test can prove the peer *does* overrun without it. **Never set in a shipping flist.** |
| 22 | `NEGO_TRAIN_CFG_RESET` | 132 | `16'h0001` | 16-bit | ✅ | POR value of `NEGO_TRAIN_CFG` @ `0x210C`. `[0]` = `train_auto_en`. |
| 23 | `NEGO_CFG_RESET` | 141 | `7'h00` | 7-bit | ✅ (wrapper default `7'h61`) | POR value of `NEGO_CFG` @ `0x2090` — the autonomy opt-in. See [§6.2](#62-nego_cfg_reset). |
| 24 | `WINSCAN_CONVERGE_LOCK_EN` | 146 | `1'b0` | 0 / 1 | ❌ | Forwarded verbatim to `axi_chiplet_controller`. Zero-poke winscan converge-lock. |
| 25 | `HONEST_MASK_HS` | 168 | `1'b1` | 0 / 1 | ✅ (wrapper default `1'b0`) | 1 ⇒ drive the controller's `mask_hs_bypass_i` from the real top-level port, so the peer-mask handshake must genuinely match. 0 ⇒ tied `1'b1` (permanently bypassed). |
| 26 | `DEBUG_UNLOCK_DEFAULT` | 178 | `1'b1` | 0 / 1 | ✅ | 1 ⇒ `apb_debug_unlock_i` tied `1'b1` at the controller and the **top-level pin is discarded**. 0 ⇒ the pin is real. |
| 27 | `RETIRE_EN` | 205 | `1'b1` | 0 / 1 | ✅ | Event-gated retire that latches on `(reanchored & fcsm==4)`, holds ≈160 ms and DISARM-PARKs the winscan FSM — the RTL equivalent of the manual `0x210C=0` escape hatch. |
| 28 | `ENABLE_AHB_WRITE` | 213 | `1'b1` | 0 / 1 | ❌ | Gates the AHB CPU-write-into-RX-FIFO path (a supported, functional path). 0 = FC-write-only posture. |
| 29 | `ROLE_FROM_STRAP` | 224 | `1'b1` | 0 / 1 | ❌ | 1 ⇒ the I²C-NACK terminal role **and** the timeout fallback derive from `role_strap_i`, so a `(master, slave)` strap survives a dead I²C bus. See [§6.3](#63-role_from_strap-and-train_entry_fallback). |
| 30 | `TRAIN_ENTRY_FALLBACK` | 229 | `1'b0` | 0 / 1 | ✅ | 1 ⇒ training entry starts from the strap on a dead I²C bus, so the SYNC beacon lights and the link can self-start without a peer I²C ACK. |

---

## 3. The Vivado IP wrapper face

`tidelink_vivado_wrapper` declares 22 parameters. Sixteen of them simply forward
the `tidelink_top` value; **six carry a different default**, and that difference
*is* the FPGA configuration:

| Parameter | `tidelink_top` default | Wrapper default | Why the wrapper differs |
|---|---|---|---|
| `TIDELINK_PAIR_BASE` | `'0` | `32'h44032000` (`:61`) | The FPGA TideLink-APB base on both paired boards, so `PAIR_BASE_ADDR` POR-initialises correctly and the deploy-time SW write became redundant. |
| `USE_IDELAY` | `1'b0` | `1'b1` (`:73`) | The Xilinx `IDELAYE2` is only wanted on FPGA. |
| `USE_CLKBUF` | `1'b0` | `1'b1` (`:77`) | Recovered-RX-clock BUFG — the fix for the LUT-on-clock lane-lock regression. |
| `USE_T3A` | `1'b0` | `1'b1` (`:83`) | Self-aligning comma hunt kills the per-deploy phase lottery. |
| `NEGO_CFG_RESET` | `7'h00` | `7'h61` (`:147`) | The FPGA image is the sole production consumer that wants autonomous POR bring-up. |
| `HONEST_MASK_HS` | `1'b1` | `1'b0` (`:168`) | Keeps every pre-existing single-die FPGA target byte-behaviour-identical; only `kr260-pair-onchip` overrides it back to 1. |

Forwarded unchanged: `SYS_ADDR_W`, `SYS_DATA_W`, `RAM_ADDR_W`, `FC_DATA_W`,
`NUM_PHY_LANES`, `PHC_LOCK_GATE_EN`, `EPOCH_ANCHOR_EN`, `HARDEN_SWI_ENABLE`,
`STUB_SERVO`, `STUB_PERF`, `STUB_PTP`, `BYPASS_ADDR_XLAT`,
`NEGO_TRAIN_CFG_RESET`, `RETIRE_EN`, `DEBUG_UNLOCK_DEFAULT`,
`TRAIN_ENTRY_FALLBACK`.

### Not on the IP face

These eight `tidelink_top` parameters cannot be set from a BD instance. On
**every** FPGA build they take the value shown:

| Parameter | Value on FPGA | How |
|---|---|---|
| `RAM_DATA_W` | `SYS_DATA_W` (32) | Hardwired in the instantiation (`tidelink_vivado_wrapper.v:544`). |
| `APB_ADDR_W` | `12` | Hardwired (`:545`). |
| `USE_PHY_V2` | `1'b0` | Absent from the param map ⇒ `tidelink_top` default. |
| `TXGEN_PRESENT` | `1'b1` | Absent ⇒ default. The traffic generator is present on every FPGA image (POR-disarmed). |
| `TXGEN_CREDIT_GATE_DIS` | `1'b0` | Absent ⇒ default. |
| `WINSCAN_CONVERGE_LOCK_EN` | `1'b0` | Absent ⇒ default. |
| `ENABLE_AHB_WRITE` | `1'b1` | Absent ⇒ default. |
| `ROLE_FROM_STRAP` | `1'b1` | Absent ⇒ default. |

:::{warning}
**Doc-vs-RTL disagreement inside the RTL itself.** `tidelink_top.sv:144-145`
says of `WINSCAN_CONVERGE_LOCK_EN` that "the FPGA vivado wrapper drives
`1'b1`". It does not — `tidelink_vivado_wrapper.v:569-570` states explicitly
that it "is left at tidelink_top's `1'b0` default", and the parameter does not
appear in the wrapper's `tidelink_top` instantiation at all. **The wrapper is
correct; the `tidelink_top` comment is stale.** Every FPGA build has
`WINSCAN_CONVERGE_LOCK_EN = 1'b0`.
:::

:::{warning}
**A second stale comment.** The comment block above `HONEST_MASK_HS`
(`tidelink_top.sv:147-167`) repeatedly describes "`0` (default)", but the
declaration on line 168 is `1'b1`. The declaration is authoritative: on a plain
`tidelink_top` instantiation (ASIC, sim, UVM) the peer-mask handshake **is**
driven from the real port. On FPGA the wrapper's `1'b0` restores the legacy
tied-open behaviour.
:::

---

## 4. Per-target overrides

Measured by grepping `CONFIG.<param>` in every
`fpga/targets/*/tidelink_design.tcl`. A target not listed sets **no** TideLink
parameter and therefore takes the wrapper defaults from §3.

| Target | Overrides |
|---|---|
| `kr260-pair-ptp`, `kr260-pair-nptp`, `kr260-pair-flip-ptp`, `kr260-pair-flip-nptp` | `TIDELINK_PAIR_BASE 0x84032000`, `USE_IDELAY 0`, **`HARDEN_SWI_ENABLE 0`** |
| `kr260-pair-onchip` (`tidelink_0` = die_a) | `NEGO_CFG_RESET 7'b1100001`, `HONEST_MASK_HS 1'b1`, `DEBUG_UNLOCK_DEFAULT 1'b1`, `USE_IDELAY 0`, `TIDELINK_PAIR_BASE 0x8C032000` |
| `kr260-pair-onchip` (`tidelink_1` = die_b) | same, but `TIDELINK_PAIR_BASE 0x84032000` |
| `pynq-z2-pair`, `pynq-z2-pair-flip`, `pynq-z2-loopback` | `USE_IDELAY 0` |
| `pynq-z2-pair-mmcmbypass-oddr-all`, `…-oddr-flip-all` | `USE_CLKBUF 1'b0` |
| `pynq-z2-pair-all`, `pynq-z2-pair-flip-all` | `TRAIN_ENTRY_FALLBACK 1'b1` **and** `EPOCH_ANCHOR_EN 1'b1` — each behind an env guard, see below |
| `mps3` | `TIDELINK_PAIR_BASE 0x00000000` |
| `kr260-eth-chiplet`, `kr260-eth-chiplet-flip` | none (they package the whole `nanosoc_eth_chiplet` as one IP) |

:::{warning}
**The two Z2 opt-ins are OFF in a plain build.** In
`fpga/targets/pynq-z2-pair-all/tidelink_design.tcl` the overrides sit inside
```tcl
if { [info exists ::env(TL_TRAIN_ENTRY_FALLBACK)] && $::env(TL_TRAIN_ENTRY_FALLBACK) == 1 } { … }   # :435
if { [info exists ::env(TL_EPOCH_ANCHOR_EN)]      && $::env(TL_EPOCH_ANCHOR_EN)      == 1 } { … }   # :451
```
(and `:417` / `:433` in the `-flip-all` target). So
`make -C fpga build_design TARGET=pynq-z2-pair-all` with a clean environment
builds **both features off**. Export `TL_TRAIN_ENTRY_FALLBACK=1` and/or
`TL_EPOCH_ANCHOR_EN=1` — and check the build log for the confirming
`puts` line — or you will bring up an image you did not intend.
:::

:::{note}
`HARDEN_SWI_ENABLE 0` on the four `kr260-pair-*` targets is deliberate: it is
what lets the hand-driven FC/LL bootstrap triplet at `0x8403_0208` land its
`bit[3]` `swreset`. Do not "restore" it to 1 on those targets without also
changing the bring-up recipe.
:::

---

## 5. Constants that behave like parameters but are not on the top face

| Constant | Where | Value | Note |
|---|---|---|---|
| `TX_STALL_TIMEOUT_LOG2` | `tidelink_fc_adapter.sv:44` | `16` | ≈1.3 ms at 50 MHz. **Not forwarded** by `tidelink_top` (`:1725-1730` omits it), so every build uses 16. Past the timeout the beat is terminated with a bounded 2-cycle AHB ERROR instead of hanging the host AXI. |
| `MAX_SIDEBAND_BURST` | `tidelink_fc_adapter.sv:433` | `4` | localparam. Forces a TX-aperture grant after four consecutive sideband grants. |
| `MAX_CREDITS` | `tidelink_fifo_ctrl.sv:110` | `1 << (RAM_ADDR_W-2)` = 4096 | Derived from `RAM_ADDR_W`. |
| `MAX_PACKET_LEN` | `tidelink_fifo_ctrl.sv:242` | `MAX_CREDITS - 2` | Two words reserved for the header. |
| `AUTOCAL_ENABLE` | `tidelink_top.sv:2457` | `1'b1` | Hardwired at the `axi_chiplet_controller` instantiation; the old `AUTOCAL=0` workaround is reverted. |

---

## 6. High-consequence parameters

### 6.1 `EPOCH_ANCHOR_EN` (and the `AUTO_ANCHOR_EN` naming correction)

:::{attention}
**There is no `AUTO_ANCHOR_EN` parameter in this repository.** A repo-wide grep
across `.v/.sv/.tcl/.md/.sh/.py` returns zero hits for that identifier; the only
occurrences anywhere in the tree are prose inside `docs/BUILD_REGISTRY.yaml`,
which uses the name because that is what the **sibling**
`nanosoc-ethernet-chiplet` RTL calls it (`nanosoc_eth_chiplet.sv:760`, not
fetchable from here — see {doc}`build_registry`). The TideLink knob people mean
is **`EPOCH_ANCHOR_EN`**. If you are carrying a note, a ticket or a script that
names `AUTO_ANCHOR_EN` against *this* tree, it will silently do nothing — Vivado
accepts an unknown `CONFIG.*` property with no error on some flows, and a
Verilog `defparam`/parameter override of a non-existent name is not a build
failure in every tool. Rename it.
:::

What it actually selects (`tidelink_top.sv:76-84`), quoting the RTL comment:

- **`1'b0` (default)** — "today's shipping deskew corrector (`SYNC_REANCHOR_EN`),
  which **never arms on real silicon because the idle-gated SYNC beacon can't
  fire**".
- **`1'b1`** — "swaps in the training-EXIT anchored corrector proven in sim to
  fix s2m delivery".

The path is `tidelink_top` → `axi_chiplet_controller.EPOCH_ANCHOR_EN`
(`axi_chiplet_controller.sv:52`) → `Wlink.EPOCH_ANCHOR_EN` (`:6157`) →
`WlinkGPIOPHY_v2`. It is **V2-only and inert under V1** — V1's `WlinkGPIOPHY`
has no such parameter, and `Wlink.v` only forwards it under
`` `ifdef TIDELINK_PHY_V2``.

**Failure mode when it is 0 on a link that needs it:** the beacon-driven
corrector never arms, cross-lane deskew is never re-anchored, and the receiving
die reads zeros. This is the beacon-starvation class of failure.

**Failure mode when the *default* is flipped to 1:** every existing golden
bitstream silently gets a different deskew corrector on its next rebuild —
including KR260's proven on-chip pair, which relies on `SYNC_REANCHOR_EN`. This
is why `check_wrapper_params.sh` enforces `EPOCH_ANCHOR_EN = 1'b0` in the
wrapper file, with the *opposite* polarity to the three `USE_*` checks:

```text
FAIL EPOCH_ANCHOR_EN = 1'b1   (default flipped ON — would silently
     change every existing golden bitstream's deskew corrector on
     its next rebuild; opt in via CONFIG.EPOCH_ANCHOR_EN per BD
     instance instead, never by editing this default)
```

**Opt in per board instance**, never by editing the default:
`set_property CONFIG.EPOCH_ANCHOR_EN {1'b1} [get_bd_cells tidelink_0]`.

:::{note}
**What is verifiable here, and what is not.** Every `kr260-pair-*` target in
this checkout sets **no** `CONFIG.EPOCH_ANCHOR_EN`, so all of them build with
the wrapper default `1'b0` — verified by grep over
`fpga/targets/*/tidelink_design.tcl`. The claim that a companion eth-chiplet
build shipped the equivalent knob at `1` is **UNVERIFIED from this repository**:
the two `kr260-eth-chiplet*` targets set no TideLink `CONFIG.*` at all, because
they package the whole `nanosoc_eth_chiplet` as a single IP from a sibling repo.
:::

:::{caution}
`EPOCH_ANCHOR_EN` and `SYNC_REANCHOR_EN` are **mutually exclusive** — the
deskew DUT `$fatal`s if both are set (`cocotb/tidelink_lane_deskew/tb_deskew.sv:20-21`).
A `SYNC_REANCHOR` build must pass `TB_EPOCH_ANCHOR_EN=0`.
:::

Gates: `sim_gate_epoch_anchor_plumb`, `sim_gate_epoch_silicon`,
`sim_gate_xfail_epoch_shipping` (a sentinel for the shipping corrector's known
defect). See [Simulation Tests](simulation_tests.md).

### 6.2 `NEGO_CFG_RESET`

POR value of `NEGO_CFG` @ `0x2090`, and therefore the **autonomy opt-in**:

| Bit | Name | Meaning |
|---|---|---|
| `[0]` | `nego_en` | Run the autoneg FSM from POR. |
| `[5]` | `nego_force_lock` | Latch `role_locked` on nego completion — no SW W1S needed. |
| `[6]` | `mask_hs_auto_en` | Run the lane-mask handshake autonomously. |

`7'h61` = all three set.

| Consumer | Value | Consequence |
|---|---|---|
| `tidelink_top` default | `7'h00` | Autoneg **off**; manual SW role-lock / host winscan. This is what cocotb, UVM and a default ASIC integration get. |
| Vivado wrapper default | `7'h61` | Autonomous POR bring-up on FPGA. |
| `kr260-pair-onchip` | `7'b1100001` (= `0x61`), **asserted** | Both dies self-negotiate. |

:::{warning}
`docs/INTEGRATION_GUIDE.md` §4.3 lists `NEGO_CFG_RESET` as "`7'h61`" for
`tidelink_top`. That is **stale** — `tidelink_top.sv:141` is `7'h00`, and the
RTL comment explains why: under `7'h61` the slave's lane mask is autoneg-locked
at `0xff`, which breaks the reduced-lane bring-up. `7'h61` is a wrapper-only
default.
:::

:::{caution}
`NEGO_CFG_RESET` is packaged as `spirit:format="bitString"`. A per-instance
override written in the wrong form is **silently coerced to `0000000`**, leaving
autoneg off with no error anywhere. `kr260-pair-onchip` therefore uses the
`{7'b1100001}` form and asserts it took (`_tl_assert_bitcfg`,
`fpga/targets/kr260-pair-onchip/tidelink_design.tcl:96-112, 347`). Copy that
pattern.
:::

`RETIRE_EN`'s safety argument leans on this default: the retire SET is gated on
`(nego_en & role_locked & train_auto_en)`, and `nego_en` is 0 by default, so
`RETIRE_EN=1'b1` "can NEVER fire on a default ASIC integration"
(`tidelink_top.sv:191-201`). If you strap `NEGO_CFG_RESET != 0` on an ASIC, you
have also armed the retire — that is deliberate, because `RETIRE_EN=0` with
`nego_en=1` is the known-broken combination (winscan livelock, B→A dead).

### 6.3 `ROLE_FROM_STRAP` and `TRAIN_ENTRY_FALLBACK`

These are the two halves of the dead-I²C story.

| Parameter | Default | At 1 | At 0 |
|---|---|---|---|
| `ROLE_FROM_STRAP` | `1'b1` | I²C-NACK terminal role **and** timeout fallback derive from `role_strap_i` — a `(master, slave)` strap survives a dead I²C bus. | **LEGACY TRAP:** NACK ⇒ slave, timeout ⇒ `nego_fallback`, so a dead I²C makes **both** dies slave and autonomy is structurally dead. |
| `TRAIN_ENTRY_FALLBACK` | `1'b0` | Training entry starts from the strap on a dead I²C bus, so the SYNC beacon lights and the link self-starts without a peer I²C ACK. | Shipping behaviour; the link waits for a peer ACK that a dead bus will never deliver. |

`ROLE_FROM_STRAP` is **not on the IP face**, so every FPGA build gets `1'b1`.
`TRAIN_ENTRY_FALLBACK` **is** on the face, defaults `1'b0`, and is opted into
only by the two `pynq-z2-pair-*-all` targets under `TL_TRAIN_ENTRY_FALLBACK=1`.

### 6.4 `USE_IDELAY`, `USE_CLKBUF`, `USE_T3A`

The three "FPGA-on" knobs. Defaults are `1'b0` on `tidelink_top` (bit-exact
passthrough for sim and ASIC) and `1'b1` on the wrapper.

| Parameter | At 1 | At 0 |
|---|---|---|
| `USE_IDELAY` | Per-lane `IDELAYE2` tap bank driven by the calibrator phase. Needs a 200 MHz `idelay_ref_clk`. | Bit-exact passthrough — `tidelink_idelay_rx` is a wire. |
| `USE_CLKBUF` | Recovered RX clock through a global BUFG. | Fabric LUT path. |
| `USE_T3A` | Per-lane self-aligning comma hunt (`WavD2DGpioRx` slips `count` once per POR). | The 16-cycle count-phase lottery is back. |

:::{danger}
**This trio caused the multi-day 0/16 lane-lock regression.** Commit `51b5169`
stripped `USE_CLKBUF`/`USE_IDELAY` from the wrapper parameters; the GPIO-PHY
recovered clock landed on a LUT-driven net (Place 30-568), the hold check failed,
Vivado treated the CRITICAL WARNINGs as soft, and the failure was invisible until
hardware. `fpga/scripts/check_wrapper_params.sh` exists solely to abort the build
**before Vivado runs** if any of the three is not `1'b1` in the wrapper file.
Root cause write-up: `docs/reference/LANE_LOCK_ROOT_CAUSE.md`.
:::

Several targets legitimately set `USE_IDELAY 0` per instance (all KR260 pair
targets — there is no I/ODELAY on an internal net; plus `pynq-z2-pair`,
`pynq-z2-pair-flip`, `pynq-z2-loopback`). That is a *per-instance* override, not
a change to the wrapper default, and the guard is fine with it.

### 6.5 `HONEST_MASK_HS` and `DEBUG_UNLOCK_DEFAULT`

These two decide whether the peer-mask handshake and the APB debug lock are
**real** or **decorative**. The tie in `tidelink_top.sv:2511-2512` is:

```systemverilog
.apb_debug_unlock_i (DEBUG_UNLOCK_DEFAULT ? 1'b1 : apb_debug_unlock_i),
.mask_hs_bypass_i   (HONEST_MASK_HS       ? mask_hs_bypass_i : 1'b1),
```

and inside the controller the gate is

```verilog
wire mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i;   // :711
```

:::{important}
**`apb_debug_unlock_i` is no longer a term in that OR.** It was removed on
2026-07-24 (`axi_chiplet_controller.sv:695-711`) because one strap did two
unrelated jobs — bypass the peer-mask gate, *and* enable external-APB writes to
Wlink on a slave die — so the handshake could never be honest while bring-up
worked. Older material (including comments still sitting in
`tidelink_top.sv:2505-2506`) repeats the three-term form; it is stale. See
{doc}`functionality`.
:::

:::{danger}
**At `DEBUG_UNLOCK_DEFAULT = 1'b1` — the default everywhere — the top-level
`apb_debug_unlock_i` pin is DISCARDED and the BD's 0-strap is decorative**
(`tidelink_vivado_wrapper.v:169-187`). Since the 2026-07-24 fix that no longer
forces the peer-mask gate open by itself; what does, on FPGA, is
`HONEST_MASK_HS = 1'b0` (the wrapper default), which ties the controller's
`mask_hs_bypass_i` to `1'b1`. The historical measurement on
`kr260-pair-onchip` 2026-07-23 — slave `mask_hs_match = 0` yet `gate_open = 1`,
a **sham handshake** that silently voids an autonomy claim — was taken *before*
that fix, when the debug strap alone was enough.
:::

:::{warning}
**Do not set `DEBUG_UNLOCK_DEFAULT = 0` until the die can actually reach
`mask_hs_match = 1`.** A closed gate blocks the SW role-lock ⇒ the Wlink is held
in reset ⇒ the link is **dead**. Proven in `cocotb/honest_mask_hs`
`MODE=honest_locked`.
:::

The previously-unreachable combination — an honest handshake **with** debug
still unlocked — is `HONEST_MASK_HS=1'b1` + `DEBUG_UNLOCK_DEFAULT=1'b1`, which
is exactly what `kr260-pair-onchip` builds. Gate:
`sim_gate_v2_mask_hs_bilateral`.

### 6.6 `HARDEN_SWI_ENABLE`

Default `1'b1`. Forces `swi_enable=1` on any APB write that asserts
`swi_swreset=1` to Wlink `0x208`. Without it, buggy software writing
`{swreset=1, swi_enable=0}` returns all 7 FCSMs to IDLE and loses the CR/CRACK
sticky state. It is bit-exact-safe because the OR engages only when software
already toggles `swreset`.

The four `kr260-pair-*` targets set it to **0** on purpose — see the note in
[§4](#4-per-target-overrides).

### 6.7 `USE_PHY_V2` — do not set

`1'b0` is the only supported value. The `g_phy_v2` generate arm
(`tidelink_top.sv:2433`) is an **empty placeholder**, not a functional PHY, and
its sources (`flists/tidelink_phy_v2.flist`) are not included by any live flist.
V2 PHY selection is done by compiling `tidelink_fpga_v2.flist` /
`tidelink_top_full_asic_v2.flist` (which `+define+TIDELINK_PHY_V2`), **not** by
this parameter.

### 6.8 `TXGEN_PRESENT` and `TXGEN_CREDIT_GATE_DIS`

`TXGEN_PRESENT = 1'b1` puts `tidelink_tx_gen` on every build including FPGA; it
is POR-disarmed (`TXGEN_CTRL[0] EN` resets 0) and its ownership mux folds away
while disarmed. **Set `TXGEN_PRESENT = 0` for tape-out** so the block and the
mux are removed by the generate and the netlist is provably unchanged.

`TXGEN_CREDIT_GATE_DIS = 1'b1` defeats the hardware credit gate. It exists only
so a negative-control test can prove the peer *does* overrun without the gate.
There is also a sim-only `` `ifdef TXGEN_FORCE_CREDIT_GATE_DIS`` that ORs into
the effective value (`tidelink_top.sv:1019-1023`).

:::{danger}
`TXGEN_CREDIT_GATE_DIS = 1'b1`, or the `TXGEN_FORCE_CREDIT_GATE_DIS` define,
must **never** appear in a shipping flist.
:::

Gates: `sim_gate_txgen_unit`, `sim_gate_txgen_negctl`, `sim_gate_v2_txgen`,
`sim_gate_txgen_ext_hijack`.

---

## 7. Depth and geometry parameters are not free

| Parameter | Derived quantity | Where |
|---|---|---|
| `RAM_ADDR_W = 14` | FIFO/TX aperture = 16 KB | `tidelink_top.sv:43` |
| | `MAX_CREDITS = 1 << (RAM_ADDR_W-2)` = **4096** 32-bit words | `tidelink_fifo_ctrl.sv:110` |
| | `MAX_PACKET_LEN = MAX_CREDITS - 2` = **4094** (2-word header reserve) | `:242` |
| | `MIN_PKT_CREDIT = 2` | `:221` |
| `FC_DATA_W = 48` | `{pkt_type[47:46], addr_offset[45:32], payload[31:0]}` — the minimum self-describing word | `tidelink_fc_adapter.sv:13,152-158` |

Changing `RAM_ADDR_W` changes the credit depth, the packet-length limit, **and**
the size of both the host TX aperture and the peer's RX window — those must
stay equal on both dies. Changing `FC_DATA_W` requires a Chisel regeneration of
`WlinkGenericFCSM_6`; it is not a free parameter.

Two silicon-defect guards live in the credit arithmetic and should be preserved
if you touch it: the consume path clamps at 0 (`:386-389`) and the mint path
**saturates** at `MAX_CREDITS` (`:424-427` — the 2026-07-15 fix for the
phantom-pop defect that minted credit above `MAX_CREDITS`). Gate:
`sim_gate_fifo` / `fifo_rx_phantom_pop`.

---

## 8. ASIC DFT wrapper parameters

`src/rtl/asic/tidelink_dft_wrapper.sv` re-declares a subset of the
`tidelink_top` parameters as pass-throughs, plus two of its own:

| Parameter | Default | Note |
|---|---|---|
| `SYS_ADDR_W`, `SYS_DATA_W`, `RAM_ADDR_W`, `RAM_DATA_W`, `APB_ADDR_W`, `FC_DATA_W`, `NUM_PHY_LANES`, `TIDELINK_PAIR_BASE`, `PHC_LOCK_GATE_EN`, `USE_IDELAY`, `USE_CLKBUF`, `USE_T3A`, `EPOCH_ANCHOR_EN`, `HARDEN_SWI_ENABLE`, `HONEST_MASK_HS`, `DEBUG_UNLOCK_DEFAULT`, `USE_PHY_V2`, `RETIRE_EN`, `ROLE_FROM_STRAP`, `TRAIN_ENTRY_FALLBACK`, `ENABLE_AHB_WRITE` | same as `tidelink_top` | Pass-through. |
| `NEGO_CFG_RESET` | **`7'h61`** | ⚠ **Differs from `tidelink_top`'s `7'h00`.** A DFT-wrapped ASIC build boots with autoneg armed unless overridden. |
| `SCAN_CHAINS` | `8` | Width of the added multi-bit scan bus. |
| `INCLUDE_TAP` | `0` | Optional JTAG TAP pads. No TAP is instantiated. |

The wrapper omits `STUB_SERVO`/`STUB_PERF`/`STUB_PTP`/`BYPASS_ADDR_XLAT`,
`TXGEN_*`, `WINSCAN_CONVERGE_LOCK_EN` and `NEGO_TRAIN_CFG_RESET` — those take
`tidelink_top` defaults. Elaboration is gated by `make sim_gate_dftelab`.

---

## 9. Verifying a parameter reached the netlist

:::{danger}
**An md5 or sha256 of the bitstream proves nothing about a parameter value.**
Two builds with different parameter values can differ; two builds with the
*same* value can also differ (Vivado is not bit-reproducible run to run).
Verify **structurally**.
:::

In increasing order of strength:

1. **Pre-flight the wrapper file.**

   ```bash
   bash fpga/scripts/check_wrapper_params.sh
   ```

   Checks `USE_IDELAY`/`USE_CLKBUF`/`USE_T3A` are `1'b1` and `EPOCH_ANCHOR_EN`
   is `1'b0` in `fpga/vivado_ip/tidelink_vivado_wrapper.v`. Exit `0` = intact,
   `1` = drift, `2` = usage error. `make -C fpga package_ip` runs it
   automatically (`fpga/Makefile:358`).

2. **Check the packaged IP-XACT.** The same script, when
   `imp/fpga/tidelink_ip/component.xml` exists, greps each parameter's
   `resolve="user"` block and parses the XML-escaped bitString
   (`&quot;0&quot;` / `&quot;1&quot;`). A mismatch means a **stale IP cache** —
   re-run `package_ip`.

3. **Assert the per-instance override took, in the target tcl.** For any
   `bitString` parameter, read the property back and fail the build if it is
   wrong. `kr260-pair-onchip` does this with `_tl_assert_bitcfg`
   (`fpga/targets/kr260-pair-onchip/tidelink_design.tcl:96-112`):

   ```tcl
   set raw [get_property CONFIG.$prop [get_bd_cells $cell]]
   # error out unless $raw parses to the expected integer
   ```

4. **Prove the plumbing in simulation.** Several parameters have a dedicated
   gate suite whose entire job is to prove the value propagates end-to-end:
   `sim_gate_epoch_anchor_plumb`, `sim_gate_retire_plumb`,
   `sim_gate_zeropoke` (`zeropoke_por`), plus the cocotb environment
   `cocotb/asic_nego_cfg_plumb/` for the ASIC side. Run them before you trust a
   knob. See [Simulation Tests](simulation_tests.md).

5. **Read it out of the running design.** Many of these knobs have an
   observable consequence at an APB register — for example `NEGO_CFG` @
   `0x2090` reads back its POR value before any software write. That is the
   only check that covers the whole chain including the bitstream. See
   [Register Map](register_map.md).

:::{note}
**Verify the instrument before the DUT.** The `component.xml` half of
`check_wrapper_params.sh` was silently blind from the day it was written until
2026-07-30 because its regex expected a bare digit where Vivado writes
`&quot;1&quot;` — so it printed a blanket "OK" regardless of the XML contents.
A check that cannot fail is not a check.
:::

---

## 10. Defaults worth a second look

Observations from reading this RTL. These are **flags for review**, not
established defects; the bug registry (`docs/BUG_REGISTRY.yaml`) is the
authority on what is actually tracked.

| Parameter | Concern |
|---|---|
| `HONEST_MASK_HS = 1'b1` (`tidelink_top.sv:168`) | Its own 20-line comment block repeatedly describes "`0` (default)". Declaration and documentation disagree; one of them is wrong. |
| `WINSCAN_CONVERGE_LOCK_EN` | `tidelink_top.sv:144-145` claims the FPGA wrapper drives `1'b1`; it does not, and cannot — the parameter is absent from the wrapper's `tidelink_top` param map. |
| `NEGO_CFG_RESET` in the DFT wrapper (`7'h61`) | Diverges from `tidelink_top`'s `7'h00`. A DFT-wrapped ASIC therefore boots with autoneg armed — and, by the `RETIRE_EN` argument in §6.2, with the retire armed too — which is the opposite of the "safe default" reasoning written into `tidelink_top`. |
| `DEBUG_UNLOCK_DEFAULT = 1'b1` | Ships APB debug permanently unlocked **and** discards the top-level strap pin. Fine as a bench posture, questionable as a tape-out posture; the RTL itself calls the tied-open gate an "APB permanently unlocked chip-killer" in the `HONEST_MASK_HS` comment. |
| `TXGEN_PRESENT = 1'b1` | Correct for FPGA benchmark images, but it is the *default*, so an ASIC integration that does not explicitly set 0 ships the traffic generator. |
| `EPOCH_ANCHOR_EN = 1'b0` | Correct as a *default* (it protects existing bitstreams), but it selects a corrector the RTL comment itself says "never arms on real silicon". Boards that need working cross-lane deskew must opt in per instance, and nothing in the build fails if they forget. |
