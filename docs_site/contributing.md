# Contributing

TideLink is a tapeout-intent subsystem with live hardware attached to it. The
conventions below exist because each one has already been paid for once.

## Repository layout

One line per top-level directory:

| Directory | Contents |
|---|---|
| `cdc/` | SpyGlass CDC sign-off: `Makefile`, `tidelink_top.sgdc`, `waiver.swl`, per-module reports. |
| `ci/` | GitLab CI helper scripts — JUnit converters, dashboard and wiki generators, PPA parsers. |
| `cocotb/` | 60 cocotb verification environments (55 with a Makefile), plus `lint/` and `debug/` harnesses. |
| `deps/` | Three git submodules (`axi-chiplet-controller`, `tidelink-gpio-phy`, `tidelink-phy`) plus the in-tree `xhb500/` generator configs. |
| `docs/` | Engineering documents, runbooks, handovers and `BUG_REGISTRY.yaml`. The working record. |
| `docs_site/` | This ReadTheDocs site (Sphinx + MyST). |
| `flists/` | 30 file lists — build-target flists and per-module unit flists (plus one `.flist.md` note). |
| `flows/` | ASIC PnR / GDSII flow includes (`makefile.asic`), included by the root `Makefile`. |
| `fpga/` | FPGA build system: `targets/<target>/`, `vivado_ip/`, farm and hardware-regression scripts. |
| `imp/` | Build and run outputs — `imp/sim_gate/`, `imp/fpga/output/`, `imp/ASIC/`. Not source. |
| `lint/` | Cadence Xcelium HAL lint driver and module lists. |
| `public/` | Published static HTML landing page. |
| `pynq_host/` | Host-side board tooling: `scripts/hwtest/` (the numbered suite), deploy and bring-up scripts, GUIs. |
| `python/` | Installable `tidelink` Python package — packet-encoding helpers used by cocotb via `PYTHONPATH`. |
| `scripts/` | Repository utilities (`rdl2c.py`, bug-registry HTML generator and server). |
| `src/` | The design: `rtl/` (62 files, ~50k lines), `rdl/` (register description), `sw/` (C headers and PHC driver). |
| `syn/` | ASIC synthesis: `design-compiler/`, `fusion-compiler/`, `formality/`, `primetime/`, `dft/`, `calibre/`. |
| `sys_desc/` | System description (`tidelink.yaml`). |
| `uvm/` | Seven UVM environments sharing one Makefile interface. |
| `v1-release/` | Frozen v1 release snapshot with `CHECKSUMS.sha256` and `PROVENANCE.md`. |
| `xprop/` | X-propagation runs via Synopsys VC Formal. Not assertion-based FPV. |

Root files worth knowing: `set_env.sh` (mandatory, see below), `Makefile` (the
gate lives here), `flists/`-driven builds, and `.readthedocs.yaml`.

## The read-only IP-library rule

:::{danger}
**Never modify, write, edit, delete, move, copy over, `chmod` or otherwise alter
anything under `/research/AAA/ip_library/**` or
`/research/AAA/phys_ip_library/**`.**

These trees hold shared, lab-wide vendor IP collateral — Arm Corstone/BP210,
XHB500, the TSMC memory compilers — that other engineers and CI builds depend
on. An edit silently corrupts builds across the whole lab.
:::

Read access is expected and fine: `CMSDK_DIR`, `XHB500_IP_DIR` and
`ARM_IP_LIBRARY_PATH` all point into those trees to source vendor RTL.

**If a fix appears to require an IP-library change**, do this instead:

1. Copy the affected file into `src/rtl/local_overrides/`.
2. Re-point the relevant flist(s) at the local copy.
3. Document the deviation in the file header — the existing overrides carry an
   SPDX line and a "MODIFIED by SoC Labs" note naming the bug they fix.

The same rule applies to submodules under `deps/`: never edit one in place.
`src/rtl/local_overrides/` exists precisely so that upstream stays pristine —
that is why it holds patched copies of `Wlink.v`, `WlinkRxLinkLayer.v`, the
`WlinkGenericFCSM*` family, the `WavD2DGpio*` PHY files and
`axi_chiplet_controller.sv`.

If a setup script resolves to a path under those trees, treat the destination
as authoritative and change the project-side wrapper, not the file it points at.

## Environment setup

Every flow in this repository requires:

```bash
source ./set_env.sh
```

It exports `TIDELINK_HOME`, `CMSDK_DIR`, `CMSDK_FPGA_SRAM_V`, `XHB500_IP_DIR`
and the tool homes, and on first run **generates** the two XHB500 bridges into
`deps/xhb500/generated/` from `deps/xhb500/configs/`.

