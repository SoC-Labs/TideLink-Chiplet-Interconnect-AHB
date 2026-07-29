# Handover — V2 pad clock-gate SYNC regression (Z2 pair)

**Date:** 2026-07-29
**Branch:** `fix/v2-sync-clock-gate` @ `c8d0e5f` (branched from `feat/txgen-v1-integration` @ `c15985b`)
**Status:** root cause found and fixed in RTL; sim shows no regression; **not HW-proven**; **not pushed**
**Blocking decision:** whether the fix ships unconditionally or behind a parameter (see §3)

---

## 1. TL;DR

The Z2 pair has **two independent faults**. One is now root-caused and fixed; the other is open.

| | Direction | Status |
|---|---|---|
| **Fault 1** | B→A (die_b → die_a) | **ROOT-CAUSED + FIXED in RTL.** V2 dropped one term from the pad clock-gate enable. Needs `package_ip` + FPGA rebuild + HW proof. |
| **Fault 2** | A→B (die_a → die_b) | **OPEN.** PHY is provably perfect; zero packets reach the link layer. Prime suspect: LL/FC data-mode entry. |

Everything previously believed about this blocker — a bad board, a bad ribbon, a missing I2C
harness, the autoneg training-exit gap — is either **retracted or demoted**. Do not spend
bench time on cables.

---

## 2. Fault 1 — the bug (fixed)

`pad_clk_tx` — the clock a die forwards, which **is** the peer's `pad_clk_rx` — is the output of a
**clock gate inside lane 0's serialiser**:

```
WavD2DGpio_v2.v:1966   io_pad_clk_tx = gpiotx_0_io_pad_clk
WavD2DGpioTx.v:322     io_pad_clk    = hs_clk_gated_wcg_io_clk_out   (enable: clk_en_qual <- io_clk_en)
```

The V2 fork dropped a term from that enable that V1 has:

```verilog
V1  WavD2DGpio.v:1003     clk_en = tx_en | postcount!=0&… | effective_training_mode | sync_insert
V2  WavD2DGpio_v2.v:1980  clk_en = tx_en | postcount!=0&… | effective_training_mode
                                                                        ↑ DROPPED
```

V2 **still has the signal** (`tx_sync_inserting_w`, `:616`/`:688`) — it was wired only to the APB
observability counter (`:708`), never to the clock gate.

**Effect on silicon.** A die in **data mode** (`training=0`) on an **idle link** (`tx_en=0`) inserts
SYNC *logically* — `tx_sync_ins_cnt` increments in the link-word domain — but the pad serialiser is
not clocked, so:
1. the beacon **never reaches the wire**, and
2. the forwarded `pad_clk_tx` stays **gated off**, leaving the peer's whole RX capture domain
   without a clock.

`effective_training_mode` is the only term holding the gate open. That is why the link works while a
die is in training and dies the instant it leaves.

### Evidence (measured on the pair, `tl-trainfb-8lane`, both dies)

- After taking the slave out of training: die_b `tx_sync_ins_cnt` **+13747 in 3 s (~4582/s)**, while
  die_a `sync_detected` delta was **exactly 0**.
- die_a `RXDET2 (0x44032124)` `seen_cnt` = **14553, all 8 lanes sticky** — *precisely* die_b's
  transmitted count from **before** it entered training. die_a received every word die_b actually
  sent, then froze on the training transition and never resumed.
- Recabling changed nothing — consistent, because the beacon was never on the wire.
- A physical connector fault cannot produce an exact TX/RX count match followed by a clean stop on
  a state transition. That is what exonerates the cable.

### The fix

`fix/v2-sync-clock-gate` @ `c8d0e5f` — adds `| tx_sync_inserting_w` to all 8
`gpiotx_N_io_clk_en` in `src/rtl/local_overrides/WavD2DGpio_v2.v:1980-2029`. One file, 8 lines.

---

## 3. DECISION REQUIRED before any tapeout

**This changes the shipping FPGA *and* ASIC netlists.** It is a restoration of V1 parity, not new
behaviour, but it is **not** param-gated — which departs from this project's convention of hiding
netlist-affecting changes behind a default-off parameter (cf. `TRAIN_ENTRY_FALLBACK`,
`DEBUG_UNLOCK_DEFAULT`, `HONEST_MASK_HS`).

Two options:
- **(a) Unconditional** — recommended. It is a bug fix restoring behaviour V1 always had; gating a
  clock that must run is not a feature anyone wants off.
- **(b) Behind a parameter** — safer for a live tapeout; costs a fifth plumbing level, and note the
  documented trap that a `+define+`/RTL default **does not reach packaged-IP OOC synth** — only a
  wrapper-face parameter recorded in `component.xml` does.

**Do not tape out with this un-ratified either way.**

---

