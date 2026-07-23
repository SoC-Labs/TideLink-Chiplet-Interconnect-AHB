# RUNBOOK — Route A: V1 SYNC-Anchored Deskew (8-lane), sim-gated for an FPGA roll

**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/v1-route-a`
**Branch:** `exp/v1-route-a` (HEAD `142a7ca`)
**PHY submodule:** `deps/tidelink-gpio-phy` @ `6ee8418` (identical to main tree)
**Date:** 2026-06-22
**Author:** Route-A synthesis agent (consolidates four prior structured agent results)

---

## VERDICT AT A GLANCE

| Question | Answer |
|---|---|
| Sim delivery gate (does V1 carry bytes today?) | **GREEN** — byte-exact, both directions, under real injected skew |
| Sim mechanism gate (is the SYNC beacon the active re-align mechanism?) | **RED / FALSIFIED** — beacon never fires in this build; no recovery from a real framer slip |
| Build config validated and V1-confirmed? | **YES** — pure V1 flist, 175 files read clean in Vivado in-memory, 0 V2 defines |
| Safe to proceed to an 18-min FPGA build? | **YES, conditionally** — roll V1 to answer the *happy-path* "does it carry bytes" question only |
| Single most important caveat | **Do NOT cite the SYNC beacon as the resilience mechanism.** It is dormant in this build. If the roll is meant to demonstrate slip-resilient re-align, sim says it will not. |

---

## 1. THESIS

The historical record is unambiguous about *what crossed real bytes on silicon*: the **V1 PHY** path (internally "v33") moved a 4-packet AHB burst byte-perfect into the peer RX FIFO (hdr `0x00240000`, p0 `0xDA7A0000`). That path is built from two co-operating blocks:

- **Always-on PHY SYNC beacon** — `src/rtl/local_overrides/WavD2DGpio.v`:
  `localparam PHY_SYNC_WORD = 128'hF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00`, `SYNC_PERIOD = 6'd32`.
  Intent: emit a full-128 SYNC word every 32 idle link words, gated to fire only when the link is idle and not training, so it slips between packets and never displaces real data. Lane *N* carries `SYNC_WORD[16N+15:16N]`.
- **SYNC-anchored cross-lane deskew** — `src/rtl/local_overrides/tidelink_lane_deskew.sv`:
  uses the reassembled SYNC word to re-anchor per-lane `sync_pos` / collective re-prime, so the framer stays aligned **between back-to-back long packets** even when lanes word-skew by up to ~7 periods.

**V2** replaced this always-on beacon with a **one-shot epoch anchor** (`SWI_EPOCH_STATUS 0x44032140`, anchored[0]/span[6:1]). The deployed V2 recipe (mask `0xe4`, R8 `0x1D`, word-pin pokes) reaches bilateral `fcsm=4` link-up — but **the V2 epoch anchor has never delivered data byte-correct on silicon.**

**Thesis under test:** V1's always-on SYNC-anchored deskew is the *only* mechanism that has ever crossed bytes, so a fresh V1 8-lane build on today's tree should carry data byte-correct. **Prove it in sim before spending an 18-min FPGA roll.**

> WARNING (settled by the mechanism gate, §3.2): "V1 carries bytes" and "the SYNC beacon is *why*" are **two separate claims**. Sim confirms the first and **falsifies the second** for this build.

---

## 2. ISOLATION

This work is fully sandboxed; the main tree at `/home/dam1n19/SoCLabs/tidelink` is untouched.

- **Worktree:** `/home/dam1n19/SoCLabs/td-bisect/v1-route-a`, branch `exp/v1-route-a`, HEAD `142a7ca` — a checkpoint forked off the V2-debug tip `10563e3`. The **branch name is irrelevant** to PHY selection: the *filelist* decides V1 vs V2, and this worktree's filelist is pure V1 (see §4).
- **PHY submodule populated (one-time env fix, already applied):** the worktree shipped with `deps/tidelink-gpio-phy` **empty**, so the first VCS compile died:
  `Error-[SFCOR] cannot open deps/tidelink-gpio-phy/rtl/tidelink_popcount16.sv`.
  Fixed with `git submodule update --init deps/tidelink-gpio-phy`, which checked out the exact gitlink commit **`6ee8418`** — *identical to the main tree's submodule HEAD*. This only populated an empty submodule; **no source was modified.**
  **→ Any FPGA build script run in this worktree MUST run that submodule init first, or it will fail identically.**
- **xhb500 generated/ is a live symlink** (no regen needed):
  `deps/xhb500/generated -> /home/dam1n19/SoCLabs/tidelink/deps/xhb500/generated` (134 slave + 130 master `.sv` present). `set_env.sh` prints "[skip] already generated".
- **Env setup for any sim/build:**
  `cd /home/dam1n19/SoCLabs/td-bisect/v1-route-a && source ./set_env.sh`
  (sets `TIDELINK_HOME`=this worktree, `VCS_HOME`, `XHB500_*`, `CMSDK_DIR`). For sim you also need `PATH+=$VCS_HOME/bin` and `SIM=vcs`. IP-library env (`CMSDK_DIR`, `CMSDK_FPGA_SRAM_V`, `XHB500_IP_DIR`) resolves under `/research/AAA/ip_library` — **read-only, only read here.**

---

## 3. SIM-GATE RESULTS

Toolchain: VCS T-2022.06-SP2 (`$VCS_HOME`), cocotb 2.0.1. Suite: `cocotb/tidelink_top_pair` and mechanism tests, **V1 default** (`TIDELINK_PHY_V2` unset → `flists/tidelink_fpga.flist`, confirmed **0** `TIDELINK_PHY_V2` references). Elaboration clean, 0 errors.

### 3.1 DELIVERY GATE — **GREEN** (does V1 carry bytes, byte-exact, both ways?)

All real data-delivery oracles pass byte-exact on today's V1 tree.

| Test | Oracle | Evidence | Status |
|---|---|---|---|
| `test_data_path_compliant_driver` | Master writes `[hdr,0,0xDEADBEEF,0xCAFEBABE]` via a compliant (hwdata-held) AHB TX driver; read slave RX FIFO @ `0x08`/`0x0C`, assert == the two payload words. **PRIMARY M→S byte-compare.** | slave FIFO w2=`0xdeadbeef` w3=`0xcafebabe` == expected; `cal_done=1` both, `fcsm=4 cr=1 crack=1`. | **PASS** |
| `test_doorbell_done_right` | Ring exactly one M→S doorbell; read raw (non-RtC) `doorbell_response_acc` in slave APB regs; assert incremented. | raw reg = `4096` (was 0 after clear); delivered+consumed. | **PASS** |
| `test_data_path_master_to_slave` | AHB packet M→S, read slave RX FIFO `0x08`/`0x0C` == `[0xDEADBEEF,0xCAFEBABE]`. | byte-exact match. | **PASS** |
| `test_05_doorbell_master_to_slave` | Ring M→S doorbell; assert slave `DOORBELL_RESP_ACC` (RtC) != 0. | PASS (sim 153880ns). | **PASS** |
| `test_06_doorbell_slave_to_master` | **REVERSE** S→M doorbell; assert master `DOORBELL_RESP_ACC` incremented. | PASS (sim 153540ns) — proves S→M. | **PASS** |
| `test_08_ahb_packet_master_to_slave` | Drive AHB packet from master TX aperture; slave RX FIFO `0x08`/`0x0C` byte-match. | PASS (sim 168280ns). | **PASS** |
| `test_10_sustained_doorbell_replenish` | **8 batches × 48 rings each way, ring depth 31, back-to-back packets** — the exact scenario the V1 SYNC-anchored deskew exists to handle; assert `DOORBELL_RESP_ACC` advances **both** directions every batch. | M→S 8/8, S→M 8/8; S→M acc = `24576` across b0..b7. | **PASS** |
| `tidelink_top_pair` full default suite (`test_01..test_11`) | E2E bringup + bidir delivery + credit ring + PTP + enable-dip resilience. | **TESTS=11 PASS=11 FAIL=0 SKIP=0.** | **PASS** |
| `test_post_watchdog_doorbell_delivery` | **CHARACTERISATION, not a data gate.** Force-injects master FCSM into wedge state 7, waits for F-1 watchdog, releases, rings 10. Always passes if it completes. | cocotb PASS; verdict logged OUTCOME(b) doorbells-BLOCKED (0/10) — the **documented build-#5 forced-wedge artifact**, wedge is *artificially injected*, never occurs in the three real suites. **Does not change go/no-go.** | PASS (informational) |

**Delivery verdict: GREEN.** Both directions carry data byte-exact; sustained back-to-back traffic survives 8/8 each way.

### 3.2 MECHANISM GATE — **MIXED / mechanism FALSIFIED** (is the SYNC beacon why?)

| Test | Oracle | Evidence | Status |
|---|---|---|---|
| `test_12_sustained_data_skew_decay` | 80 back-to-back AHB DATA packets M→S under **DIFFERENTIAL per-lane skew L=[0,1,2,3,0,1,2,3]** both dirs; assert delivered==80, `fe_rx_is_full` never latches, `fe_rx_ptr` never freezes. | "DIFFERENTIAL per-lane skew present: True"; **delivered 80/80 intact**; `fe_rx_is_full` ever latched: False; "no decay — link sustained all 80." Proves coherence under **real** skew, not zero-skew luck. | **PASS** |
| `test_data_path_probe` (M→S, zero-skew) | Trace FCSM + FC-adapter to localise where data dies; non-asserting. | `S.fifo_wr=4`, final `M.fcsm=4 S.fcsm=4` — 4-word packet reached slave and committed. ("master never submits a2l=0" string is a sampling artifact, contradicted by `fifo_wr=4`.) | **PASS** |
| `test_s2m_path_probe` (bidir, zero-skew) | Part A: M→S byte-readback. Part B: drain → credit release → S→M sideband → master l2a + credit accumulators. | Part A byte-exact: slave FIFO `[0x00]=0x00240000`, `[0x08]=0xdeadbeef`, `[0x0c]=0xcafebabe`. Part B: `s_a2l_cyc=1 m_l2a_cyc=1`; master `RELEASED_CREDITS_ACC=0x4` `PAIR_CREDIT_COUNTER=0x4`. Both dirs byte-correct. | **PASS** |
| `test_15_framer_resync_after_slip` | Bring pair up healthy, deliver 8 M→S, **inject a real framer SLIP** into slave RX (force byte-align FSM state=2 trap 1 cy), drive 16 more; require LOSSLESS recovery (≥23/24, 0 corruptions) — recovery is *supposed* to come from the SYNC delimiter re-hunting the framer. | Pre-slip 8/8 intact. **Post-slip 0/16, TOTAL 8/24.** CRITICAL: **the SYNC beacon NEVER FIRED the whole run** — `master sync_insert=0` across all 2388 TX samples, `slave sync_detected=0`, **0 SYNC_DET events**. The gate `(sync_word_ctr==0) & tx_idle & (postcount==0) & ~training` never closes because idle&&en are asserted simultaneously 224/240 cycles. | **FAIL** |

**Mechanism findings (load-bearing):**

1. **Data IS byte-correct in V1** — `test_12` carries 80/80 under *differential* per-lane skew (not zero-skew luck); both probes show byte-exact M→S and a working S→M credit-release sideband. The "V1 carries data" half holds.
2. **The SYNC-anchored re-align is NOT the active mechanism.** `test_15` proves the beacon **never fires** in this build, yet pre-slip data still flows 8/8. Coherence here comes from the **deskew FIFO + framer hunt**, *not* from SYNC re-anchoring.
3. **No recovery from a real slip.** Once the framer is knocked into its state=2 trap, there is no live SYNC delimiter to re-hunt → post-slip recovery is **0/16**. On silicon, a mid-stream byte-align slip under sustained load would **not self-heal** in this build.

**Mechanism verdict: the proposed mechanism is FALSIFIED in sim.** The beacon gate (`idle && en` asserted together) structurally never asserts `sync_insert` in this build → triage required before any claim of slip-resilience.

---

## 4. BUILD — V1 8-lane (config validated)

### 4.1 Exact build command

```bash
cd /home/dam1n19/SoCLabs/td-bisect/v1-route-a \
  && git submodule update --init deps/tidelink-gpio-phy \
  && source ./set_env.sh \
  && unset TIDELINK_PHY_V2 \
  && make -C fpga build_design TARGET=pynq-z2-pair-all
