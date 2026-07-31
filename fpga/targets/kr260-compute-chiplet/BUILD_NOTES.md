# KR260 compute-chiplet target — build notes

The `kr260-compute-chiplet` (die_a) and `kr260-compute-chiplet-flip` (die_b)
targets build the WHOLE nanoSoC multicore **compute** SoC with **two** internal
TideLink die-to-die links (+ one TideChart) for the two-board KR260 demo. This is
the two-link sibling of the `kr260-eth-chiplet` target: TideLink is *inside* the
packaged `nanosoc_compute_chiplet` IP; the on-chip Cortex-M cores drive the links.

> **FIRST-CUT SCAFFOLD.** Exactly like the eth-chiplet flow when it landed, this is
> a structurally-sound scaffold that has **NOT been through a Vivado build**. The
> OOC scoping synth (`make package_compute_chiplet_ip`) is the go/no-go gate; the
> block-design build is the next phase and **will need Vivado-interactive
> iteration** on the `SCOPING-TODO` items below. No timing/util numbers here yet.

## Compute-vs-eth deltas applied

| Aspect | eth-chiplet | compute-chiplet (this target) |
|---|---|---|
| PS backdoor slave | `eth_ss_0` | **`ps_ahb_s`** (G2 host backdoor; becomes SoC `ps_m`) |
| TideLinks | one | **two** — link 0 to J21, **link 1 tied off in the BD (G8)** |
| Ethernet | LAN8720 RMII + MDIO exposed | **dropped** (compute has no ethernet subsystem) |
| Debug | SWD only | **full SWJ-DP** — swclk, swdio, jtag_tdi, jtag_tdo(+oe), jtag_ntrst |
| `user_ref_clk` | single (aliased) | **separate `user_ref_clk_0` / `user_ref_clk_1`** |
| IRQs to PS | eth/phc_pps/phc_alarm/tidechart (4) | **only `tidechart_irq`** (D2D/link IRQs stay in the on-chip NVICs) |
| Role strap | `role_strap_i` | `role_strap_i_0` (link 0); `role_strap_i_1` fixed const (link 1 tied off) |
| LEDs | link_active / role_is_master | `link_active_o_0` -> led0, `role_is_master_o_0` -> led1 |

`dap_swj_enable` and `dap_npotrst` are tied active INSIDE the packaged IP wrapper,
mirroring the ASIC chip-boundary ties
(`sys_desc/chip_boundary/nanosoc_compute_chiplet.yaml`).

## Build order (run from the tidelink repo root)

```
# 0. Flatten the parent repo's SoC + tidelink source lists (single source of truth)
make -C .. elab                        # writes build/elab/{soc,tidelink}_vcs.f

# 1. Env
source ../set_env.sh
export TIDELINK_PHY_V2=1                # MANDATORY (silent-V1 trap otherwise)

# 2. SCOPING SYNTH — the go/no-go. OOC-synthesises the entire compute SoC + both
#    links on xck26 and is the first proof it fits. Expect it to surface FPGA
#    memory-model gaps (behavioural SRAM -> BRAM). Needs NO block design.
make -C fpga package_compute_chiplet_ip
#    -> reports/util/timing in imp/fpga/run/package_compute_chiplet_ip.log

# 3. Only once (2) is clean: the full board build (PS8 BD + bitstream)
make -C fpga package_phc_ip
make -C fpga build_design TARGET=kr260-compute-chiplet       # die_a
make -C fpga build_design TARGET=kr260-compute-chiplet-flip  # die_b
```

## What is in place

- **IP packaging** (`fpga/vivado_ip/`): `nanosoc_compute_chiplet_filelist.tcl`
  (parses the parent's flattened `.f` lists + tidechart.flist + the 3 integration
  RTL files), `nanosoc_compute_chiplet_vivado_wrapper.v` (ps_ahb_s AHB backdoor,
  two GPIO-PHY ribbons, full SWJ-DP, tidechart IRQ; scan/qspi/nego/PUF tied off,
  link-1 pads exposed for the BD to tie off), `package_compute_chiplet_ip.tcl`
  (packages `soclabs.org:user:nanosoc_compute_chiplet_vivado_wrapper:1.0`, memory
  map on `ps_ahb_s`).
- **Board wrapper**: `tidelink_design_wrapper.v` — the four IOBUFs (i2c0 scl/sda,
  swdio, jtag_tdo) + BD instance. Board port names match the XDC.
- **BD**: `tidelink_design.tcl` — PS8 + clk_wiz + PHY /8 divider + proc_sys_reset
  + SmartConnect + axi_ahblite_bridge -> ps_ahb_s + role-strap constants + link-1
  tie-off constants + tidechart IRQ concat + address map.
- **PHY divider**: `tidelink_phy_clk_div2.v` (copied unchanged from the eth target).
- **Constraints**: the `*.xdc` (pin / timing / drc) are the constraints agent's
  deliverable, using the SAME board port names as the wrapper here.

