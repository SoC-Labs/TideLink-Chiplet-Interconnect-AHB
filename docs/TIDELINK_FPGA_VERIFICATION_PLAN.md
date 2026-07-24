# TideLink / TideChart — Full-Scale FPGA Hardware Verification Plan

> **Status:** DRAFT v1 — 2026-07-17. Author: verification-plan lane (assessment session).
> **Scope:** proving *every* chiplet-related function on real FPGA hardware before the
> v1 (100 MHz GPIO-PHY) tapeout, ~3 weeks out. This plan is the hardware companion to the
> sim-side `docs/VERIFICATION_PLAN.md` and `make sim_gate`. It does **not** replace them —
> it defines what silicon must additionally prove, how to prove it *without lying to
> ourselves*, and the exit checklist the team signs.
> **Read alongside:** `docs/STATUS_LIVE.md` (live dashboard), `docs/KR260_RECOVERY_PLAN_2026_07_17.md`,
> `docs/HANDOVER_2026_07_10.md`, `docs/AUTONOMY_STATUS_2026_07_14.md [removed 2026-07; in git history]`, `docs/REGISTER_MAP.md`.

---

## 0. Why this plan exists — the instrument-first mandate

This campaign logged **fifteen instrument failures** in which a debug conclusion was wrong
because the *instrument*, not the DUT, was broken. The cost was measured in nights and in
RTL fixes built against phantoms. The plan is designed around one non-negotiable rule:

> **RULE #1 — verify the INSTRUMENT before theorizing about the DUT.**
> A register access on this system is an AHB/AXI transaction with side effects. A zero from
> a register you have not proven live is *not a measurement*. Every observation channel in
> this environment must be self-verifying, and every automated verdict must be cross-checked
> against a second independent path.

The failure classes this plan must structurally prevent (each is a real, dated event):

| # | Failure class | The lie | Structural defense in this plan |
|---|---|---|---|
| A | **Retired register reads 0 by construction** | `0x215C sync_seen` reads `0x00` on *every* V2 build → "dead RX/lane/cable" | §2.1 instrument preamble: never read a register not on the V2-trust allow-list; RW-scratch write/readback proof |
| B | **`struct.pack_into` = 5 bus stores** | one "write" = 5 beats → 5×-over-advance "phantom"; 3 RTL fixes built | §2.1 mandate `ctypes.c_uint32.from_buffer` single-aligned u32 only |
| C | **Saturating livematch false-positives** | `0x2144` `q<=q\|match` saturates; an all-zero lane popcount==tol reads "matched" | §1/§2 forbid livematch as a primary gate; use RAW post-deskew slice + EPOCH |
| D | **AFI port-width defect drops 3/4 of APB** | KR260 stock firmware = 128-bit AFI vs 32-bit BD → every odd-16B-aligned word silently dropped, *for months* | §2.1 AFI canary + width probe as a mandatory board preamble |
| E | **`make -n sim_gate` writes FAKE pass files** | dry-run creates `.status` PASS files | §2/§6 never `make -n` a gate; gates fail-loud; CI runs real |
| F | **`verify_build.sh` read wrong log, passed WNS −2.4 ns** | structural check looked at stale synth log | §4 structural netlist checks + WNS-aware verify_build (R5) |
| G | **`ifdef` RTL dead in every bitstream** | `-verilog_define` never reaches packaged-IP OOC synth → V2 blocks dead for weeks; md5 differences proved nothing | §4 structural DCP cell-count verify; parameters not defines for IP config |
| H | **Bring-up is a placement LOTTERY** | n=1 pass/fail meaningless (die_a 1/4 vs die_b 4/4 on the *same* image) | §3 every link metric is a binomial statistic, N≥8, Clopper-Pearson bounds |
| I | **Chip-killer visible only on hardware** | empty-RX-FIFO phantom pop needed X-init→zero-init BRAM; sim structurally blind | §4 HW-only coverage definition + sim-fidelity models |
| J | **Missing-reader / wiped-`/tmp` null looks like "chip dead"** | script rc=2 (missing) indistinguishable from DECERR | §2.1 reader self-test against an always-answering reg first |

**The single highest-leverage historical fix** (per `docs/HANDOVER_2026_07_10.md`): `make sim_gate`
was wired into *no* CI hook — four of five tapeout defects survived to T−3wk because of it.
It is now a **blocking** GitLab CI job (`.gitlab-ci.yml`, `allow_failure: false`, flipped
2026-07-16). This plan extends that discipline to the *hardware* loop, which today has **no
CI at all** — every silicon run is hand-driven.

---

## 1. Feature inventory — what must be proven on FPGA before tapeout

Coverage legend: **SIM** = sim_gate/cocotb/UVM only · **Z2** = proven on PYNQ-Z2 pair ·
**KR** = proven on KR260 pair · **ONCHIP** = kr260-pair-onchip · **NEVER** = no hardware evidence.
"Proven" for a *link* feature means proven **as a statistic** (§3), not n=1.

