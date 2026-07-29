# TideLink status — hardware autonomy & sustained data (2026-07-24)

Scope: the KR260 on-chip pair (`kr260-pair-onchip`). Supersedes nothing; additive to
`docs/HANDOVER_*`. `docs/STATUS_LIVE.md` was removed by `0cf39da` (publication cleanup)
and is deliberately not resurrected here.

---

## 1. Headline

| Claim | State | Evidence |
|---|---|---|
| Sustained byte-exact data across the link | **PROVEN** | 30,500 packets (500 + 5,000 + 25,000), 0 bad, 0 stalls, 0 wedges |
| Credit-return loop closes on silicon | **PROVEN** | pair-credit accumulator rises by exactly `(len+2)` per packet |
| Bring-up lottery (on-chip vehicle) | **GONE** | `fcsm=4 cal=1` both dies from POR, stable across all polls |
| Peer-mask handshake genuinely gates | **PROVEN** (was a SHAM) | both dies `mask_hs_match=1`, `gate_open==match`, forging term deleted from RTL |
| Zero-poke hardware autonomy | **PROVEN** | `kr260_onchip_autonomy.py`: "AUTONOMY PROVEN — zero host writes" |
| Full 34-suite `sim_gate` after the fix | **NOT RUN** | deferred: Vivado was live on the host (co-scheduling OOMs) |

Final measured silicon state (`kr260-01`, build = F1+F2b):

```
die_a(mst) 0x2194=0x0019e4e4 match=1 gate=1              | fcsm=4 cal=1 locked=1
die_b(slv) 0x2194=0x00380000 match=1 gate=1 wlink_hs=0b01 | fcsm=4 cal=1 locked=1
SOAK 25000/25000 byte-exact, 0 bad, 0 stalls — link healthy after
```

---

## 2. What was wrong (the sham gate) and what fixed it

The slave die reported `mask_hs_match=0` while `gate_open=1` — a **sham handshake** that
silently voided the autonomy deliverable. Two stacked, independent defects:

**D1 — the slave had no path to a match.** The mask capture/compare FSM states are
master-only (loser branches jump straight to `ST_NEGO_DONE`), and the slave's only inbound
path — the master's I²C verdict into `0x21C` — hit a dead stub
`assign mask_hs_result_o = 2'b00;`. Confirmed on hardware that the verdict **arrived and was
discarded** (`OBS_I2C_MST_STATUS` `missed_ack=0`).
→ **F1**: the real `0x21C` verdict sniffer. It already existed in
`deps/axi-chiplet-controller/logical/wlink/Wlink.v` but was **never compiled** — the flist
resolves `` `include "Wlink.v" `` via `+incdir` to `src/rtl/local_overrides/`. An incdir-precedence
trap, not missing design. (Committed in `a69de80`, which is mislabeled — see §5.)

**D2 — the gate was forgeable.** `apb_debug_unlock_i` was OR'd into `mask_hs_gate_open`, *and*
that same strap enables slave external-APB writes to Wlink (`axi_chiplet_controller.sv:3599`).
One strap served two unrelated purposes, so the handshake could never be honest while bring-up
worked.
→ **F2b**: removed the term. `wire mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i;`
The forging path is now **gone from the RTL**, not merely strapped off.
→ **F2a**: `DEBUG_UNLOCK_DEFAULT` plumbed onto the Vivado IP face (it was welded at the RTL
default `1'b1` with the top-level pin **discarded**, so the BD's 0-strap was decorative).

Commit: **`5c85602`** (references `a69de80` for F1 traceability).

---

## 3. What was tried and rejected — and why that matters

**F3 (retire the `nego_lost_w` role_lock free pass) — IMPLEMENTED, THEN REVERTED.**
Silicon A/B, identical flow:

