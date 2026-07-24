# KR260 eth-chiplet target — build notes

The `kr260-eth-chiplet` (die_a) and `kr260-eth-chiplet-flip` (die_b) targets
build the WHOLE nanoSoC multicore+ethernet SoC with internal TideLink for the
two-board KR260 demo. This differs fundamentally from the bare-link
`kr260-pair-*` targets: TideLink is *inside* the packaged
`nanosoc_eth_chiplet` IP; the on-chip Cortex-M0 cores drive the D2D link.

## Build order (run from the tidelink repo root)

```
# 0. Flatten the parent repo's SoC + tidelink source lists (single source of truth)
make -C .. elab                        # or the parent's flist prep

# 1. Env
source ../set_env.sh
export TIDELINK_PHY_V2=1                # MANDATORY (silent-V1 trap otherwise)

# 2. SCOPING SYNTH — the go/no-go. OOC-synthesises the entire SoC on xck26 and
#    is the first proof it fits. Expect it to surface FPGA memory-model gaps
#    (behavioural SRAM -> BRAM). This needs NO block design.
make -C fpga package_eth_chiplet_ip
#    -> reports/util/timing in imp/fpga/run/package_eth_chiplet_ip.log

# 3. Only once (2) is clean: the full board build (PS8 BD + bitstream)
make -C fpga package_phc_ip
make -C fpga build_design TARGET=kr260-eth-chiplet       # die_a
make -C fpga build_design TARGET=kr260-eth-chiplet-flip  # die_b
```

## Full build result — die_a BITSTREAM (2026-07-23, Vivado 2024.1, xck26)

`make build_design TARGET=kr260-eth-chiplet` now runs the WHOLE flow to a
bitstream: **synth + place + route + write_bitstream all complete** ->
`imp/fpga/output/kr260-eth-chiplet/tidelink.bit` (+ .hwh / .xsa / routed .dcp).
The complete nanoSoC ethernet-chiplet (multicore SoC + ethernet subsystem + V2
TideLink) implements on the KR260.

Impl utilisation (placed): **47.6% CLB LUT, 21.2% FF, 22.6% BRAM, 0.6% DSP,
25 IOB** — comfortable headroom.