:::{warning}
**Running the gate without sourcing `set_env.sh` fails every suite in 4–5
seconds** and looks exactly like RTL breakage. `sim_gate_env_check`
(`Makefile:305-317`) now refuses to start unless both `vcs` and `cocotb-config`
are on `PATH`, but ad-hoc runs are unprotected. **Always read one suite log
before theorising about a break.**
:::

Most V2 PHY work additionally needs `export TIDELINK_PHY_V2=1`.

## Branch conventions

`main` is the trunk. Work branches carry a type prefix and a short slug, and
dated integration branches carry the date:

| Prefix | Purpose | Example |
|---|---|---|
| `fix/` | A bug fix against a specific defect | `fix/z2-drop-park-hook` |
| `feat/` | New functionality | `feat/txgen-v1-integration` |
| `integ/` | Integration, consolidation and freeze candidates (dated) | `integ/tidelink-consolidated-2026-08-07` |
| `analysis/` | Investigation with no netlist change (dated) | `analysis/link-survey-2026-08-01` |
| `experiment/` | Throwaway measurement runs (dated) | `experiment/throughput-overnight-2026-07-31` |
| `confirm/` | Confirmation of a prior result (dated) | `confirm/i1-fix-throughput-2026-07-31` |
| `test/`, `docs/` | Test-only and documentation-only work | `docs/bug-registry-2026-08-07` |

Retired branches are preserved as tags under `archive/<date>-<reason>/`, not
deleted.

:::{caution}
**Prefer cherry-pick over rebase onto a live branch.** A rebase onto `main` was
rejected on 2026-07-30 because it silently reintroduced a commit that broke
eth-chiplet bring-up. Before rebasing onto any live branch, cross-check
`HEAD..target` against the known-live blockers **by commit hash**.
:::

## The `sim_gate` contract

`make sim_gate` is the merge gate. Its contract:

```bash
source ./set_env.sh
make sim_gate            # ~45-60 min, 43 blocking suites + 2 sentinels
make sim_gate_quick      # 14-suite smoke variant (SIM_GATE_QUICK_SUITES, Makefile:1206)
make sim_gate_inventory  # lists suites and cross-checks wiring; runs nothing
```

It depends on `sim_gate_env_check` and `sim_gate_clean_builds`, wipes and
recreates `imp/sim_gate/`, runs every suite, then scores them in
`sim_gate_summary`. Per-suite artefacts land at `imp/sim_gate/<suite>.log` and
`<suite>.status`. Exit is non-zero if any blocking suite is not `PASS` or any
sentinel is not `XFAIL`.

### Status vocabulary

| Status | Meaning | Blocks? |
|---|---|---|
| `PASS` | Suite ran and passed. | no |
| `FAIL` | Suite ran, assertions failed. | **yes** |
| `MISS` | No `.status` file — the suite never ran. | **yes** |
| `XFAIL` | A known-defect sentinel: the defect is present and **unchanged**. Reported in its own section, never as `PASS`. | no |
| `XCHG` | A sentinel's behaviour **changed**, in either direction. | **yes** |
| `XERR` | The sentinel harness itself broke. | **yes** |

### Rules the gate enforces, and the traps it does not

- **Every scored suite must be invoked.** `make sim_gate_inventory` cross-checks
  the scored list against the targets that actually run. This defect has
  shipped: `v2_mask_hs_bilateral` was scored but no target invoked it, so the
  gate reported `MISS` and could never pass.
- **Stale `simv` is real.** cocotb Makefiles track only `tb_top.sv` and
  `pad_skid.sv` as compile dependencies, so an RTL-only or flist-only edit does
  **not** retrigger a VCS compile and a cached `simv` silently tests old RTL.
  `make sim_gate` is protected — `sim_gate_clean_builds` (`Makefile:1219-1245`)
  `rm -rf`s the `sim_build*` directories using **globs**, deliberately, because
  an enumerated list rots. **Ad-hoc runs are not protected**: after any RTL
  edit, `rm -rf <suite>/sim_build*` or use a private `SIM_BUILD=`.
- **Never use `make -n sim_gate`.** The `sim_gate_run` macro writes
  `<suite>.status` unconditionally, so `-n` **echoes fake PASS files into
  existence**. Use `sim_gate_inventory` to inspect the gate without running it.