```

- **Target:** `pynq-z2-pair-all` (die_a / non-flip), part `xc7z020clg400-1`. For die_b use the mirrored-pinout `pynq-z2-pair-flip-all`.
- **Est. time:** ~18 min local. Output bitstream:
  `/home/dam1n19/SoCLabs/td-bisect/v1-route-a/imp/fpga/output/pynq-z2-pair-all/tidelink.bit` (`.hwh`/`.bin` alongside).
- **Both halves (optional, farmed):**
  `make -C fpga build_pair_farmed FARM_HOST=srv04936` (master local + slave on srv04936). Single-host: `make -C fpga build_pair_concurrent`. The farm path **inherits the caller env** → stays V1 as long as `TIDELINK_PHY_V2` is unset.

### 4.2 V1 selection mechanism (why this is V1, not V2)

Two places, both keyed on env `TIDELINK_PHY_V2`:
- `fpga/filelist.tcl` lines 41–43: unset → `tidelink_fpga.flist` (V1); `==1` → `tidelink_fpga_v2.flist`.
- `build_design.tcl` lines 289–295: injects `-verilog_define TIDELINK_PHY_V2` into every synth run **only when `==1`**.
**Unset on both ⇒ clean V1.**

### 4.3 Config validation status — **VALIDATED (without a full build)**

| Layer | Result |
|---|---|
| Env paths on disk | `CMSDK_DIR`, `CMSDK_FPGA_SRAM_V`, `XHB500_IP_DIR` all exist; `deps/xhb500/generated` live symlink (134 slv + 130 mst `.sv`). |
| Flist walk (as `fpga/filelist.tcl`) | **175 source files + 3 incdirs ALL exist, 0 defines, 0 missing.** |
| Vivado 2024.1 in-memory read (`create_project -in_memory -part xc7z020clg400-1`; source filelist; **no synth**) | All 175 files `read_verilog`'d with **NO ERROR/CRITICAL/not-found**; `verilog_define` **EMPTY** (no V2 define). V1 `WavD2DGpio.v` present=1, V1 `tidelink_lane_deskew.sv` present=1, **V2 `deps/tidelink-phy` present=0.** |
| Wrapper param guard (`fpga/scripts/check_wrapper_params.sh`) | **PASS** — `USE_IDELAY=USE_CLKBUF=USE_T3A=1'b1` (FPGA-on defaults intact). |

