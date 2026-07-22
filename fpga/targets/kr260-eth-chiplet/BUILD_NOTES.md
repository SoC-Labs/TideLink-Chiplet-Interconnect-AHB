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

## What is in place

- **IP packaging** (`fpga/vivado_ip/`): `nanosoc_eth_chiplet_filelist.tcl`
  (parses the parent's flattened `.f` lists), `nanosoc_eth_chiplet_vivado_wrapper.v`
  (eth_ss_0 AHB backdoor, GPIO-PHY pads, SWD, IRQs; RMII/scan/etc tied off for
  M1), `package_eth_chiplet_ip.tcl`.
- **Constraints**: `kr260_eth_chiplet_tidelink.xdc` (J21 ribbon pads + PMOD0
  LEDs + spare-pin UART + **SWD on PMOD4** L2/T7/AF7), timing + drc copied from
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

Reuses the PYNQ-Z2 OpenOCD flow unchanged — external ST-Link/DAPLink on PMOD4,
`transport select swd`. See `pynq/scripts/openocd/nanosoc_multicore.cfg` and the
`swd_pmod4` constraints folded into `kr260_eth_chiplet_tidelink.xdc`.
