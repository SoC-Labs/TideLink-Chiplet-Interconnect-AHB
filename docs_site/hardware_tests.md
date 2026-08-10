# Hardware Tests

TideLink ships a numbered, safety-gated hardware test suite at
`pynq_host/scripts/hwtest/` — one orchestrator (`run_all.sh`) plus 13 category
scripts, all of which reach the boards through a single shared transport
library, `lib/lib_hwtest.sh`. This page documents what each script does, how to
run it, what "pass" means, and how to read a failure.

The suite is only one of three hardware test surfaces. The other two —
`fpga/hw_regression/` (the certified on-silicon bring-up and channel
regressions) and the KR260 Python probes under `pynq_host/scripts/` — are
covered in [Bring-Up](bringup.md); this page cross-references them where the
suite hands off.

:::{danger}
**Read this before running anything on a board.**

1. **The `hwtest` suite is PYNQ-Z2 ONLY and refuses to run anywhere else.**
   Every helper mmaps raw Z2 control literals (`0x4403_xxxx`, `0x4404_xxxx`)
   over `/dev/mem`, un-relocated. On a ZynqMP (KR260) those addresses are
   **undecoded with no bus timeout — a hard PS hang, power-cycle to recover**.
   The library therefore aborts with `exit 3` the moment it is sourced if
   `TIDELINK_SOC` is set to anything but a Z2 alias
   (`lib/lib_hwtest.sh:43-71`).
2. **An `ahb_tx` write on a link that is not fully up wedges the board.**
   Bench-confirmed 2026-04-27 on `z2_02`; recovery was a physical power-cycle
   (`pynq_host/scripts/hwtest/README.md`, "Safety constraints" §1). Category 5
   is hard-gated behind `tt_gate_ahb_tx()` and every write is wrapped in
   `timeout`.
3. **Never reload the PL on a live link.** A PL reprogram mid-session drops
   `role_lock` (W1S, POR-only clear) on one die while the peer still holds it.
4. **`0x21AC`, `0x21B0` and `0x21B4` hard-stall the CPU** and must never be
   probed; see [Register Map](register_map.md). The hwtest suite does not touch
   them — do not add a sweep that does.
5. **On a board with an unprogrammed PL, any read of a PL aperture is a bus
   error**, and on ZynqMP an *undecoded* aperture hangs the PS outright. Confirm
   `/sys/class/fpga_manager/fpga0/state` reads `operating` first.
:::

## Where the suite runs, and against what

| Item | Value | Source |
|---|---|---|
| Platform | PYNQ-Z2 pair only (hard refusal elsewhere) | `lib/lib_hwtest.sh:43-71` |
| Transport | `sshpass` + `ssh` + an embedded `python3` `/dev/mem` mmap | `lib/lib_hwtest.sh:110-168` |
| Default master | `MASTER_IP=192.168.4.101` | `lib/lib_hwtest.sh:73` |
| Default slave | `SLAVE_IP=192.168.6.101` | `lib/lib_hwtest.sh:74` |
| APB base (TideLink) | `0x4403_2000` | `lib/lib_hwtest.sh:144-168` |
| APB base (Wlink) | `0x4403_0000` | `REG_INVENTORY.md` |
| Prerequisite | bitstream loaded on both boards with `role_lock=1`, link converged | `README.md`, "Pre-requisites" |

:::{warning}
**The default `SLAVE_IP` may be the wrong board.** `192.168.6.101` is `z2_03`.
As of 2026-07-24/30 the ribbon-connected pair is
`z2_02` (`192.168.4.101`, die_a) ↔ **`z2_01` (`192.168.2.101`, die_b)**, and
`z2_03` is a spare that is **not on the ribbon**
(`docs/HANDOVER_Z2_PICKUP_2026_07_30.md:308-310`,
`docs/HANDOVER_LINK_GUI_Z2_2026_07_24.md:320-321`). A run against the spare
reads flat zeros on the slave for the whole session and looks exactly like a
dead link. **Pass `MASTER_IP` / `SLAVE_IP` explicitly** — see
[Boards](boards.md) for the current rig.
:::

## Running the suite

All commands below are verified against
`pynq_host/scripts/hwtest/run_all.sh` and the per-category scripts.

```sh
# Default safe subset: categories 1,2,3,4,6,7,8,10,11,12 (no AHB_TX, no soak)
./pynq_host/scripts/hwtest/run_all.sh

# Everything, including the AHB_TX storm (cat 5) and the soak (cat 13)
HWTEST_INCLUDE=all ./pynq_host/scripts/hwtest/run_all.sh

# One category, standalone
./pynq_host/scripts/hwtest/12_chiplet_phyalign.sh

# Overnight endurance soak (8 h)
SOAK_SECS=28800 HWTEST_INCLUDE=13 ./pynq_host/scripts/hwtest/run_all.sh

# Let the orchestrator take and release the bridge1 lease itself
HWTEST_ACQUIRE_LEASE=1 HWTEST_LEASE_TTL=3600 ./pynq_host/scripts/hwtest/run_all.sh
```

