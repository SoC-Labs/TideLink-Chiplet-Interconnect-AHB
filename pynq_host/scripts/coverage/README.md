# Coverage gates — KR260 eth-chiplet TideLink pair

New SoC-side verification gates that close the data-plane + error-recovery
coverage gaps on the two-board KR260 eth-chiplet TideLink pair. All four are
**dev-host orchestrators** (run on **mapstone-dev**, which owns both boards):
they drive the boards over **timeout-wrapped ssh** and **reuse the proven
on-board modes** (`kr260_eth_xfer.py`, `kr260_eth_soak_fwd.py`,
`eth_tlapb_poke.py`, `health_snapshot.py`) rather than re-poking `/dev/mem`.
Shared ssh / FCSM-gate / Region-F-decode / POR-staging helpers live in
`cov_common.py`.

## Wedge-safety model (baked into every gate)

- **Refuse unless FCSM=4** on BOTH dies (`require_pair_fcsm4`) before driving anything.
- **Every board access is subprocess-timeout-wrapped**; a timeout == a PS-bus
  **WEDGE** (the AXI data plane hangs with no software timeout) and is reported as such.
- **Verdicts come from die_b (or the surviving die) LOCAL reads** so the verifier
  itself can never wedge.
- **JTAG-POR is STAGED, not auto-fired.** On a wedge the gate prints the exact
  recovery (`weekend/por_recover.sh <target>` + the raw fpgahub reset curl). It
  only issues a POR when `COV_AUTO_POR=1`. Recovery is JTAG-POR only — never `reboot`.
- Never touches bare-link addresses (`0x8403/0xA400/0x8000`); never runs `kr260_afi.sh`.

## Prerequisites

```bash
export KR260_PASSWORD=...        # REQUIRED — never hardcoded (gates exit if unset)
# boards deployed (deploy_pair.sh stages ~/td/scripts/) and brought up:
#   bringup_pair_release.sh   (fcsm=4 on both dies)
# optional env: KR260_DIEA_IP / KR260_DIEB_IP (default .159 / .153),
#   COV_AUTO_POR=1 to auto-issue JTAG-POR on a wedge,
#   COV_T_STREAM / COV_T_VERIFY / ... to tune per-access timeouts.
```

## The gates

| Script | Gap closed | Run command | Wedge-risk | PASS / FAIL |
|---|---|---|---|---|
| `cov_axinode_wedge_gate.py` | **P0.** AXI data nodes sustained + the UNTESTED **reverse** (B→A) direction; per-beat `OBS_AXI_NODES 0x21E0` wedge gate. | `python3 cov_axinode_wedge_gate.py --iters 500 --seed 0xC0FFEE` (add `--direction fwd\|rev\|both`) | MED fwd / **HIGH rev** (attended) | PASS = both directions: sender healthy every beat (data_healthy=1, no wedge-sticky) **and** die_b byte-exact **and** no timeout. FAIL = any wedge-sticky / data_healthy=0 / mismatch / timeout(=WEDGE). |
| `cov_decerr_confine.py` | Inbound confinement: a CAM-retargeted peer write to an **excluded byte** (not 0x2D/0x23) must DECERR cleanly on die_b, land nowhere, wedge neither die. | `python3 cov_decerr_confine.py` (sweeps 0x2A/0x2C/0x2E; `--excl 0x2C` for one) | MEDIUM (attended) | PASS = every excluded byte: die_a survived + link healthy **and** die_b still reads the sentinel (poison landed nowhere). FAIL = die_a wedged / link unhealthy / poison leaked / timeout. |
| `cov_auto_anchor_verify.py` | AUTO_ANCHOR actually fired + re-anchored on HW; classify the non-fire mode. | `python3 cov_auto_anchor_verify.py` (`--die a\|b\|both`) | **NONE** (RO obs plane; unattended-safe) | PASS = `pulsed_ever=1 & reanchored=1` on both dies. FAIL = classified: EN=0 (rebuild) / gate-too-strict / emit-blocked / peer-didn't-latch. |
| `cov_errinject_sweep.py` | Directional one-shot inject on each node **on the transmitting die** {AW/W/AR@die_a, B/R@die_b} × bytes/bits, resume + byte-exact verify; measure **W-byte-0 residual wedge rate**. | `python3 cov_errinject_sweep.py` (`--nodes W,B` `--bytebits 0:0,1:0` `--wsoak 10`) | **HIGH** — deliberately provokes the recovery gap (attended, POR staged) | PASS(matrix) = every node recovered a byte-0 flip, die_a alive, data byte-exact (die_b local for writes). W-byte-0 rate is a **measurement** (non-gating). FAIL = die_a wedged / residual corruption / timeout. |

