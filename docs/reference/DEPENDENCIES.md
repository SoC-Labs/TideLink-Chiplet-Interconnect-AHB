# TideLink — External Dependencies and Submodule Policy

This document lists every third-party / external code unit TideLink
depends on, what it provides, and the policy for editing it (don't,
mostly).

## Submodule: `deps/axi-chiplet-controller`

**Upstream:** `git@git.soton.ac.uk:soclabs/chiplets/axi-chiplet-controller.git`
**Recorded SHA on `main`:** see `git ls-tree HEAD deps/axi-chiplet-controller`
**Tracked branch in `.gitmodules`:** `main` (current). Two feature
branches also exist on the submodule's `origin`:

  - **`feat/tidelink-integration`** (`a9ec909a` as of 2026-05-23): the
    named pointer for the TideLink-integrated state of the submodule,
    created per
    `/home/dam1n19/SoCLabs/td-bisect/axi-chiplet-controller_main_rewrite_plan.md`
    (non-destructive half only — the plan's destructive `main` rewrite +
    force-push is DEFERRED). The branch currently sits one commit ahead
    of `main` (= `2f602d1`) because it was fast-forwarded onto the
    `feat/remove-mark-debug` tip (`a9ec909a`). That's a one-commit
    forward-look at the `mark_debug` cleanup; it is functionally
    equivalent to the `main`-recorded state for the RTL TideLink builds
    out of (mark_debug attrs do not synthesize), but is NOT yet
    HW-validated.
  - **`feat/remove-mark-debug`** (`a9ec909a`): disables the 15 active
    `(* mark_debug = "true" *)` attrs in `WlinkRxLinkLayer.v` to remove
    the auto-inserted dbg_hub at source (cleans the persistent WHS noise
    that the three prior XDC waiver attempts couldn't catch). Parked
    awaiting bridge1 lease for 16/16 lock HW validation before merge.
  - **`feat/cdc-fix-wip`** (`0086e1b`): the structural `tl_calibration_cdc`
    instantiation. Not needed for V1 per CDC audit §9; parked
    indefinitely.

Switching `.gitmodules` to track `feat/tidelink-integration` is cosmetic
and intentionally not done yet; the recorded SHA on parent `main`
(`2f602d1`) resolves regardless of branch.
**Provides:**

- `logical/wlink/` — the Wavious Wlink IP (LL + TL + GPIO PHY,
  Chisel-generated Verilog tree). Includes:
    * `Wlink.v` — top-level Wlink wrapper
    * `WlinkRxLinkLayer.v` — receive link layer
    * `WavD2DGpio*.v` — GPIO PHY (TX, RX, top)
    * `WlinkGenericFCSM_*.v` — FC state machines
    * `WavMultibitSync.v`, `WavDemetReset.v`, `WavResetSync.v`,
      `WavClockMux.v`, `WavClockInv.v`, `WavFastDigDivBy2.v` —
      Wavious standard-cell synchronizer / clock-utility library
- `logical/top/axi_chiplet_controller.sv` — the chiplet controller
  wrapper that TideLink instantiates as `u_chiplet_controller`. Owns:
    * APB register file (Region 0-8)
    * Autoneg FSM (role lock, I²C arbitration)
    * IDELAYE2 RX wrapper instantiation (FPGA target)
    * BUFG / WavClockMux instantiation for the recovered RX clock
    * `tl_calibration_cdc` instantiation point (parked on
      `feat/cdc-fix-wip` — not on main)
- `logical/i2c/` — the I²C master + slave AXIL cores used for autoneg
- `logical/phy-align/` — alignment-specific submodules (calibrator
  fragments that the parent repo's `src/rtl/tidelink_phy_align_*`
  modules reference)
- `logical/xhb500/` — XHB500 AHB-to-AXI bridge generator output

**Edit policy:**
- The parent repo owns the wrapper boundary
  (`tidelink_top.sv` ↔ `axi_chiplet_controller.sv`). All TideLink-
  specific changes go in `src/rtl/` of the parent.
- Edits to the submodule's `axi_chiplet_controller.sv` (e.g.
  `tl_calibration_cdc` instantiation, autoneg bug fixes) MUST go on a
  feature branch of the submodule + a matching feature branch of the
  parent. They MUST HW-validate (`bringup_pair_converge.sh STABLE=3`
  on bridge1 + 16/16 lock) before being squashed into main.