## 4. Rebuild procedure (read the trap first)

🔴 **`imp/fpga/tidelink_ip/src/WavD2DGpio_v2.v` is a SEPARATE CHECKED-IN COPY and still has the old
text.** `build_design` synthesises *that* copy, not `src/rtl/`. This exact trap has burned the
project before (`fpga/scripts/build_provenance.tcl:14-26` "stale packaged IP";
memory `project_farm_package_ip_stale_2026_07_02` — on-silicon obs read all-zeros because the
instrument was never actually synthesised).

```bash
source ./set_env.sh                    # MANDATORY — without it every sim suite FAILs in 4-5 s
export TIDELINK_PHY_V2=1
export TD_AUTO_LANE_MASK_E4=0          # 8-lane. Default is 0xE4 (4-lane) and is genuinely harmful.
export TL_TRAIN_ENTRY_FALLBACK=1       # Option A self-start; needed on this dead-I2C rig

make -C fpga package_ip TARGET=pynq-z2-pair-all
# VERIFY STRUCTURALLY — never by md5:
grep -c 'tx_sync_inserting_w' imp/fpga/tidelink_ip/src/WavD2DGpio_v2.v    # must be >= 8

make -C fpga build_design TARGET=pynq-z2-pair-all        # die_a
make -C fpga build_design TARGET=pynq-z2-pair-flip-all   # die_b
```

Targets are `pynq-z2-pair-all` (die_a) and `pynq-z2-pair-flip-all` (die_b). The `TL_TRAIN_ENTRY_FALLBACK`
env var is read at `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl:435`.

---

## 5. How to prove it on hardware

**The rig.** die_a = `z2_02` = **192.168.4.101** = MASTER. die_b = `z2_01` = **192.168.2.101** = SLAVE.
(⚠ `pynq_host/scripts/tl39.sh` maps `b` to **192.168.6.101 = z2_03**, the *wrong* board for this
pair. Drive z2_01 by IP.)

```bash
# leases — NEVER chain acquire with board ops; check, then acquire each alone
ssh mapstone-dev 'fpgahub lease show pynq_z2_02_ps'
ssh mapstone-dev 'fpgahub lease acquire pynq_z2_02_ps --user $USER --ttl 3600'
ssh mapstone-dev 'fpgahub lease acquire pynq_z2_01_ps --user $USER --ttl 3600'

# POR is MANDATORY before every deploy (role_lock survives a PL reload)
ssh mapstone-dev 'fpgahub hub power-cycle pynq_z2_02_ps --yes --off 3'
ssh mapstone-dev 'fpgahub hub power-cycle pynq_z2_01_pl --yes --off 3'   # note: _pl for z2_01

./pynq_host/scripts/deploy_pair.sh 192.168.4.101 z2_02 die_a <artefact-dir>
./pynq_host/scripts/deploy_pair.sh 192.168.2.101 z2_01 die_b <artefact-dir>
```

**The test.** Instruments are already staged on both boards: `/home/xilinx/tlsnap.py`
(`snap` | `rate <s>` | `set ADDR VAL` | `syncclr`) and `/home/xilinx/tltx1.py` (guarded single-word TX,
run detached).

```bash
# 1. fresh state: both dies anchored span 0, 8/8 lanes, SLICEMAP 0x76543210
sudo python3 /home/xilinx/tlsnap.py                       # on each die

# 2. transition the slave to data mode (on die_b / 192.168.2.101)
sudo python3 /home/xilinx/tlsnap.py set 0x4403210C 0x0    # clear train_auto_en (stop the retry loop)
sudo python3 /home/xilinx/tlsnap.py set 0x44032100 0x1C   # training OFF + force_always beacon ON

# 3. THE PASS CRITERION — on die_a (192.168.4.101):
sudo python3 /home/xilinx/tlsnap.py rate 3
#    BEFORE the fix: SYNC_DETECTED delta == 0        (die_a blind)
#    AFTER  the fix: SYNC_DETECTED delta > 0         <-- B->A alive
```

Everything else (epoch anchored, 8/8 LIVEMATCH, identity slicemap) is already good *before* the fix
and is **not** a discriminator. **The only discriminator is die_a's `sync_detected` delta.**

---

## 6. Traps — every one of these cost real time

1. **Counters SATURATE at 0xFFFF and are NOT read-clear** (`Wlink.v:1102`). A reading of `65535`
   cannot distinguish "beaconing hard" from "stopped an hour ago". **Always use a delta over a dwell
   on an unsaturated counter.** R8 bit[5] `sync_obs_clr` does **not** clear them (they are LL-domain,
   `WavD2DGpio_v2.v:38`); only a POR does.