| # | Feature | Best coverage today | Evidence / gate | Gap to tapeout |
|---|---|---|---|---|
| F01 | **Manual link bring-up** (deterministic recipe `rcp()`) | **Z2: certified** N=40, CP [91%,100%]; **KR: n=1** (first light 2026-07-17) | `td_v2_hwlib.sh:rcp()`; `td_v2_regress.sh` test 01; `allchan_recipe_soak.sh` | KR needs N≥8 statistic; ONCHIP never |
| F02 | **Hardware autonomy — zero-poke POR** (MANDATORY, David) | **SIM: gated** (`sim_gate_zeropoke`, `NEGO_CFG_RESET=7'h61`); **Z2: UNRELIABLE ~25–35%**; **KR/ONCHIP: NEVER** | `test_zeropoke_por.py`; `AUTONOMY_STATUS_2026_07_14.md`; `zp_arm()` canary in hwlib | **#1 gap.** Never measured on a live-`set_bus_skew` bitstream. Not a deliverable until statistically reliable |
| F03 | **Lane training / IDELAY winscan centring** | **Z2: proven** (recipe, WINSCAN_CELLS≈555); **KR: N/A** (HDIO bank 44 → `USE_IDELAY=0`, no per-lane trim) | `td_v2_hwlib.sh:winscan()` (lanes hardcoded `[6,2,5,7]` :176); `0x2140 reanchored` | winscan lane-set is recipe-hardcoded (mask-recipe defect); KR has no IDELAY path at all |
| F04 | **Cross-lane deskew under real skew** | **SIM: proven** (`tidelink_top_pair_wordskew` test_08); **Z2: proven** (content-anchor `1a08308`) | `0x2140` EPOCH (span smaller=better); raw slices `0x212C–0x2138` vs golden | ASIC-flist parity (deskew must be in V2 ASIC flist — verified present, keep gated) |
| F05 | **Lane masking** (0xE4 = 4 active lanes) | **Z2: proven** at 0xE4; **0xFF (8-lane 2× lever): NEVER on HW** | `0x214 LANEMASK`; `OBS_MASK_HS 0x2194` (latched at handshake) | 0xFF is a *separate campaign* (mask latched at bring-up; runtime poke does NOT rewire) — out of tapeout scope, in inventory for completeness |
| F06 | **Data A→B** (byte-exact, committed) | **Z2: proven** byte-exact (24/24, 4→1024 words); **KR: NEVER** (blocked at master fcsm=2) | `td_v2_channels.sh gate_data`; GP1 RX `0x84010000` (POP-on-read) | KR blocked on HARDEN_SWI (R6) → then N≥8 |
| F07 | **Data B→A** (autonomy channel) | **Z2: certified** N=40 (RETIRE-autonomy fix); **KR: NEVER** | `td_v2_channels.sh` (rotation-aware ring compare); `RETIRE_EN` plumbed | KR never; ONCHIP never |
| F08 | **Doorbell channel** (RTT) | **Z2: proven**; **KR: NEVER** | `gate_doorbell` (`0x2014` WO / `0x2024` W-add/R-clear) | KR/ONCHIP never |
| F09 | **XHB transparent-window channel** | **Z2: proven** (silicon, `ahb_sub` HREADY backstop `cb33c9f`); **SIM: NOT modelled** (peer XHB target absent from pair tb) | `gate_xhb_window` (`0x40000000`, bounded `WIN_SOAK_TXNS=8`) | Only silicon-gated; `sim_gate_xhb` is out of the aggregate until peer target modelled |
| F10 | **Credit / flow-control — empty-FIFO phantom pop** | **SIM: gated** (`sim_gate_fifo` test_41/42, zero-init BRAM model); **Z2: proven** (soak 0/6→8/8) | `f9b94b7`; credit must never exceed 4096 | Write-side **twin latent** (`tidelink_fifo_ctrl.sv:184`) — needs intent decision + HW check |
| F11 | **Credit ceiling / A→B `fe_tx_credit_max`** | **Z2: silicon-verified fixed**; sim tap `0x21A8[19]` | `project_a2b_rootcause_fe_tx_credit_max`; `fe_tx_credit_max_eff` clamp | Merge-direction hazard (G0 gate must assert clamp present) |
| F12 | **Sustained / continual data + throughput baseline** | **Z2: proven** 195 kB/s (16.7% of raw); **25 MHz byte-exact** (10.67×); packing N: **NEVER on HW** | `linkhold_soak.sh` ("never yet run on silicon" per TESTING.md); `HW_CHARACTERIZATION_PLAN` T1–T8 | Characterization plan **unexecuted**; long-soak stability unmeasured |
| F13 | **PTP path — two PHCs converging** | **SIM: proven** (UVM stress/sync, servo PI); **Z2: opt-in channel**; **KR: -ptp built but MMCM timing FAIL** (R1) | `gate_ptp` (`\|offset\|≤12000 ns`); PHC `0x8405_xxxx` | End-to-end two-board convergence **NEVER** on HW. `phc_locked 0x2048[18]` tied 0 — never gate on it |
| F14 | **Error injection / recovery** | **Z2: partial** (power-cycle recovery in `overnight_autonomy.sh`); **mid-burst reset / link-degradation: NEVER systematic** | Phase-2 "does die_a survive arming die_b"; `fpgahub hub power-cycle` | No systematic degradation/recovery matrix exists |
| F15 | **APB observability + instrument trust** | **Partial** — trust table below; canaries defined (KR) | `0x2108`, `0x2140`, `0x2120`, `0x21A8`; canary `0x8403_0204/0214` | No automated instrument-preamble library yet (build it — §5) |
| F16 | **Autonomy arm / retire** | **SIM: gated** (`sim_gate_retire_plumb` A/B); **Z2: certified** N=40 B→A retire-autonomy | `RETIRE_EN` hierarchical read-back at destination | KR never |
| F17 | **Role negotiation / straps** | **SIM: role-lock**; **ONCHIP: strap GPIO smoke** (`kr260_onchip_smoke.py`) | `0x2080` role; strap GPIO `0x8404/0x8C04_0000` | `apb_debug_unlock_i`/`mask_hs_bypass_i` tied `1'b1` → **APB debug permanently unlocked in silicon** — wants straps pre-tapeout |
| F18 | **TideChart** (root election / DFS enum / route program / hop distribution) | **SIM: 60/60 cocotb + UVM**; **FPGA: NEVER** — never wired to a TideLink pair on silicon | `tidechart/cocotb`, `uvm/tidechart` | **Entire IP unproven on hardware.** No two-die on-silicon integration exists |
| F19 | **On-silicon PHY BIST / BER** | **NEVER in production bitstream** | standalone `pynq-z2-phy-bist-pair` (`0x44060000`) built, **never deployed** | The BIST gap (§4) — no BER/eye-width on any deployed image |
| F20 | **kr260-pair-onchip** (two dies, one bitstream, no ribbon) | **DESIGNED, not buildable** | `kr260_onchip_smoke.py` / `kr260_onchip_autonomy.py` (ready) | Not yet built; removes the ribbon variable — high value for lottery isolation |