- **Cross-repo prerequisites fail per-suite, not globally.** `SIM_GATE_REQUIRE`
  (`Makefile:853-874`) makes the TideChart and Ethernet suites fail loudly on a
  missing sibling checkout while every other suite still runs.

## How to add a test

1. **Pick the layer.** Unit-level behaviour → a new or existing directory under
   `cocotb/`. Paired-die / system behaviour → one of the `*_pair*`
   environments. Constrained-random or scoreboarded system traffic → `uvm/`.

2. **Create the environment.** Copy the closest existing `cocotb/<suite>/`
   directory. Each needs a `Makefile` (`SIM = vcs`, `TOPLEVEL_LANG = verilog`),
   a `tb_top.sv`, and one or more `test_*.py` modules. `PYTHONPATH` already
   picks up `$(TIDELINK_HOME)/python`.

3. **Run it by hand first.** For example:

   ```bash
   cd cocotb/tidelink_top_pair_v2
   make EPOCH_PROFILE=zero MODULE=test_v2_pair_data
   ```

   Use a **private** `SIM_BUILD=` if the directory is shared with other suites,
   as `cocotb/tidelink_error_injection` is.

4. **Add a flist entry if you added RTL.** Apply RTL additions to **both** the
   FPGA and ASIC flists — a one-sided edit produces a split-brain where one
   flow elaborates and the other does not.

5. **Wire it into the gate.** Add a `sim_gate_<name>` target using the
   `sim_gate_run` macro, add the suite name to `SIM_GATE_ALL_SUITES`, and add
   the target to the aggregate `sim_gate` dependency list. If your suite needs a
   sibling repo, add a `SIM_GATE_REQUIRE` line.

6. **Prove the wiring.** Run `make sim_gate_inventory` and confirm it prints
   `OK — every declared suite is invoked`. A suite that is scored but never
   invoked makes the whole gate unpassable.

7. **If you are pinning a known defect** rather than fixing it, write it as an
   **XFAIL sentinel** with a signature specific enough that the behaviour
   changing produces `XCHG`. A sentinel whose pattern matches nothing is worse
   than no sentinel: it cries `XCHG` forever, or worse, sits comfortably
   `XFAIL` for the wrong cause.

## Other gates

| Command | What it checks |
|---|---|
| `make -C lint lint MODULE=<name>` | Xcelium HAL lint for one module. |
| `make -C lint lint-each` | All standalone and CMSDK modules. |
| `make -C cdc cdc MODULE=tidelink_top` | SpyGlass CDC (goal `cdc/cdc_verify`). |
| `make sim_synth_mode` | Verilator strict synthesisability lint. |
| `make xdc_lint` | Catches silently-dropped XDC constraints. |
| `make farm_gate` | **Mandatory before any farm build.** Ratcheted lint baselines plus the V2 pair sim at the silicon epoch fingerprint. |
| `make -C cocotb regression` | The 28 unit environments (see the scope caveat in {doc}`simulation_tests`). |

## Commit and gate expectations

- **`make sim_gate` must be green before any farm build and before any hardware
  deploy.** A sim-discoverable bug once burned 75 minutes of farm and deploy
  time. This is not negotiable.
- **`make farm_gate` must pass before kicking a farm build.** It exits non-zero
  specifically to refuse the build.
- **Never reload the PL on a live link**, and never chain `lease acquire` with
  board operations in one shell call — run `show` first, `acquire` alone, then
  work.
- **Verify the instrument before theorising about the DUT.** This has been the
  root cause often enough to be a standing rule: a broken measurement script
  reporting `best_run = 0` while data was actually landing cost a full debug
  cycle.
- **Do not write an unverified hypothesis into the repo as if it were
  measured.** If you did not measure it, mark it `UNVERIFIED`. Speculation
  committed as fact comes back later as circular self-corroboration.
- **Bug status is not self-certifying.** `docs/BUG_REGISTRY.yaml` sets
  `auto_signoff_allowed: false` with a status lifecycle
  `open → root_caused → fix_built → sim_proven → hw_proven → signed_off`.
  Anything that changes the netlist on the tapeout trunk, pushes to a public
  default branch, or is a rig or architecture decision is a **decision** and is
  never auto-signed. Sign-off is the approver's, not the author's.
- **Commit messages** follow `type(scope): summary` — for example
  `fix(fc): close a2l replay self-latch on ACK lap-ahead` or
  `gate(farm): re-ratchet sv_anti_pattern baseline`. Reference the registry ID
  (`TL-0NN`) when a commit moves a tracked bug.

## Building this documentation

See `docs_site/README.md` for the local build command and how ReadTheDocs
builds the same tree.
