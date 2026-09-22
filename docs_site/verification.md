# Verification

This page describes **how TideLink is verified, what the gate proves, and what
it does not**. The practical catalogue of individual suites and the exact
commands to run them live in [Simulation Tests](simulation_tests.md); the board
procedures live in [Hardware Tests](hardware_tests.md).

Everything below is verified against this checkout
(branch `fix/z2-drop-park-hook`, `9eaafb7`). Where a number could rot, the page
gives you the command that regenerates it rather than the number alone — that
is a rule the repo enforces on itself, because suite counts in prose have
rotted twice (`docs/SIM_GATE_COVERAGE.md` lines 17-24).

## The verification stack

| Layer | Tool | Entry point | Blocking in CI |
|---|---|---|---|
| Unit / module | cocotb + VCS | `make -C cocotb regression` (28 envs) | yes (`cocotb-regression`) |
| Paired-die / integration | cocotb + VCS | `make sim_gate` (43 suites + 2 sentinels) | yes (`sim-gate`) |
| Constrained-random / scoreboarded | UVM + VCS | `make -C uvm/<env> run_all` | partly — see [CI](#ci-what-actually-runs) |
| Elaboration integrity (FPGA + ASIC + DFT flists) | VCS elab only | 4 suites inside `make sim_gate` | yes |
| RTL lint | Cadence **HAL** (Xcelium) | `make -C lint lint MODULE=<m>` | yes (`hal-lint`) |
| Synthesisability lint | **Verilator** strict | `make sim_synth_mode` | via `farm-gate-lint` |
| Constraint lint | Python (`cocotb/lint/xdc_lint.py`) | `make xdc_lint` | via `farm-gate-lint` (ratcheted) |
| CDC | Synopsys **SpyGlass** | `make -C cdc cdc MODULE=tidelink_top` | yes (`spyglass-cdc`) |
| Formal | Synopsys **VC Formal — X-propagation only** | `make -C xprop regression` | **no CI job** |
| Pre-farm-build gate | shell + cocotb | `make farm_gate` | yes (`farm-gate-lint`, `farm-gate-sim`) |
| FPGA-in-the-loop | fpgahub + PYNQ-Z2 pair | `ci/fpga_run_pair.sh` | `allow_failure: true` |
| Silicon / board | `pynq_host/scripts/hwtest/` | `run_all.sh` | `allow_failure: true` |

:::{note}
**There are no SVA property proofs in this tree.** `docs/VERIFICATION_PLAN.md`
§1 states the toolchain explicitly as "Synopsys VC Formal **xprop**
(X-propagation, *not* assertion-based FPV — zero SVA proofs in tree today)".
The `xprop/` directory covers 14 modules (`xprop/Makefile` `STANDALONE_ENVS`
+ `CMSDK_ENVS`) and is wired into **no** CI job.
:::

## Environment setup

Every simulation flow needs the environment sourced from the repo root:

```bash
cd $TIDELINK_HOME
source ./set_env.sh
export TIDELINK_PHY_V2=1     # required for most V2 work; see below
```

`set_env.sh` exports `TIDELINK_HOME`, `CMSDK_DIR`, `CMSDK_FPGA_SRAM_V`,
`XHB500_IP_DIR`, `XHB500_GEN_DIR`/`_SLV_DIR`/`_MST_DIR`, `VCS_HOME`,
`VERDI_HOME`, `VIP_HOME`, and on first run **generates** the two XHB500 bridges
into `deps/xhb500/generated/` from `deps/xhb500/configs/`.

:::{warning}
**`set_env.sh` does not put VCS on `PATH`.** It sets `VCS_HOME` but contains no
`export PATH=...` (verified: the file has no `PATH` assignment). On a shell
where the tools are not already on `PATH` you also need what CI does at
`.gitlab-ci.yml:296`:

```bash
export PATH="$VCS_HOME/bin:$VERDI_HOME/bin:$PATH"
```
:::

### The 4-5-second whole-gate failure

:::{danger}
**If you forget `source ./set_env.sh`, every suite fails in 4-5 seconds and it
looks exactly like an RTL break.** This has cost real debugging time
(`docs/HANDOVER_Z2_PICKUP_2026_07_30.md:331`). Before theorising about the
design, **read one suite log**: `imp/sim_gate/<suite>.log`.

The gate now carries a guard for this — `sim_gate_env_check` (`Makefile:305`)
refuses to start unless both `vcs` and `cocotb-config` resolve on `PATH`:

```
sim_gate: vcs not in PATH — run 'source ./set_env.sh' first
```

The guard covers `make sim_gate` and `make sim_gate_quick` only. An ad-hoc
`cd cocotb/<suite> && make ...` gets no such protection.
:::

### The XHB500 generation trap

`set_env.sh`'s `_generate_xhb500()` pipes the generator through `sed` and then
tests `$?`, which is **`sed`'s** exit status, not the generator's — so a failed
generation can be reported as success. This is tracked as **TL-012** in
`docs/BUG_REGISTRY.yaml` (status `fix_built`). If a flow fails on missing
XHB500 sources, check `deps/xhb500/generated/*/logical/` actually exists rather
than trusting the setup banner.

## The `sim_gate` contract

`make sim_gate` is *the* pre-merge, pre-farm-build and pre-deploy gate.

```bash
source ./set_env.sh
make sim_gate            # ~45-60 min (banner: Makefile:1255)
make sim_gate_quick      # 14-suite smoke variant (Makefile:1206, 1325)
make sim_gate_inventory  # prints the authoritative lists; runs no simulation
```

| Property | Value | Where |
|---|---|---|
| Blocking suites | **43** | `SIM_GATE_ALL_SUITES`, `Makefile:1183` |
| Known-defect sentinels | **2** | `SIM_GATE_SENTINELS`, `Makefile:1203` |
| Quick-gate suites | **14** | `SIM_GATE_QUICK_SUITES`, `Makefile:1206` |
| Artefact directory | `imp/sim_gate/<suite>.log` + `.status` | `SIM_GATE_DIR`, `Makefile:210` |
| Prerequisites | `sim_gate_env_check`, `sim_gate_clean_builds` | `Makefile:1246` |
| Exit rule | non-zero unless every blocking suite is `PASS` **and** every sentinel is `XFAIL` | `sim_gate_summary`, `Makefile:1346-1385` |

Never copy the suite list into a document. Run:

```bash
make sim_gate_inventory
```

It prints both lists and then **cross-checks that every scored suite is
actually invoked**, ending with `OK — every declared suite is invoked`
(`Makefile:280-303`).

### Status vocabulary

| Status | Meaning | Fails the gate? |
|---|---|---|
| `PASS` | Suite ran and its assertions held. | no |
| `FAIL` | Suite ran, assertions failed. | **yes** |
| `MISS` | No `.status` file — the suite never ran. | **yes** |
| `XFAIL` | Sentinel: the known defect is present and **unchanged**. Printed in its own block, never as `PASS`. | no |
| `XCHG` | Sentinel: behaviour **changed**, in either direction — a human must look. | **yes** |
| `XERR` | Sentinel harness / precondition / environment broke. | **yes** |

`XFAIL` and `FAIL` are deliberately distinct substrings so the two scoring
loops in `sim_gate_summary` can never confuse them. The sentinel machinery is
`sim_gate_sentinel` (`Makefile:1014-1026`): it runs the module, then matches
the log against **fixed strings** (not regexes — the verdict lines contain
`{}`, `''` and `/`, and an ERE would rot into a pattern that silently matches
nothing).

:::{note}
**Why sentinels exist at all.** Some benches record a wedge or a silent
corruption as a `VERDICT[...]` log line rather than a test failure, so
`make MODULE=test_ei_lane7_repro` **exits zero while demonstrating a defect**.
Gating those the ordinary way would print a green `PASS` next to a chip-killer.
A sentinel is the only shape that is *never green* and *only red on news*
(`docs/SIM_GATE_COVERAGE.md` §3.1).
:::

## What a green gate does *not* prove

This section matters more than the pass list. `docs/SIM_GATE_COVERAGE.md` §7
maintains the authoritative gap table; the load-bearing items:

| Not proven by a green `sim_gate` | Why | Where it *is* (or is not) covered |
|---|---|---|
| The two sentinels are fixed | `XFAIL` means the defect is **present and unchanged** | `xfail_f14b_datamode_wedge` (a data-mode disturbance wedges until a POR of **both** dies); `xfail_epoch_shipping_corrector` (the *shipping* corrector configuration shears) |
| Behaviour under real whole-word lane skew | no whole-word corrector is armed in the V2 build; `EPOCH_PROFILE=zero` is pinned on the eth suites | `docs/SIM_GATE_COVERAGE.md` §4 |
| XHB peer-window round trip | the pair testbench does not model the peer-side XHB500 target memory | silicon only, `fpga/hw_regression/td_v2_channels.sh --channels xhb` |
| Throughput / sustained soak | wall-clock, not a correctness gate | board soak scripts |
| Two-board PTP convergence | needs two real PHCs | never run end-to-end on hardware |
| On-silicon PHY BIST / BER | no production bitstream contains it | nothing — a standing gap |
| TideChart on hardware | `tc_pair_*` are sim-only | nothing |
| That the green result belongs to *your* checkout | `make sim_gate` writes **no commit stamp** — the Makefile contains zero `rev-parse` calls, and `imp/sim_gate/` holds only `.log` and `.status` files | see the provenance warning below |

:::{danger}
**`imp/sim_gate/` carries no provenance on this branch.** A green directory can
have been produced by a *different branch's* Makefile — this exact confusion is
recorded as finding **A2** in `docs/VERIFICATION_AUDIT_2026_07_30.md`. By
contrast `fpga/farm_gate.sh` *does* stamp its pass token with the SHA
(`fpga/farm_gate.sh:424`, `:447-450`, `FARM_GATE_STAMP`). Until `sim_gate`
gains the same, treat an inherited `imp/sim_gate/` as **unattributed** and
re-run the gate yourself.
:::

:::{warning}
**Two trees diverge.** `docs/BUG_REGISTRY.yaml` records that
`integ/axirec-on-chiplet` carries the recovery / PTP / header-ECC fixes and
their gates, while this standalone branch carries **none** of them — so several
registry items are structurally open *here* as a merge/pin gap, not as unfixed
RTL. Neither line is on `main`. See [Known Issues](known_issues.md).
:::

## The documented traps

### 1. A suite scored but never invoked

A suite name can sit in `SIM_GATE_ALL_SUITES` while no target in the aggregate
runs it. `sim_gate_summary` then scores it `MISS` and the gate **can never
pass**. This shipped on this branch: `v2_mask_hs_bilateral` was scored but
uninvoked (audit finding A1), and it was the only executable test able to catch
a sham mask handshake — so the mask gate had no asserting coverage at all.

**Defence:** `make sim_gate_inventory` cross-checks declared-vs-invoked and
exits non-zero on an orphan. Run it after touching the gate wiring.

### 2. A stale `simv` silently testing old RTL

cocotb's build rule is `$(SIM_BUILD)/simv: $(VERILOG_SOURCES)
$(CUSTOM_COMPILE_DEPS)`. In most benches `VERILOG_SOURCES` lists only the
testbench; the DUT arrives via `COMPILE_ARGS += -f <flist>`, which `make`
cannot see. Without `CUSTOM_COMPILE_DEPS`, an RTL-only edit changes no
prerequisite and `make` **re-runs the previous binary**. This has already
produced a false "hazard refuted" result once.

Current, measured state of the defence on this checkout:

| Defence | State |
|---|---|
| `make sim_gate` cleans build dirs first | `sim_gate_clean_builds` (`Makefile:1219-1245`) `rm -rf`s `sim_build*` using **globs** — deliberately, because an enumerated list rots |
| Per-bench dependency tracking | **25 of 55** cocotb Makefiles `include $(TIDELINK_HOME)/cocotb/flist_deps.mk`, which adds the flist and every bare source path it lists to `CUSTOM_COMPILE_DEPS` |
| Benches that name their RTL explicitly | e.g. `cocotb/tidelink_txgen/Makefile:33` sets `CUSTOM_COMPILE_DEPS` by hand — `make` can see those sources |
| Residual exposure | **two** flist-sourced benches have neither guard: `cocotb/honest_mask_hs/Makefile` (`-f ...tidelink_top_full_asic_v2.flist`, line 52) and `cocotb/tidelink_fifo_twin2/Makefile` (`-f ...tidelink_fifo.flist`, line 36) |

:::{warning}
`cocotb/tidelink_fifo_twin2` is a **gated** bench (suite `fifo_rx_twin2_tree`),
and it is *not* in the `sim_gate_clean_builds` glob list
(`Makefile:1230-1237`) nor does its target `rm -rf` its build dir
(`Makefile:1103-1105`). Both facts are verifiable in the Makefiles. Treat a
green `fifo_rx_twin2_tree` after an RTL-only edit with suspicion and clean the
directory by hand.

**Ad-hoc runs are never protected.** After any RTL edit:
`rm -rf cocotb/<suite>/sim_build*`, or pass a private `SIM_BUILD=`.
:::

### 3. `make -n sim_gate` fabricates PASS files

The `sim_gate_run` macro's recipe body writes `<suite>.status`, and a dry run
echoes it into existence — reproduced 2026-07-18, when
`make -n sim_gate_nack_wedge` emitted `nack_wedge_recovery PASS 4s` into
`imp/sim_gate/`. The macro now **detects `-n` in `MAKEFLAGS` and refuses**
(`Makefile:234-249`), but the rule stands: **never use `-n` to validate the
gate.** Use `make sim_gate_inventory`, or read the Makefile.

### 4. Cross-repo prerequisites

Six suites need sibling checkouts. `SIM_GATE_REQUIRE` (`Makefile:858`) fails
**only the dependent suites**, loudly, while the rest of the gate still runs —
deliberately, and deliberately not a silent skip.

| Suites | Variable (default) | Probed file |
|---|---|---|
| `tc_pair_smoke`, `tc_pair_election_datamode` | `TIDECHART_HOME` (`../tidechart`) | `flist/tidechart.flist` |
| same | `CHIPLET_HOME` (`../nanosoc-ethernet-chiplet`) | `src/rtl/tidechart_shim.sv` |
| `eth_relay_m0`, `eth_relay_m1`, `eth_regs_shape_a` | `ETH_SS_HOME` (`../nanoSoC-refactor/ethernet-subsystem-ahb`) | `set_env.sh` |

Defaults are at `Makefile:871-872` and `Makefile:934`. CI clones all three
siblings in the `clone` job (`.gitlab-ci.yml:123-127`).

### 5. Never co-schedule a Vivado build with `sim_gate`

A co-scheduled Vivado build once SIGKILLed the simulator mid-run. The sentinel
reported `XERR` rather than a misleading `XFAIL` — the machinery worked, but
the run was wasted (`docs/SIM_GATE_COVERAGE.md` §3.1).

## Lint

### RTL lint — Cadence HAL

```bash
make -C lint lint                    # MODULE defaults to `tidelink`
make -C lint lint MODULE=tidelink_fc_adapter
make -C lint lint-synth              # synthesisability checks only (-nohalcheck)
make -C lint lint-all                # -check ALL
make -C lint lint-standalone         # every module with no CMSDK dependency
make -C lint lint-each               # standalone + CMSDK modules
make -C lint report                  # extract errors/warnings from the last log
make -C lint gui
make -C lint help
```

`MODULE` selects `flists/<MODULE>.flist`; the elaboration top is `MODULE`
except for two remapped names (`TOP_tidelink = tidelink_fifo`,
`TOP_tidelink_fifo = tidelink_fifo_mem`, `lint/Makefile`). Nineteen standalone
modules and four CMSDK-dependent modules (`tidelink_fifo`, `tidelink`,
`tidelink_ahb`, `tidelink_fifo_ahb`) are listed in `lint/Makefile`; `make -C
lint help` prints them. Waivers live in `lint/hal.tcl`. CI runs this as
`hal-lint` on the `xcelium` runner.

### Synthesisability lint — Verilator

```bash
make sim_synth_mode        # runs make -C cocotb/lint -f Makefile.synth lint
make synth_lint_selftest   # proves the gate catches CASEINCOMPLETE / WIDTH / BLKANDNBLK
```

### Constraint lint — XDC

```bash
make xdc_lint            # python3 cocotb/lint/xdc_lint.py fpga/targets/
make xdc_lint_selftest
```

:::{warning}
**`make xdc_lint` exits non-zero on this branch.** Measured on this checkout:
`scanned 67 XDC file(s)` … `FAIL — 5 XDC finding(s)`, all
`XDC_NESTED_PROC_TCL` on line 18 of `pynq_z2_tidelink_timing.xdc` in five
`pynq-z2-*` targets. Those five are **accepted debt**, ratcheted in
`fpga/farm_gate_xdc_baseline.txt`, which is why `make farm_gate_fast` is green
while the bare lint is red. The gate fails only on findings *not* in the
baseline.
:::

### Meta-gates

```bash
make robust_all       # xdc_lint_selftest + synth_lint_selftest + xdc_lint + sim_synth_mode + sim_robust
make sim_robust       # adversarial cocotb tests under cocotb/debug/sim_robust/
make farm_gate        # MANDATORY before any farm build (bash fpga/farm_gate.sh)
make farm_gate_fast   # Tier-0 lint only; NOT a build gate
```

`farm_gate` is two tiers: **Tier-0** (seconds, pure Python) is `xdc_lint` +
`sv_anti_pattern`, each ratcheted against `fpga/farm_gate_xdc_baseline.txt` /
`fpga/farm_gate_sv_baseline.txt`; **Tier-1** (minutes) runs the V2 pair sim at
the silicon-faithful configuration. It exits non-zero to *refuse* a farm build,
and `build_farm.sh` consumes its SHA-stamped pass token. Per-check skips and
`FARM_GATE_STRESS=1` (promotes the silicon tier to blocking) are documented in
the script header, `fpga/farm_gate.sh:81-101`.

Both baselines are **content-keyed, not line-keyed** (since 2026-08-24). Each
linter emits a stable discriminator — `[key=<signal>]` for `COMB_NO_DEFAULT`,
`[key=<case selector>]` for `CASE_NO_DEFAULT`, `[key=<constraint text>]` for the
XDC rules — and the ratchet compares those, as a *multiset*, ignoring line
numbers. Two consequences worth knowing before you touch a baseline:

* **Adding lines above a finding no longer turns the gate red.** The previous
  line-based key drifted six times on one untouched `always_comb`, and each
  drift was answered by re-ratcheting — a habit that accepts genuinely new
  findings unread. If the gate is red now, something really changed.
* **Do not "refresh" a baseline to make it green.** Fix the finding and delete
  its line, or read it and add it deliberately. A repeated key is listed once
  per occurrence (`tidelink_lane_deskew_v2.sv` has two `di` iterators), so
  deleting a duplicate silently widens the waiver.

## CDC

```bash
make -C cdc cdc                      # MODULE defaults to tidelink_top
make -C cdc cdc MODULE=tidelink_fifo
make -C cdc cdc-report               # re-extract the summary from the last run
make -C cdc help
```

| Item | Value |
|---|---|
| Tool | SpyGlass `vT-2022.06-SP2` |
| Goal | `cdc/cdc_verify` |
| Project / constraints | `cdc/tidelink_top.prj`, `cdc/tidelink_top.sgdc`, `cdc/axi_chiplet_controller.sgdc`, `cdc/xhb500.sgdc` |
| Waivers | `cdc/waiver.swl` |
| Reports | `<MODULE>/<MODULE>/cdc/cdc_verify/spyglass_reports`, summarised into `<MODULE>_cdc_summary.rpt` |

**Sign-off record** — `docs/reference/SPYGLASS_CDC_SIGNOFF.md`, re-run
2026-05-28 at integration SHA `6666c1be` with `deps/tidelink-gpio-phy @ d00dd88`
and `deps/axi-chiplet-controller @ c0a69ff`:

> 0 fatals, 0 errors, 4 warnings (none CDC), 0 unsynchronized crossings,
> 0 convergences. **Verdict: GO.**

The earlier 2026-05-23 baseline in the same file records the conditional pass
and why the eight `Ac_unsync01/02` "errors" were constraint-file gaps on
top-level primary inputs, not RTL defects. CDC design details and the two real
quasi-static crossings are covered in [Integration](integration.md).

## Formal — X-propagation

```bash
make -C xprop regression       # all 14 modules
make -C xprop standalone       # the 12 with no CMSDK dependency
make -C xprop tidelink_fifo_ctrl
```

Synopsys VC Formal X-prop over `tidelink_fifo_ctrl`, `tidelink_returner`,
`tidelink_apb_regs`, `tidelink_phc_cdc`, `tidelink_perf`, `tidelink_mul_iter`,
`tidelink_apb_addr_ctrl`, `tl_addr_trans_cam`, `tl_addr_trans_regs`,
`tidelink_idelay_rx`, `tidelink_rxclk_buf`, `tidelink_clkfreq_check`
(standalone) plus `tidelink_fifo` and `tidelink` (CMSDK). **No CI job runs
it** — treat any xprop result as run-on-demand evidence with a date attached.

## What counts as a valid regression test here

The project's recorded failure mode is not "the fix was wrong". It is *"the fix
was never gated, so it rotted out and nobody noticed"*
(`docs/SIM_GATE_COVERAGE.md` §0) — the XHB channel fix silently rotted out of
three branches, and `make sim_gate` was wired into **no** CI hook until
2026-07-16. So a test earns its place only if it satisfies all of the
following.

1. **Reproduce first.** The test must fail against the pre-fix RTL or
   configuration. "We ran it once and it passed" is not a state this repo
   recognises.
2. **Carry a negative control that fails when the fix is reverted.** Without
   one, a green result is vacuous. In-tree examples you can copy:

   | Control | Mechanism |
   |---|---|
   | `txgen_negctl` | recompiles with the credit gate **removed** and asserts the generator *does* send at zero peer credit — the complement of the gate-in refusal |
   | `v2_lane_mask_negctl` | the lane-mask sweep's complement arm |
   | `retire_en_plumb` | identical stimulus to `t31` with **one parameter flipped** (`RETIRE_EN=0`) and the opposite outcome asserted, with a hierarchical read-back taken *inside* the controller |
   | `epoch_anchor_plumb` | the measured A/B for `EPOCH_ANCHOR_EN`: 0 ⇒ 1/3, 1 ⇒ 3/3 byte-exact through the shipping plumbing node |
   | `make -C cocotb/fifo_rx_twin2 ab` | compiles frozen pre-fix RTL copies; **expected to fail**, so it can never be a gate suite. If `unfixed` ever passes, the test has gone blind |

3. **Assert something.** Audit finding A7 measured **84 of 982**
   `@cocotb.test()` functions with no reachable `assert`/`raise` — including
   the tests named for two backlog defects. A test that returns early instead
   of skipping is counted by CI as a pass.
4. **Beware both-branches-pass checks.** The same vacuous shape appeared in the
   hardware suite: a check whose `if`/`else` both called `tt_pass` masked a
   *real* RTL defect (the PTP timestamp mailbox was not read-only from APB).
   Both branches of a conditional must not report success.
5. **If you are pinning a defect rather than fixing it, write a sentinel** —
   an exact, fixed-string signature specific enough that any behaviour change
   produces `XCHG`. Add it to `SIM_GATE_SENTINELS`, never to
   `SIM_GATE_ALL_SUITES`.
6. **Prove the wiring.** `make sim_gate_inventory` must print
   `OK — every declared suite is invoked`.

Step-by-step mechanics for adding a suite are in
[Simulation Tests](simulation_tests.md#adding-a-new-cocotb-suite) and
[Contributing](contributing.md).

## CI: what actually runs

GitLab CI, `.gitlab-ci.yml`. `GIT_STRATEGY: none` — the `clone` job checks the
repo out by hand with `--recurse-submodules`, then clones the PHC repo and the
three sibling co-sim repos. Stages: `setup`, `lint`, `regression`,
`new_module`, `system`, `fpga`, `synthesis`, `coverage`, `pages`, `cleanup`,
`hwtest`.

### Jobs that genuinely block

| Job | Stage | Runs |
|---|---|---|
| `preflight` | setup | environment / IP-path check |
| `strip-generalbus-check` | lint | `bash ci/check_strip_generalbus.sh` |
| `farm-gate-lint` | lint | `make farm_gate_fast` (ratcheted Tier-0) |
| `merge-guard` | lint | `bash fpga/scripts/merge_guard.sh` — asserts silicon-proven fixes have not been reverted by a merge (`allow_failure: false`, `.gitlab-ci.yml:241`) |
| `hal-lint` | lint | HAL on the `xcelium` runner |
| `spyglass-cdc` | lint | SpyGlass CDC |
| **`sim-gate`** | regression | `make sim_gate` — `allow_failure: false` since 2026-07-16 (`.gitlab-ci.yml:340`) |
| `cocotb-regression` | regression | `make -C cocotb coverage` (the 28 `ENVS`) |
| `farm-gate-sim` | regression | `make farm_gate` (Tier-1) |
| `cdriver-regression` | regression | `make -C cocotb/tidelink_ahb driver-so` then `sim MODULE=test_tidelink_ahb_cdriver` — the C driver-in-the-loop path |
| `uvm-regression` | regression | `make -C uvm/tidelink run_all` — promoted to blocking 2026-07-07 |
| `cocotb-fc-adapter`, `cocotb-top`, `cocotb-top-pair-smoke`, `cocotb-ptp` | new_module | per-env cocotb |
| `uvm-fc-adapter`, `uvm-integration` | new_module | UVM |

### Jobs that are `allow_failure: true`

Green pipelines do **not** imply these passed.

| Job | Why it is non-blocking |
|---|---|
| `uvm-top-system` | elaborates clean since 2026-07-30, but the run hits a functional blocker — training completes and the FC-layer FCSM never leaves state 1, so every packet test's scoreboard reads TX ≠ RX. Classified as the already-tracked backlog item #14b, not a new defect |
| `uvm-ptp-chain`, `uvm-ptp-stress` | got the same build fix; their suites have not yet been run |
| `uvm-system`, `cocotb-system`, `cocotb-wlink-pair` | separately non-blocking |
| `fpga-pair`, `fpga-ptp-pair` | real-board flow; opt-in via branch/schedule/manual rules so a flaky board cannot redden every pipeline |
| `synth-fifo`, `synth-top`, `synth-top-full`, `formality-lec` | synthesis stage |
| `hwtest:safe`, `hwtest:full`, `hwtest:soak` | run on the `bridge1-runner` tag; kept non-blocking so pipelines stay green when the lab is offline |

:::{warning}
**A UVM `run_all` once printed "PASSED" for a test with 6 scoreboard errors.**
The echo trusted `simv`'s shell exit code, which UVM does not set non-zero for
`UVM_ERROR`. It is fixed, and `ci/uvm_results_to_junit.py` — what CI actually
gates on — always parsed the real `UVM_ERROR`/`UVM_FATAL` tally correctly. When
reading a UVM log by hand, count the tally, not the exit code.
:::

:::{note}
**Comments in CI have rotted before.** The `sim-gate` job comment still
describes "10 suites" (`.gitlab-ci.yml:323`) against a real 43. The
authoritative answer is always `make sim_gate_inventory`.
:::

### Not in CI at all

- `make -C xprop regression` (VC Formal X-prop) — no job.
- `make sim_robust`, `make robust_all` — no job (their Tier-0 components run
  inside `farm-gate-lint`).
- `make -C lint lint-each` — CI lints, but confirm which modules in the job
  body before assuming full coverage.

### Broken repo-root targets, verified

:::{warning}
`make sim-repro` and `make sim-repro-skid3` (`Makefile:99`, `:106`) invoke
`$(MAKE) -C cocotb/wlink_pair`. **That directory does not exist** on this
branch; the bench lives at `cocotb/debug/wlink_pair/` (it contains
`test_hw_regression_gates.py` and `test_assert_bringup.py`). Run it directly
from `cocotb/debug/wlink_pair` until the target is re-pointed. Reported here
rather than fixed — this page does not modify the build.
:::