## Notes / open assumptions

1. **Reverse (B→A) is symmetric at the address level** — each die's `0x2F`
   aperture, CAM `0x2F→0x2D`, lands in the PEER's `0x2D` shared_sram_0 — but has
   NEVER run on silicon. `cov_axinode_wedge_gate.py --direction rev` runs the same
   proven `--mode soak`/`soak_recv` on die_b/die_a. If the `kr260-eth-chiplet-flip`
   image differs in address map (not just PHY byte-lane orientation), reverse needs
   a per-image CAM/aperture check first. **Confirm before an unattended reverse run.**
2. **`cov_auto_anchor_verify.py` needs the `200bce5` (pause-accumulate) build with
   `AUTO_ANCHOR_EN=1`.** On today's bitstream `EN` may read 0 → the gate reports the
   BITSTREAM gap (rebuild), not an FSM failure. It supersedes the print-only
   `eth_tlapb_poke.py anchorobs` / `kr260_eth_ecc_hwverify.sh [0b]` with a
   programmatic pass/fail + action per the diagnostic doc.
3. **`cov_errinject_sweep.py` read-node (AR/R) byte-exactness is die_a-side** (a peer
   readback that traverses the link — wedge-prone), unlike the write nodes whose
   byte-exactness is a wedge-safe die_b local read. Treat AR/R "byte_exact" as the
   less-safe leg.
4. **Injector must be wired in the bitstream.** If `ERR_INJECT 0x003C` is a no-op,
   injected beats do not corrupt and the sweep reads as a vacuous "survive"
   (`kr260_eth_xfer.py --mode errinject` reports this as INCONCLUSIVE via a CRC-rise
   check; the sweep here asserts liveness+exactness, so confirm the injector is live
   before trusting a PASS).
5. **Password handling** deviates deliberately from the older scripts'
   hardcoded default: `cov_common.password()` requires `KR260_PASSWORD` and
   exits if unset — nothing is hardcoded.
6. These gates were **written and syntax/-help/decoder-checked on the dev host
   only; nothing was run against the boards.**

---

# Cross-die MAILBOX + INTERRUPT coverage (mbox/irq)

Closes the cross-die **interrupt** gap the data-plane gates above don't touch. Per
the V-plan: *"No interrupt has EVER been observed asserting on hardware — not a
line, not an ISR, not even a confirmed source-latch high."* Every prior HW "IRQ"
check is a register poll used as a proxy. These three tests attack that in order —
source latch → PS line → ISR delivery.

Unlike the dev-host gates above, two of these are **board-side tools** (run ON a
die), paired with a host orchestrator that reuses `cov_common.py`:

