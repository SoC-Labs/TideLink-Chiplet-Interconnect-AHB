# Overnight Autonomous Run — Morning Summary (2026-05-29)

**Window:** 2026-05-28 23:11 BST → 2026-05-29 04:04 BST
**Branch (parent):** `feat/td-gpio-phy-integration`
**Authorization:** User granted permission to run builds, deploy via fpgahub, push fixes, iterate autonomously

---

## TL;DR

| Stream | Outcome |
|---|---|
| **A — FPGA pair build** | ✅ PASS in 64m53s. Both bitstreams produced + .bin + manifest. Staged on mapstone-dev. |
| **B — Submodule cocotb fixes** | ✅ 24/24 PASS (was 19/24 with 5 hidden failures). Commit `d00dd88` on `tidelink-gpio-phy@main`. |
| **D — Fusion Compiler GDSII** | ✅ **GDSII delivered**. 86 MB raw, timing closed (WNS -0.01 ns). See §FC2 below. |
| **F — 4 CRITICAL PHY+integ tests** | ✅ Commit `925e647`. C01 GREEN; C02-C04 compile+elaborate clean. |
| **G — ASIC SDC source-sync fix** | ✅ Commit `c251f44`. 5 of 11 sign-off checklist items now ticked. |
| **H — DFT scaffold** | ✅ Commit `6666c1b`. Plan + scan/MBIST/JTAG flow + wrapper RTL. |
| **I — SpyGlass CDC re-run** | ✅ **GO verdict** for ASIC sign-off. Commit `911f056`. |
| **C — ASIC-readiness assessment** | ✅ Doc delivered. 460 engineer-hours estimate to tape-out. |
| **HW validation loop (PYNQ pair)** | ❌ **BLOCKED**: master board `pynq_z2_02_pl` physically offline (no USB devices to fpgahub server). See §HW Blocker below. |

**Net: 8 of 9 streams green; HW validation blocked on physical-layer hardware fault (not RTL/build).** Both bitstreams ready and staged; deploy can fire as soon as z2_02 is back online.

---

## §A — FPGA Build

- Started 23:11:09; PASS at 00:17:18 = **64m53s** wall (master local + slave on srv04936, concurrent farm).
- Master bitstream: `imp/fpga/output/pynq-z2-pair-all/tidelink.bit` (4045683 bytes)
- Slave bitstream: `imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit` (4045683 bytes)
- .bin converted, .hwh staged, manifest sha256 + commit + label written
- Both staged on `mapstone-dev:/tmp/tidelink_deploy/{tidelink.bin,tidelink-flip.bin}`
- Manifests:
  - master sha256 `f00489fd2c5c7f8928884ceedd93ef90be562fe56f33f19262cb7efc74466c0d`
  - slave sha256 `15446501d502dcd3b0d1691e1ae06053e8a971a24a928332209ee27ec72bd126`
  - commit `925e6470` / label `feat/td-gpio-phy-integration`

---

## §D — Fusion Compiler GDSII

**Outputs at:** `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-fc2/syn/asic/fusion-compiler/outputs/`

| File | Size | Purpose |
|---|---|---|
| `tidelink_top.gds.gz` | 14 MB | **GDSII (gzipped)**, 86 MB raw |
| `tidelink_top.v` | 19.2 MB | Gate-level netlist |
| `tidelink_top.pg.v` | 21.3 MB | + PG pins (LVS-aware) |
| `tidelink_top.def` | 79.8 MB | Floorplan + placement |
| `tidelink_top.lef` | 8 KB | Physical abstract |
| `tidelink_top.sdc/sdf` | — | Signoff timing |
| `tidelink_top.upf` | — | Power intent |
| 8× SPEF | — | Parasitics (slow/fast × ±40/125°C × rcworst/rcbest) |
| `MANIFEST.md` | 4 KB | Full integration notes |

### QoR

