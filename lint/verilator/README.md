# Verilator strict-lint gate

A fast (~5–30s) static lint gate that catches synth-class defects before they
escape to silicon. Sits alongside the two existing TideLink lint flows:

| Gate                     | Tool                     | Location                              |
|--------------------------|--------------------------|---------------------------------------|
| Style + structural lint  | Cadence HAL (Xcelium)    | `lint/Makefile`                       |
| Anti-pattern lint        | Python (custom)          | `cocotb/lint/sv_anti_pattern_lint.py` |
| **Strict synth-class**   | **Verilator (this dir)** | **`lint/verilator/Makefile`**         |

Run all three in CI: HAL is broad and style-heavy, the Python lint catches
patterns Verilator/HAL miss, and Verilator catches width / case-incomplete /
pin-missing / always-comb-order issues that only show up on silicon if they
slip past simulation.

---

## Quick start

```bash
# Lint every targeted module (~30s)
make -C lint/verilator lint-all

# Lint just one module
make -C lint/verilator lint-calibrator

# Clean logs
make -C lint/verilator clean

# (Best-effort) Full-design lint over the FPGA flist
make -C lint/verilator lint-fpga-top
```

Exit code 0 = clean, non-zero = at least one strict-class warning. Per-module
logs are written next to the Makefile as `<top_module>.log`.

---

## What each warning class catches

The flags promoted to **errors** (defect class → silicon-relevant failure):

| Class            | Catches                                                       |
|------------------|---------------------------------------------------------------|
| `CASEINCOMPLETE` | Case statement with missing arms and no `default` → latch     |
| `CASEOVERLAP`    | Overlapping arms in `unique` case → synth picks first, sim picks last |
| `WIDTH`          | Width mismatch (e.g. 33-bit RHS into 32-bit LHS) — caused the `tidelink_perf:493` finding |
| `IMPLICIT`       | Implicit net declaration — often a port-name typo             |
| `PINMISSING`     | Instance pin omitted — silent wrong-connection class          |
| `ALWCOMBORDER`   | `always_comb` evaluation-order hazards — latch precursor      |
| `CMPCONST`       | Constant compare (always-true / always-false predicate)       |

Kept as **warnings** (visible in log, not blocking):

| Class       | Why warning, not error                                       |
|-------------|--------------------------------------------------------------|
| `UNUSED`    | Common on APB register banks — `paddr` upper bits, `pstrb`, AXI4-Lite `bresp`/`rresp`. Promote to error per-module with `STRICT_UNUSED=1` |
| `UNDRIVEN`  | Same logic — promote with `STRICT_UNUSED=1`                  |

Promote to errors on a clean module:

```bash
make -C lint/verilator lint-calibrator STRICT_UNUSED=1
```

### Note on Verilator 4.028

The installed Verilator (4.028, Feb 2020) **does not have** explicit `LATCH`
or `MULTIDRIVEN` warning classes — those were added in Verilator 4.2xx /
5.x. Today the gate catches the same defect class indirectly:

- Latches: via `ALWCOMBORDER` + `UNDRIVEN` + `CASEINCOMPLETE`
- Multi-driver: via `BLKANDNBLK` (already part of `-Wall`)

When the host is upgraded to Verilator ≥ 5.x, edit `lint/verilator/Makefile`
and add to `VERILATOR_STRICT`:

```makefile
VERILATOR_STRICT += -Werror-LATCH -Werror-MULTIDRIVEN
```

---

## Suppressing legitimate false positives

Three ways, in order of preference:

### 1. Narrow inline marker (preferred for vendor IP and one-line cases)

```systemverilog
/* verilator lint_off UNUSED */
input wire [31:0] m_axil_bresp,  // AXI4-Lite response — we tie low, don't read
/* verilator lint_on UNUSED */
```

Always pair `lint_off` with `lint_on`. Always add a comment explaining
**why** the suppression is correct — never just silence noise.

### 2. File-scope `lint_off` at top of file (use sparingly)