`HWTEST_INCLUDE` accepts a comma list of category numbers, or the keywords
`all` (1–13) and `safe` (1,2,3,4,6,7,8,9,10,11,12 — i.e. everything except the
AHB_TX storm and the soak). `HWTEST_EXCLUDE` is applied afterwards
(`run_all.sh:34-36,52-58`).

### Environment variables

| Variable | Default | Used by | Purpose |
|---|---|---|---|
| `MASTER_IP` | `192.168.4.101` | all | master board |
| `SLAVE_IP` | `192.168.6.101` | all | slave board (**check this**, see warning above) |
| `TIDELINK_SOC` | unset (= z2) | all | anything non-Z2 aborts the suite (`exit 3`) |
| `TIDELINK_BOARD_PASS` | `xilinx` | all | board password for `sshpass` |
| `TIDELINK_TX_BASE` | `0x44000000` | cat 5 | AHB_TX aperture; **`0x84000000` on GP1-split images** |
| `TIDELINK_RXFIFO_BASE` | `0x44010000` | — | RX FIFO window; `0x84010000` on GP1-split images |
| `HWTEST_LOGDIR` | `/tmp/tidelink_hwtest_logs` | run_all | per-category logs |
| `HWTEST_INCLUDE` | `1,2,3,4,6,7,8,10,11,12` | run_all | category selection |
| `HWTEST_EXCLUDE` | *(empty)* | run_all | drop categories after include |
| `HWTEST_BAIL_ON_FAIL` | `0` | run_all | stop at first category failure |
| `HWTEST_ACQUIRE_LEASE` | `0` | run_all | acquire/release the `bridge1` lease |
| `HWTEST_LEASE_TTL` | `3600` | run_all | lease seconds |
| `RUN_RELIABILITY` | `0` | cat 1 | enable the re-deploy convergence sweep (heavy) |
| `MINI_SWEEP_N` | `5` | cat 1 | reliability sweep iterations |
| `RETRAIN_N` | `5` | cat 1 | retrain cycles |
| `AHB_SUB_BASE` | `0x44010000` | cat 3 | local AHB_SUB aperture |
| `AHB_SUB_NWORDS` | `64` | cat 3 | storm depth |
| `N_DBELL` | `8` | cat 4 | doorbell rings |
| `AHB_TX_BASE` | `$TIDELINK_TX_BASE` | cat 5 | AHB_TX aperture base |
| `N_AHB_TX` | `16` | cat 5 | storm depth |
| `AHB_TX_TIMEOUT_S` | `5` | cat 5 | per-write timeout (wedge guard) |
| `PTP_SYNC_INTERVAL` | `0x0000C350` | cat 9 | `HW_SYNC_INTERVAL` value |
| `PTP_SOAK_SECS` | `60` | cat 9 | PTP soak duration |
| `PTP_SYNC_OBSERVE_SECS` | `5` | cat 9 | seq-num observation window |
| `SOAK_SECS` | `600` | cat 13 | long-soak duration |
| `SAMPLE_GAP_S` | `10` | cat 13 | soak sample period |
| `SOAK_FAIL_ON_DROP` | `1` | cat 13 | fail the soak on any drop |

Sources: `pynq_host/scripts/hwtest/README.md` ("Environment variables"),
`lib/lib_hwtest.sh:73-83`, and each category script's own defaults.

### Exit codes

| Code | Meaning | Orchestrator behaviour |
|---|---|---|
| `0` | all selected categories passed | — |
| `1` | one or more sub-tests failed | continue (unless `HWTEST_BAIL_ON_FAIL=1`) |
| `3` | AHB_TX gate refused — link not verified up **or** the suite refused a non-Z2 `TIDELINK_SOC` | **stops the run immediately** |
| `4` | an AHB_TX write timed out — board possibly wedged | **stops the run immediately** |
| `5` | setup error (lease, deploy bins, ssh) | abort |

`run_all.sh:22-27` declares them; `run_all.sh:119-125` implements the hard stop
on 3 and 4. The run ends with a coverage matrix and a single `VERDICT: PASS` /
`VERDICT: FAIL` line.

## The 13 categories

Runtimes are the estimates published in
`pynq_host/scripts/hwtest/README.md` ("Runtime estimates") — approximate, and
dominated by SSH round-trip time, not by the hardware.