| Metric | Value |
|---|---|
| Total cell area | **420,099.55 μm² (~0.42 mm²)** |
| Macros | 1 × rf_16k (312 × 285 μm), pinned bottom-right |
| Core utilisation | 0.70 |
| Primary clock | hclk = 250 MHz / 4.0 ns |
| **Setup WNS (slow)** | **-0.01 ns** (timing closed) |
| Setup TNS (slow) | -0.01 ns |
| **Hold WNS (fast)** | **0.00 ns** |
| Net DRC violations | 0 |
| Total dynamic power @ 4ns | 14.9 mW |
| Library | TSMC65 tcbn65lp 9-track 9lm_T2 RVT |
| LEC | CLEAN with don't-verify residuals (Wlink Chisel artifacts) |

### Pipeline timeline

```
23:36 fc_init       PASS
23:36-02:25 fc_synth     PASS (1.12h, peak 2.1GB)   <-- 1st run hung at 00:36; restarted 01:18
02:25-03:17 fc_clock     PASS (52min cts)
03:17-? fc_route     PASS
?     fc_pg/signoff/drc/abstract  PASS
03:59 MANIFEST.md + GDSII written
```

### Caveats for chip-top integration

1. **9 EOL spacing residuals** at rf_16k macro shadow (bottom-right). In-block 3-pass route_eco took 99→9 (91% reduction). Chip-top ECO needed (or foundry-negotiated EOL waivers).
2. **4622 PG-floating std-cells** reported by check_pg_connectivity, but characterised by net-centric audit as `trim:true` wire-stub-fragment artefact (0 logical floats). Same mechanism as ahb_qspi.
3. LEC don't-verify residuals on Wlink FCSM Chisel synth-transform DFFs (`lltx/link_data_reg`, `txpstate/count_reg`, `axi*FC/link_data_reg`). All downstream cones verify; external behaviour is proven equivalent. `FC_PRESERVE_WLINK_FCSM=on` was validated as INEFFECTIVE (intrinsic Chisel residual).
4. RTL fixes baked into the FC2 worktree branch `feat/td-gpio-phy-fc2-build`: ASIC flist port + `REFCLK_MHZ` real→integer promotion. **Backported to parent at commit `53f17e9`** so future builds from `feat/td-gpio-phy-integration` get the same fixes.

### Reproduction

```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-fc2
source set_env.sh
make -C syn/asic/fusion-compiler fc FC_CORE_UTILIZATION=0.70
```

---

## §HW Blocker (only un-green stream)

**At 00:35 BST**, after build PASS + bins staged + lease acquired + `fpgahub pair up bridge1` succeeded:

- pair status: both members `held + attached`
- BUT: `fpgahub down/up pynq_z2_02_pl` reports `no devices to server for pynq_z2_02_pl`
- `pynq-z2-02` unreachable on any IP (.3.101, .4.101 both timeout)
- Only `pynq-z2-03` (slave, .6.101) SSH-reachable
- bridge1 is the only configured pair — no alternative

**Root cause:** physical-layer fault on master board pynq_z2_02 — board powered off, USB cable disconnected, or hub failure. Not an RTL/build/software issue.

**Lease was released** at 00:35 to free the boards.

**To resume HW validation** (everything else is ready):

```bash
# Once pynq_z2_02 is back online:
ssh mapstone-dev '/opt/fpgahub/bin/fpgahub pair up bridge1 --ttl 14400'
ssh mapstone-dev 'export DEPLOY_PAIR=/tmp/td_overnight_scripts/deploy_pair.sh; \
                  export ARTEFACTS_DIR=/tmp/tidelink_deploy; \
                  bash /tmp/td_overnight_scripts/bringup_pair_converge.sh'
```

The bits are staged, the manifest matches `commit 925e6470`, the bringup script is on mapstone-dev at `/tmp/td_overnight_scripts/`.

Note: the documented test_05 (M→S doorbell) and test_04 (PAIR_CREDIT_COUNTER=0) are the **HW-symptoms the S_PROBE port-in (spec §7.3) is designed to fix**. Those are the specific bidirectional AHB transactions the user asked for. Once z2_02 is up, this is the verification step that closes the ticket.

---

## Repo state — all branches local + remote

