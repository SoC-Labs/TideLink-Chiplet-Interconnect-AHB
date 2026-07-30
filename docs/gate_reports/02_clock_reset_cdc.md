# TideLink SoC-Integration Gate Report — Dimension 02: CLOCK / RESET / CDC

**Scope:** what can go wrong at the SoC-embedding boundary in the clock, reset, and
clock-domain-crossing dimension, and the tests/conditions that would catch it *before*
silicon. Read-only audit; no repo files modified.

**Headline:** the two shipped clock-gate regressions (V2 dropped `| sync_insert`, then
dropped the postcount drain guard) are not one-offs — they are the visible tip of a
**structural blindness**: the interesting clock/reset/CDC logic lives inside
`axi_chiplet_controller`, which is **black-boxed in SpyGlass CDC signoff** and driven at a
**non-silicon clock ratio in every gated sim**. The benches that *do* exercise the real
hazards (async-reset-deassert tear, 40 ns ratio, incommensurate CDC) **exist but are gated
nowhere**. That combination is how a "green" project shipped a dead clock — and it will do
so again on the next V1→V2 or SoC-ratio change unless the gate is widened.

---

## 1. Domain / Reset / CDC map at the embedding boundary

### 1.1 Clock domains (`tidelink_top` ports + `cdc/tidelink_top.sgdc` + ASIC/FPGA constraints)

| Clock | Port / origin | Nominal (ASIC SDC / FPGA -all) | Drives | Notes |
|---|---|---|---|---|
| `hclk` | input | 4 ns (250 MHz) / 4.687 MHz | ALL AHB/APB/AXI bus logic, FIFO, FC adapter, `apb_regs`, addr-translation, PTP/servo, XHB bridges. **= `apb_clk` inside controller** | the SoC application clock |
| `phc_clk` | input | 20 ns / 25–50 MHz | PHC timestamping only (`tidelink_phc_cdc`, `tidelink_ptp`) | independent frequency by design |
| `user_ref_clk` | input | 4 ns / **2.343 MHz (÷2)** | Wlink PLL ref + PHY hi-speed serialiser clock | FPGA `-all` build runs it at **½ hclk** to widen the RX eye → **hclk:PHY = 2:1** there |
| `pad_clk_rx` | input | 4 ns / 426.666 ns | RX capture. **= the PEER die's `pad_clk_tx`** | async to hclk (XDC `set_clock_groups -asynchronous`) |
| `pad_clk_tx` | **output** | — | the PEER's `pad_clk_rx` | gated by lane-0 serialiser clock-gate (the bug locus) **and** by `wlink_por_reset` |
| `link_rx_clk` (internal `link_rx_clk_o`) | `pad_clk_rx / 16` | 64 ns in sgdc; **no generated-clock in ASIC SDC** | RX deskew FIFO, replay FIFOs, SYNC insert/detect, `gpio_phy_apb_regs` link-side syncs | the **LL "word" domain** — see §1.4 |
| `idelay_ref_clk` | input | 200 MHz (FPGA only) | IDELAYE2 cal | ties off on ASIC |
| `scan_clk` | input | 10 ns | DFT | `set_case_analysis 0` functionally |

### 1.2 Resets

| Reset | Type | Feeds | Constraint |
|---|---|---|---|
| `poresetn` | async, active-low | `wlink_por_reset = ~poresetn \| ~role_locked` (`axi_chiplet_controller.sv:2916`); `idelay_rst` | not false-pathed in ASIC SDC (recovery/removal handling unclear) |
| `hresetn` | async, active-low | all bus logic; `app_clk_reset = ~hresetn \| ~role_locked` (`:2921`) | **`set_false_path -from hresetn`** in ASIC SDC — recovery/removal **NOT STA-checked** |
| `phc_resetn` | async, active-low | PHC domain (`tidelink_phc_cdc`) | synchronized 2× (SpyGlass `Reset_sync04`) |
| `role_locked` (runtime, **not a port**) | functional reset / **mutual clock enable** | gates `wlink_por_reset` AND `app_clk_reset`; sgdc declares `reset -name role_locked_o` | **this die's `pad_clk_tx` (= peer's `pad_clk_rx`) is dark until `role_locked`** |

### 1.3 The mutual-clock-enable coupling (the load-bearing integration fact)

`wlink_por_reset = ~poresetn | ~role_locked` and `app_clk_reset = ~hresetn | ~role_locked`.
Because `role_locked` gates the forwarded `pad_clk_tx`, and `pad_clk_tx` **is** the peer's
`pad_clk_rx`, the two dies are **clock-coupled through a runtime event**: die-A cannot clock
die-B's RX capture until die-A locks role, and vice-versa. Any reset/power sequencing the SoC
applies to the two chiplets asymmetrically (one held in `poresetn`, skewed release, one clk_wiz
not yet locked) can leave both RX domains dark with neither able to bootstrap.

