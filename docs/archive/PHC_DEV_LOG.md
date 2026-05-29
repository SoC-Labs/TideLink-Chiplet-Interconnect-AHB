# PHC Hardware Test — Development Log (feat/phc-hw-test)

**Branch:** `feat/phc-hw-test` (off `main` @ `fbdebc2`, submodule `2f602d1`)
**Worktree:** `/home/dam1n19/SoCLabs/td-phc-dev`
**Plan:** `docs/PTP_HW_TEST_PLAN.md`
**Status:** Ready for review / build verification.

---

## 1. What was done

### 1.1 PHC IP packaged for Vivado

`fpga/vivado_ip/phc/`:
* `phc_fpga_top.sv` — FPGA-friendly top that mirrors the upstream `phc.sv`
  structurally (clock-core + apb-regs + servo source-0/1 mux + ethernet
  capture) and additionally re-exports `seconds_o` / `nanoseconds_o` on its
  top-level boundary. Needed because `tidelink_top` consumes the PHC's
  current time as discrete inputs for the HW SYNC initiator; upstream
  `phc.sv` keeps those wires internal (only readable via APB).
* `phc_vivado_wrapper.v` — IP-Integrator boundary. Exposes APB as a Xilinx
  `xilinx.com:interface:apb:1.0` bus interface, annotates `clk` /
  `resetn` with `ASSOCIATED_BUSIF apb` + 50 MHz `FREQ_HZ`, and surfaces
  the source-0 servo signals + PPS + counter + IRQs as discrete pins.
  HA1588 source-1 is tied off internally.
* `package_phc_ip.tcl` — packages the above as `soclabs.org:user:
  phc_vivado_wrapper:1.0`, adds a 4 KB memory map for the `apb`
  interface (`APB_ADDR_W=12`), mirrors the message-gate from the
  tidelink IP packager.
* Component XML verified: `apb` bus interface present, all
  hardware-servo source-0 + counter signals exported, integrity check
  passed.

### 1.2 Build flow wiring

`fpga/Makefile`:
* New `PHC_REPO_DIR ?= $(HOME)/SoCLabs/ptp-hardware-clock-ahb` variable.
* New `PHC_IP_OUTPUT_DIR := $(BUILD_DIR)/phc_ip`.
* New `package_phc_ip` target (vivado -mode batch -source
  package_phc_ip.tcl) — runs in <2 min, no Arm IP dependency.
* `build_design` prerequisite list extended: `package_ip` + `package_phc_ip`.
* `FPGA_PHC_IP_REPO` exported into the `build_design` env.

`fpga/build_design.tcl`:
* Reads `FPGA_PHC_IP_REPO` (optional); when set, adds it to
  `ip_repo_paths` alongside the tidelink IP. Backward-compatible — old
  BDs that don't instantiate the PHC IP still build.

### 1.3 BD integration (pynq-z2-pair + pynq-z2-pair-flip)

In `fpga/targets/pynq-z2-pair/tidelink_design.tcl` (and the structurally
identical `-flip` variant):

* **Removed** the five `xlconstant_phc_*` zero-tie-off cells that lived
  at lines 262-308.
* **Added** `phc_0` instance of `soclabs.org:user:phc_vivado_wrapper:1.0`.
* **Added** `axi_apb_phc` (axi_apb_bridge:3.0, APB4) routing
  SmartConnect M06 → phc/apb.
* **Added** `axi_gpio_pmod_trig` (dual-channel: 1-bit output ch1 drives
  pmod_b_trig_o, 1-bit input ch2 senses pmod_b_trig_i). Address
  `0x4404_2000`.
* **Added** `xlconcat_phc_hw_cap` + `util_reduced_logic_hw_cap`
  (2-input OR) so `phc_0/hw_capture_0_i = tidelink_0/phc_hw_capture |
  pmod_b_trig_i` — this is the Option-A cross-board trigger from plan
  §3.1.
* **Bumped** `axi_smc.NUM_MI` from 6 → 8 (added M06=phc_apb,
  M07=pmod_trig GPIO).