| build | F3 | result |
|---|---|---|
| F1 only | no | `match=1 gate=1 locked=1` **`fcsm=4`** (healthy) |
| F1 + F3 | yes | `match=1 gate=1 locked=1` **`fcsm=2`** (FC stalled) |

Without the free pass the slave latches `role_lock` **later** (waiting for the verdict);
`role_locked` gates the slave's Wlink out of reset, so it misses the training window.
**Both simulations passed it** — the v2 pair test, and `test_24`, whose own docstring
disclaims asserting downstream training. Only silicon caught it.

The integrity hole F3 closes is already closed in practice by F1, so it is redundant rather
than load-bearing. **To retire it properly:** decouple Wlink-out-of-reset from `role_lock`
*timing* (or hold the training window open until the verdict lands), then re-run the A/B.
Both paired terms (lock + pending-clear) must move together or the slave deadlocks.
Evidence and instructions are recorded in-code at those sites.

---

## 4. Why it reached silicon — the gates were blind

Three independent false-greens, all now addressed or flagged:

* `test_v2_onchip_pair.py` — the only module asserting bilateral `mask_hs_match==1` — reports
  **5 PASS at 0.00 ns simulated time**. It bails via a helper that `return`s, and cocotb 1.7.2
  has no runtime skip, so CI counts **passes, not skips**. A banner now makes that unmissable.
* `cocotb/honest_mask_hs` **asserted the defect** as expected behaviour.
* `test_24` baked the sham into its docstring ("slave gets role_lock via the `nego_lost_w` path").
* None were referenced by the root Makefile, so none gated anything.

**New blocking gate suite: `v2_mask_hs_bilateral`** (`HONEST_STRAPS=1` drives both straps to 0,
so only a genuine match can open the gate). Currently the **only executable test that can catch
a sham gate**. `tb_top.sv` gained `TB_TOP_HONEST_STRAPS` and now forwards the two parameters —
previously it hardcoded both straps to `1'b1`, so that env could never test the gate at all.

---

## 4b. Later the same day — the F3 story was re-analysed and CORRECTED

Two claims in §3 above were overstated, and the correction changed the fix:

**`role_locked` is a MUTUAL CLOCK ENABLE, not merely a reset.** `wlink_por_reset` (`:2832`) gates
this die's forwarded `pad_clk_tx` — which *is* the peer's `pad_clk_rx` — so a die that never locks
silences the **peer's entire RX clock domain** (chain verified through `Wlink.v:2071` →
`WlinkGPIOPHY_v2.v:358` → `WavD2DGpio_v2.v:1979` → `WavD2DGpioTx.v:322-341`). The two dies' lock
times are not independent variables. Nothing in Wlink or the PHY consumes the *role* at all.

**F3's real effect was stagger collapse, not lateness.** The verdict lands ~**3.1 ms** after the
free-pass lock instant (17 I²C bytes at 50 kHz). There is no ms-scale deadline anywhere (autoneg
timeout 5.24 s; `TRAIN_POLL_PEER` ~18 ms) — so the sensitive machinery is the CR/CRACK exchange,
whose own in-code fix is calibrated in *tens of link clocks*. `WlinkGenericFCSM_6.v:602-618`
documents that symmetric deadlock and names its signature `a[fcsm=4] b[fcsm=2]` — exactly what the
F3 build measured.

**A hazard F3 would have shipped.** On the I²C-NACK fallback (`nego_force_lock`, in the shipped
`NEGO_CFG=0x61`) the losing die never receives a verdict, so under F3 it never locks and
**permanently gates its own PHY clock — killing the peer's RX clock too**. A degraded-but-alive
fallback becomes a hard, bilateral, unrecoverable dead link. The free pass is what makes that
fallback work.

**Evidence caveat (correcting §3):** the F3 A/B was **N=1 vs N=1** on a vehicle with a documented
bring-up lottery. "F3 causes `fcsm=2`" is the best-fit hypothesis, **not statistically safe**.
Settling it needs per-die, per-POR attribution (`0x21A8` OBS_FCSMCAP + CR/CRACK sticky bits), ≥20
PORs across three arms including an F1-only rebuilt negative control, and a ≥25k soak.
**Simulation cannot arbitrate — sim passed the broken version.**