**`is_v1_confirmed: true`, `config_validated: true`.** `synth_design`/`impl`/`write_bitstream` were **not** run (that is the 18-min roll).

### 4.4 Build blockers / gotchas

- **`TIDELINK_PHY_V2` must be UNSET.** It is a sticky env knob shared with cocotb; a lingering `export TIDELINK_PHY_V2=1` silently flips to V2. The command prepends `unset` to guarantee V1.
- **Submodule init first** (see §2) or VCS/Vivado both fail on missing `tidelink_popcount16.sv`.
- **PHC IP:** `build_design` depends on `package_phc_ip` (`PHC_REPO_DIR` default `~/SoCLabs/ptp-hardware-clock-ahb`, present). To skip: `SKIP_PACKAGE_IP=1` + manual `package_ip` (not needed here).
- **Farm not yet usable:** srv04936 is UP (Vivado 2024.1 + IP-lib) but BatchMode publickey auth fails → password fallback. Provision: `fpga/scripts/setup_farm_ssh.sh FARM_HOST=srv04936`, then `make -C fpga farm_check FARM_HOST=srv04936`. **Not a blocker for the local single-bitstream build.**

---

## 5. BRING-UP RECIPE — V1 8-lane (and what differs from V2 0xe4)

**Address basis:** pair-base = `0x44032000`; every `0x2xxx` offset maps to `0x44032xxx`.
**Lane mask = `0xff` (full 8-lane) by LEAVING THE POR DEFAULT — do NOT write `0xe4`.** At POR, `Wlink.v` straps `swi_tx_lane_mask<=8'hff`, `out_prepend_swi_rx_lane_mask<=8'hff`, and the V1 full-128 SYNC strap `swi_sync_lane_mask_r<=8'hFF` (`axi_chiplet_controller.sv:1395`). Full 8-lane is the **only** mask at which the 128-bit `PHY_SYNC_WORD` reassembles across all lanes.