* **Wired** PHC outputs into tidelink:
  - `phc_0/seconds_o` → `tidelink_0/phc_seconds`
  - `phc_0/nanoseconds_o` → `tidelink_0/phc_nanoseconds`
  - `phc_0/pps_o` → `tidelink_0/phc_pps`
  - `phc_0/hw_cap_*_0_o` → `tidelink_0/phc_hw_cap_*`
* **Wired** tidelink outputs into PHC (servo phase step + freq steer):
  - `tidelink_0/phc_hw_set_*` → `phc_0/hw_set_*_0_i`
  - `tidelink_0/phc_hw_adj_*` → `phc_0/hw_adj_*_0_i`
* **Address map additions:**
  - `0x4404_2000` 4 KB — `axi_gpio_pmod_trig/S_AXI/Reg`
  - `0x4405_0000` 4 KB — `phc_0/apb/Reg`
* **External BD ports** `pmod_b_trig_o` / `pmod_b_trig_i` added.

Board wrapper (`tidelink_design_wrapper.v`):
* New `inout pmod_b_trig` port + an `IOBUF` (tristate gated by `~o_w`,
  so the line idles high-Z and only the driving board pulses).

XDC (`pynq_z2_tidelink.xdc`):
* `pmod_b_trig` → `Y16` (JB1 on PYNQ-Z2 v1.0) `LVCMOS33 PULLDOWN TRUE`
  on both the `pair` and `-flip` XDCs.

### 1.4 Bring-up scripts

`pynq_host/scripts/`:
* `_ptp_common.sh` — shared helpers (remote /dev/mem read/write, PHC
  register accessors, PMOD-trigger pulse, link-up-first gate,
  servo-quiesce, NS_INCR=20 init).
* `bringup_ptp_sync.sh` — Phase 2 initial sync + convergence (~2 min).
* `bringup_ptp_track_freq.sh` — Phase 3a freq tracking (~3.5 min).
* `bringup_ptp_track_offset.sh` — Phase 3b offset-step recovery (~5 min).
* `bringup_ptp_soak.sh` — Phase 4 multi-hour soak + CSV log + summary
  (SOAK_HOURS configurable; default 4).

All four:
* Use `_ptp_common.sh::check_link_up` to enforce link-up-first.
* Never write `AHB_TX` (0x4400_0000) — the wedge hazard.
* Disable the autonomous servo before injecting perturbations
  (plan §4.3).
* Pass/fail thresholds match plan §6 (500 ns steady-state, 200 ns
  1-σ jitter, 300 ns mean over soak, 2 µs 99th-%ile).
* `bash -n` clean.

**None of the scripts have been run against hardware yet** — they are
gated on the user's review of the BD changes + post-merge HW deploy.

### 1.5 CI integration

`.gitlab-ci.yml`:
* New `fpga-ptp-pair` job in stage `fpga`.
* Manual trigger on `web` or `feat/phc-hw-test` branch pushes; auto on
  scheduled pipelines. `allow_failure: true` while the campaign is
  characterising.
* `PTP_SOAK_HOURS` / `PTP_DURATION` exposed as web-pipeline variables.

`ci/fpga_run_ptp_pair.sh`:
* Mirrors the `fpga_run_pair.sh` background-tier-lease pattern.
* Acquires bridge1 chassis lease (`pynq_z2_02`); heartbeat in
  background; waits for confirmed grant via `lease wait`.
* Runs the four bringup scripts sequentially, stops at first failure
  (subsequent ones depend on prior convergence).
* Emits a per-script `RESULT:` summary into a JUnit XML.

---

## 2. Build verdict

Build launched on the local box (srv03335 — the existing td-freshbuild
farm session occupies its own srv slot). Concurrency = 1 vivado on
this host, well below the <=2 srv04936 ceiling. TARGET=pynq-z2-pair.

* `package_phc_ip` — **PASS** (~1 min). component.xml integrity ok;
  APB bus + counter outputs exported correctly. Verified via grep on
  the generated component.xml.
* `package_ip` (tidelink) — **PASS** (~3 min). No regressions from
  prior runs of the same script.