**Instrument trust table (V2 silicon — the current path).** Full addr = APB base + offset
(Z2 base `0x4403_2000`, KR260 base `0x8403_2000`; LANEMASK is base `+0x214` in the `0x..30xxx`
block, i.e. Z2 `0x44030214` / KR `0x84030214`).

| Offset | Meaning | TRUST on V2 |
|---|---|---|
| `0x2108` | `[19:17]` fcsm, `[16]` cal_done | **TRUST** fcsm/cal. `[7:0] lane_locked` reads 0x00 on a healthy link — **DO NOT trust** |
| `0x2140` | SWI_EPOCH_STATUS: `[0]` anchored, `[6:1]` span (0..24, **smaller=better**) | **TRUST** — the real V2 RX-health word. Confirm build takes `tidelink_lane_deskew.sv:1303` branch (`:1540` ties span=0) |
| `0x2120` | TX SYNC-OBS: `[16]` tx_idle, `[17]` tx_train, `[15:0]` sync_ins_cnt (sat 0xFFFF), `[31:24]`=0x5C | **TRUST** — TX-domain, immune to RX/cable; proves a die is beaconing |
| `0x21A8` | FCSMCAP: `[19]` fe_tx_credit_max==0 (A→B smoking gun), `0xC1` marker | **TRUST** — also the dead-board `0xC1` probe |
| `0x219C` | credit: `[7:0]` fe_rx_credit_max (=0x1f) | **TRUST** (distinct from fe_tx_credit_max) |
| `0x2194` | OBS_MASK_HS: peer masks, match, `[18]` lock_pending, `[20]` gate_open | **TRUST** — role-lock chain. `anchored=1` is VACUOUS if mask=0 |
| `0x2160` | RW scratch (per-nibble `0x7777_7777` mask) | **RW instrument-check reg** (wr 0xAA→0x22222222). Data content dead in V2 |
| `0x2144` | livematch `[7:0]` per-lane | **DO NOT trust as primary** — SATURATES (`q<=q\|match`); false-positives all-zero lanes |
| `0x215C` | sync_seen (golden 0xE4) | **RETIRED on V2 — reads 0x00 always.** V1-only |
| `0x2174` | noise-mode reg | **RETIRED — silently ignores writes** (wr 0x3→0x0); the RW-scratch litmus |
| `0x2164/68/78/7C` | noise/wiring/canary | **RETIRED — read 0 by construction** |

---

## 2. The environment architecture — a layered, unattended, multi-board harness

The environment is four layers. Each higher layer refuses to run until the layer below has
passed its self-check. Everything archives raw register evidence for post-hoc audit.