| # | Script | Needs | Gate | Approx. time |
|---|---|---|---|---|
| 1 | `01_wlink_layer.sh` | pair | none (APB + lane mask) | ~30 s (~5 min with `RUN_RELIABILITY=1`) |
| 2 | `02_tidelink_top_regs.sh` | pair | none | ~20 s |
| 3 | `03_ahb_sub_e2e.sh` | pair | none (safe AHB path) | ~1 min |
| 4 | `04_ahb_mng_incoming.sh` | pair, **link up** | self-skips if link down | ~15 s |
| 5 | `05_ahb_tx_storm.sh` | pair, **link up** | **`tt_gate_ahb_tx()` — hard** | ~15 s |
| 6 | `06_ahb_fifo.sh` | pair | none | ~15 s |
| 7 | `07_addr_translation.sh` | pair | none | ~30 s |
| 8 | `08_ptp_basic.sh` | pair | none | ~15 s |
| 9 | `09_ptp_hw_sync.sh` | pair, **link up**, PHC image | self-skips without PHC | ~1.5 min |
| 10 | `10_servo_mailbox.sh` | pair | none | ~30 s |
| 11 | `11_perf_counters.sh` | pair | delta sub-test needs link up | ~30 s |
| 12 | `12_chiplet_phyalign.sh` | pair | none | ~30 s |
| 13 | `13_long_soak.sh` | pair | safe ops only | `SOAK_SECS` (default 600 s) |

Default subset ≈ 4 min; `HWTEST_INCLUDE=all` ≈ 15 min at default depths.

### Category 1 — Wlink layer

**Purpose.** Prove the link layer beneath TideLink: PHY identity, lane lock,
FC channel plumbing, ECC counters, and two active perturbations (lane-mask
fault injection and repeated retrain).

**Sub-tests and pass criteria** (`01_wlink_layer.sh`):

| Sub | What it does | Pass |
|---|---|---|
| 1a | Reads `PHY_ALIGN_ID` at `0x4403_211C` on both dies | exactly `0x50410100` |
| 1b | Lane-status snapshot via `tt_read_lane_status` | informational; PASS if 8/8 locked + `cal_done=1`, else SKIP |
| 1c | Reads the 7 Wlink FC channel headers at `0x4403_0000 + {0x1000,0x1100,0x1200,0x1300,0x1400,0x1600,0x1700}` | none read `0xffffffff`, empty, or `0x00000000` |
| 1d | ECC counters at `0x4403_2114` | not saturated at `0xFFFF` |
| 1e | Convergence reliability mini-sweep, `MINI_SWEEP_N` full re-deploys | ≥80 % converged — **opt-in**, needs `RUN_RELIABILITY=1` |
| 1f | Masks each of lanes 0–7 on the master TX side (`0x4403_0214`), observes slave popcount | slave popcount drops to ≤7 for every masked lane |
| 1g | `RETRAIN_N` coordinated recal cycles (`0x4403_2100` ← `0x3` then `0x1`, both dies) | 0 failures to relock |

**Safety.** No AHB_TX. The lane mask is restored on exit via
`trap restore_mask EXIT`; 1f and 1g self-skip when the link is not up.

:::{note}
Sub-test 1d asserts only that the ECC counters are *unsaturated*. Both fields
are known dead or repurposed in current RTL: `ecc_corrupted` reads 0 because
`WlinkEccSyndrome.v` ties `corrected = 0`, and `[31:16]` has been repurposed as
a saturating **SYNC-detected** counter. See
[Register Map](register_map.md) and the interpretation table below.
:::

### Category 2 — Region 0 top-system registers

**Purpose.** Round-trip every RW register in Region 0, confirm RO registers
reject writes, and confirm `CTRL.FLUSH` self-clears.

**Pass criteria** (`02_tidelink_top_regs.sh`, run per board):
`TIDELINK_VERSION` at `0x4403_2014` reads `0x544c0100`; `CTRL_LOCK`
(`0x4403_201C[2]`) is clear; `PAIR_BASE_ADDR` round-trips four trial values and
is restored; `RELEASE_THRESHOLD` round-trips `0/1/20/64/255`; the RO offsets
`0x008/0x00C/0x010/0x018` never read back `0xdeadbeef`; `CTRL.FLUSH` reads back
clear; `STATUS` sticky errors (overrun/underrun/master_error) are 0. The
doorbell-ring sub-test (2h) is skipped when the link is down.

**Safety.** APB only. `PAIR_BASE_ADDR` is restored. The suite never sets
`CTRL_LOCK` — it is write-once until POR.

### Category 3 — AHB SUB end-to-end

**Purpose.** Exercise the *safe* AHB datapath. Unlike AHB_TX, `HREADY` is
returned locally regardless of link state, so this path cannot wedge the PS.

**Pass criteria** (`03_ahb_sub_e2e.sh`): single-word write/read at
`AHB_SUB_BASE` matches on each board; an `AHB_SUB_NWORDS`-deep storm reads back
with zero mismatches; the 32-word timed burst reads back byte-exact at
samples 0/15/31; and, when the link is up, a word written on the master is
readable on the slave at the same offset (3d).

