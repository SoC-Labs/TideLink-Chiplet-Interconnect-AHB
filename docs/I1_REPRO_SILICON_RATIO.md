# I1 async/cold sim repro of the FCSM-override d2d bring-up regression

Branch: `sim/i1-repro-silicon-ratio`
Env:    `cocotb/tidelink_fcsm_silicon_ratio` (test `test_i1_async_cold.py`)
Date:   2026-07-30

## Objective

Reproduce, **in RTL simulation**, the I1 silicon failure in which re-pointing the
five AXI flow-control nodes (`WlinkGenericFCSM{,_1..4}`) from the recovery-stripped
`deps/` copies to the recovery-capable `src/rtl/local_overrides/` copies regresses
die-to-die bring-up:

    SWI_LANE_STATUS = 0x00100000   (cal_done=0, cr_seen=0, fcsm=0, lane_locked=0x00) — BOTH dies

No prior sim reproduced it. The existing `tidelink_fcsm_silicon_ratio` env comes up
**cr=1 GREEN** with the override because it (a) forces the calibrator bypass
`tb_early_exit_force_q`, (b) runs both dies off ONE shared `ref_clk`, and (c) models
"marginal link" with an artificial periodic LL re-bring-up. The task hypothesis:
a genuine **async (two-oscillator) + cold (no bypass)** bring-up is the missing
instrument.

## What the instrument adds (all opt-in; legacy targets unchanged)

* **Split clock** (`tb_top.sv`): a second PHY reference `ref_clk_s` for the slave
  die, driven by cocotb with `I1_REF_PPM` ppm / `I1_REF_PHASE_PS` phase offset, gated
  by `+define+TB_TOP_SPLIT_REFCLK`. Confirmed via RTL trace (see below) that this makes
  the two dies' `io_tx_clk` (= `user_ref_clk`/16) and forwarded pad clocks genuinely
  asynchronous — the PHY is source-synchronous with **no shared PLL**, so each die's RX
  domain is slaved to the *peer's* forwarded clock.
* **Cold bring-up**: no `tb_early_exit_force_q`. cal walks the true
  sweep → S_HOLD → `cr_pkt_seen`-gated S_VALIDATE path. `+define+TB_TOP_CAL_FAST`
  shrinks only the S_HOLD / S_VALIDATE *windows* (defparam `HOLD_CYCLES`,
  `VALIDATION_TIMEOUT`); `DWELL_CYCLES` / `LOCK_THRESH` are untouched so the eye sweep
  and the cr gate stay fully armed.
* **POR stagger** (`I1_POR_STAGGER_HCLK`): holds the slave in reset past the master's
  release via the existing `s_por_gate` (deploy-skew emulation).
* **SKID** (`SKID=`): compile-time bit-level RX capture-phase skew.
* **FCSM source select** (`gen_flist.sh`, `FCSM_SRC=`): `override` (shipping I1),
  `deps` (recovery-stripped baseline), `emitfix` (the refuted e79a5b8 emit-gate fix).
  **FCSM_6 (the sideband node) is `local_overrides` in ALL three variants** — only the
  five AXI nodes are the controlled variable.

**Oracle** (matches the silicon RTL exactly): the sticky sideband latch
`tl2wl.wlink_tidelinktl.cr_pkt_seen_rx` (= SWI_LANE_STATUS bit[23]) on BOTH dies, plus
the SWI_LANE_STATUS 4-tuple. GREEN ⟺ `cr_pkt_seen_rx==1` on both dies.
(`VAL_TIMEOUT_TO_DONE=1` in the shipping wrapper means `cal_done` times out to DONE
regardless, so `cr_pkt_seen_rx` — not `cal_done` — is the load-bearing oracle.)

## RESULT: no faithful RED. The override does NOT regress `cr_seen` in RTL sim.

### Instrument-trust gate