```
┌───────────────────────────────────────────────────────────────────────┐
│ L4  REPORTING (TideChart dashboard)  — telemetry → HTML/artifact         │
│     new; builds on eye_toolkit/web + stress_toolkit/web Flask precedent  │
├───────────────────────────────────────────────────────────────────────┤
│ L3  STATISTICS  — Clopper-Pearson binomial CI, regression-vs-baseline    │
│     allchan_recipe_soak.sh / proven_method_soak.sh (clopper_pearson())   │
├───────────────────────────────────────────────────────────────────────┤
│ L2  STIMULUS / RECIPE  — bring-up, channels, error-injection, PTP        │
│     td_v2_channels.sh (engine) · td_v2_hwlib.sh (rcp/winscan)            │
├───────────────────────────────────────────────────────────────────────┤
│ L1  BOARD ACCESS + INSTRUMENT SELF-CHECK  (the preamble — §2.1)          │
│     tl39.py/tl_poke.py (ctypes) · lease · AFI · canaries · reader probe  │
└───────────────────────────────────────────────────────────────────────┘
```

### 2.1 L1 — the instrument-verification preamble (MANDATORY before any run)

Every hardware run — nightly soak, single channel test, one-off probe — MUST execute this
preamble first and **abort the run (not the feature)** if any step fails. This is the direct
countermeasure to failure classes A/B/D/J. Package it as a reusable library
`fpga/hw_regression/lib/instrument_preamble.sh` (does not exist yet — build it, §5).

1. **Reader self-test against an always-answering register.** Read PS GPIO `0xE000_A068`
   (EMIO, always live regardless of PL state). If this fails, the *host/ssh/tool path* is
   broken, not the chip — abort with a distinct code. (Defends J: missing-script rc=2 vs
   DECERR both look like "chip dead".)
2. **Tool-access-width self-test.** Prove single-aligned-u32 semantics: the harness must use
   `ctypes.c_uint32.from_buffer(m,o).value` (or `tl_poke.py`), **never** `struct.pack_into`
   (5 bus stores). Assert the tool in use is the ctypes path (`grep`-guard on the harness, or
   a wbin-delta canary: one poke → advance by 1, not 5). (Defends B.)
3. **KR260 AFI health check** (KR only). `kr260_afi.sh check`: `0xFF419000[9:8]==0` and
   `0xFD615000[9:8]==0`. If not, `kr260_afi.sh fix` (RMW `&= ~0x300` both) — else 3/4 of every
   APB access is silently dropped. (Defends D.) The AFI poke **does not survive reboot** —
   re-apply every session until R4 persistence lands.
4. **Control-plane canaries** (read, must match hardwired constants):
   - KR260: `0x8403_0204 == 0x0000_0001`, `0x8403_0214 == 0x0000_E4E4`,
     negative control `0x8403_0200 == 0x0000_0088` (hardwired slave ID, INFO only).
   - Z2: `PHY_ALIGN_ID 0x4403_211C == 0x5041_0100`, `OBS_OBS_ID 0x4403_2190 == 0x4F42_0100`,
     peripheral ID read of `0x4403_2014 == 0x544C_0100`.
5. **RW-scratch write/readback litmus.** Write `0x5555_5555` then `0xAAAA_AAAA` to the known-RW
   scratch `+0x2160`; confirm the per-nibble `0x7777_7777`-masked readback (`0x22222222` for
   `0xAA`). Proves APB RW is *live* — so a subsequent zero from a data register is a
   measurement, not a dead bus. **A zero from a register not proven writable/live is not a
   measurement.** (Defends A/C.)
6. **Trust allow-list guard.** The harness must refuse to read any register outside the V2
   trust allow-list (table §1) as a *verdict* input. `0x215C`, `0x2144`, `0x2174`,
   `0x2164/68/78/7C`, `lane_locked[7:0]` are quarantined from all pass/fail logic.
7. **Wedge-safety envelope.** No `ahb_tx 0x84000000` write until `cal=1`+`fcsm=4` bilateral
   (a TX write to a down link hangs the PS with no timeout → power cycle). Never touch
   undecoded `0x4403_xxxx` on ZynqMP / `0x21AC/0x21B0/0x21B4` (hard-stall). Throttle every
   read (`THROTTLE≥0.25s`); dense mmap loops wedge the kernel.

Board access matrix (fill/confirm at bench): **Z2 pair** — `pynq_z2_02_ps` (die_a, master)
+ `pynq_z2_01_pl` (die_b), reached `ssh david@mapstone-dev`, leased via
`fpgahub hub power-cycle`. **KR260 pair** — boards are plain Ubuntu, no PYNQ → `fpgautil`;
`.bit→.bin` = strip 127 B header, never byte-swap; `reboot` WEDGES (JTAG POR only), use
`kexec --command-line` for the `cma=512M` fix.

### 2.2 L2 — stimulus / recipe layer

Reuse the certified engine unchanged; extend, don't fork:
- `fpga/hw_regression/td_v2_channels.sh` — per-trial engine. GATE order (enforced): `link`
  (mandatory) → `data` → `doorbell` → `ptp` (opt-in) → `xhb`. Register map authoritative at
  `td_v2_channels.sh:200-262`. Payload = 28-word protocol-legal frame (word0=len<<20,
  word1=dest, 28 payload); byte-exact at index 2, rotation-aware ring compare.