- Edits to Wlink-generated files (`Wlink.v`, `WavD2D*`, etc.) are
  manually applied patches on top of the Chisel output. If the Chisel
  source is regenerated upstream, those patches must be re-applied.
  Track such patches with a comment block at the start of the edit
  region — search `SoC Labs ILA` and `SoC Labs §9` for examples.
- The Wavious synchronizer library (`Wav*` files) is treated as
  vendor read-only. SpyGlass recognises `WavDemetReset` /
  `WavMultibitSync` as qualified synchronizer cells.

## Submodule: `deps/xhb500`

**Provides:** the XHB500 AHB-to-AXI bridge generator
**Generated output:** `deps/xhb500/generated/` (kept in tree to avoid
re-running the generator on every clone)
**Edit policy:** treat as vendor read-only. The generator is invoked
by `fpga/Makefile`'s `xhb500` target if `XHB500_IP_DIR` is missing.

## Vendor IP: Arm CMSDK (BP210)

**Path:** `${CMSDK_DIR}` (default
`${ARM_IP_LIBRARY_PATH}/Corstone-101/BP210-r1p1-00rel0/BP210-BU-00000-r1p1-00rel0`,
falls back to standalone `BP210/BP210-BU-00000-r1p1-00rel0` per
`cdc/Makefile` line 6).
**Provides:**

- `logical/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v`
- `logical/cmsdk_ahb_to_apb/verilog/cmsdk_ahb_to_apb.v`
- `logical/models/memories/cmsdk_fpga_sram.v` (sometimes missing —
  fall back to `${CMSDK_FPGA_SRAM_V}` env, see
  [`project_cmsdk_fpga_sram_workaround`](../../.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/project_cmsdk_fpga_sram_workaround.md))
**Edit policy:** vendor read-only. Per-flist references via
`${CMSDK_DIR}` so the path is overridable.

## FPGA Tools

- **Vivado 2024.1** at `/apps/Xilinx/Vivado/2024.1/bin/vivado`
- **VCS T-2022.06-SP2** at `/eda/synopsys/2022-23/RHELx86/VCS_2022.06-SP2`
- **SpyGlass T-2022.06-SP2** at `/eda/synopsys/2022-23/RHELx86/SPYGLASS_2022.06-SP2`
- **Cadence Xcelium 22.03-s005** for HAL lint
- **Synopsys Fusion Compiler** for ASIC synth (`syn/asic/fusion-compiler/`)
- **Synopsys Design Compiler** for legacy ASIC synth (`syn/asic/design-compiler/`)
- **PYNQ Linux + fpga_manager** on the Zynq-7020 boards (PYNQ image,
  user `xilinx`, password `xilinx` by default)

## Sibling Repos

- **`~/SoCLabs/ptp-hardware-clock-ahb`** — the PHC IP. The FPGA build's
  `fpga/Makefile::package_phc_ip` packages this into the SmartConnect
  for the `-all` targets. Required by the production -all builds at
  `PHC_REPO_DIR` (default `$HOME/SoCLabs/ptp-hardware-clock-ahb`).
- **`~/SoCLabs/tidechart`** — the TideChart dynamic chiplet-ID protocol
  (separate peer repo; not used by current TideLink build path, but
  referenced from the autoneg architecture).
- **`~/SoCLabs/fpgahub`** — the FPGA-hub lease + deploy tooling (`fpgahub
  pair lease acquire bridge1 --ttl <s>`).

## CI Runners

- **`xcelium`** tag — Cadence Xcelium HAL lint
- **`vcs`** tag — Synopsys VCS UVM / cocotb
- **`bridge1-runner`** tag — bridge1 PYNQ-Z2 pair HW tests
  (`hwtest:safe` / `hwtest:full` / `hwtest:soak`). These jobs are
  `allow_failure: true` when no bridge1-runner is registered, so
  pipelines stay green when the lab is offline.

## Updating Dependencies

When a submodule is updated (e.g. a Wlink Chisel regen drops in):

1. Cherry-pick / re-apply any TideLink-specific patches to the
   regenerated tree.
2. Run `make -C cdc cdc` (SpyGlass CDC) — should be clean per
   `docs/reference/SPYGLASS_CDC_SIGNOFF.md`.
3. Run `make -C cocotb regression` — should be green per
   [`cocotb/README.md`](../cocotb/README.md) "Known-excluded-from-CI".
4. Run a `-all` farm build + bridge1 16/16 lock validation
   (`bash fpga/scripts/build_farm.sh pynq-z2-pair-all@local
   pynq-z2-pair-flip-all@srv04936` + `bringup_pair_converge.sh STABLE=3`
   with manifest provenance).
5. Update the recorded submodule SHA on `main`.