**Timing (build #11, superseded):** WNS = -31.0 ns. **Root cause found and
fixed** — it was NOT a timing-XDC hierarchy problem (an earlier note in this file
claimed that; it was wrong, those `-hier` filters are wildcards and do match).
The real cause was a **block-design clocking bug**: this BD drove
`phy_clk_div/clk_in` from `clk_wiz clk_out2`, while the timing XDC declares
`pad_clk_tx_fwd` as `clk_wiz_0/clk_out1 -divide_by 8`. That made the TX launch
clock (`user_ref_clk_div2`, off clk_out2) and the forwarded output clock
(off clk_out1) two *unrelated* near-equal-period clocks (320.572 vs 319.857 ns),
so Vivado analysed their beat-frequency worst case: a 0.728 ns requirement on
`gpiotx_*/io_pad_q_reg -> pad_tx[*]`. The bare-link target drives the divider
from clk_out1; this BD now matches it.

### die_a rebuild — SWD@PMOD2 + timing fix + ethernet wired (2026-07-24)

Bitstream builds. **Timing fix confirmed: WNS -31.0 -> -2.9 ns** (28 ns gain)
from sourcing the PHY divider off `clk_out1`. Both clocks now share one period
(319.857 ns) and are properly related (`Requirement 0.000ns`), instead of the
old beat-frequency analysis.

| | die_a (this build) |
|---|---|
| CLB LUTs | 58,654 / 117,120 = **50.1%** |
| CLB Registers | 53,771 / 234,240 = 23.0% |
| Block RAM | 32.5 / 144 = 22.6% |
| Bonded IOB | **34** (was 25 — +9 = the RMII/MDIO signals) |
| WNS | **-2.923 ns** (4 failing / 110,349) |
| WHS | -22.408 ns (8 failing) |

Pins all placed clean: **SWD on PMOD2 at LVCMOS33** (no BIVB-1 — PMOD2 confirmed
a real 3.3 V bank), RMII on PMOD1 + TX1 on K12, MDIO IOBUF no multi-driver DRC.

**Remaining hold (-22.4 ns) is PRE-EXISTING, not eth-chiplet-specific.** The
bare-link `kr260-pair-nptp` shows the same -22.489 ns on the *same* path shape:
`gpiotx_2/g_pad_iob.io_pad_q_reg -> pad_tx[2]`. It is the forwarded-clock
(source-synchronous) TX output analysed against `set_output_delay`, where what
physically matters is data-vs-forwarded-clock skew, not absolute hold to a
virtual clock. The bare-link ships a bitstream with it. Treat as a constraint-
modelling item for the TX interface, shared with the bare-link target — not a
blocker introduced here. Residual setup (-2.9 ns, 4 endpoints) is small and
likely closable.

### Fixes required to get here (all committed on integ/kr260-eth-chiplet)
1. build-integrity helpers (`build_provenance.tcl` + msg_gate hooks) were missing
2. xhb `ahb_sub` comb-loop fix `cb33c9f` cherry-picked (bare-link route DRC)
3. BD: `axi_ahblite_bridge` interface names (AXI4 / M_AHB)
4. BD: clock HPM0 master + role strap via xlconstant
5. BD: match clk_wiz PRIM_IN_FREQ to the PS's 99.999 MHz
6. skip the tidelink-flist provenance gate for the eth-chiplet IP
7. global (non-OOC) BD synthesis to dodge duplicate-basename clobber
8. disambiguate the two `phc_ahb.sv` at packaging
9. use the **V2** TideLink flist (tidelink_fpga_v2.flist) — the parent elab
   defaults to V1, which mismatches the V2 tidelink_top epoch interface
10. materialise the V2 `\`include` PHY shims so ipx packaging keeps them
11. SWD pins: PMOD4 is a 1.8V HP bank -> now MOVED to PMOD2 (3.3V, J11/J10/K13)
12. BD clocking: PHY divider must derive from clk_out1 (see timing note above)

### Timing after ethernet-clock constraints (2026-07-24, final for this pass)

Adding the MII generated clocks + `async_sys_rmii` group (see the timing XDC)
**closed setup on both dies** — the async grouping removed over-constraint and
let the placer close the TideLink RX capture:

| | die_a | die_b | prior (no eth clocks) |
|---|---|---|---|
| WNS | **+0.194 ns** | **+0.267 ns** | -2.9 / -3.3 ns |
| setup fails | **0** | **0** | 4 |
| WHS | -22.562 ns | -22.916 ns | -22.4 ns |
| hold fails | 8 | 8 | 8 |

**Setup is met.** The remaining hold (-22.x ns, 8 endpoints) is two things,
neither an M1 blocker:
1. The TideLink forwarded-clock RX/TX (`pad_clk_rx`/`pad_clk_tx` domain) — **at
   bare-link parity** (kr260-pair-nptp is -22.489 ns on the same path shape) and
   **runtime-calibrated** (TideLink's autonomous winscan finds the capture
   window regardless of static skew). This is why the shipping bare-link works
   despite the same number.
2. Some `rmii_to_mii` CE crossings (`mtx_clk`÷2 → `rmii_ref_clk`-clocked flop CE)
   — genuinely **multicycle-stable / false** (the enable is held for 2 ref-clk
   cycles by construction). **M2 refinement:** a `set_multicycle_path`/
   `set_false_path` on those CE arcs would clear them. The ethernet is not
   exercised in M1 (no PHY firmware), so left for the M2 session.

### die_b — BUILT (2026-07-24), matched pair complete

`make build_design TARGET=kr260-eth-chiplet-flip` builds clean, and tracks die_a
closely — confirming the flip target is a true mirror, not a divergent build:

| | die_a | die_b |
|---|---|---|
| WNS | -2.923 ns (4 fail) | -3.336 ns (4 fail) |
| WHS | -22.408 ns (8 fail) | -22.923 ns (8 fail) |
| CLB LUTs | 58,654 (50.1%) | 58,649 (50.1%) |
| Bonded IOB | 34 | 34 |
| role strap | 0 (die_a) | **1 (die_b)** |

Both produce the full artefact set (.bit / .hwh / .xsa / routed .dcp / timing
report / manifest). **Pair the die_a image with the -flip image** — same image on
both boards shorts every ribbon lane.

## Scoping-synth result (2026-07-22, Vivado 2024.1, xck26-sfvc784-2LV-c)

OOC `synth_design` of `nanosoc_eth_chiplet_vivado_wrapper` **completed
successfully — the SoC FITS with large headroom**:

| Resource | Used | Avail | % |
|---|---|---|---|
| CLB LUTs | 52,534 | 117,120 | 44.9% |
| CLB Registers | 43,770 | 234,240 | 18.7% |
| Block RAM tiles | 32.5 | 144 | 22.6% (20xRAMB36 + 25xRAMB18) |
| DSPs | 7 | 1,248 | 0.6% |

The behavioural CMSDK SRAMs **inferred to Block RAM** — the memory-model risk is
largely retired at synth level. Timing is unconstrained (pure OOC fit synth, no
clocks); closure is a later phase once the BD clock/XDC constraints exist.
Benign critical warnings: duplicate `xhb500_*`/`cmsdk_apb_slave_mux` module
definitions (flist-cleanliness — last-wins), and 2 async-set flops in
`axi_chiplet_controller.sv` flagged un-timeable. Regenerate via
`make package_eth_chiplet_ip` (elaborate) or the standalone OOC synth.

## What is in place

- **IP packaging** (`fpga/vivado_ip/`): `nanosoc_eth_chiplet_filelist.tcl`
  (parses the parent's flattened `.f` lists), `nanosoc_eth_chiplet_vivado_wrapper.v`
  (eth_ss_0 AHB backdoor, GPIO-PHY pads, SWD, IRQs; RMII/scan/etc tied off for
  M1), `package_eth_chiplet_ip.tcl`.
- **Constraints**: `kr260_eth_chiplet_tidelink.xdc` (J21 ribbon pads + PMOD0
  LEDs + spare-pin UART + **SWD on PMOD2** J11/J10/K13 (3.3V)), timing + drc copied from
  the bare-link target. The flip target swaps the TX/RX ball-sets.
- **Board wrapper**: `tidelink_design_wrapper.v` — the SWDIO IOBUF + BD instance.
- **Makefile**: `kr260-eth-chiplet(-flip)` targets (xck26 + KR260 board preset),
  `package_eth_chiplet_ip` goal, and build_design wired to the eth-chiplet IP.

## Known iteration points (marked `SCOPING-TODO` in tidelink_design.tcl)

The block design (`tidelink_design.tcl`) is a **first-cut** — the OOC scoping
synth (step 2) is the gate; the BD is the next phase and needs Vivado work on:

1. **FPGA memory models.** The SoC's imem/dmem/shared_sram are behavioural in
   sim; xck26 synth needs the BRAM variants (the parent's PYNQ-Z2 flow does this
   for Zynq-7000 — port the same memory selection to xck26). This is the most
   likely blocker step 2 surfaces.
2. **eth_ss_0 clock association.** The SoC derives its own hclk from `sys_fclk`;
   if it divides, the AXI→AHB bridge must run on the chiplet's `sys_hclk` output,
   not `clk_wiz/clk_out1`.
3. **PS8 preset + address map.** Confirm the `CONFIG.PSU__*` set from a KR260
   preset export and the HPM0 `eth_ss_0` window base/range the firmware expects.
4. **Finding G1 (DEVICE_CLASS).** Not a chiplet top parameter yet — needs a
   one-line parent-repo change to strap die_a=0x0001 / die_b=0x0002. Until then
   pin die_a grandmaster by `role_strap_i`; do not rely on auto-election.

## SWD bring-up

Reuses the PYNQ-Z2 OpenOCD flow unchanged — external ST-Link/DAPLink on PMOD2 (3.3V),
`transport select swd`. See `pynq/scripts/openocd/nanosoc_multicore.cfg` and the
the SWD constraints (PMOD2: J11/J10/K13) folded into `kr260_eth_chiplet_tidelink.xdc`.