### 5.1 Steps (both dies unless noted)

| Step | Action | Register / value |
|---|---|---|
| POR | Power-on / reload both dies. Confirm `PHY_ALIGN_ID 0x4403211C == 0x50410100`. ROLE_CFG lock=0, R8=0, SYNC mask POR=`0xFF`. | — |
| 1 — autonomy OFF | Clear `train_auto_en[0]` so SW owns the sequence (kills the marginal-eye lottery). | `NEGO_TRAIN_CFG 0x4403210C = 0x0000` |
| 2 — role-lock | Set role bit[0] if non-strap role wanted (0=master,1=slave, writable only while lock=0), then W1S the lock. | `ROLE_CFG 0x44032080 = 0x00000002` (bit[1]) |
| 3 — KEEP mask 0xff | **Do NOT write `0x44032128`.** In V1 that write is `ifdef TIDELINK_PHY_V2`-compiled-out → `swi_sync_lane_mask_r` stays `0xFF`. Writing `0xe4` here is **inert**. | (skip) |
| 4 — train + recal | Assert training, pulse recal, drop back to hold. `tl3x.py 'arm'`. | `0x44032100 = 0x1`; then `=0x3` (set RECAL bit[1]); wait ~2 ms; `=0x1`. **Never `0x1D`** (bits[2:4] are V2-only, inert). |
| 5 — lock-relax (optional) | If a marginal 8th lane won't lock, relax per-lane Hamming threshold 3→5. Harmless on a clean eye. | `LOCKTHR 0x44032160 = 0x55555555` |
| 6 — release + dwell | Drop training → data mode. **This enables the hardwired SYNC beacon** (gated by `~effective_training_mode`). Dwell/poll ~15–20 s for `fcsm=4 + cr=1 + ck=1`, `lane_locked=0xff`, `cal_done=1` on both. | `0x44032100 = 0x0` |
| 7 — DROP all V2-only steps | No `0x104` word-pin/auto_dis; no `0x148`/`0x14C` per-lane word-pin; no `0x128` SYNC mask+tol; no R8 bits[2:4]; **do not read/gate on `SWI_EPOCH_STATUS 0x44032140`** (V2 one-shot epoch — V1 has no epoch). | (skip all) |