### 1.4 How the SoC consumers actually wire it (the embedding boundary as shipped)

The RTL consumers that instantiate `tidelink_top` are the **chiplet wrappers**, not the repos
named in the task (`nanosoc-multicore-system` supplies the *core* the eth chiplet embeds;
`nanoSoC-refactor`/`ethss-demo` contain no `tidelink_top` instance). What the SoC does
*differently* from every bench:

| Consumer | `hclk` / `phc_clk` | `user_ref_clk` / `pad_clk_rx` | Resets | Notes |
|---|---|---|---|---|
| `nanosoc-ethernet-chiplet/src/rtl/nanosoc_eth_chiplet.sv:603` | `phc_clk = hclk = sys_hclk` (**same net**, "PHC shares the AHB clock") | boundary ports; `pad_clk_rx` external pad | `phc_resetn = hresetn`; `poresetn/hresetn` from embedded SoC | 1 link |
| `NanoSoC-Compute-Chiplet/…nanosoc_compute_chiplet.sv:696,896` | `phc_clk = hclk = sys_hclk` (both links) | **two independent** `pad_clk_rx_{0,1}` / `user_ref_clk_{0,1}` off one shared core clock; link-1 sometimes `pad_clk_rx_1=1'b0` | `phc_resetn = hresetn`, shared `poresetn/hresetn` | **2 links, 1 clock/reset** |
| `nanosoc-simple-chiplet/…/wrappers/tidelink_ahb.sv:266` | `phc_clk`/`phc_resetn` **kept separate** (fusion deferred) | pass-through | pass-through | thin wrapper |

**Real reset controller = `nanosoc_clkctrl.v`** (CMSDK-derived, inside the embedded SoC):
3-stage sync on `PORESETn`, then `HRESETn` is a flop **async-reset by `~PORESETn`** →
**`poresetn` deasserts one source-clock cycle before `hresetn`** (POR leads HRESET). No ICG on
the TideLink clocks by default (`CLKGATE_PRESENT==0` → `PCLK=clk`). **But** the FPGA IP wrapper
*advises tying `poresetn = hresetn` on boards*, and **both pair TBs gate `poresetn`/`hresetn`
identically** (`verif/g2_peer_aperture/tb_pair.sv:76-79`, `tb_het_pair.sv`) → the intended
POR-before-HRESET ordering exists in exactly one module and is routinely flattened.

**`pad_clk_rx` is asynchronous and peer-sourced (or self-loopback), and force-gated around
reset in EVERY sim** — `.pad_clk_rx(s_pad_clk_tx_skid & s_por_gate)` (`tb_pair.sv:240`),
`… & c_pad_en` (`tb_het_pair.sv:330`); HAPS uses `PHY_LOOPBACK: pad_clk_rx = pad_clk_tx`. On HAPS
`user_ref_clk` is a **/8 ripple-counter-divided, non-global-buffered 3.125 MHz** clock driven
straight into the Wlink PLL ref (clock-quality risk). `d2d_reset_o` is exported everywhere and
**consumed nowhere**.

### 1.5 CDC crossings at the boundary

| # | Crossing | Mechanism | Where verified today |
|---|---|---|---|
| A | `hclk`(apb) ↔ `link_rx_clk`(pad/16) — APB↔LL control | **fixed-cycle pulse-stretchers** ("127 apb_clk ≈ 16 link_rx_clk", `axi_chiplet_controller.sv:5700-5792`); `swi_enable` via `WavDemetReset`; `swi_swreset` via `WavResetSync` | **RATIO-SENSITIVE. Not in CDC (blackbox). Not gated in sim.** |
| B | `pad_clk_rx`/`link_rx_clk` ↔ `hclk` — RX data | deskew FIFO (`WavMultibitSync_18` Gray CDC); replay-FIFO ACK ptr (`WlinkGenericFCReplayV2_13`) with **two reset halves in different domains** (`w_reset=link`, `r_reset=app`) | modelled by `cdc_tear` + `a2l_replay_cdc` — **both UNGATED** |
| C | `pad_rx[7:0]` `pad_clk_rx` → `hclk` (raw) | into controller blackbox | SpyGlass flags **`Ac_unsync02` (unsynchronized)** — unverified |
| D | `hclk` ↔ `phc_clk` — PTP time bus | 6 toggle/enable-based syncs (`tidelink_phc_cdc.sv`) | **the ONLY CDC SpyGlass analyzes**; data-hold **"Not-Analyzed"** |
| E | `hclk` → `user_ref_clk` (Wlink PLL dom) | `puf_ready`, `apb_debug_unlock_i`, `hresetn` | SpyGlass **`Ac_unsync01`** into blackbox — unverified |
| F | `poresetn` → `hclk` | `idelay_rst`, `wlink_por_reset` | SpyGlass **`Ac_unsync01`** — unverified |