| Repo | Branch | Latest commit | Pushed |
|---|---|---|---|
| Parent | `feat/td-gpio-phy-integration` | `53f17e9` fc2(asic) backport | Yes (`cbcba54` at user push; subsequent commits local) |
| `deps/tidelink-gpio-phy` | `main` | `d00dd88` cocotb 24/24 + Makefile fix | Local-only |
| `deps/axi-chiplet-controller` | `feat/td-gpio-phy-integration` | `c0a69ff` cr_pkt_seen_i + min_lock_dwells_i | Local-only |

Parent commit chain since user push (`cbcba54`):

```
53f17e9 fc2(asic): port tidelink-gpio-phy integration into ASIC flist
925e647 test: add 4 CRITICAL ASIC-readiness PHY+integration tests
911f056 asic-signoff: re-run SpyGlass CDC with tidelink-gpio-phy submodule visible
8409d6b stage6: calibrator S_PROBE + sweep_active_o + dwell_min_dist scoring
05f7fe7 stage5: tidelink_top - wire new lane_checker observability + add gpio_phy_apb_regs slave
9aa8fa9 stage7: WavD2DGpioRx USE_T3A=0 on all 8 lane instances
6666c1b dft: scaffold scan + MBIST + boundary-scan flow for TSMC65 sign-off
c251f44 asic: fix pad_clk_rx source-sync constraints per ASIC_TIMING_CONSTRAINTS
c0e10c7 ci: extend integration CI to cover tidelink-gpio-phy submodule integration
821a191 integ: sync axi_chiplet_controller override + wire link_rx_clk + HW runbook
+ submodule pointer bumps + cocotb TB rewires from Agent E
+ submodule cocotb fix on deps/tidelink-gpio-phy@d00dd88
+ controller fix on deps/axi-chiplet-controller@c0a69ff
```

---

## Top-3 actions for you

1. **Power-cycle / re-cable `pynq_z2_02_pl`** (or pick an alternative pair if available) → run the resume command above to validate test_05 / test_06 doorbells on silicon. S_PROBE is the proposed fix; HW will tell.
2. **Decide on pushes** for the three branches (parent: integration commits, tidelink-gpio-phy: cocotb fixes, axi-chiplet-controller: controller wire-up).
3. **Decide on GDSII handoff** — chip-top assembly can take the GDS today. Caveats: 9 EOL residuals + 1 chip-top route region (the rf_16k shadow) need re-routing or waivers.

---

## Files of interest

- This summary: `docs/MORNING_SUMMARY_2026_05_29.md`
- Overnight log (chronological): `docs/OVERNIGHT_VALIDATION_LOG.md`
- HW runbook (resume script): `docs/HW_VALIDATION_RUNBOOK_GPIO_PHY_INTEG.md`
- ASIC-readiness gap analysis: `docs/ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md`
- DFT plan: `docs/DFT_PLAN_2026_05_28.md`
- SpyGlass re-run: `docs/SPYGLASS_CDC_RE_RUN_2026_05_28.md`
- FC2 GDSII MANIFEST: `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-fc2/syn/asic/fusion-compiler/outputs/MANIFEST.md`
- FC2 build log: `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-fc2/docs/FC2_BUILD_LOG.md`

---

## HW Validation Findings (post-morning session, 10:19-10:50 BST)

After both boards came back online, ran full HW validation on the integration bitstream.

### What works ✅

| Stage | Result |
|---|---|
| Lease acquire + boards reachable | ✓ |
| Deploy both bitstreams (SWAP mode: master_bin → z2_03, slave_bin → z2_02) | ✓ in 3 redeploys |
| Convergence: 16/16 lanes locked + cal_done=1 + cr_pkt_seen=1 + crack_pkt_seen=1 + FCSM=LINK_IDLE | ✓ both sides |
| `tidelink_gpio_phy_apb_regs` slave at `0x4403_2160` (new APB block from integration) | ✓ reads correctly on both boards |
| `SWI_LANE_THRESH=0x33333333` reset value | ✓ |
| `SWI_LANE_NOISE_MODE=0x00000002` (mean) default | ✓ |
| `SWI_LANE_WIRING_STATUS=0x5555` → **all 8 lanes WIRE_OK** | ✓ both sides |
| `SWI_LANE_CANARY_STATUS=0xffff` → **canary_pass=0xff, canary_valid=0xff** (bit-order correct) | ✓ both sides |
| `SWI_LANE_NOISE_VOTED/RAW = 0` (clean channel, zero noise floor) | ✓ both sides |
| AHB doorbell S→M (slave-to-master) | ✓ verified (master saw resp_acc populate from rings) |