2. **There is NO software re-anchor.** Once the deskew anchor is lost, no combination of
   recal / force_always / sync_obs_clr / re-arm restores it (`calibrated_once_q` makes `SWI_RECAL` a
   no-op). **POR + autonomous winscan only.** Every experiment must start from POR + deploy and
   finish before the anchor decays (it decayed on its own in ~45 min of idling).
3. **`tl39.py recal` is unsafe on this build** — it does `keep = rd(R8) & 1` and so **wipes beacon
   bits [2]/[4]**. Pulse recal by hand: `0x1C → 0x1E → 0x1C`.
4. **`force_always` (R8[3]) bypasses the postcount serialiser-drain guard**, which exists because a
   beacon landing on a live payload word **corrupts it**. `0x1C` is safe for *anchoring*, **not** for
   carrying data. Anchor with `0x1C`, drop to `0x14` before real traffic.
5. **The autoneg FSM is PARKED, not retrying** — `TIMEOUT_CTR (0x184)` is *static* (read it twice).
   Older notes saying "large and counting" are wrong. Because the master never *attempts* a
   transaction, **`I2C_MST_STATUS = 0x0` cannot distinguish a dead bus from a correctly-wired bus
   nobody drives** — this rig currently cannot validate the I2C harness at all.
6. **`sim_gate` without `source ./set_env.sh` fails every suite in 4-5 s**, looking exactly like
   catastrophic RTL breakage. Flat 4-5 s FAIL is *always* the env.