| # | config | knobs | verdict |
|---|--------|-------|---------|
| (d) positive control | `override`, **sync** | ppm=0 | **GREEN** — cr=1 both, cr_first @50 hclk. TB *can* read cr=1. |
| (a) deps baseline | `deps`, async | ppm=400, stg=300 | **GREEN** — cr=1 both |
| (b) override (RED candidate) | `override`, async | ppm=400, stg=300 | **GREEN** (expected RED — NOT reproduced) |
| (c) refuted emit-gate fix | `emitfix`, async | ppm=400, stg=300 | **GREEN** (moot: (b) is not RED) |

The two gates that MUST hold for the instrument to be trustworthy — (d) positive
control GREEN and (a) deps GREEN — both hold, so the harness is **not blind / not
stuck-green** (it brings a real cold+async link up and reads cr=1). But the RED the
task sought (b) did not appear.

### Async ladder (deps vs override, both dies) — `cr_seen` never regresses

| ppm | stagger | deps | override |
|-----|---------|------|----------|
| 400    | 300  | GREEN | GREEN |
| 2 000  | 300  | GREEN | GREEN |
| 8 000  | 300  | GREEN | GREEN |
| 20 000 | 1000 | GREEN | GREEN |
| 50 000 | 2000 | GREEN | GREEN |
| 100 000| 5000 | GREEN | GREEN |

Even a **10 %** frequency offset (ppm=100 000) between the dies brings the link up
cr=1 on both, for both FCSM sources. The source-synchronous PHY tolerates the offset
(the forwarded clock carries the data) and the sticky `cr_pkt_seen_rx` latch — which
has **no deadline** — always catches the sideband CR.

Adding capture-phase skew on top (override, async ppm=8000) does not flip it either —
the V2 calibrator's bit-slip + epoch-anchor deskew absorbs a uniform per-lane delay
right up to a full word:

| SKID (bits) | override, async | note |
|-------------|-----------------|------|
| 7  | GREEN (cr=1) | cal takes longer (sim 5.7 ms) but converges |
| 15 | GREEN (cr=1) | ≈ a full 16-bit word of skew, still absorbed |

A `cr_seen=0` RED would require actually killing the RX decode (differential per-lane
skew / a stuck lane) — a PHY-level break that is **identical across deps/override** and
therefore still cannot single out the FCSM footprint.

### Mechanism probe (ppm=8000) — the panel's premise is confirmed, its conclusion refuted

Router (`WlinkTxRouter`, fair round-robin) grant counts over a 20 000-hclk data-mode
window, and sideband CR-emit / RX-decode timing:

| | ch0 | ch1 | ch2 | ch3 | ch4 | ch5 | **ch6** | total | ch6 share | ch6 CR-emit first | RX CR-decode first | cr_seen |
|--|--|--|--|--|--|--|--|--|--|--|--|--|
| **deps**   m | 7 | 7 | 7 | 5 | 7 | 7 | **38** | 78  | 48.7 % | — | 399934 ns | 1 |
| **deps**   s | 4 | 4 | 4 | 3 | 3 | 3 | **74** | 95  | 77.9 % | 396063 ns | 396760 ns | 1 |
| **override** m | 38 | 38 | 38 | 37 | 38 | 7 | **43** | 239 | 18.0 % | — | 399934 ns | 1 |
| **override** s | 43 | 43 | 43 | 42 | 42 | 3 | **73** | 289 | 25.3 % | 396063 ns | 396760 ns | 1 |

* **Panel premise CONFIRMED**: the override's L6/L7 HOLD makes the five AXI nodes
  (ch0-4) emit ~**6× more** (38 vs ~6 grants each on the master; 43 vs ~4 on the slave).
  They stay in state 1/2 longer and consume many more arbiter grants, exactly as the L6
  hypothesis predicts.
* **Panel conclusion REFUTED**: this does **not** starve the sideband. ch6's **absolute**
  grant count is essentially unchanged (38→43 master, 74→73 slave); only its *percentage*
  share drops (48→18 %, 78→25 %) because the AXI emits inflate the total. The
  round-robin is work-conserving — extra AXI requests never steal ch6's turns — and the
  sideband CR-emit and RX-decode times are **bit-identical** between deps and override
  (slave ch6 first CR-emit @396063 ns; RX first decode @396760 ns; master RX @399934 ns
  in BOTH). `cr_pkt_seen_rx=1` in every case.