---

## 2. Structural blind spots (why "green" is not "safe" here)

1. **SpyGlass CDC black-boxes `axi_chiplet_controller`** (`cdc/…/CDC-report.rpt` line 88:
   `UnsynthesizedDU … Stop applied`; `cdc/waiver.swl` waives `Wlink*`, `Wav*`, `i2c_*`, the
   FC replay FIFOs). Consequence: crossings **A, B, C, E, F are entirely outside CDC scope.**
   The clock-gate bug, the replay-FIFO tear, the deskew FIFO, and the APB↔LL stretchers are
   **never seen by CDC signoff.** Only D (PHC) and the FIFO `read_ptr` reset are actually analyzed.
2. **No edge-list for any clock** — SpyGlass `Ac_clockperiod01` **Error**: "Edge-List is not
   defined for 8 (100 %) clocks." Duty cycle and true ratio are not modeled even for the crossings
   it does see.
3. **No gated sim runs at the silicon clock ratio.** `pair_v2_common.py:80` defaults
   `REF_CLK_PERIOD_NS=8` with `hclk=20` (ratio 2.5:1, pad *faster* than hclk). Silicon is 40 ns
   (pad *slower*, ratio ~1:2) — the *opposite regime*. `epoch_silicon` (the one "silicon" suite in
   the aggregate, `Makefile:527`) sets `EPOCH_PROFILE=silicon` but **not** `TIDELINK_SIM_REF_PERIOD_NS`,
   so it still runs at 8 ns. `farm_gate.sh` runs 40 ns (`silicon_data`/`silicon_negctl`) but they are
   **ADVISORY (non-blocking) unless `FARM_GATE_STRESS=1`** (`farm_gate.sh:406`, header §65-77).
4. **The idle-link clock-gate case is structurally unreachable in the pair sim.** The pair TB's LL
   holds `io_link_tx_tx_en` high continuously, so `postcount` never drains and the idle-gated SYNC
   inserter never fires — which is *exactly* why `v2_syncdet`/`v2_data`/`v2_sustained` PASS with and
   without the fix (`test_pad_clkgate_idle.py` docstring; handover §7.3). The bug shipped through a
   hole no gated stimulus can reach.
5. **ASIC signoff does not time the `link_rx_clk` (pad/16) domain** — no `create_generated_clock`
   in `imp/ASIC/tidelink_top_full/tidelink_top.sdc`; `hresetn` is a `set_false_path`. The LL-word
   domain (deskew FIFO, replay FIFO, sync insert, APB↔LL stretchers) and its reset recovery/removal
   are a **functional-verification-only** responsibility — and functional verification runs at the
   wrong ratio and blackboxes the CDC.

---

## 3. Embedded-specific failure modes (concrete scenarios)

Each is something a *bench* with a synchronous, single-ratio, single-die-pair release does not
provoke, but a *real SoC* (reset controller, PS clk_wiz, two independently-sequenced chiplets,
different hclk:pad ratio) will.

### FM-1 — Reset-deassert order / skew tears the replay-FIFO ACK pointer (A→B dead on first write)
The pair bench uses ONE fixed order: `poresetn=0,hresetn=0 → +20 hclk → poresetn=1 → +5 → hresetn=1`
(`pair_v2_common.py:183-190`), both edges aligned to hclk, `phc_resetn`/`role_locked` untouched.
The replay FIFO's synced-ACK crossing (`WavMultibitSync_18`) has its two halves reset by **different
domains** (`w_reset=link_reset`, `r_reset=app_reset`). On an **asymmetric deassert** the read-side
handshake (`r_ready = rptr ^ wptr_demet`) can latch a stale value → `a2l_full=1` on the very first
write → `app_ready=0` → FCSM never transmits → **A→B silently dead** (silicon-proven; OBS
`0x44032158`; `a2l_replay_cdc` docstring). Because `app_clk_reset = ~hresetn | ~role_locked`, the
SoC's hresetn timing and the runtime `role_locked` edge **compound**. **Consumer reality
(§1.4):** the intended POR-before-HRESET skew lives only in `nanosoc_clkctrl`; the FPGA wrapper
advises tying `poresetn = hresetn` and both pair TBs gate them identically, so the *ordering* is
usually flattened — the live variable becomes the **asynchronous `pad_clk_rx` force-gating around
reset** (`… & por_gate`), which every sim applies but no sim *sweeps*.