### 5.2 How V1 differs from the proven V2 `0xe4` recipe (five concrete ways)

All five are rooted in `ifdef TIDELINK_PHY_V2` in `axi_chiplet_controller.sv` + the hardwired beacon in `WavD2DGpio.v`:

1. **LANE MASK = `0xff`, NOT `0xe4`.** V2 narrowed the SYNC compare to lanes {2,5,6,7} via `0x128=0x5e4`; in V1 that write is compiled out → mask permanently `0xFF`, all 8 lanes deskew-validated. Writing `0xe4`/`0x5e4` in V1 has **zero effect**.
2. **NO SYNC-insert arming.** V2's beacon is APB-armed (R8 bit[2] `swi_sync_insert_en`, bit[3] force_always, bit[4] robust_detect — the `0x1D`). V1's beacon is **hardwired** (fires every 32 idle words whenever `~effective_training_mode`). Use R8 `0x1`/`0x3`/`0x0` only, **never `0x1D`**.
3. **NO epoch anchor.** V2 reads/gates on `SWI_EPOCH_STATUS 0x44032140` (the one-shot that never delivered data). V1 has no epoch register — skip the read entirely.
4. **NO word-pin pokes.** V2 needs `0x104`/`0x148`/`0x14C` to fix its credit/send-gate; all V2-only-ifdef'd and inert in V1 — drop them.
5. **SAME as V2:** autonomy-off `0x210C=0`, role-lock `0x2080[1]` W1S, training+recal on `0x2100`, ~15–20 s dwell, and the **marginal-eye reality** (poll for `fcsm=4` on both — still an eye lottery, just with the deskew kept coherent by the beacon instead of a one-shot anchor).

> Caveat not silicon-validated: `SWI_LANE_STATUS` bit packing `[19:17]=fcsm`, `[23]/[24]=cr/ck` is the SEND-GATE-OBS packing (authoritative per RTL/`tl3x` decode); the RDL still documents the older `[20:17]` packing — **trust the RTL/`tl3x` decode.**

---

## 6. SILICON GO/NO-GO

### 6.1 PRE-SEND gate (both dies)
`SWI_LANE_STATUS 0x44032108`: `lane_locked[7:0]=0xff`, `cal_done[16]=1`, `fcsm[19:17]=4`, `cr[23]=1`, `ck[24]=1`, `fe_rx_is_full[31]=0`; **AND** `training_mode 0x44032100 bit[0]=0`; **AND** receiver `SYNC_DET 0x44032114[31:16] > 0` (coherent SYNC reassembled = deskew anchored). If any fail → link not up, do not attempt data.