## Why no async condition can flip it (structural argument, corroborated by the probe)

1. **The differentiator is downstream of, and orthogonal to, the cr path.** `cr_seen`
   is produced by the sideband node `WlinkGenericFCSM_6` (ch6), which is `local_overrides`
   in ALL variants. The five AXI nodes (ch0-4) are the only thing that changes; their
   extra ~65-reg / +7-`io_tx_clk`-stage footprint lives on separate router channels and
   never gates ch6's emit or the peer's RX decode.
2. **A fair round-robin cannot permanently starve ch6** (probe: 18-78 % share, never 0).
3. **`cr_pkt_seen_rx` is a sticky latch with no deadline** (clears only on full POR), so
   any single decoded sideband CR sets it forever. The only way to keep it 0 is for the
   peer to decode *zero* CR packets — a PHY/decode failure, not an FCSM-footprint effect
   (and any such failure is symmetric across deps/override).
4. **If anything the override HELPS**: its longer state-1 HOLD makes the sideband (which
   also carries the L6 gate) emit *more* CR, not fewer.

The one place a deadline exists — the calibrator S_VALIDATE window — is a hard
*circular* deadlock for BOTH sources when `VAL_TIMEOUT_TO_DONE=0` (lltx is gated by
`calibration_done`, so no CR can cross during S_VALIDATE); with the shipping
`VAL_TIMEOUT_TO_DONE=1` it times out to DONE for both. Neither produces an
override-vs-deps split.

## Interpretation

The silicon signature `cr=0 / cal=0 / fcsm=0` is a **cal-cascade**: `cal_done=0`
→ lltx disabled → sideband FCSM parked in IDLE (fcsm=0) → no CR → `cr_seen=0`. The
root is `cal_done=0`, and the AXI-FCSM override sits **downstream** of the calibrator —
it cannot force `cal_done=0` in RTL. This RTL evidence is consistent with the
`e79a5b8` commit's own conclusion that the byte-identical I1/v1/v2 silicon signature is
"the signature of a **stale packaged IP**" (the eth-chiplet FPGA build imports an
IP-XACT copy with `FPGA_SKIP_IP_VERIFY=1`; the edited RTL most likely never reached the
netlist) — i.e. a **build/packaging** regression, not an RTL bug, which by definition an
RTL sim cannot reproduce.

This is exactly the trap the trust gate guards against: the refuted emit-gate fix
(`e79a5b8`) greened *its own* sim by attacking the emit gate, but silicon stayed RED
because the emit gate is not the cause. The present instrument, driven by physical
async instead of an artificial re-bring-up, **declines to manufacture that false RED** —
deps, override and emitfix all stay GREEN — which is the honest outcome.

## Workarounds (against the RED that did not appear)

* **revert-to-deps**: GREEN (trivially — deps is GREEN at every point).
* No mechanism-relevant RTL workaround is warranted: there is no RTL RED to fix. The
  next step is a **build/packaging** check (re-`package_eth_chiplet_ip` with
  `TIDELINK_PHY_V2=1`, diff `imp/fpga/eth_chiplet_ip/src/WlinkGenericFCSM*.v` against the
  edited source, confirm `VAL_TIMEOUT_TO_DONE=1` is in the netlist), per
  `docs/I1_FCSM_ROOTCAUSE_AND_FIX.md`.

## Reproduce

    source ./set_env.sh ; export TIDELINK_PHY_V2=1 ; export PATH=$VCS_HOME/bin:$PATH
    cd cocotb/tidelink_fcsm_silicon_ratio
    make i1_poscontrol            # (d) GREEN — TB can read cr=1
    make i1_deps                  # (a) GREEN
    make i1_override              # (b) GREEN (the sought RED does NOT appear)
    make i1_emitfix               # (c) GREEN
    # ladder / probe:
    make i1_override I1_PPM=100000 I1_STAGGER=5000
    make FCSM_SRC=override SPLIT_REFCLK=1 CAL_FAST=1 I1_REF_PPM=8000 \
         MODULE=test_i1_async_cold TESTCASE=test_i1_mechanism_probe SIM_BUILD=sim_build_probe