### FM-2 — Mutual-clock-enable deadlock across two independently-reset chiplets
`pad_clk_tx` is gated by `wlink_por_reset` until `role_locked`. In a real 2-chiplet SoC the dies
come out of `poresetn` at different times (independent PMICs / PS resets / clk_wiz lock). If die-B's
`poresetn` is held or skewed, die-A's `pad_clk_rx` (= die-B's `pad_clk_tx`) is dark, die-A cannot
train, cannot lock role, so die-A's `pad_clk_tx` stays gated, and die-B cannot train either. The
bench releases both dies together and never reproduces this. (Memory: `role_lock IS a mutual clock
enable`.)

### FM-3 — Gated-clock starvation (the shipped bug + its siblings)
The shipped V2 bug: on an idle link in data mode the pad clock is gated off because
`gpiotx_N_io_clk_en` lost `| sync_insert` (`WavD2DGpio_v2.v:1980-2029`). Generalises to **any** term a
data-mode-idle SoC workload needs but that the pair sim keeps masked by pinning `tx_en` high. The V1→V2
audit (this report's sub-agent) found **two more same-class divergences not yet signed off**:
- **Deskew FIFO write-gate dropped.** V1 gated writes on `tm_sync1`/`training_mode` and re-primed
  `wr_ptr<=0` every training→data cycle (`tidelink_lane_deskew.sv:190-209`); V2 free-runs the writes
  and relies on a content-only epoch/SYNC re-anchor (`tidelink_lane_deskew_v2.sv:537-546`, documented
  :35-71). But `docs/SIM_GATE_COVERAGE.md §4` states the whole-word epoch corrector **is not armed in
  V2** — so the replacement for V1's per-cycle origin re-prime may be inert.
- **RX word-clock source changed** from phase-adjusted `~adj_count[3]` to free-running `~count[3]`
  (`WavD2DGpioRx.v:313` → `WavD2DGpioRx_v2.v:595`), a deliberate glitch fix but a behavioural change to
  the /16 word-clock generation that no gated sim discriminates.

### FM-4 — Clock-ratio sensitivity (only fails at ~40 ns)
- **FCSM state-2 CRACK-emit gate stalls at 40 ns** under a marginal/retrying link: the emit count
  reaches ~29 between resets, never the gate of 32 → `socl_l7_crack_release` never fires → no
  LINK_IDLE, all-zeros both directions (`test_fcsm_silicon_ratio.py`; `flists/tidelink_fpga_v2.flist:283-289`).
- **APB↔LL fixed-cycle stretchers assume a ratio.** "127 apb_clk cycles ≈ 16 link_rx_clk cycles"
  (`:5700`) is only true for a specific hclk:pad ratio. A SoC that runs hclk faster (or pad slower)
  than the assumed ratio shortens the stretcher below the CDC handshake it must span.
- **The clock-gate 16-cycle hold** — `clk_en_qual <= io_clk_en` is sampled only at `count==4'hf`
  (`WavD2DGpioTx.v:339-345`) on the *ungated* `io_clk`, then held for a whole 16-cycle word. One
  link-word `tx_sync_inserting_w` pulse therefore opens the pad gate for a full word — the handover
  **ADDENDUM's** mechanism for why the *unconditional* clock-gate fix **breaks bring-up on silicon**
  (injects pad edges during winscan). This is a ratio/edge-alignment effect invisible at 8 ns.

### FM-5 — CDC metastability on the unverified crossings (incl. the latent PHC trap)
Crossings C (raw `pad_rx`→hclk) and E (`hclk`→`user_ref_clk`: `puf_ready`,`apb_debug_unlock_i`,
`hresetn`) are unverified (blackbox). The PHC time bus (D) has data-hold **Not-Analyzed**.
**Latent trap:** every shipping chiplet ties `phc_clk = hclk` (§1.4), so `tidelink_phc_cdc` runs
**degenerate (same-clock) in silicon today** — the crossing that `phc_cdc` and SpyGlass verify is not
actually active, and the *first* integrator to give PHC a real TCXO (which the FPGA IP wrapper
explicitly anticipates: "`phc_clk` may differ from hclk on boards with a dedicated PTP TCXO") suddenly
activates a real 48-bit/30-bit multi-bit CDC that has **never run at a non-unity ratio in any gated
context**. `phc_cdc` proves the handshake at 0.5/0.7/1.3/2.0×, but it is **not in the pre-deploy gate**.

---

## 4. Current coverage vs gaps (cite suites / file:line)

### 4.1 What exists and is genuinely strong — but is GATED NOWHERE
| Bench | What it proves | In `sim_gate` aggregate? | In CI (`.gitlab-ci.yml`)? | In `farm_gate`? |
|---|---|---|---|---|
| `cocotb/tidelink_cdc_tear` (incommensurate 20/333 ns, torn multibit capture, reset skew) | replay-FIFO false-FULL self-heal under a genuine async tear | **No** | **No** | No (`cdc_tear_gate.sh` wired nowhere) |
| `cocotb/tidelink_a2l_replay_cdc` (**reset-coherency sweep**, asymmetric deassert) | **FM-1** — the actual silicon false-FULL on first write | **No** | **No** | No |
| `cocotb/tidelink_fcsm_silicon_ratio` (40 ns CRACK-gate) | **FM-4** — state-2 stall at silicon ratio | **No** | **No** | only as the advisory 40 ns pair tier |
| `cocotb/tidelink_phc_cdc` (ratio 0.5/0.7/1.3/2.0×) | **FM-5** — PHC time-bus CDC across ratios | **No** | Yes (per-env loop) | No |
| `cocotb/tidelink_clkfreq_check` | freq-mismatch monitor (wrong-bitstream guard) | **No** | Yes | No |
| `cocotb/tidelink_rxclk_buf` | pad_clk_rx BUFG passthrough pin | **No** | Yes | No |

### 4.2 What is in the aggregate but ratio/idle-blind
- `epoch_silicon` (`Makefile:527`) — runs at **8 ns**, not 40 ns (see §2.3).
- `v2_pair_data` / `v2_pair_sustained` / `v2_autonomous_sync_detect` — LL never idles → **clock-gate blind** (§2.4).
- `nack_wedge_recovery`, `apb_fc_cfg_preempt`, `fch_apb_watchdog` — protocol/PS-hang, not CDC.

### 4.3 The pad-clock-gate sentinel (worktree only)
`cocotb/tidelink_pad_clkgate_idle` (branch/worktree, `sim_gate_pad_clkgate_idle`) forces
`io_link_tx_tx_en=0` to reach the idle case and asserts `pad_clk_tx` edges ≥ 128 AND peer
`sync_detected` delta > 0. It is a **sentinel, not in the aggregate**, and is **one-sided**: it proves
the *idle-link* direction but, per the handover ADDENDUM, "proves NOTHING about bring-up," where the
same gate must stay *quiet* — and the bring-up break was caught **only on silicon**.

### 4.4 SpyGlass CDC (`make -C cdc cdc`)
Analyzes only crossing **D** (PHC, all `Ac_sync02` synchronized) and one FIFO reset. Everything else is
black-boxed or waived (§2.1). Three `Ac_unsync01/02` **Errors** stand (C, E, F). `Ac_clockperiod01`
**Error** (no edge-list). This gate is green on a design whose main CDCs it never looked at.

---

## 5. Proposed tests (assertion + location + gate wiring), ranked in §6

> Principle behind the set: (a) make the *silicon operating point* reachable in sim (idle link, 40 ns
> ratio, asymmetric reset); (b) put the already-written CDC benches **into a blocking gate**; (c) add
> the two-sided and swept cases the existing benches miss. Keep every sim light (unit DUT or the
> existing pair TB with a knob).

### T1 — Reset-deassert ORDER + SKEW sweep (pair) — **catches FM-1, FM-2**
- **Where:** new `cocotb/tidelink_top_pair_v2/test_reset_sequencing.py`; reuse `PairV2TB`.
- **Stimulus:** parametrize `reset()` over (i) all 6 orderings of {`poresetn`,`hresetn`,`phc_resetn`}
  release; (ii) sub-hclk skew (release `hresetn` 0/1/2/3 *ref-clk* cycles after `poresetn`, and at a
  fractional offset so the async deassert lands near an hclk edge); (iii) **one die's `poresetn` held
  10 µs longer than the other** (FM-2).
- **Assertion:** after each combination + full bring-up, `role_locked` on both dies, `cal_done=1`,
  `epoch anchored`, and a **byte-exact word crosses both directions**; AND the replay FIFO never shows
  `a2l_full=1` with an empty window (hierarchical read of `dbg_a2l_full`/`dbg_synced_ack` per
  `a2l_replay_cdc`). FAIL if any ordering wedges (that is the integration bug).
- **Gate:** add `reset_sequencing` to `SIM_GATE_ALL_SUITES` (`Makefile:999`). Light (reuses
  `sim_build_zero`).

### T2 — Promote the async-reset-coherency benches into the blocking gate — **FM-1**
- **Where:** `cocotb/tidelink_a2l_replay_cdc` (both `DUT_KIND=a2l` and `l2a`) + the negative control.
- **Assertion (already written):** adversarial arm — read-side reset releases strictly *after* write
  side → must FAIL pre-fix, PASS post-fix; baseline no-tear must PASS.
- **Gate:** add `sim_gate_a2l_replay_cdc` target and both `l2a`/`a2l` arms to the aggregate; add to the
  CI per-env loop. These are the only benches that model the shipped false-FULL and today gate nowhere.

### T3 — Promote `cdc_tear` (incommensurate + torn multibit) into the gate — **FM-1/FM-5**
- **Where:** `cocotb/tidelink_cdc_tear`, `TEAR_FIX` A/B, `DUT_KIND∈{a2l,l2a}`.
- **Assertion (written):** injected one-shot torn capture self-heals (`synced_ack==wbin`, `a2l_full=0`,
  write accepted) with fix; wedges without.
- **Gate:** wire `cocotb/tidelink_cdc_tear/cdc_tear_gate.sh` (currently referenced nowhere) into
  `SIM_GATE_ALL_SUITES` and CI. Keep the unfixed arm as a **negative control** (must FAIL) exactly like
  `fifo_rx_twin2`.

### T4 — Clock-gate LIVENESS family, generalized (idle link, both directions) — **FM-3**
- **Where:** generalise `test_pad_clkgate_idle.py` into `test_clockgate_liveness.py` (pair TB).
- **Stimulus + assertion:** for **each of the 8 lanes** and **both dies**, with the link idle
  (`tx_en=0`) in data mode, assert (a) `pad_clk_tx` keeps toggling (edges ≥ threshold) AND (b) peer
  `sync_detected` delta > 0 — i.e. every lane's `gpiotx_N_io_clk_en` keeps the forwarded clock alive.
  Add a **general invariant**: over any 10 µs data-mode window with the SoC bus quiescent, the
  forwarded `pad_clk_tx` must not stay gated > N pad-cycles. This makes the *class* of "dropped enable
  term" fail, not just `sync_insert`.
- **Gate:** promote to a blocking aggregate suite **once conditioned** (see caveat §7). Until then keep
  as a sentinel but ALSO add the **two-sided bring-up guard** (T5).

### T5 — Two-sided clock-gate guard: bring-up must NOT clock the idle serialiser — **FM-3/FM-4**
- **Where:** `cocotb/tidelink_top_pair_v2/test_clockgate_bringup_quiet.py`.
- **Assertion:** during winscan/calibration (`cal_done=0`, `training_mode=1`→transitions),
  `pad_clk_tx` must **not** produce pad edges attributable to an idle SYNC beacon, and both dies must
  reach `cal=1 fcsm≥4 epoch anchored`. This is the direction the ADDENDUM's silicon regression broke
  (`cal=0 fcsm=1`, LIVEMATCH→1/8). Without it, the idle-link fix (T4) can pass while bring-up dies —
  the exact green-but-blind trap the ADDENDUM records.
- **Gate:** aggregate. Pair with T4 so the clock-gate has coverage in **both** polarities.

### T6 — Silicon clock-ratio tier, BLOCKING in `sim_gate` — **FM-4**
- **Where:** run `v2_pair_data` + `v2_pair_sustained` at `TIDELINK_SIM_REF_PERIOD_NS=40` (and a 20 ns
  mid-tier) as new gate targets `epoch_silicon_ratio40`, `v2_pair_data_ratio40`.
- **Assertion:** byte-exact both directions at 40 ns; explicitly assert **no FCSM node stuck < state 4**
  (fold `test_fcsm_silicon_ratio`'s per-node `max_state ≥ 4` check into the gate).
- **Gate:** add to `SIM_GATE_ALL_SUITES`; also flip `farm_gate.sh` silicon tier to **blocking on the
  shipping lineage** (it is advisory today, `farm_gate.sh:406`). This is the only way a 40 ns-only
  regression (like the CRACK-gate stall) fails a gate by default.

### T7 — APB↔LL stretcher ratio robustness — **FM-4**
- **Where:** unit bench on the APB↔`link_rx_clk` handshake (the 127-cycle stretcher, `:5700-5792`);
  or the pair TB with hclk swept relative to pad.
- **Assertion:** for hclk:pad ∈ {4:1, 2:1, 1:1, 1:2, 1:4}, every APB-driven `swi_*` write that must
  cross to the link domain (`swi_enable`, `swi_swreset`, `sync_obs_clr`, `force_recal`) is observed
  exactly once on the link side (no drop, no double). FAIL if a fixed-count stretcher is too short at
  any ratio.
- **Gate:** aggregate (light unit sim).

### T8 — Extend `phc_cdc` ratio sweep and put it in the pre-deploy gate — **FM-5**
- **Where:** `cocotb/tidelink_phc_cdc` — add extreme ratios (10:1, 1:10) and a **data-hold assertion**
  (the SpyGlass "Not-Analyzed" gap): drive a changing 48-bit seconds value continuously and assert the
  hclk-side capture only ever sees coherent (never torn) values.
- **Gate:** add `sim_gate_phc_cdc` to `SIM_GATE_ALL_SUITES` (it already runs in CI, so cost is known).

### T9 — SpyGlass CDC must see inside the controller (structural) — **§2.1**
- **Where:** `cdc/tidelink_top.prj` — remove the `stop_module`/black-box on
  `axi_chiplet_controller` for the clock/reset-gen, deskew, replay-FIFO and pad-clock-gate hierarchy
  (keep true 3rd-party leaf IP black-boxed), and add **edge-lists** to the 8 clocks (fixes
  `Ac_clockperiod01`).
- **Assertion:** crossings A, B, C, E, F resolve to *synchronized* (or explicitly waived with a
  reason), not "Qualifier not found." A new `Ac_unsync` there fails `make -C cdc cdc`.
- **Gate:** `make -C cdc cdc` clean is already an INTEGRATION_GUIDE signoff gate — make the controller
  crossings part of it.

### T10 — Formal reset-domain / CDC assertions (SVA) — **FM-1/FM-3/FM-5**
- **Where:** the repo has `SVA=0 repo-wide` (verification audit). Add a small SVA layer:
  - **Reset:** `assert property (@(posedge link_rx_clk) $rose(hresetn) |-> ##[0:2] app_clk_reset_released)`
    style — deassert coherency between the coupled `hresetn`/`role_locked`/link domains.
  - **Clock-gate liveness:** `assert property (data_mode && sync_inserting |-> ##[0:16] $changed(pad_clk_tx))`
    — the general form of FM-3 (any enable term that should clock the pad does).
  - **CDC data-hold:** on each `WavMultibitSync_18`, `assert property (r_ready |-> $stable(w_data) throughout handshake)`.
- **Gate:** run under the existing VCS builds; a formal `assert` failure fails the owning suite.

### T11 — `clkfreq_check` must be INSTANTIATED, then gated — **green-but-blind, §7**
- **Where:** `src/rtl/tidelink_top.sv` — instantiate `tidelink_clkfreq_check` on
  (`local_clk`=link-TX, `link_clk`=recovered RX, `link_up`=`role_locked`), route
  `freq_mismatch_sticky` to an OBS register.
- **Assertion:** the existing `test_tidelink_clkfreq_check` suite (matched, 2:1, 1:2, ppm, link-down)
  now gates a **live** guard; add a pair-level check that a deliberately mismatched build latches the
  sticky.
- **Gate:** aggregate. Today the monitor is **definition-only — not instantiated anywhere** in shipping
  RTL, so its green suite protects nothing (§7).

### T12 — Negative controls for every new gate (mandatory)
For T2/T3/T6/T4, keep the pre-fix / gate-out arm as a **non-gated negative control that MUST fail**
(the `fifo_rx_twin2` pattern, `SIM_GATE_COVERAGE.md §3.2`). A CDC/idle gate with no failing control is
vacuous — this repo has been burned by exactly that (`feedback_verify_instrument_before_dut`).

---

## 6. Risk ranking

| Rank | Test | Failure mode | Why this rank |
|---|---|---|---|
| **1** | **T2 + T3** (promote a2l_replay_cdc / cdc_tear to blocking) | FM-1 replay-FIFO tear / async-reset | silicon-proven data-loss bug; benches already written; **gated nowhere today**. Highest ratio of risk-covered to effort. |
| **2** | **T5 + T4** (two-sided clock-gate) | FM-3 gated-clock starvation | shipped twice (`sync_insert`, drain guard); ADDENDUM shows the *fix* also broke bring-up — needs BOTH polarities or it re-ships. |
| **3** | **T6** (40 ns ratio blocking) | FM-4 ratio-only stall | the only regime matching silicon; **no gated sim runs there today**; farm_gate tier is advisory. |
| **4** | **T1** (reset order/skew sweep) | FM-1/FM-2 | real reset controllers and 2-chiplet sequencing differ from the bench's fixed synchronous release; mutual-clock-enable deadlock is unmodelled. |
| **5** | **T9** (CDC un-blackbox + edge-lists) | all A/B/C/E/F | makes the *sign-off* gate actually cover the controller CDCs it now skips. |
| **6** | **T7** (APB↔LL stretcher ratio) | FM-4 | fixed-cycle stretchers silently assume an hclk:pad ratio the SoC may not honour. |
| **7** | **T11** (instantiate + gate clkfreq_check) | wrong-bitstream / clk_wiz mismatch | cheap; converts a dead verified block into a live guard. |
| **8** | **T8** (phc_cdc into gate) | FM-5 PTP time-bus tear (**latent** — activates on a real TCXO) | low current risk (PHC=hclk today) but a day-1 trap for the first TCXO integrator; already in CI, cheap to promote; data-hold assertion closes the SpyGlass "Not-Analyzed". |
| **9** | **T10** (SVA layer) | FM-1/3/5 | highest long-term value, highest effort; SVA is currently zero repo-wide. |

---

## 7. Green-but-blind flags (unreachability / dead protection)

1. **`v2_syncdet`/`v2_data`/`v2_sustained` are structurally blind to the pad clock-gate** because the
   pair TB pins `io_link_tx_tx_en` high — the idle-link operating point is unreachable, so they PASS
   with and without the fix. This is *how the bug shipped* (handover §7.3). **Do not treat their green
   as clock-gate coverage.**
2. **`test_pad_clkgate_idle` is one-sided.** It gates the idle-link direction but "proves NOTHING about
   bring-up" (ADDENDUM). The *unconditional* clock-gate fix passes it while **breaking bring-up on
   silicon** (`cal=0 fcsm=1`). Any clock-gate change needs T5 (bring-up-quiet) as well, and must be
   re-proven on silicon regardless of sim green.
3. **`tidelink_clkfreq_check` protects nothing** — the freq-mismatch monitor is **definition-only, not
   instantiated in any shipping RTL** (`grep` over `src/rtl/*.sv` finds only its own definition). Its
   green cocotb suite and its CI slot assert a guard that does not exist in silicon (T11).
4. **`epoch_silicon` is not the silicon ratio.** Its name implies silicon fidelity but it runs at 8 ns
   (`Makefile:527` sets `EPOCH_PROFILE=silicon` but not `TIDELINK_SIM_REF_PERIOD_NS`). The 40 ns regime
   is untested in the blocking gate (T6).
5. **SpyGlass CDC green is scoped to the PHC path only.** `axi_chiplet_controller` is black-boxed and
   `Wlink*`/`Wav*`/FC-replay are waived, so a clean `make -C cdc cdc` says nothing about crossings
   A/B/C/E/F — the ones that actually carry the shipped bugs (T9).
6. **`farm_gate` 40 ns silicon tier is ADVISORY by default** (`farm_gate.sh:406`) — a 40 ns-only
   regression is a "loud WARN", not a gate failure, unless someone remembers `FARM_GATE_STRESS=1`.
7. **`cdc_tear`, `a2l_replay_cdc`, `fcsm_silicon_ratio` are in NEITHER `make sim_gate` NOR CI** — the
   three benches that most directly model the integration hazards run only when invoked by hand. An
   ungated finding becomes folklore (`SIM_GATE_COVERAGE.md §0`).
8. **The PHC CDC is verified but not active, and the active-on-day-1 case is unverified.** Every
   shipping chiplet ties `phc_clk = hclk` (§1.4), so the crossing `phc_cdc` and SpyGlass both check is
   degenerate in silicon, while the real multi-bit PHC CDC that a TCXO integrator activates has never
   run at a non-unity ratio in any gate. Verified where it doesn't matter yet; blind where it will.

---

## 8. One-line integration contract that is currently undocumented (recommend adding)

`docs/INTEGRATION_GUIDE.md` documents the AHB/AXIS functional ports and their bring-up hazards but has
**no clock/reset port rows and no clocking contract**. The SoC integrator is given no statement of:
(a) the allowed `hclk : pad_clk_rx` ratio band the fixed-cycle CDC stretchers assume; (b) the required
`poresetn`/`hresetn`/`phc_resetn` deassert ordering (and that `hresetn` recovery/removal is *not* STA-
checked — `set_false_path`); (c) that `pad_clk_tx` is dead until `role_locked` and therefore the two
chiplets are clock-coupled and must be reset/powered coherently. These three sentences would prevent
FM-1/FM-2/FM-4 at the source; the tests above catch them if they slip.

The RTL-consumer audit (§1.4) confirms this is not hypothetical: every chiplet fuses PHC onto AHB
(`phc_clk=hclk`, `phc_resetn=hresetn`), the POR-before-HRESET ordering is defined in exactly one
module and flattened by the wrapper's own advice and by both pair TBs, and `pad_clk_rx` is an
async peer/loopback clock force-gated around reset in every sim but swept in none. The concrete
FPGA embedding (pynq-z2 / kr260 BD) additionally runs hclk:PHY = 2:1 via a post-MMCM ÷2 with
`pad_clk_rx↔hclk` declared `set_clock_groups -asynchronous`, and HAPS drives `user_ref_clk` from a
non-buffered /8 divider. None of these embedding choices is stated as a contract for the next
integrator.