:::{note}
Sub-test 3c was **fixed on 2026-07-30** by the verification audit: the previous
version called `tt_pass` unconditionally with no assertion, so a burst that
silently dropped writes went unnoticed. It now reads three of the written words
back. The same audit found and fixed the equivalent vacuous check in
category 5. This is documented inline in `03_ahb_sub_e2e.sh` and
`05_ahb_tx_storm.sh`.
:::

Sub-test 3d is the hardest to interpret: depending on address-translator
configuration a build may legitimately not propagate. It is reported as a
failure rather than silently skipped so it surfaces.

### Category 4 — AHB MNG incoming credit / doorbell accounting

**Purpose.** Verify slave-side receive accounting and the
`PAIR_CREDIT_COUNTER` underflow guard.

**Prerequisite.** The link must be up — the script skips everything and exits 0
otherwise.

**Pass criteria** (`04_ahb_mng_incoming.sh`): after `N_DBELL` doorbell rings
from the master, the **master's** `DOORBELL_RESP_ACC` (`0x4403_2024`) is
non-zero and read-clears to 0; `PAIR_CREDIT_COUNTER` (`0x4403_2028`) consumes
to zero and **saturates at 0** when `0xFFFFFFFF` is written to
`PAIR_CREDIT_CONSUME` (`0x4403_202C`); `PAIR_CREDIT_COUNTER_EN` toggles;
`CURRENT_CREDITS` reads in `[0..4096]`.

:::{warning}
The script's own comment records a 2026-06-11 bench finding that has **not**
been closed: both dies read `0x1000` on the first post-converge read (link-up
residue), and after the read-clear, rings accumulate nothing on either die —
the hardware doorbell sideband looked inert despite the cocotb doorbell suite
passing on the same RTL. A baseline read was added so residue cannot
masquerade as responses. If 4b fails, check this note before assuming a
regression.
:::

### Category 5 — AHB TX storm (the wedge-hazard path)

**Purpose.** The only category that writes the TX aperture. This is the path
that historically killed a board.

**Gate.** `tt_gate_ahb_tx()` runs first and aborts the script with `exit 3`
unless `tt_verify_link_up()` succeeds on both dies. Every write is additionally
wrapped in `timeout $AHB_TX_TIMEOUT_S`; the first timeout exits `4` and
`run_all.sh` stops the whole run.

**Pass criteria** (`05_ahb_tx_storm.sh`):

| Sub | Pass |
|---|---|
| 5a | one AHB_TX word completes within the timeout |
| 5b | `N_AHB_TX` writes complete, **and** the slave's `STATUS[4] packet_committed` is set afterwards |
| 5c | link still verifies up; master `STATUS` sticky errors still clear |
| 5d | an AHB_TX read returns a value within the timeout |

The `packet_committed` assertion is deliberately hard: the script's inline
analysis traces it to `src/rtl/fifo/tidelink_fifo_ctrl.sv:445-469`, where the
bit is a **level/sticky** flop set on `write_complete` and cleared only by an
explicit read of FIFO address 0. It does not pulse and does not self-clear, and
the script sleeps 1 s before reading, so a 0 here is deterministic evidence the
data never landed — not a timing artefact.

**Before running category 5**, make sure `AHB_TX_BASE` matches the bitstream
generation. GP1-split images (2026-06-12 onwards) moved the aperture from
`0x4400_0000` to `0x8400_0000`; a read or write to the wrong one hits an
unmapped hole (DECERR/SIGBUS).

### Category 6 — AHB FIFO

**Purpose.** Observe FIFO behaviour through Region 0/1 registers only.

**Pass criteria** (`06_ahb_fifo.sh`): `CURRENT_CREDITS` at idle is in
`[4090..4096]`; `CTRL.FLUSH` clears `RELEASE_ACC` to 0 and clears the `STATUS`
sticky errors `[3:1]`; `RELEASE_THRESHOLD` round-trips 0 and 64 (then is
restored to 20); `RELEASED_CREDITS_ACC` and `DOORBELL_RESP_ACC` both read 0 on
the second consecutive read (clear-on-read); sticky errors are clean at rest.

### Category 7 — Address translation

**Purpose.** `PAIR_BASE_ADDR` and the Region 4 CAM/aux slots.

**Pass criteria** (`07_addr_translation.sh`): `PAIR_BASE_ADDR` round-trips five
trial values and restores; `CTRL_LOCK` is clear; each Region 4 slot
`0x084`–`0x09C` either round-trips a XOR-perturbed value or is stable (RO) —
both are accepted and the script reports which, and every slot is restored.

**Safety.** Slot 0 (`0x4403_2080`, `ROLE_CFG`) carries the W1S `role_lock` and
is **never touched**.