* `build_design` BD validation — **PASS after two follow-up fixes**:
  - **Initial fail:** `validate_bd_design` errored on
    `tidelink_0/idelay_ref_clk` not connected. The tidelink IP wrapper
    requires this 200 MHz clock as a top-level port whenever
    USE_IDELAY≥0 (it's a wrapper port, not gated by the param). The
    base `pynq-z2-pair` target never had the 200 MHz MMCM output
    (only the `-all` variants do).
  - **Fix A:** added `set_property -dict {CONFIG.USE_IDELAY {0}} $tl`
    on the tidelink_0 IP cell so the IDELAY logic is structurally
    omitted at synth time. Same edit applied to the `-flip` variant.
  - **Fix B:** connected `tidelink_0/idelay_ref_clk` to
    `clk_wiz_0/clk_out2` (50 MHz). With USE_IDELAY=0 the clock has no
    timing-relevant load; this just satisfies validate_bd_design's
    clock-pin-connectivity check.
* `build_design` BD validation — re-run **PASS**. Confirmed in log:
  - Address map populated with the three new slaves (phc @
    0x4405_0000, pmod_trig @ 0x4404_2000, plus the existing 6).
  - PHC IP wired into both directions of tidelink_0 (set/adj from
    servo into hw_set_*_0_i / hw_adj_*_0_i; counter and cap into
    phc_seconds / phc_nanoseconds / phc_hw_cap_*).
  - 3× `WARNING: [BD 41-1306]` for the GPIO interface-override on
    axi_gpio_strap, axi_gpio_pmod_trig (gpio_io_o + gpio2_io_i) —
    cosmetic, expected, same warnings appeared on the strap GPIO
    pre-PR.
* `build_design` synth — **running at write-time**. All 15 OOC IP
  synth jobs launched in parallel; master `synth_1` waiting on them.
  The PHC IP got its own OOC run
  (`tidelink_design_phc_0_0_synth_1/`).
* Place / Route / write_bitstream — **not yet reached**; this build is
  the structural validation pass. The user picks up from here:
  `make -C fpga TARGET=pynq-z2-pair build_design` will resume from the
  in-progress synth, or rebuild from scratch if the user prefers.

If synth completes cleanly, the build verdict is the structural one
the plan asked for: **PHC integration wired in correctly, no BD
validation errors, no synth elaboration errors on the PHC IP itself.**
HW lane-lock is not characterised by this build (USE_IDELAY=0 is the
A/B comparison path, not the production -all build).

The `-all` mirror (the production deploy target) is the work-remaining
checklist item §3.1 below.

---

## 3. Pending / future-work (NOT in this PR)

### 3.1 -all variants

The bringup-converge / deploy_pair_role flow targets `pynq-z2-pair-all`
and `pynq-z2-pair-flip-all`, NOT the base `pair` / `-flip` targets.
The `-all` BDs are 372 lines diff from the base — they add a 200 MHz
IDELAYCTRL reference clock (CLKOUT3), the debug-unlock GPIO at
0x4404_1000, and several `(* dont_touch *)`-style structural anchors
not present in the base BDs. Mirroring the PHC drop onto the `-all`
variants is structurally identical to the base edits in this PR, but
non-trivial enough to warrant a separate review-gated cycle:
* Bump `NUM_MI` 7 → 9 (preserve M06=axi_gpio_debug_unlock, then add
  M07=phc, M08=pmod_trig).
* Add the same xlconcat + OR + IOBUF + XDC pmod pin.
* Add the same address-map segments (`0x4405_0000`, `0x4404_2000`).
* Update `clk_out2` fanout (in `-all` the IDELAY MMCM has 3 outputs).

**Until that lands**, this PR's bitstreams (TARGET=pynq-z2-pair{,-flip})
cannot be deployed through `deploy_pair_role` (which expects the `-all`
naming). The user can deploy them manually via `make deploy
TARGET=pynq-z2-pair BOARD=...` for an ad-hoc HW test.

### 3.2 `bare_overlay.py` PHC_BASE

`pynq_host/bare_overlay.py` was updated by the test plan author to
include `PHC_BASE` constants. Not strictly required for the bash
bringup scripts (they use `/dev/mem` directly), but the python overlay
class would need a `PHC_BASE = 0x4405_0000` constant + a small
`PhcRegs` mixin to match the existing class hierarchy. Defer to a
follow-up PR after HW verification.

### 3.3 `phc_locked_i` semantics

The plan (§7 R6) advises leaving `PHC_LOCK_GATE_EN=0` for the 2-board
bridge1 case, so `phc_locked_i` is don't-care. The current wrapper
default already does this — `tidelink_vivado_wrapper.PHC_LOCK_GATE_EN`
defaults to 0. No change.

### 3.4 ASIC scaling

All numerical thresholds (NS_INCR=20, LSB_per_ppm=85_900) assume the
50 MHz FPGA `phc_clk`. The ASIC v1 target is 100 MHz — those constants
must scale by 2× when the scripts are re-used on silicon.
`_ptp_common.sh::NS_INCR_FOR_50MHZ=20` is the only place; rename if
the scripts get adapted for silicon.

### 3.5 Hardware verification

This PR is build-only. The scripts have been syntax-checked but never
run on real boards. Phase 1 (single-PHC sanity — counter increments,
SW CAPTURE reads plausible time, PPS LED blinks at 1 Hz) needs to be
done by the user on the bridge1 pair before Phase 2+ are meaningful.

---

## 4. Files touched (commit summary)

```
# Commit 1 — BD + IP integration
fpga/vivado_ip/phc/phc_fpga_top.sv               new  (BD-friendly top)
fpga/vivado_ip/phc/phc_vivado_wrapper.v          new  (IPI wrapper)
fpga/vivado_ip/phc/package_phc_ip.tcl            new  (packaging)
fpga/Makefile                                    mod  (package_phc_ip)
fpga/build_design.tcl                            mod  (FPGA_PHC_IP_REPO)
fpga/targets/pynq-z2-pair/tidelink_design.tcl    mod  (PHC IP + PMOD)
fpga/targets/pynq-z2-pair/tidelink_design_wrapper.v
                                                 mod  (PMOD IOBUF)
fpga/targets/pynq-z2-pair/pynq_z2_tidelink.xdc   mod  (PMOD Y16)
fpga/targets/pynq-z2-pair-flip/                  mod  (mirror)

# Commit 2 — scripts + CI
pynq_host/scripts/_ptp_common.sh                 new
pynq_host/scripts/bringup_ptp_sync.sh            new
pynq_host/scripts/bringup_ptp_track_freq.sh      new
pynq_host/scripts/bringup_ptp_track_offset.sh    new
pynq_host/scripts/bringup_ptp_soak.sh            new
ci/fpga_run_ptp_pair.sh                          new
.gitlab-ci.yml                                   mod  (fpga-ptp-pair)

# Commit 3 — this dev log
docs/PHC_DEV_LOG.md                              new
```

---

## 5. Next session checklist

1. [ ] User reviews BD diff (`git diff main fpga/targets/pynq-z2-pair`).
2. [ ] Local FPGA build of TARGET=pynq-z2-pair completes; capture
       Place/Route status and timing summary.
3. [ ] If build clean, replicate PHC drop onto `pynq-z2-pair-all` +
       `pynq-z2-pair-flip-all` (the production deploy targets).
4. [ ] Deploy both `-all` bitstreams to bridge1 pair via
       `deploy_pair_role`.
5. [ ] Run `bringup_pair_converge.sh` — confirm 16/16 + cal_done.
6. [ ] Operator solder/clip a PMOD-B JB1↔JB1 jumper between the two
       boards.
7. [ ] `bringup_ptp_sync.sh` — Phase 2 PASS.
8. [ ] `bringup_ptp_track_freq.sh` — calibrate the empirical
       LSB_per_ppm (the script logs it; current default 85_900 may
       need a single-figure correction).
9. [ ] `bringup_ptp_track_offset.sh` — Phase 3b PASS.
10. [ ] Short-soak (SOAK_HOURS=1) to verify the CSV summariser before
        the 4-hour baseline.

— development continues post-review.