> Mechanism caveat carried from §3.2: sim shows `SYNC_DET` may stay **0** even while data flows, because the beacon gate never closes. On silicon, a `SYNC_DET=0` read is therefore **not necessarily fatal to data** — but it *does* mean the slip-resilience anchor is dormant. Read it, log it, but gate the **data verdict** on the byte-compare (§6.2), not on `SYNC_DET`.

### 6.2 Sender-side credit sanity (read before declaring delivery)
`OBS_FC_CREDIT 0x4403219C`: `[7:0] fe_rx_credit_max` healthy (WARN if <8 — the V1 ~97%-coherence residual that `fe_rx_is_full` misses because it only flags ==0); `[31:24]=0xFC` presence marker.

### 6.3 PASS (data crossed) — run BOTH directions
Host writes a known 4-word packet via the TX aperture (`TX base 0x84000000` on GP1-split images / `0x44000000` legacy; link-target addr in packet = peer RX FIFO `0x44010000`): hdr `0x00240000`, payload `0xDA7A0000`/`0xDA7A0001`. Within the catch window the RECEIVER shows:
- RX FIFO occupancy (`4096 - CREDIT_COUNT 0x4403200C`) rises by ≥4, **AND**
- `PERF_RXW 0x440320D4` increments by burst length (enable/clear perf first: `PERF_CTRL 0x440320A0 = 0x5`; `PERF_ID 0x440320FC == 0x50460100`), **AND**
- popped words from RX FIFO aperture (`0x84010000` GP1-split / `0x44010000`) are **BYTE-IDENTICAL** (first word == `0x00240000`).
This is the `link_delivery_proof.sh` PASS condition. Run A→B and B→A.

### 6.4 FAIL
Pre-send: `fcsm != 4` either side, training still set, `fe_rx_is_full=1`, or `fe_rx_credit_max < 8`.
Delivery: occupancy delta = 0 after catch timeout, RXW flat, or popped header != `0x00240000` (byte mismatch = deskew incoherent).

### 6.5 DISPROOF OF THE THESIS (the load-bearing case)
**If V1 at FULL 8-lane (mask `0xff`, beacon hardwired-on, NO epoch anchor) reaches `fcsm=4` + cr/ck on both dies but the receiver STILL shows RXW=0 / occupancy delta=0 / byte mismatch after a clean send**, then the failure is **NOT** the V2-epoch-vs-V1-beacon difference. The whole "deskew-anchor is the data blocker" thesis is **wrong**, and the bug lives elsewhere in the FC/credit/returner path (`WlinkGenericFCSM` / `WlinkRxLinkLayer` / `fc_adapter`), not in PHY cross-lane alignment. In that case, **do not keep rolling V1 bitstreams** to chase it.

---

## 7. NEXT ACTION + RISKS

### Next action
**Proceed with the V1 8-lane FPGA build (§4.1) — to answer the happy-path "does it carry bytes on silicon today" question only.** Sim has discharged that thesis byte-exact, both directions, under real injected skew. Then bring up per §5 and run `link_delivery_proof.sh` both directions per §6.3.

### Risks (blunt)
1. **The SYNC beacon is dormant in this build (mechanism gate RED).** If the *purpose* of the roll is to demonstrate slip-resilient re-align, **this build will not show it** — `test_15` proves 0/16 recovery after a real slip and the beacon never fires (`sync_insert=0` across 2388 samples). **Triage the beacon gate (`idle && en` asserted simultaneously 224/240 cycles → `sync_insert` never asserts) BEFORE spending the roll on a resilience claim.** Do **not** put "SYNC-anchored re-align" in any Route-A writeup for this build.
2. **Marginal-eye lottery persists.** Even at `0xff` you must poll for `fcsm=4` on both dies; an 8th marginal lane may need the §5 step-5 threshold relax.
3. **`SYNC_DET=0` ambiguity on silicon.** Because the beacon is dormant in sim, do not hard-gate the data verdict on `SYNC_DET>0` — gate on the byte-compare. Log `SYNC_DET` for the record.
4. **Sticky `TIDELINK_PHY_V2`.** A lingering export silently builds V2; the command unsets it, but verify `verilog_define` is empty if anything looks off.
5. **Disproof outcome (§6.5) is a real possibility.** If V1 8-lane also delivers RXW=0, stop chasing the PHY anchor and move to the FC/credit/returner path.

---

### Appendix — sim logs
`/tmp/t12_run.log`, `/tmp/t15_run.log`, `/tmp/tdp_run.log`, `/tmp/s2m_run.log`.
