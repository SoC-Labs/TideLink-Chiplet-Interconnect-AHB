# KR260 hardware regression: build, test, selftest

Tooling for the `kr260-pair-onchip` image (both TideLink dies on ONE KR260, "board 1"; board 2 is only POR'd).
It produced all KR260 evidence for TL-059. Everything site-specific (addresses, lock path, POR host) comes from
the environment; nothing in the repo names a machine. Passwords are environment-only.

| Where | What |
|---|---|
| `scripts/hw/build.sh` | build the image with every precondition and post-condition checked; writes the vetting record |
| `scripts/hw/check_markers.py` | proves the fixes are in the sources the flist compiles and in the packaged IP Vivado used (groups `a7 h30 h31 tl036 errinj asic tl059`) |
| `scripts/hw/hw_test.sh` | the board run: lock, POR, deploy, checks, restore |
| `pynq_host/hw_regress/rev2hw.py`, `b19_dip.py` | run ON the board as root; staged by `hw_test.sh` |
| `pynq_host/hw_regress/injector_controls.py` | the injector must-fail controls, shared with the cocotb benches |
| `scripts/hw/stubs/`, `selftest_hw.sh` | offline rehearsal and proof the tooling can fail |
| `scripts/hw/hw_rig.env.example` | every setting, with placeholders |
| `scripts/ci/check_host_addrs.py` | lint: host-script register addresses vs the register map |

## 1. One-time setup (3 minutes)

1. `cp scripts/hw/hw_rig.env.example scripts/hw/hw_rig.env`, edit (gitignored). Required: `KR260_LOCK`, `KR260_IP`,
   `KR260_IP2`, `POR_HOST`. `touch` the lock file once; it must sit where everyone driving the boards can `flock` it.
2. In your own shell, per session: `read -s KR260_PASSWORD && export KR260_PASSWORD`
   (and `KR260_SUDO_PASSWORD` if sudo differs). Never put them in a file or on a command line.
3. `make hw_tooling_selftest` must print `HW_SELFTEST_RESULT=PASS` before the first real run.

## 2. Build (45 to 90 minutes, from your own terminal or tmux)

```
export PHC_REPO_DIR=<clean ptp-hardware-clock-ahb checkout at PHC_PIN_SHA>
bash scripts/hw/build.sh <worktree> --dry-run     # ~10 s, all prechecks + source markers
nohup bash scripts/hw/build.sh <worktree> > build.log 2>&1 &
```
Last line is `BUILD_EXIT=<n>`: 0 trustworthy; 2 precheck failed (dirty tree, no `site.env`, PHC not at its pin, no Vivado,
disk, empty deps); 3 a fix is missing from the sources; 4 built but an assertion failed (phy_marker, source_commit,
git_dirty, xhb500_tree, sha256, WNS/WHS, stale packaged IP). Evidence lands in `$HW_OUT/builds/<sha8>/`
(default `imp/hw_regress/`, untracked).

## 3. Hardware test (25 to 40 minutes once the lock is yours)

```
bash scripts/hw/hw_test.sh <worktree>/imp/fpga/output/kr260-pair-onchip --dry-run    # plan only
bash scripts/hw/hw_test.sh <worktree>/imp/fpga/output/kr260-pair-onchip
```
Safety features (each has a rehearsal in `selftest_hw.sh` that goes red without it):
- `flock` on `$KR260_LOCK` for the whole run, taken first. Waits `LOCK_WAIT` (3600 s), then exit 75.
- Step 00 proves sudo (`sudo -S -k -p ''`, password on stdin) BEFORE any POR: a refused sudo touches nothing.
- Step 01 POR's BOTH boards (`ssh $POR_HOST "$POR_REMOTE_CMD"`, 3 tries 20 s apart each), waits for ping and ssh, checks CMA.
- Step 03 stages, verifies md5 on the board, then `sync`s to the SD card. `verify_staged` repeats the md5 check
  before every deploy and refuses to load an image that is not this run's (a POR right after `scp` once lost the writes).
- The PL is only loaded on a freshly POR'd board, never over a live link.
- EXIT trap (success or failure) POR's both boards and prints the hand-off message (`RIG_RESTORE_NOTE`). The script
  does not restore the owner's images.
- One log per step in `$HW_OUT/results/<time>-<sha8>/`, STOP at the first failing step.
  Resume: `hw_test.sh <bitdir> --results <dir> --from 1` (takes the lock and POR's again).

Exit status: 0 all passed; 1 a step failed; 2 refused/precheck; 4 passed but a step was INCONCLUSIVE; 6 passed on an
UNVETTED build (never evidence).

### Vetting (no bypass)
The image must have a passing built-marker report. `build.sh` writes it; if it is absent `hw_test.sh` re-runs
`check_markers.py --mode built` on the worktree (needs `imp/fpga/tidelink_ip/src`). Otherwise the run is refused.
The only way past is `--unvetted`: loud banner, results directory `...-UNVETTED`, `UNVETTED` marker file, every verdict
line tagged, exit 6. `ALLOW_UNVETTED_BUILD` no longer exists and is refused.

### Profiles (environment, default = the old Wave C sequence)
| Profile | Command prefix | Passes when |
|---|---|---|
| TL-059 fixed-image acceptance | `EXPECT_FIXED=1 CRCSTATS=1 STREAM=1` | per direction `STATS_RESULT=FIXED_PASS exact=N detected=N`, aggregate `replayed exactly once 2N/2N` and detected >= `CRCSTATS_MIN_DETECTED`; stream start `NO_STORM_OBSERVED` both directions; then restore (7 to 9 min) |
| cold bring-ups | `BRINGUPS=37 STREAM=1` | `bring-ups 37/37 PASS`; a wedge (timeout, rc 2, lost ssh/POR, cycle > `BRINGUP_CYCLE_MAX`) aborts at once and restores (about 2 min 15 s per cycle) |
| statistics | `CRCSTATS=1` | measurement mode: P(lost given detected) with Wilson interval; not an acceptance |

Do not turn injection into a loop: shots stay bounded (`rev2hw` caps `crc stats` at 64, `stream` at 16).

## 4. Injector controls (every injection test, sim and board)

`injector_controls.py` is the single implementation; `rev2hw.py` and `cocotb/common/injector_ctl_cocotb.py` both call it.
- C-REG-ADDR: the injector offset is the RDL `link_error_injection` (0x023C); the alias 0x003C is refused before a write.
- C-REG-HOLD: 0x23C reads 0 before an arm and reads back exactly what was armed (a dropped write is NO_HOLD).
- C-INJ-INERT: armed for a DataID nobody uses, nothing changes and the disarm reads back 0.
- C-INJ-LIVE: a shot the injector fired must move the receiver CRC counter; on the board (no fired counter) +1 with exact
  data is EFFECTIVE, +0 with exact data is INERT (never a pass alone), anything else FAIL.
- C-COUNT-EXPECT: shots fired equal counter increments over the whole run.
- Slave die: die_b's external APB is read-only unless its debug-unlock GPIO is high; it is raised only while armed and
  always relocked.

## 5. Selftests (no board, no network)

`make hw_tooling_selftest` (about 1 minute): `selftest_rev2hw.py` (the board checks against simulated register models,
healthy and broken), the injector library tests, rehearsals of `hw_test.sh` against stub ssh/sshpass/scp/flock/ping with
a synthetic image, and a `check_markers.py` must-fail. `make check_host_addrs` lints the register addresses; its own
must-fail control runs in `make selfcheck_gates`. Rehearse one profile by hand:
`EXPECT_FIXED=1 CRCSTATS=1 STREAM=1 bash scripts/hw/stubs/rehearse.sh mylabel` (prints where the console and results are).

## 6. What this does not prove
- A rehearsal exercises the script logic against stubs, not the board. It never counts as a hardware result.
- The register lint reads Python only (not `.sh` helpers), judges offsets 0x100 and above by value, and judges short
  (block-relative) offsets only by the 0x003C rule and by constant names; see the header of `check_host_addrs.py`.
- Hardware claims need the on-disk artefacts of a real run (CONTRIBUTING section 7): `SUMMARY.tsv`, the per-step logs.