- `fpga/hw_regression/td_v2_hwlib.sh` — `rcp()` bring-up + `winscan()`. **Being ported to
  ctypes** on `infra/hwlib-ctypes-bus-access` — do not certify through the old `struct.pack_into`
  harness; every autonomy measurement through it is suspect and must be re-taken.
- New stimulus to add (§5): error-injection driver (mid-burst reset, link-degradation via
  lane-mask narrowing, power-cycle-recovery matrix); TideChart-pair driver.

### 2.3 L3 — statistics layer (see §3)

`allchan_recipe_soak.sh --cycles N` wraps the engine in independent power-cycle trials and
computes an exact **Clopper-Pearson 95% CI** (`clopper_pearson()`, pure-python, no scipy).
`proven_method_soak.sh` scores link / A→B / B→A / doorbell separately plus an ALL-4 interval.
CSV archive per run (`cycle,reset,verdict,detail,elapsed_s`) + per-trial logs. This is the
model to generalize per-feature.

### 2.4 L4 — TideChart reporting layer (to be built)

**Correction of a common assumption: TideChart is a *protocol IP / DUT*, not a dashboard.**
The repo has zero plotting/telemetry-rendering code (`scripts/` empty; `python/` is
`packet.py` only; the sole HTML is auto-generated SpyGlass CDC output). So the "TideChart
reporting layer" is a **new deliverable**, but it is not from scratch:

- **Precedent to build on:** `pynq_host/scripts/eye_toolkit/web/` and
  `stress_toolkit/web/` are existing Flask apps (`app.py`, `runner.py`, `lease.py`,
  `static/`, `systemd/` units) that already render live per-lane sweeps to HTML/PNG/CSV on a
  board-adjacent host. The verification dashboard should reuse this pattern (Flask + systemd,
  or a static self-contained HTML artifact for archival).
- **Data sources it consumes:** the L3 CSVs (per-feature pass/CI history), raw register
  evidence archives, and — for the TideChart *feature* (F18) — the `packet.py` FC-word
  decoder and TideChart's APB status regs / topology map / congestion cost RF.
- **What it renders:** (a) a per-feature green/amber/red matrix with N and CI bounds; (b)
  bring-up-rate trend across builds (regression detection); (c) per-lane EPOCH-span / TX-obs
  time series; (d) a raw-register audit view. **Every rendered number must cite its source
  register/CSV** so a reviewer can re-derive it — no un-sourced aggregate.

Unattended operation: nightly `systemd` timer on the board-adjacent host runs the L1→L3 chain
per platform, publishes an L4 report, archives raw evidence under a dated `RUNDIR`. Lease is
acquired once per run and released on every exit path (trap). Never co-schedule a Vivado build
with a soak (OOM mimics a regression) or with `make sim_gate`.

---

## 3. Statistical certification — the lottery is real, treat every link metric as a proportion

Bring-up is a placement/skew lottery (RX capture-clock-tree residual LUT; measured die_a 1/4
vs die_b 4/4 on the *same* image). **n=1 proves nothing.** Rules:

- **Per-feature N and target.** Each link feature is a Bernoulli trial (a fresh power-cycle
  → bring-up → test = one independent sample). Report the point estimate **and** the
  Clopper-Pearson 95% interval. A feature is GREEN at its target only when the **lower** CI
  bound clears the threshold.

| Feature class | Target rate | Min N | Rationale |
|---|---|---|---|
| Manual bring-up + channels (F01,F06–F09) | ≥95%, CI-lower ≥90% | **N≥40** | matches the certified `allchan_recipe_soak --cycles 40` → CP [91%,100%] |
| Hardware autonomy zero-poke (F02) | ≥95%, CI-lower ≥90% | **N≥40** per bitstream | MANDATORY deliverable; today ~25–35% — the gating gap |
| First-order smoke (link-up exists at all) | 100% of N | **N≥8** | KR260 recovery gate G3; enough to distinguish a lottery from a dead build |
| Long-soak stability (F12) | 100% byte-exact | **N≥30 words × long duration** | `linkhold_soak.sh 30` — never yet run on silicon |

- **What N proves what.** To assert "≥95% bring-up" with 95% confidence you need the CI-lower
  ≥95%: e.g. **39/39** gives CP-lower ≈ 91% (not yet 95% — so 40 is a *floor*, not proof of
  95%); ~59/59 is needed for lower-bound ≥95%. State the achieved lower bound; never round a
  91%-lower result up to "95% reliable."
- **Signal vs noise.** A single failure inside a run where the CI still clears target = noise,
  keep going. A failure that drops the CI-lower below target, OR a *new* failure signature not
  in the baseline, = signal: **stop and root-cause** (the `overnight_autonomy.sh` Phase-2
  "does die_a survive arming die_b?" model — a FAIL there is the night's headline, not buried
  under 20 soak cycles).