### Category 8 — PTP basic

**Purpose.** APB-side plumbing of the `tidelink_ptp` pass-through registers,
without initiating a sync.

**Pass criteria** (`08_ptp_basic.sh`): `PTP_CTRL` (`0x4403_2034`) accepts
benign values with W1P-aware read-back; `PTP_RX_PAYLOAD` (`0x4403_2038`) and
`PTP_STATUS` (`0x4403_203C`) are read-only and non-faulting.

### Category 9 — PTP hardware sync

**Purpose.** Region 2 hardware-sync initiator, on a PHC-integrated image.

**Gates.** Two: the link must verify up, **and** the PHC block must be present
— detected by reading `HW_SYNC_STATUS` (`0x4403_2048`); the script skips and
exits 0 if it reads `0xffffffff` or is unreadable.

**Pass criteria** (`09_ptp_hw_sync.sh`): `HW_SYNC_CTRL` round-trips on its
sticky bits `[0]`/`[2]`; `HW_SYNC_INTERVAL` round-trips; `seq_num` advances over
`PTP_SYNC_OBSERVE_SECS`; `HW_SYNC_STATUS.active` reads 1 with sync enabled;
servo telemetry at slave `0x060/0x064` is readable; and a `PTP_SOAK_SECS` soak
shows zero link drops.

### Category 10 — Servo config + timestamp mailbox

**Purpose.** Region 2 servo config (`0x04C`–`0x05C`) and the Region 3 mailbox
(`0x060`–`0x07C`).

**Pass criteria** (`10_servo_mailbox.sh`): each servo slot either round-trips a
XOR-perturbed value or is stable (RO) — both accepted, and the original is
restored; every mailbox slot is readable.

:::{note}
The timestamp mailbox is **read-only from APB** by design — it is written by
the FC sideband when a PTP exchange completes. That read-only property was a
real RTL defect found on 2026-07-30 (a plain external APB write could overwrite
an assembled cross-die timestamp) and is now enforced by the
`fc_cfg_apb_active` qualifier in `tidelink_top.sv`. See
[Verification](verification.md) for the gate that pins it.
:::

### Category 11 — Performance counters

**Purpose.** Regions 5/6/7 (`0x0A0`–`0x0FC`, 24 slots) readability and
movement under traffic.

**Pass criteria** (`11_perf_counters.sh`): all 24 slots readable; with the link
up, at least one slot advances after four doorbell rings on the peer;
`0x4403_20E0` (R7 `DBG_LINK_STATUS`) does not read `0xFFFFFFFF` — the sentinel
for the R7 33→32-bit truncation defect.

### Category 12 — Region 8 chiplet extended (PHY align + I²C training)

**Purpose.** The most surface-exposed configuration block: `0x100`–`0x11C`.

**Pass criteria** (`12_chiplet_phyalign.sh`): `PHY_ALIGN_ID` exact;
`SWI_BIT_SLIP_LO` round-trips on `[23:0]`; `SWI_LANE_STATUS` ignores writes;
`NEGO_TRAIN_CFG` round-trips; `NEGO_TRAIN_STEP` does not latch; `SWI_PHASE_OFFSET`
is read (never written — it is latched at `role_lock`); `SWI_TRAINING_MODE`
round-trips on `[1:0]`.

### Category 13 — Long soak

**Purpose.** Endurance. A tick loop for `SOAK_SECS`, sampling lane status,
`STATUS` sticky errors and ECC counters every `SAMPLE_GAP_S`, with a random
safe operation per tick (version read, doorbell ring if the link is up,
`RELEASE_THRESHOLD` round-trip, `PAIR_BASE_ADDR` read, `SWI_BIT_SLIP_LO` read).

**Pass criterion**: 0 drops and 0 sticky events, unless `SOAK_FAIL_ON_DROP=0`.

:::{warning}
**Category 13's drop criterion is `popcount(locked) == 8` on both dies**
(`13_long_soak.sh`, drop detection). On a link that has *left* training mode,
`lane_locked` reads **0 by design** — the lane checker only matches training
patterns — which is criterion B in `tt_verify_link_up()` and is called out
explicitly in `docs/BOARD_DEPLOY_RUNBOOK.md` §6. A data-mode soak will therefore
log a `LINK-DROP` on every tick. Interpret cat 13's drop count against the
training-mode state of the link, not in isolation.
:::

## The helper library — `lib/lib_hwtest.sh`

`lib_hwtest.sh` is the trust boundary: **only it knows how to talk to the
boards**, and category scripts must not introduce a new transport
(`docs/reference/HW_TEST_SUITE.md` §2). It deliberately mirrors the
`/dev/mem` mmap-over-`sshpass` idiom already used by `wlink_probe.sh` and
`bringup_pair_converge.sh` — slow, but identical to the safety-audited path.