For wholly-third-party files (Wlink-generated Verilog, XHB500 vendor IP):

```systemverilog
/* verilator lint_off UNUSED */
/* verilator lint_off WIDTH */
// rest of vendor file
```

### 3. Makefile-level `-Wno-<CLASS>` (last resort)

If an entire subtree is third-party (e.g. `deps/xhb500/`), pass `-Wno-UNUSED`
to that target only. The `lint-fpga-top` target already does this for
`UNUSED`/`UNDRIVEN`/`WIDTH` because the Wlink-generated Verilog is noisy and
out of scope.

---

## Adding a new module to the lint scope

1. Pick the module's top SV file and its include dirs.
2. Add a target to `lint/verilator/Makefile` modelled on `lint-calibrator`:

   ```makefile
   lint-my-new-module:
   	$(call VERILATE,my_new_module,\
   	  $(RTL_DIR)/my_new_module.sv,\
   	  $(INC_RTL))
   ```

3. Append `lint-my-new-module` to `LINT_TARGETS`.
4. Run `make -C lint/verilator lint-my-new-module` once. Triage each
   finding — fix the bug or add a narrow `lint_off` with justification.
5. Commit.

If the module depends on packages or sub-modules, add their files to the
target's source list (positional args after the `--top-module`).

---

## Recommended CI integration

Wire this into the existing CI plan (see the four CI plans in the
`docs/V2_DEFERRALS.md` section) as **gate 3 of 3**:

```yaml
# .github/workflows/lint.yml (or equivalent)
jobs:
  verilator-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - run: sudo apt-get update && sudo apt-get install -y verilator
      - run: source set_env.sh && make -C lint/verilator lint-all
```

Run order in CI:

1. `cocotb/lint/sv_anti_pattern_lint.py` — fastest, no tool dependency
2. `make -C lint/verilator lint-all` — fast, FOSS tool (this gate)
3. `make -C lint` HAL — slowest, requires Cadence licence

Pre-commit hook (drop into `.git/hooks/pre-commit` or use `pre-commit.yaml`):

```bash
#!/bin/bash
# Only run on changes to lintable RTL
changed=$(git diff --cached --name-only | grep -E '\.(sv|v)$' || true)
if [ -z "$changed" ]; then exit 0; fi
make -C lint/verilator lint-all || exit 1
```

For PRs that touch a single module, run the per-module target only — keeps
the local feedback loop under 5s.

---

## Known-noisy modules / current findings

As of `feat/td-combined` tip 57c2810:

| Module                       | Findings                                                  |
|------------------------------|-----------------------------------------------------------|
| `tidelink_phy_align_calibrator` | clean                                                     |
| `tidelink_lane_checker`      | clean                                                     |
| **`tidelink_perf`**          | **1× `WIDTH` ERROR at line 493** — 33-bit RHS into 32-bit `perf_reg_rdata`. Real bug; layout comment doesn't match actual width |
| `tidelink_apb_regs` (FIFO)   | 2× `UNUSED` — APB `paddr` + `reset_n_raw_edge` (intentional CDC edge detect, not consumed) |
| `tidelink_fifo_ctrl`         | clean                                                     |
| `tidelink_returner`          | 1× `UNUSED` — AHB `hrdata` (write-only path)              |
| `tidelink_autoneg`           | 2× `UNUSED` — AXI4-Lite `bresp`/`rresp` (we don't read responses) |

The `tidelink_perf:493` WIDTH finding is **gating** — fixing this is the
first action item once the gate lands.

---

## Verification: gate actually catches synth-class bugs

A synthetic-defect test (in `/home/dam1n19/SoCLabs/td-bisect/verilator-lint/`)
verified both bug classes:

1. **CASEINCOMPLETE** — `unique case` with missing arms and no `default` →
   `Error-CASEINCOMPLETE`, verilator exit=1.
2. **WIDTH** — 33-bit `{a, b}` assigned to 32-bit `y` → `Error-WIDTH`,
   verilator exit=1.

Removing the defect in each test → exit=0. The gate is sound.