- **Regression detection across builds.** Every soak archives its CSV keyed by the bitstream
  **provenance** (git-SHA low32 stamped into `BITSTREAM.CONFIG.USR_ACCESS` by
  `msg_gate_child_promote.tcl`; manifest JSON from `build_provenance.tcl`). L4 diffs the new
  build's per-feature CI against the last green baseline; a CI-lower drop ≥ (some margin, e.g.
  10 pts) flags a regression *even if still above absolute threshold*. **Autonomy % is only
  meaningful against a named, fixed bitstream** — never compare across un-pinned builds.

---

## 4. Hardware-only coverage vs sim — and the BIST question

**What sim_gate already owns (do not re-litigate on silicon).** The 15-suite blocking gate
covers: autonomous training-exit chain (t31), zombie-retry (t32), arm-stagger episode binding
(t33), FC handoff (t30), V2 pair data + sync-detect + winscan FSM, empty-FIFO phantom-pop
(fifo, with zero-init BRAM model), zero-poke POR, RETIRE_EN plumbing A/B, V1/ASIC-V1/ASIC-V2
elaboration. `farm_gate` adds ratcheted XDC-lint + SV-anti-pattern + a silicon-faithful sim
tier (`EPOCH_PROFILE=silicon REF_PERIOD_NS=40`) — the *only* tier that catches the FCSM-family
merge trap. Logic correctness lives here.

**What is HARDWARE-ONLY (sim is structurally blind — these MUST be on FPGA):**

| Hardware-only behavior | Why sim can't | Feature |
|---|---|---|
| **X-init → zero-init SRAM power-up** | vendor SRAM model leaves arrays X; real BRAM powers up 0 → phantom pop | F10 (found only on HW; now sim-modelled *after* the fact) |
| **Placement-dependent RX capture-clock skew** | routing/placement not in RTL sim; the whole lottery | F01/F02/F03 — the reason §3 exists |
| **Real PS↔PL access paths** (AFI width, undecoded-read hang, posted-write rc=0) | no PS model in cocotb | F15, the D-class AFI defect |
| **Power-cycle / POR / bootpy-clobber flows** | no power domain in sim | F14 |
| **Source-synchronous eye at real UI** | needs routed netlist + I/O timing; unisim BUFG paths uns­imulatable | F19, chip-killer #3 |
| **`set_bus_skew` / matched-routing constraints actually applied** | silently dropped in every build ever (matched ports → discarded) | F02 autonomy — never measured with a live constraint |
| **XHB peer transparent-window round-trip** | peer XHB target not modelled in pair tb | F09 |

**The on-silicon BIST gap — cost/benefit.** Production `tidelink_top.sv` does **not**
instantiate the PHY-BIST core (`tidelink_phy_bist_core`/`_regs`: PRBS-15 gen/check, per-lane
error counters, eyescan). On deployed silicon you get only binary `lane_locked` + Hamming-noise
+ EPOCH — **no BER, no eye-width, no per-direction PRBS sync**. A standalone
`pynq-z2-phy-bist-pair` target (`0x44060000`, `bringup_phy_bist_eyescan.sh`) exists, is built,
and was **never deployed**.

- **Recommendation (pre-tapeout):** **deploy the existing standalone BIST bitstream once** to
  get a real eye/BER characterization number for the v1 PHY (effort **S** — it is on the
  shelf; needs a bench slot + lease). This directly de-risks chip-killer #3 (the eye is a
  static-skew/matched-routing problem, and today we have *zero* BER data — all "16/16 taps"
  numbers are whole-UI word-framing statistics at 6.25 MHz, not a picosecond eye).
- **Do NOT** param-gate a BIST/scoreboard block *into the production top* before tapeout
  (effort **L**, schedule risk, and it changes the DUT). The standalone target is the
  cost-effective path. A lightweight always-on **RX scoreboard** (compare committed RX payload
  against an expected LFSR, credit-ceiling assertion) is worth adding **only** if it is the
  standalone/characterization variant, not the shipping netlist.

---

## 5. Gap list + prioritized roadmap

Effort: **S** ≤1 day · **M** 2–4 days · **L** ≥1 week. "Weekend-automatable" = buildable with
**no board access** (farm-host-b is password-blocked) — design to run later from a board-local /
key-authenticated context.

### Weekend-automatable now (no hardware)