| Helper | Signature | Notes |
|---|---|---|
| `tt_devmem_read` | `IP ADDR` → `0xXXXXXXXX` or empty | single 32-bit read |
| `tt_devmem_write` | `IP ADDR VAL` | single 32-bit write |
| `tt_debug_unlock` | `IP` | writes 1 to the debug-unlock GPIO `0x4404_1000`; idempotent, required before non-trivial Region-4/8 access on the slave |
| `tt_tl_read_batch` | `IP OFF...` | batched reads relative to `0x4403_2000` |
| `tt_tl_write_batch` | `IP OFF VAL ...` | batched writes relative to `0x4403_2000` |
| `tt_read_lane_status` | `IP` → `locked fault cal_done popcount fcsm cr_seen` | decoder for `0x4403_2108` |
| `tt_link_popcount` | `IP` → integer | popcount of the locked byte |
| `tt_verify_link_up` | — → rc | two acceptance criteria, below |
| `tt_gate_ahb_tx` | — | **aborts with `exit 3`** if the link is not verified up |
| `tt_ahb_tx_write` / `tt_ahb_tx_read` | `IP ADDR [VAL]` | only safe after the gate |
| `tt_pass` / `tt_fail` / `tt_skip` | `MSG` | result accounting |
| `tt_assert_eq` / `tt_assert_neq` / `tt_assert_in_range` | — | assertions |
| `tt_summary` | — → rc | prints the pass/fail/skip tally; rc 0 iff 0 failures |
| `tt_snapshot_regs` | `IP` | dumps the register set the suite cares about |
| `tt_read_version` | `IP` | reads `0x4403_2014` |

### The two link-up criteria

`tt_verify_link_up()` accepts **either**:

* **Criterion A (training mode):** both dies report 8/8 lanes locked **and**
  `cal_done = 1`.
* **Criterion B (data mode):** both dies report `cal_done = 1` **and** an FCSM
  state of 4 (`LINK_IDLE`) or 5 (`LINK_DATA`). After `swi_training_mode`
  clears, `lane_locked` legitimately drops to 0, so criterion A can never pass
  in data mode.

:::{warning}
**Known instrument defect in the FCSM decode.** `tt_read_lane_status()` extracts
the FCSM state as `(s >> 17) & 0xF` — a **4-bit** field, i.e. bits `[20:17]`
(`lib/lib_hwtest.sh:192`). `REG_INVENTORY.md` and
`docs/BOARD_DEPLOY_RUNBOOK.md` §6 document the same 4-bit field. But the
instantiated RTL packs `fcsm_state` as **3 bits at `[19:17]`**, with `[20]` =
`a2l_replay_app_valid` (`src/rtl/local_overrides/axi_chiplet_controller.sv:2734-2738`;
`docs/REGISTER_MAP.md` records the same divergence against the RDL and states the
RTL is authoritative). Consequence: whenever `[20]` is set, a healthy FCSM 4
decodes as **12** and FCSM 5 as **13**, so criterion B fails on a healthy link.
If `tt_verify_link_up` reports an implausible FCSM ≥ 8, mask the value with
`& 0x7` before believing it. This is an instrument bug, not a DUT bug — verify
the instrument before theorising about the link.
:::

## Register inventory

`pynq_host/scripts/hwtest/REG_INVENTORY.md` is the suite's own
register-by-register catalogue: for every register the suite touches it records
offset, access type, reset value, bit layout, the test method, and the expected
result, plus a per-category coverage matrix. `docs/reference/HW_TEST_SUITE.md`
§4 carries the complementary "what is exercised vs not" matrix and names the
deferred gaps (thermal characterisation, PHC absolute-offset accuracy,
multi-pair topologies).

Note that `REG_INVENTORY.md` predates the current `SWI_LANE_STATUS` packing —
see the warning above and [Register Map](register_map.md), which is written
against the RTL.

## Scripts that exist only on the consolidation branch

This documentation tree is written against `fix/z2-drop-park-hook` @ `9eaafb7`.
Two hardware-test artefacts exist **only** on
`integ/tidelink-consolidated-2026-08-07` and are absent here. Verify with:

```sh
git ls-tree -r integ/tidelink-consolidated-2026-08-07 --name-only | grep hwtest
```