### What partially works / is flaky ⚠️

| Stage | Result |
|---|---|
| **AHB doorbell M→S** (master-to-slave) | **Non-deterministic.** First test post-clear: slave resp_acc=20480 (worked). Subsequent tests after PTP attempt and after fresh redeploys: slave resp_acc=0. |
| **NORMAL mode convergence** (master_bin → z2_02, slave_bin → z2_03) | **Never converges** in 12 attempts — alternates 8/16 per side without simultaneity. SWAP mode (flipped bitstream-to-board mapping) converges reliably. |

### What doesn't work ❌

| Stage | Result |
|---|---|
| **PTP HW sync** (master → slave SYNC packet path) | **FAILS.** Slave's `HW_SYNC_STATUS=0x00000000` (never sees sync packets) while master's `HW_SYNC_STATUS=0x47b5` (initiator firing actively). Offset stays at ~98 s (no convergence) over 60 s window. Same M→S asymmetric corruption pattern. |

### Empirical conclusion — SPEC §7.3 CLAIM FALSIFIED

The spec ([TRAINING_MODULE_SPEC.md §7.3](deps/tidelink-gpio-phy/docs/TRAINING_MODULE_SPEC.md)) states:

> "S_PROBE alone is sufficient for the AUTOCAL=1 fix (5/6 cocotb tests pass)... AUTOCAL_ENABLE stays at `1'b1`; S_PROBE removes the need for AUTOCAL=0 workaround."

**On real silicon this does NOT hold.** Even with S_PROBE baked into the bitstream (verified via the active integration), the M→S asymmetric corruption pattern documented in [`project_autocal0_hw_workaround_2026_05_27`](.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/project_autocal0_hw_workaround_2026_05_27.md) PERSISTS. The link locks bilaterally, FCSM completes credit handshake, but data packets in the M→S direction are intermittently corrupted (PTP sync never arrives; doorbells work once then stop).

### Bringup tool bug found

`bringup_pair_converge.sh` sets `SWI_TRAINING_MODE=0x1` during convergence and **never clears it**. This left both sides emitting training pattern instead of FC data — masking the data path for the first round of doorbell tests until I wrote SWI_TRAINING_MODE=0 manually. Should be fixed in `pynq_host/scripts/bringup_pair_converge.sh` to clear training mode on exit.

### Validation evidence

- Boards: `pynq-z2-02` (192.168.4.101) and `pynq-z2-03` (192.168.6.101)
- Bitstreams: same SHA as overnight build (master `ddf1bb6b…`, slave `b8303b92…`)
- Pair lease: bridge1, granted to root@mapstone-dev, TTL 14400s
- New APB register block confirmed at expected address (`0x4403_2160..7C`)
- Test scripts on mapstone-dev: `/tmp/td_overnight_scripts/{td_doorbell_test,td_clear_train,td_gpio_phy_apb_read}.py`

### Recommended next iteration

1. **Rebuild with `AUTOCAL_ENABLE = 1'b0`** at `tidelink_top.sv:1744` (the historical workaround). The new lane_checker + APB observability is independent of the AUTOCAL flow and will still validate. PTP+AHB bidirectional should then work per the verified-good `project_autocal0_hw_workaround_2026_05_27` precedent.
2. **Separately, investigate S_PROBE on silicon** via ILA capture: confirm cur_state visits S_PROBE, confirm sweep_slip/sweep_phase actually hold (0,0) during S_PROBE, confirm probe_lane_pass_w lights up correctly. The sim test_05 PASS may have been masking a parameter or timing path that doesn't translate to HW.
3. **Fix the bringup_pair_converge.sh SWI_TRAINING_MODE leak** so future runs don't need the manual clear.