| P | Item | Effort | Notes |
|---|---|---|---|
| 1 | **Instrument-preamble library** `fpga/hw_regression/lib/instrument_preamble.sh` (§2.1 steps 1–7) + trust-allow-list guard | **M** | Highest leverage; every future run inherits self-verification. Unit-testable against the fake board model (`fpga/hw_regression/tests/fake_board_model.sh`) |
| 2 | **Statistics library** — factor `clopper_pearson()` out of `allchan_recipe_soak.sh`/`proven_method_soak.sh` into `lib/stats.py`; add per-feature CI targets + baseline-diff regression check | **S** | Pure python; test with synthetic pass/fail vectors |
| 3 | **TideChart reporting layer** scaffold — Flask/static report reusing `eye_toolkit/web` pattern; consume L3 CSVs + raw-evidence archives; source-cited numbers | **M** | No board needed to build/serve against archived CSVs |
| 4 | **Complete the ctypes harness port** (`infra/hwlib-ctypes-bus-access`) for `td_v2_hwlib.sh` + `lane_health_preflight.sh`; retire `struct.pack_into` everywhere | **S** | Un-blocks trustworthy autonomy measurement (class B) |
| 5 | **Fix `merge_guard.sh` grep bug** (`n=$(grep -c -- "$2" "$1" \|\| echo 0)` reports any zero-hit token as PASS) | **S** | Silent gate hole guarding the A→B credit-clamp merge |
| 6 | **Error-injection stimulus** (sim first): mid-burst reset, link-degradation via lane-mask narrowing, credit-ceiling assertion — add cocotb tests, then a HW driver stub | **M** | Sim portion is weekend-safe; HW portion gated on bench |
| 7 | **TideChart↔TideLink integration smoke (cocotb)** — wire `tidechart_controller` to the pair tb via `tc_axis_*`; prove election+enum over a simulated 2-die link | **M** | Precondition for any F18 hardware work; no board needed |
| 8 | **Wire the hardware soaks into a nightly `systemd` timer + report publish** (dormant until keys land) | **S** | Runs later from a board-adjacent host |

### Needs David / bench

| P | Item | Effort | Blocker |
|---|---|---|---|
| 9 | **KR260 A→B/B→A/doorbell first data** at N≥8 (F06–F08) | **M** | R6 HARDEN_SWI fix + G2 bitstream + lease |
| 10 | **Autonomy zero-poke statistic on a live-`set_bus_skew` bitstream** (F02) at N≥40 | **L** | The #1 deliverable gap; needs the new build + bench nights |
| 11 | **PTP two-board convergence** end-to-end (F13) | **M** | R1 MMCM fix on -ptp targets + a bench PTP run |
| 12 | **Deploy standalone PHY-BIST once** for real eye/BER (F19) | **S** | Bench slot + lease |
| 13 | **kr260-pair-onchip build + smoke** (F20) — removes the ribbon variable | **M** | Not yet buildable; then `kr260_onchip_smoke.py` |
| 14 | **Board ssh keys for farm-host-b** — unblocks *all* remote hardware automation | **S** | David (Monday list) |
| 15 | **RX-FIFO write-side twin** intent decision + HW check (F10) | **S** | "Is AHB-write-to-RX supported?" (evidence=no) |
| 16 | **`apb_debug_unlock_i`/`mask_hs_bypass_i` straps** before tapeout (F17) | **M** | Design-intent sign-off; today permanently unlocked in silicon |
| 17 | **Execute `HW_CHARACTERIZATION_PLAN` T1–T8 + SRAM sweep** (F12) | **L** | Sizes the ASIC FIFO macro; bench-heavy |

---

## 6. Exit criteria for tapeout — the sign-off checklist

Sign only when **every** box is checked. Each link feature is green at its **target N with
CI-lower ≥ threshold** on **at least one** FPGA platform, with **no instrument in the loop
carrying an unverified reading**.

**Gates (all blocking, all real — no `make -n`, no `allow_failure`):**
- [ ] `make sim_gate` — all 15 suites PASS, run in CI (`allow_failure: false`), fresh build dirs.
- [ ] `make farm_gate` / `farm_gate_fast` — Tier-0 + Tier-1 green; `FARM_GATE_STRESS=1` silicon-skew tier green.
- [ ] `sim[silicon_data]` (`EPOCH_PROFILE=silicon REF_PERIOD_NS=40`) PASS — catches the FCSM-family merge/flist trap.
- [ ] `verify_build.sh` (WNS-aware, R5) PASS on the tapeout-candidate bitstreams: V2 banner present, `LANE_MASK_RESET`/`TD_AUTO_LANE_MASK_E4` present, autonomy signals ref-count > 0, no silently-dropped XDC (`set_bus_skew`), no md5 collision across targets, `.bin` newer than `.bit`, **WNS ≥ 0**.
- [ ] Structural provenance: manifest JSON matches, git-SHA in `USR_ACCESS`, packaged-IP content-hash matches sources (no stale IP), `NEGO_CFG_RESET` bitString `1100001` in `component.xml`.
- [ ] G0 merge gate: `fe_tx_credit_max_eff` clamp present in the freeze branch; FCSM 0–4 flists point at `deps/axi-chiplet-controller/logical/wlink/`, not dieb `local_overrides/`.