### Adopted instead: move the integrity boundary off the clock enable (`c179660`)

`mask_hs_verified_reg` — sticky, POR-only, set **only** by a genuine `mask_hs_match` (never
`mask_hs_bypass_i`, never `nego_lost_w`), mirrored in **`OBS_MASK_HS[23]`** — now gates entry to
autonomous **RETIRE**. This is the property F3 was reaching for, but it fails closed *recoverably
and observably* instead of by bricking a clock. Bring-up timing is untouched: `role_lock`,
`wlink_por_reset` and `autonomy_armed` all latch exactly as before. `autonomy_armed` is deliberately
**not** gated — it feeds `fch_pending`/`ws_kick` sequencing, so gating it would re-introduce a
stagger collapse.

`cocotb/honest_mask_hs` MODE=default was also **inverted**: it had been *asserting the defect*
(`gate_open==1` with `match==0`). Post-F2b the correct expectation is a closed gate, and the shipped
posture now achieves debug-unlocked **and** handshake-honest simultaneously — previously unreachable.
(That inversion was nearly missed: a stale per-mode `SIM_BUILD` dir produced a false PASS —
`rm -rf sim_build` does **not** clear `sim_build_default`.)

---

## 5. Open items

1. **ASIC APB-debug posture.** F2b is shared RTL, so the tapeout gate is honest too.
   `tidelink_dft_wrapper.sv:99 DEBUG_UNLOCK_DEFAULT=1'b1` no longer forges the gate — it now only
   leaves **APB debug unlocked** in silicon. Flipping it to 0 is **not free**: it also disables
   slave external-APB writes to Wlink (`:3599`), the same coupling that stalled FC at `fcsm=2`.
   Needs the bring-up path addressed first.
2. **`a69de80` is mislabeled** — titled "legal: add Apache-2.0 LICENSE, NOTICE and third-party
   provenance" but also contains **F1** (`Wlink.v`, +59 lines), a load-bearing silicon change
   invisible to anyone reading the log. Not rewritten (shared tree, parallel session live);
   `5c85602` cites it as partial mitigation.
3. **Full `sim_gate` (34 suites) not yet run** after the fix — Vivado was live on the host and
   co-scheduling OOMs (an OOM also mimics a regression). Individually passed: `v2_mask_hs_bilateral`,
   `dft_wrapper_elab`, `asic_v2_elab`, `test_24`, `honest_mask_hs`, `tidelink_ahb` 17/17.
4. **`farm_gate` is RED on pre-existing debt** — stale packaged IP + `sv_anti_pattern` baseline not
   updated. All four builds used `FARM_SKIP_GATE=1` (justified: the remote re-packages IP from
   current RTL). Since RTL changed, run `make package_ip` before any *local* build.
5. **TX has no hardware backpressure** — an `ahb_tx` overrun hangs the PS bus. Firmware must gate
   every write on credit. The on-chip soak does this by reading the receiver's RX room directly.

---

## 6. Caveat to carry into any autonomy claim

The slave's match is **"the master asserts we match"**, not an independent bilateral comparison —
the slave never captures a peer mask (`OBS_MASK_HS` low16 stays `0x0000`) and never runs the
comparator. A master with a corrupted view of the masks would open the slave's gate anyway.
The handshake-delivery path is now genuine; **symmetric verification is not implemented**, and any
claim should say so explicitly.

Related: the autonomy proof prints the same "AUTONOMY PROVEN" text whether or not the gate is
welded — it **cannot see a welded tie** (the `apb_debug_unlock` GPIO is a blind instrument; the pin
is discarded inside `tidelink_top`). Always confirm the **gate expression**, not just the banner.