| File | Role | Gap closed | Run | Wedge-risk | PASS |
|---|---|---|---|---|---|
| `cov_mbox_doorbell_irq.py` | **board-side** tool (die_a/die_b) | IPC mailbox doorbell as the **first interrupt-SOURCE proof**. `recv` PASS **requires** `IRQ_STATUS[0]` latched (not just data), unlike `kr260_eth_xfer.py mbox_recv` which only reports it. Also tests R/W1C clear. | staged/run by the orchestrator below (modes `arm`/`send`/`recv`/`clear`) | `send` only crosses (peer WRITES; MED, attended). arm/recv/clear = die_b LOCAL (safe) | `recv`: `IRQ_STATUS[0]==1` **and** 4 words match. `clear`: source drops 1→0. |
| `cov_mbox_irq_source.py` | **dev-host** orchestrator | end-to-end #1: FCSM gate → die_b `arm` → die_a `send` → die_b `recv` verdict → die_b `clear`. Pushes the board tool, timeout-wraps every access, stages JTAG-POR. | `python3 cov_mbox_irq_source.py` (`--payload 0x...`) | MED (attended; step-2 crosses the AXI data plane) | interrupt-SOURCE latched **and** W1C clear both YES. |
| `cov_ps_irq_observe.py` | **board-side** (runs ON the PS) | **first** instrument that checks a chiplet IRQ line reaches the **PS GIC**. Snapshots `/proc/interrupts` + UIO, pulses a source, asserts a `pl_ps_irq0`/fabric line count INCREMENTS. | on the die: `sudo python3 cov_ps_irq_observe.py` (`--stimulus tidechart\|none`, `--phase auto\|baseline\|compare`) | **NONE** (reads /proc + in-window TideChart APB pulse; config-plane only) | a fabric/PL line incremented = first PS-reachable IRQ evidence. INCONCLUSIVE (no line moved) is the *expected* current state. |
| `cov_cross_die_isr_plan.md` | plan | **ISR DELIVERY** (#8): far-die core's ISR actually runs. STAGED — needs firmware + boot-gate release. | read it | — | ladder inside. |
| `cov_die_b_mbox_isr_stub.c` | firmware stub | die_b CPU1 mailbox ISR: enable irq + NVIC ISER; ISR W1C's the source and bumps a backdoor-readable flag in shared_sram_0 @ `0x2D00_1F00`. | (built by the harness) | — | — |
| `cov_cross_die_isr_harness.sh` | **dev-host** harness (STAGED) | loads the stub, releases the gate, fires die_a's doorbell, reads the flag back (die_b LOCAL). Exits **BLOCKED** unless prereqs land (`COV_ISR_FORCE=1` dry-runs the wiring). | `bash cov_cross_die_isr_harness.sh` | MED (attended) | `ISR_RUN_COUNT>=1` = far-die ISR delivered. |

## mbox/irq notes

1. **`IRQ_STATUS[0]` is edge-set + R/W1C** (`ipc_mailbox_apb_regs.sv`): it latches on
   the far-die MSG_VALID **rising** edge *regardless of* `irq_enable` (enable only
   gates the NVIC output). So the source proof (#1) is firmware-free, but a clean,
   repeatable edge needs `arm` (de-assert MSG_VALID + W1C) on die_b **before** each
   `send` — otherwise a stale MSG_VALID gives no rising edge and the source won't
   re-latch. The orchestrator does arm→send→recv→clear in order.
2. **The mailbox feeds the NVIC, not `pl_ps_irq0`.** `cov_ps_irq_observe.py`'s
   PS-reachable source is `tidechart_irq_o` (eth-chiplet IRQ[14], concatenated into
   `pl_ps_irq0`), so its default `--stimulus tidechart`. The mailbox doorbell is an
   internal `d2d_irq → CPU1 IRQ0` source and needs firmware to observe (that is #3).
   Use `--phase baseline`/`compare` to watch an EXTERNALLY-applied source (bench, or
   a scope-confirmed line) if `tidechart_irq_o` is gated (TideChart RTL gap).
3. **#3 is STAGED.** Prereqs not in the shipped bitstream: an SWD/backdoor firmware
   -load path to die_b CPU1, a boot-gate release, and confirming mailbox slot0 →
   CPU1 NVIC IRQ0 on silicon. `cov_die_b_mbox_isr_stub.c` puts its flag in
   shared_sram_0 so the delivery verdict is a wedge-safe die_b LOCAL read.
4. **Password / wedge model** match the peer gates: `KR260_PASSWORD` from env only,
   FCSM=4 refuse, timeout==WEDGE, JTAG-POR staged, never the bare-link map.
5. Written + syntax/`--help`-checked on the dev host only; **nothing run against the
   boards.**

---

# PERF-MONITOR / OBSERVABILITY / TIDECHART / REGISTER-PLANE coverage (perf/obs/tc/reg)

Closes the **PERFORMANCE-MONITOR**, **TIDECHART**, and **REGISTER-PLANE** gaps that
the data-plane / IRQ gates above do not touch. Same dev-host + wedge-safety model,
built on `cov_common.py` (`require_pair_fcsm4` / timeout-wrapped ssh / `decode_regf`
/ staged `por_stage` / `KR260_PASSWORD`-only).

These four are **self-shipping single files**: the default (dev-host) run
base64-ships the file to the target die and runs it `--on-board` in **one
timeout-wrapped ssh** (so the `coverage/` dir need not be pre-staged on the
board); `--on-board` is a stdlib-only `/dev/mem` agent. All register offsets are
the **eth-chiplet backdoor** offsets from `TLAPB 0x2E030000` (config plane at
`+0x2000..`, per-node FC at `+0x1000..`, TideChart at `0x2E040000`) — i.e. the Z2
`REG_INVENTORY.md` low offsets **+0x2000** for the R0..R8 regions.

| Script | Gap closed | Run command | Wedge-risk | PASS / FAIL |
|---|---|---|---|---|
| `cov_perf_thresholds.py` | Turns perf into a **threshold ASSERTION** (hwtest/11 was liveness-only). Computes link + FIFO-drain **latency** from TX_START/RX_FIRST/RX_DONE, asserts stall-fraction + credit-starve budgets, **decodes PERF_CONG_STATE** (0x20F8), retires the dead ECCCNT half. | `python3 cov_perf_thresholds.py --induce doorbell` (or `--induce none` RO / `--induce peerwrite` attended) | `none`=NONE (RO), `doorbell`=LOW, `peerwrite`=MED (attended) | PASS = latency ≤ bounds, stall/starve ≤ budget, no starve_sticky, PERF_ID ok, link FCSM=4. FAIL = any bound breached (calibrate `--max-*` against a golden run). |
| `cov_obs_health_gate.py` | Promotes `health_snapshot.py`/`winscan_read.py`/`anchorobs` DUMPS into one **asserting RO gate**: OBS_AXI_NODES data_healthy=1 + no wedge-sticky/resp-err, AUTO_ANCHOR reanchored=1, WINSCAN locked (markers 0xC5/0x25), **per-node FC CRC delta==0**. | `python3 cov_obs_health_gate.py` (`--die a\|b\|both`) | **NONE** (pure RO obs/config plane — cannot wedge; does not refuse on a down link, it FAILS it) | PASS = both dies clean on every asserted bit. FAIL = data_healthy=0 / wedge-sticky / rising CRC / reanchored=0 / marker missing / link down. |
| `cov_tidechart_election.py` | **Deterministic** TideChart bootstrap on BOTH dies: election→enum→route→telemetry→**IRQ**, asserting **EXACTLY-ONE-ROOT** (host-side, since `TC_ERROR[2] dual_root` never asserts), distinct IDs, a peer route, rx_bcast increment, and the TideChart IRQ (edge on election/enum_done + TC_HOTPLUG W1C level). Detects+reports the **G1** dual-root condition. | `python3 cov_tidechart_election.py` (`--sync-slack 4 --timeout 8`) | LOW (TideChart is in-window only — no peer aperture; FCSM=4 still required for packets to cross) | PASS = one root, total=2 distinct ids, peer route, rx_bcast++ , IRQ edges+HOTPLUG W1C. FAIL = dual/no root (**G1**), enum/route/telemetry/IRQ miss. |
| `cov_regplane_sweep.py` | **First full TideLink APB register-plane sweep** on the eth-chiplet backdoor (only the Z2 `hwtest/02/04/06` did it before, on a different base). RW round-trip+restore / RO write-reject / reset-&-ID match / W1P self-clear across R0–R8 + perf + obs + FC-node CRC, per `REG_INVENTORY.md`. | `python3 cov_regplane_sweep.py` (`--die b`; `--include-ptp/-routing/-phy` for the gated RW regs) | LOW (config/obs/FC plane only — never AHB_TX / peer aperture / bare-link) | PASS = every reg behaves (round-trip / reject / id / W1P / marker). FAIL = any misbehave. |

## perf/obs/tc/reg notes

1. **G1 PREREQUISITE (bitstream fix).** Both dies are strapped
   `TC_DEVICE_CLASS=0x0001` with the PUF off, so election falls to the
   free-running `random_id` tiebreak → non-deterministic / silent dual-root, and
   `force_root` (TC_CTRL[2]) is decoded but **not consumed** in silicon so it can't
   fix it from SW. **EXACTLY-ONE-ROOT can only PASS after re-strapping
   `die_a=0x0001 < die_b=0x0002` and REBUILDING BOTH bitstreams.**
   `cov_tidechart_election.py` **detects and loudly reports** the unfixed
   (identical-strap / `puf_ready=0`) condition and FAILs with the fix instructions.
2. **TideChart IRQ is not directly PS-readable** on this backdoor (the `tidechart_irq`
   wire goes to the IRQC/GIC, not an APB pending reg). The gate asserts the IRQ
   **sources**: the `election_done`/`enum_done` rising edges (that pulse the IRQ) and
   the `TC_HOTPLUG` sticky link-change level (W1C self-clear — the deassert path).
   A raw-line capture still needs the IRQC/GIC path (see the peer `cov_ps_irq_observe.py`).
3. **Perf thresholds are placeholders.** `--max-link-ns/-drain-ns/-total-ns` and the
   stall/starve budgets are conservative defaults — **calibrate against a golden run**
   before treating a FAIL as a regression. `--induce none` asserts on whatever the
   perf block last latched (e.g. post-soak); use `--induce doorbell` (low wedge risk)
   or `--induce peerwrite` (reuses the proven `kr260_eth_xfer.py --mode soak`,
   attended) for a fresh bounded workload. `ns` fields are 30-bit sec:ns
   (`--ns-per-sec`, default 1e9); a single rollover is tolerated.
4. **Dead counters explicitly retired:** `ECCCNT 0x2114 ecc_corrupted[15:0]` (ties 0
   in silicon) is printed as a SKIP and never gated; the register-sweep gives it the
   `skip` (read-only, step is W1P) treatment.
5. **RO write-reject over the backdoor = read-back-unchanged.** TideLink APB *does*
   assert `pslverr` on an RO write (`tidelink_apb_regs.sv`), but a rejected write on
   the `/dev/mem` path is absorbed by the AHB default slave (SLVERR), so the sweep’s
   reliable RO signal is "the forced value did not stick". Write-once bits
   (`CTRL.LOCK`, `ROLE_CFG.role_lock`), `SWI_PHASE_OFFSET`, `NEGO_TRAIN_CFG`,
   `SWI_TRAINING_MODE` recal and the WO consume reg are **never written** (skip
   list); link-disruptive RW (routing / PHY bit-slip / PTP) is opt-in.
6. Host-side verdict logic (latency/threshold math, Region-F/WINSCAN/AUTO_ANCHOR
   decode, exactly-one-root vs G1 dual-root, the full register-sweep classifier) was
   **offline-tested with synthetic snapshots + a fake `/dev/mem`**; **nothing was run
   against the boards.**