| File | Branch | What it is |
|---|---|---|
| `pynq_host/scripts/hwtest/14_rx_fifo_phantom_pop.sh` | consolidation only | Board regression for the RX-FIFO empty-read **phantom-pop** defect (TL-022). After `FLUSH`, an empty-FIFO word0..word7 read sweep must leave `CURRENT_CREDITS` ≤ MAX (4096) and no higher than the post-FLUSH baseline, with the overrun sticky clear. Reads only — never writes the FIFO window. Its own header records that it is **pending a rig run** and is not yet wired into `run_all.sh`. |
| `pynq_host/scripts/hwtest_gate.sh` | consolidation only | The durable HW regression gate — the hardware analogue of the sim gate. Checks **provenance** (the build manifest's `source_commit` must equal `git HEAD`, else refuse), then runs `HWG_PORS` fresh POR cycles (default 4) on `kr260-pair-onchip`, each proving autonomy and a byte-exact data soak, and requires a land rate ≥ `HWG_MIN_PASS`. Emits `imp/hw_gate/verdict.json` and exits non-zero on FAIL. Usage: `hwtest_gate.sh [-N pors] [-s soak] [-m min_pass] [-H host] [-b board]`. |

The consolidation branch also carries a set of KR260 Ethernet-chiplet probes
(`kr260_eth_*`), a weekend campaign harness (`pynq_host/scripts/weekend/`) and
several read helpers that are not present here.

:::{note}
`14_rx_fifo_phantom_pop.sh` targets the **standalone pair** vehicle, not the
eth-chiplet image. `hwtest_gate.sh` is intentionally scoped to the KR260
on-chip (one board, two dies) vehicle — the lottery-free one — and the
standalone-Z2 and eth-chiplet gates are separate entry points.
:::

## Interpreting a failure

### Step 0 — verify the instrument, not the DUT

Before concluding anything about the link, confirm:

- `TIDELINK_SOC` is unset or a Z2 alias (otherwise the suite aborts `exit 3` and
  it is not a link failure).
- `MASTER_IP` / `SLAVE_IP` point at the two ribbon-connected boards, not the
  spare (see the warning at the top).
- The bitstream generation matches the aperture bases you exported
  (`0x44xx_xxxx` pre-GP1-split vs `0x84xx_xxxx` GP1-split).
- On a KR260 (which the hwtest suite does not serve, but the other harnesses
  do) the AFI canaries pass — see [Bring-Up](bringup.md). If they do not, every
  other reading is a lie.

### Step 1 — read the observability registers

| Register | MMIO (Z2) | Fields worth reading | Interpretation |
|---|---|---|---|
| `SWI_LANE_STATUS` | `0x4403_2108` | `[7:0]` lane_locked, `[15:8]` lane_fault, `[16]` cal_done, `[19:17]` fcsm, `[20]` a2l_replay_app_valid, `[22:21]` llrx state, `[23]` cr_seen, `[24]` crack_seen, `[29]` llrx_valid, `[30]` a2l link valid, `[31]` fe_rx_is_full | The one register everything reads. `cal_done=0` ⇒ the calibrator never finished. `fcsm=4` ⇒ `LINK_IDLE`, `5` ⇒ `LINK_DATA`. `lane_locked=0` **after** training mode clears is expected, not a fault. |
| `OBS_FC_CREDIT` | `0x4403_219C` | `[7:0]` `fe_rx_credit_max`, `[15:8]` `fe_rx_ptr`, `[16]` `fe_rx_is_full` mirror, `[31:24]` presence marker `0xFC` | **Read the credit *value*, not just `0x2108[31]`.** `fe_rx_is_full` only flags credit `== 0`; a credit garbled to a small non-zero passes the send gate and exhausts after a few packets. `0x00000000` here means an older image without the observability. |
| `SYNC_DET / ECC` | `0x4403_2114` | `[15:0]` ecc_corrupted (**dead**, reads 0), `[31:16]` **sync_detected** saturating count | `[31:16] > 0` proves the RX reassembled a coherent 128-bit SYNC word, i.e. cross-lane deskew is delivering aligned words. `= 0` means lanes are still misaligned or the link is dead. |
| `SWI_EPOCH_STATUS` | `0x4403_2140` (V2) | `[0]` epoch_anchored, `[6:1]` epoch_span (0–24 words) | `anchored=1` on **both** dies simultaneously is the hardware analogue of the sim `(deskew: m=1 s=1)` banner — proof the epoch corrector is engaged. |
| `STATUS` | `0x4403_2010` | `[0]` returner_busy, `[1]` overrun, `[2]` underrun, `[3]` master_error, `[4]` packet_committed | `[4]` is **sticky**, cleared only by reading FIFO address 0. `[4]=0` after a storm means the data did not land. |
| `CURRENT_CREDITS` | `0x4403_200C` | 13-bit | ≈4096 at idle. A value **above** 4096 is the phantom-pop signature. |
| `PHY_ALIGN_ID` | `0x4403_211C` | — | must read `0x5041_0100`; anything else means you are not talking to TideLink |
| `TIDELINK_VERSION` | `0x4403_2014` | — | must read `0x544C_0100` |

For the full map and the region decode, see [Register Map](register_map.md).

### Step 2 — do not trust the status registers for liveness

This is the single most important interpretation rule on this page, and it is
measured, not asserted. From `docs/LINK_RECOVERY_MECHANISM.md` §5, which
sampled every APB-reachable candidate in a healthy and a wedged state and
diffed them:

| Observable | Healthy | Wedged | Discriminates? |
|---|---|---|---|
| `fcsm` state | 4 | **4** | **No** |
| `cal_done`, `cr_seen`, `crack_seen` | 1, 1, 1 | **1, 1, 1** | **No** |
| llrx framer state | 0 | **0** | **No** |
| EPOCH (`0x2140`) | `0x00000000` | **`0x00000000`** | **No** |
| TX SYNC-insert count (`0x2120`) | `0x5c010000` | **same** | **No** |
| RX SYNC-detect count (`0x2124`) | `0x5d000000` | **same** | **No** |
| `crc_errors` | 0 | **0** | **No** |
| **a2l replay backlog** (`wptr − synced_ack`, hierarchical) | **1** | **9…16** | **Yes, while traffic flows** |

The prescribed two-stage liveness recipe (stage 2 is **not** optional):

1. **Cheap:** read the a2l replay backlog on both dies. More than 2 outstanding
   ⇒ declare wedged. Healthy steady state is exactly 1 outstanding — that is a
   measured value, not a chosen threshold.
2. **Definitive:** a **tagged data canary** — drain both RX FIFOs, send a
   payload carrying a value never previously sent in **each** direction, and
   require byte-exact receipt.

Also excluded as liveness indicators: `0x2144` (live-match) saturates and lies,
and `0x215C` (`sync_seen`) is retired in V2 and reads 0 by construction.

**Corollary:** two of the three tested disturbance classes self-heal over 1–3
probe rounds (single-lane stuck-1 after ~1 retry round; all-lane corruption
after ~3). **Re-probe a few times before declaring a wedge.** Only the
link-clock dropout class is a hard wedge, and nothing below a POR of **both**
dies clears it — every firmware-reachable rung was tried and failed.

:::{caution}
**Do not write a beacon-based recovery routine.** `docs/LINK_RECOVERY_MECHANISM.md`
§3 and §6.1 record that the SYNC beacon is non-causal for the classes that
recover (a matched-dwell zero-write control recovered at the same count) and
that a forced beacon **destroyed a still-working direction** in one measured
case. Likewise, there is no firmware-reachable PHY retrain: `SWI_RECAL` is a
measured no-op after first lock because `calibrated_once_q` gates both
re-trigger edges off forever. A dedicated forced-recal W1P is a **proposal
only** — no such bit exists.
:::

### Step 3 — known failure signatures

| Signature | Likely cause | Action |
|---|---|---|
| Every category fails instantly, `exit 3` before any board access | `TIDELINK_SOC` set to a non-Z2 value | unset it, or use the KR260 tooling instead |
| Slave reads flat zeros for the whole run | `SLAVE_IP` points at `z2_03`, the spare not on the ribbon | pass `SLAVE_IP` explicitly |
| Cat 5 exits 4 | AHB_TX write timed out — board possibly wedged | stop; re-verify the link; a physical power-cycle may be required |
| Cat 5 exits 3 | gate refused — link not verified up | run `bringup_pair_converge.sh` first ([Bring-Up](bringup.md)) |
| `FCSM=5`, `0x2108[30]=1`, `0x2108[31]=0` | un-ACKed long packet jamming the FC node | `pynq_host/scripts/unjam_fc_node.sh <IP>`, or a full re-converge |
| `CURRENT_CREDITS` reads above 4096 | RX-FIFO phantom pop (TL-022) | the guard has regressed; see cat 14 on the consolidation branch |
| Board SSH dead, `/dev/mem` bus error | PS hard-wedge (pre-`4c0a51a` images) | JTAG rescue, then redeploy — see [Boards](boards.md) |
| Everything reads `0xffffffff` / bus errors right after a reboot | the PL is simply unprogrammed | deploy; not a fault |

For the tracked-defect list and the two-diverging-trees caveat, see
[Known Issues](known_issues.md).

## What this suite does not cover

Per `pynq_host/scripts/hwtest/README.md` and
`docs/reference/HW_TEST_SUITE.md` §4:

- **Build and synthesis** — see [Verification](verification.md).
- **Simulation** — `cocotb/` and `uvm/`; see [Simulation Tests](simulation_tests.md).
- **PHC absolute timing accuracy** — category 9 verifies protocol mechanics,
  not the offset bound; that needs a GPS reference.
- **Thermal characterisation** — no on-die temperature sensor is exposed.
- **Multi-pair topologies** — `bridge1` is a single pair.
- **KR260** — entirely out of scope for `hwtest/`; use
  `fpga/hw_regression/td_v2_channels.sh` and the KR260 Python probes described
  in [Bring-Up](bringup.md).