7. **AHB_TX (`0x8400_0000`) writes with no FC credit can wedge the PS.** Use `tltx1.py` (gates on
   credit, logs before the store, runs detached so a stalled beat can't take your session).

### Register cheat-sheet
- APB base **`0x4403_2000`** (Z2). ⚠ `0x21AC` / `0x21B0` / `0x21B4` **hard-stall the CPU** — never probe.
- **R8 `0x4403_2100`**: `[0]` training_mode `[1]` recal `[2]` sync_insert_en `[3]` sync_force_always
  `[4]` sync_robust_detect `[5]` sync_obs_clr (W1 pulse). *(from `axi_chiplet_controller.sv:2701`)*
- `0x210C` NEGO_TRAIN_CFG `[0]`=train_auto_en · `0x2140` EPOCH `[0]`anchored `[6:1]`span ·
  `0x2144` LIVEMATCH · `0x2114` `[31:16]`sync_detected · `0x2120` TXSYNC `[15:0]`ins_cnt
  `[16]`idle_lvl `[17]`train_lvl · `0x213C` SLICEMAP (identity = `0x76543210`) · `0x2124` RXDET2
- Data apertures are **GP1**: TX `0x8400_0000`, RX FIFO `0x8401_0000`.

---

## 7. Owed work

1. **A sim test that actually covers this.** `v2_syncdet`, `v2_data`, `v2_sustained` all PASS *with
   and without* the fix — they are blind to the idle-link clock-gating case, and that blindness is
   exactly the hole that let the regression ship. Needed: die in data mode, link **idle**, assert
   `pad_clk_tx` keeps toggling and the peer's SYNC-detect count rises.
2. **Confirm the enable timing in sim.** `clk_en_qual` samples `io_clk_en` only when `count==4'hf`
   (`WavD2DGpioTx.v:339-345`), while `tx_sync_inserting_w` lives in the link-word domain (hsclk/16).
   `count` and `clk_en_qual` run on the **ungated** `io_clk`, so there is no chicken-and-egg — but
   confirm the enable is high at the sampling instant covering the SYNC word's own 16 pad cycles.
3. **Audit V1 vs V2 for further dropped terms.** This is the **second** one in this same
   clock-gate/beacon area — the first was the postcount serialiser-drain guard, whose own comment
   reads *"V1 ALREADY HAS THIS GUARD; V2 LOST IT"* (`WavD2DGpio_v2.v:651`). A systematic diff of this
   file is warranted.

---

## 8. Fault 2 — A→B, still open

With die_b out of training and its RX ungated, the A→B PHY is **provably perfect**: die_b anchored
span 0, 8/8 LIVEMATCH, identity slicemap, `SYNC_DETECTED` saturating from die_a's beacons. Yet a
single word sent from die_a gives `txp=1 txw=1` on die_a (the word left) and **`rxp=0 rxw=0` on
die_b — nothing reached the link layer.** The RX FIFO stays empty.

So the A→B blocker is **above the PHY**: it is not deskew, not lane health, not the beacon, and not
the autoneg training-exit gap.

**Next suspect:** the LL/FC data-mode entry on die_b — the `0x208` LL-swreset bootstrap and the FC
handoff gated on the training **fall** (`axi_chiplet_controller.sv:3922`/`4806`/`3428-3437`). A
software-forced `R8[0]` fall may not produce the edge the handoff needs.
⚠ **Caveat to resolve first:** an APB read of `0x208` returned the same value as `0x008` (`0xcaf`) —
suspected **aliasing** in that window. Re-derive the correct access before trusting any `0x208` read.

---

## 9. Superseded — do not re-chase

- ~~z2_02 is physically faulty / re-seat the ribbon~~ — **retracted**; the failing die follows the
  *build*, not the board, and §2's count-match evidence exonerates the cable.
- ~~The training-exit gap is the delivery blocker~~ — the `R8` poke disambiguator was **run and
  refuted** (2026-07-29 AM). Clearing the slave's `training_mode` sticks but does not deliver.
- ~~The 4th PARK hook (`0a3b1cf`) fixes delivery~~ — it targets a real gap, but not the one stopping
  data. On a dead-I2C rig it parks the slave waiting for a master I2C write that cannot arrive.
- ~~Fit the I2C harness to unblock delivery~~ — **demoted**. Still worth doing for the designed flow,
  but it is not on the critical path, and per trap #5 this rig cannot currently validate it.

---

## 10. Rig state as left

`tl-trainfb-8lane` deployed on both dies after a clean POR, autonomous state (master `R8=0x14`,
slave `R8=0x15`, 8/8 lanes, span 0 both), **leases released**. Artefacts at
`~/tidelink_artefacts/tl-trainfb-8lane/` (die_a `777bf435…`, die_b `51c952ac…`, manifests +
SHA256SUMS). `tlsnap.py` and `tltx1.py` staged on both boards.

Uncommitted and **not** mine, left alone deliberately: `pynq_host/throughput_gui/agent/tl_perf_agent.py`
(the `cmd_cleartrain` interim workaround). Stage by name — a previous session swept another
session's fix in with `git add <dir>`.

---

# ⛔ ADDENDUM 2026-07-30 — THE UNCONDITIONAL FIX BREAKS BRING-UP. DO NOT BUILD IT.

A one-variable A/B on silicon **refutes the unconditional form of this fix.**

| image | source | zero-poke result |
|---|---|---|
| `tl-trainfb-8lane` | `76202ed-dirty`, **no fix** | ✅ `cal=1 fcsm=4`, anchored span 0, 8/8, identity slicemap |
| `tl-clkgatefix-8lane` | main `18491ef` **+ fix** | ❌ both dies `cal=0 fcsm=1`, no anchor, SLICEMAP POR |
| `tl-clkgatefix-trainfb-8lane` | `76202ed-dirty` **+ fix ONLY** | ❌ **identical failure** |

Two independent baselines, same fix, same failure. Each failing image POR+deployed twice (not the
lottery); the working image redeployed on the same boards immediately after each failure (rig fine).

**Failure signature:** both dies stay in training, never calibrate (`cal=0`), park at `fcsm=1` (just
before state 2), epoch never anchors. Lanes conduct (`lk=0xff`) but die_a's LIVEMATCH collapses to
**0x01 (1/8)** — the peer's capture is being *corrupted*, not disconnected.

**Correcting §2/§3 above:** I argued the fix was "provably inert during training" from
`insert_now = sync_en & ~training_mode & (ctr==0)`. That is unsound *as an argument about bring-up* —
bring-up is not one continuous `training_mode=1` interval, and the V2 autonomy heal pins
`insert_en=1` early (`axi_chiplet_controller.sv:2288`), so the inserter is armed in windows where
training_mode is 0. I also briefly blamed main's FCSM consolidation (`b98b944`) on that reasoning
plus a confounded first build; **the A/B refuted it and main is not implicated by any measurement.**

**Likely mechanism (hypothesis, unproven):** `clk_en_qual` latches `io_clk_en` only at `count==4'hf`
and holds it 16 cycles (`WavD2DGpioTx.v:339-345`), so one link-word `tx_sync_inserting_w` pulse opens
the pad clock gate for a WHOLE WORD. During bring-up that injects pad-clock edges when the serialiser
should be quiet — and `pad_clk_tx` IS the peer's `pad_clk_rx`, so calibration never converges.

**What still stands:** the B→A diagnosis and its sim proof are unaffected
(`sim_gate_pad_clkgate_idle`: edges 0→2352, peer sync_detected 0→138). **The diagnosis is right; the
unconditional fix is not.** It must be conditioned so the extra enable applies only once the link is
genuinely in data mode (cal_done / FCSM settled / latched post-training), never during
winscan/calibration. That is a design change, not a one-liner.

⚠ **`sim_gate_pad_clkgate_idle` passing proves NOTHING about bring-up.** Any future version must be
re-tested for bring-up on silicon. Branch `fix/v2-sync-clock-gate` and worktree branch
`worktree-agent-addd36a23a37dc875` both carry the unconditional form — do not build z2 images from
either until it is conditioned.