**Per-feature hardware sign-off (each: platform, N, CI-lower, evidence-archive path):**
- [ ] F01 manual bring-up — N≥40, CI-lower ≥90%, ≥1 platform.
- [ ] F02 **hardware autonomy zero-poke** — N≥40, CI-lower ≥90%, on a live-`set_bus_skew` bitstream (MANDATORY per David; **currently RED ~25–35%**).
- [ ] F04 cross-lane deskew — EPOCH anchored, span in-budget; deskew present in V2 ASIC flist.
- [ ] F06/F07/F08 data A→B, B→A, doorbell — byte-exact both directions, N≥40 (Z2 done; **KR RED**).
- [ ] F09 XHB window — bounded round-trips 8/8 (silicon-gated; sim `sim_gate_xhb` rejoined the aggregate OR documented waiver).
- [ ] F10/F11 credit path — phantom-pop gate green, credit never > 4096, `fe_tx_credit_max_eff` clamp verified on silicon; write-side twin dispositioned.
- [ ] F12 sustained data — `linkhold_soak` 100% byte-exact for the target duration (**never yet run — RED**); throughput baseline recorded.
- [ ] F13 PTP — two-board `|offset| ≤ 12000 ns` convergence (**never end-to-end on HW — RED**); never gated on `phc_locked`.
- [ ] F14 error/recovery — power-cycle recovery + mid-burst reset + link-degradation matrix all recover to a healthy link.
- [ ] F16 autonomy arm/retire — RETIRE_EN A/B green in sim; B→A retire-autonomy N≥40 on silicon.
- [ ] F17 role/straps — role negotiation proven; `apb_debug_unlock`/`mask_hs_bypass` strap decision signed off.
- [ ] F18 **TideChart** — at minimum a two-die integration smoke (election+enum+route) proven; on FPGA if schedule allows, else an explicit documented waiver with the sim evidence (60/60 cocotb + UVM) and a post-tapeout hardware plan.
- [ ] F19 PHY BIST — one real eye/BER characterization from the standalone bitstream on record.

**Instrument hygiene (blocks sign-off):**
- [ ] Every automated verdict reads only V2-trust-allow-list registers; `0x215C`/`0x2144`/`0x2174`/`lane_locked` quarantined.
- [ ] All harnesses use ctypes single-u32 access; no `struct.pack_into` remains.
- [ ] Instrument preamble (§2.1) runs and passes at the head of every archived run.
- [ ] Every green number in the L4 report cites its source register/CSV and is reproducible from the archived raw evidence.

---

### Appendix A — canonical scripts and their roles

| Script | Role |
|---|---|
| `fpga/hw_regression/td_v2_channels.sh` | per-trial channel engine (link/data/doorbell/ptp/xhb); register map `:200-262` |
| `fpga/hw_regression/td_v2_hwlib.sh` | bring-up lib: `rcp()`, `winscan()` (lanes `[6,2,5,7]` `:176`), `zp_arm()` canary |
| `fpga/hw_regression/td_v2_regress.sh` | 4-test datapath regression (link_up / phy_rx_clean / deskew_align / data_a2b) |
| `fpga/hw_regression/allchan_recipe_soak.sh` | N-trial Clopper-Pearson soak wrapping the engine (the "N=40" harness) |
| `fpga/hw_regression/proven_method_soak.sh` | per-metric CP soak (link / A→B / B→A / doorbell + ALL-4) |
| `fpga/hw_regression/overnight_autonomy.sh` | unattended bounded autonomy soak (Phase-2 decisive test; PDU recovery) |
| `pynq_host/scripts/kr260_afi.sh` | AFI port-width check/fix (`0xFF419000`/`0xFD615000` `[9:8]`) + canaries |
| `fpga/scripts/verify_build.sh` | structural build provenance gate (markers, dropped-XDC, DCP cell counts) |
| `fpga/farm_gate.sh` | Tier-0 XDC/SV ratchet + Tier-1 V2 pair sim |
| `pynq_host/scripts/tl_poke.py` / `tl39.py` | host register access (ctypes single-u32; `tl39.py wr` = legacy 5-store, deprecated) |
| `pynq_host/scripts/kr260_onchip_smoke.py` | on-chip pair plumbing smoke (dual-instance, opposite straps) |
| `pynq_host/scripts/eye_toolkit/web/` · `stress_toolkit/web/` | existing Flask dashboards — the L4 reporting precedent |

### Appendix B — build targets

`fpga/targets/`: **Z2** `pynq-z2-pair-all` (die_a) / `pynq-z2-pair-flip-all` (die_b) — the
proven vehicle; **KR260** `kr260-pair-nptp` (primary bring-up, no PHC CDC), `-flip-nptp`,
`kr260-pair-ptp`, `-flip-ptp`, `kr260-pair-onchip` (two dies, one bitstream — designed, not yet
buildable). Build with `TIDELINK_PHY_V2=1` (a V1 bitstream ships the fix-less PHY). ASIC default
must be `_asic_v2.flist` (chip-killer #2). Apertures: Z2 GP1 `TX 0x8400_0000` / `RX 0x8401_0000`
/ APB `0x4403_2000`; KR260 APB `0x8403_2000`, PHC `0x8405_0000`.