## Constraints coordination — SWJ-DP pin reconciliation (CONVERGENT, flagged)

The board wrapper (`tidelink_design_wrapper.v`) top ports and the pin XDC
(`kr260_compute_chiplet_tidelink.xdc`) converge on the SAME collapsed SWJ-DP form,
but the first-cut XDC currently ships PLACEHOLDER split pads. The XDC's own note
(its SWJ-DP section) documents the reconciliation target, and this wrapper already
implements it:

| Signal | Wrapper board port (this file) | XDC today | Reconcile to |
|---|---|---|---|
| SWDIO | `swdio` (inout, IOBUF `.I(swdio_o) .O(swdio_i) .T(~swdio_oe)`) | split `swdio_i/o/oe` placeholders | `swdio` inout on J10 |
| JTAG TDO | `jtag_tdo` (inout, IOBUF, `.T(jtag_tdo_t)` = dap_ntdoen) | split `jtag_tdo` + `jtag_tdoen` | `jtag_tdo` inout on F12 |
| SWCLK / TDI / nTRST | `swclk` / `jtag_tdi` / `jtag_ntrst` | match | (no change) |
| SWD PoR | not bonded (`dap_npotrst` tied 1'b1 in the IP wrapper) | `swd_nporesetn` pad present | drop from XDC |
| I2C0 | `i2c0_scl` / `i2c0_sda` inout (IOBUF i/o/t) | match | (no change) |

**Action for the XDC (its SCOPING-TODO, not the wrapper's):** collapse the split
`swdio_*` pads to one `swdio` inout, collapse `jtag_tdo`+`jtag_tdoen` to one
`jtag_tdo` inout, and drop `swd_nporesetn` (this wrapper ties `dap_npotrst` active
internally per the chip-boundary spec). The GPIO-PHY / I2C / UART / LED names
already match 1:1.

## Known iteration points (marked `SCOPING-TODO` in tidelink_design.tcl)

The block design is a **first-cut** — the OOC scoping synth (step 2) is the gate;
the BD is the next phase and needs Vivado work on:

1. **FPGA memory models.** The compute SoC's imem/dmem/shared_sram are behavioural
   in sim; xck26 synth needs the BRAM variants. Most likely blocker step 2 surfaces.
2. **`ps_ahb_s` clock association.** The SoC derives its own hclk from `sys_fclk`;
   if it divides, the AXI→AHB bridge (and SmartConnect) must run on the chiplet's
   `sys_hclk` output, not `clk_wiz/clk_out1`. Same open question the eth chiplet
   flagged for `eth_ss_0`.
3. **PS8 preset + address map.** Confirm the `CONFIG.PSU__*` set from a KR260 preset
   export and the HPM0 `ps_ahb_s` window base/range the firmware expects — the
   packaged IP `.hwh` aperture is authoritative (scaffold uses base 0x8000_0000,
   range 1 GB per the eth precedent).
4. **Link-1 tie-off clock.** `user_ref_clk_1` is driven from `clk_out1` so the
   tied-off link-1 domain has a valid clock. If link 1 is ever activated it needs
   its OWN /8 PHY divider and a link-1 source-synchronous timing XDC (as link 0).
5. **Dual `user_ref_clk` frequencies.** Confirm the per-link user_ref frequency
   against the SoC timing budget (link 0 is the /8 = 3.125 MHz PHY clock).
6. **IRQ set.** Only `tidechart_irq` reaches the chiplet boundary; the D2D/TideLink
   vectors are routed to the on-chip NVICs internally. Confirm whether the PS needs
   any additional PL-visible IRQ — if so it must be surfaced in the SoC RTL first.
7. **Finding G1 (DEVICE_CLASS).** A TideChart PARAMETER (defaults 16'h0001, wins the
   root election), not a chiplet port — per-die strapping needs a one-line RTL
   change to surface it. Until then pin die_a grandmaster by `role_strap_i_0`; do
   not rely on auto-election.

## die_a vs die_b (flip)

`kr260-compute-chiplet-flip` (die_b) differs from die_a in exactly two things:
the **XDC swaps the TX/RX ball-sets** (straight vs flipped ribbon) and the **role
strap constant defaults to 1** (`CONFIG.CONST_VAL {1}` in the flip's
`tidelink_design.tcl`). Everything else (wrapper, PHY divider, timing/drc XDC) is
identical. **Pair the die_a image with the -flip image** — same image on both boards
shorts every ribbon lane.

## SWD / JTAG bring-up

Full SWJ-DP on PMOD2 (3.3V). Reuses the multicore OpenOCD flow — external
ST-Link/DAPLink, `transport select swd` (SWDIO/SWCLK), with the JTAG TAP
(TDI/TDO/nTRST) also broken out for a `transport select jtag` probe if wanted. See
the SWD constraints folded into `kr260_compute_chiplet_tidelink.xdc`.
