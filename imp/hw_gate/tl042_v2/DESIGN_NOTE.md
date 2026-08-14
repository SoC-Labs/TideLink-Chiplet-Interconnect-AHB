# TL-042 fix v2 — design note (2026-08-13)

Status: **proposed, sim-proven, NOT committed, NOT benched.**
Patch: `imp/hw_gate/tl042_v2/tl042_v2_proposed.patch` (working tree left clean).
Tests: `cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_writehold.py`,
`make -C cocotb/tidelink_axi_datanode_recovery tl042v2`.

---

## 0. The headline you must read before pre-registering anything

**TL-042 v2 is NECESSARY BUT NOT SUFFICIENT for the wedge the round-2 ILA
measured.** The usual summary of that capture — "ranks 1-4 are false, so rank-5
`wr_hold_r` is the SOLE term driving `ahb_sub_hreadyout` low" — is true about mux
*priority* and false as an *implication*, because the mux **fallthrough was also
0**.

Derivation, from `imp/hw_gate/ila_tl035_run_round2/ila_capture.csv` (4096
contiguous samples, hex-parsed, `Sample in Buffer` strictly +1, `sub_stall_ctr_r`
strictly +1/clk with exactly one wrap at 65536):

| probe | value across all 4096 samples |
|---|---|
| `dbg_wr_hold_r` | 1 |
| `dbg_wr_hold_set` / `dbg_wr_hold_clr` | 0 / 0 |
| `dbg_ext_is_nonseq` / `dbg_pipe_valid_r` / `dbg_rd_pipe_r` | 0 / 0 / 0 |
| `sub_err1_r` / `sub_err2_r` | 0 / 0 |
| `sub_aw_accept` / `sub_wr_os_ctr` / `synth_b_pending` | 0 / 0 / 0 |
| `dbg_ahb_sub_hreadyout` | 0 |
| `sub_stall_ctr_r` | ramps 0..65536 (+1/clk) |
| `sub_osr_ctr_r` / `sub_osr_expired` | 0 / 0 |
| `dbg_fcsm_state`, `dbg_a2l_full`, `dbg_a2l_lnk_empty`, `dbg_fe_rx_cred` | 4, 0, 1, 31 — **the link is healthy** |

`sub_stall_ctr_r` only increments while `sub_ext_stalled = (sub_stall_fill ||
sub_stall_busy) && !sub_err1_r && !sub_err2_r`. Measured: `sub_stall_fill =
(ext_is_nonseq && !pipe_valid_r) = 0`, and `sub_err{1,2}_r = 0`. Therefore
`sub_stall_busy = !xhb_sub_hreadyout_raw` **must be 1**, i.e.

> **`xhb_sub_hreadyout_raw == 0` at the silicon wedge.**

`xhb_sub_hreadyout_raw` was *not* directly probed, so this is a derivation, not a
direct reading — but it is forced by the counter's own update equation and there
is no other branch that can make it ramp. `wr_hold_r` does not feed XHB500
(`xhb_sub_hready` is deliberately built from `pipe_valid_r` / `ext_is_nonseq` /
`xhb_sub_hreadyout_raw`, never from `ahb_sub_hready`), so the bridge stall is
**independent** of the wrapper hold, not caused by it.

Consequence: clearing `wr_hold_r` makes `ahb_sub_hreadyout` fall through to
`xhb_sub_hreadyout_raw`, which is 0. **The PS-facing bus will not come back from
this fix alone.** `test_tl042_v2_escape_with_stalled_bridge` asserts exactly that
so nobody can quietly re-acquire the optimistic reading later.

What v2 *does* buy: today the wedge is **unconditional and permanent** (only a
JTAG POR clears `wr_hold_r`); with v2 it becomes "wedged only while XHB500 is
stalled", i.e. if the bridge ever recovers, the bus recovers with it. That is a
strict improvement and it removes one of the two latches, but it is not the whole
wedge.

**This also retro-explains v1's bench result**: v1 suppressed `s_axi_bvalid` on
its own arm, so it never presented the synthetic B to XHB500 either — it could
not have lifted `raw` either. v1 was incapable of fixing the wedge *and* it broke
the data plane. Its `0/16` was pure regression, with no upside possible.

---

## 1. The bug (restated precisely)

`wr_hold_r` (TL-002, the peer-write data-phase hold) latches high and never
clears:

```
wr_hold_set = ext_is_nonseq & ahb_sub_hwrite & ~pipe_valid_r
wr_hold_clr = (s_axi_wvalid & s_axi_wready & s_axi_wlast) | synth_b_pending
```

Self-sustaining loop:

```
wr_hold_r=1 -> ahb_sub_hreadyout low -> the master's data phase never ends
            -> no AW reaches s_axi (sub_aw_accept=0) -> sub_wr_os_ctr stays 0
            -> sub_wr_stuck_fire is gated on (ctr != 0) -> synth_b_pending never arms
            -> wr_hold_clr never asserts -> wr_hold_r stays 1.  Forever.
```

`sub_stall_expired` *does* fire (the counter reaches 2^16), and arming still
cannot happen — so the `& (sub_wr_os_ctr != 0)` conjunct is the decisive blocker,
measured rather than argued. The ERROR backstop cannot substitute either: both
expiry paths are `if (sub_rd_os_r) sub_err1_r <= 1'b1`, read-only since the F-1
fix, and `sub_rd_os_r = 0` here.

---

## 2. The v2 mechanism

Three small pieces, all inside the `wr_hold` block. Nothing else in the module
changes; in particular **`synth_b_pending`, `s_axi_bvalid`, `s_axi_bresp`,
`s_axi_bid`, `sub_wr_stuck_fire` and the `ahb_sub_hreadyout` override mux are
byte-for-byte untouched.**

### 2.1 The arm — "no AW accepted SINCE this hold was set"

```systemverilog
logic aw_since_hold_r;
always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn)           aw_since_hold_r <= 1'b0;
    else if (wr_hold_set)   aw_since_hold_r <= 1'b0;   // new hold epoch
    else if (sub_aw_accept) aw_since_hold_r <= 1'b1;   // this hold's AW got out
end
wire wr_hold_starved = wr_hold_r & ~aw_since_hold_r;
```

Deliberately **not** `sub_wr_os_ctr == 0`: on the bufferable/EWR path an early B
can return that counter to 0 while `wr_hold_r` is still validly waiting for its W
beat, so a ctr-keyed arm can fire on a live write. (That is precisely what v1
did.) `aw_since_hold_r` is per-hold-**epoch**, delimited by `wr_hold_set`.

Set-priority on the clear is safe and necessary: a write's own AW-accept is
strictly **later** than its own `wr_hold_set`, because during the pipeline-fill
cycle `xhb_sub_hready` is driven low, so XHB500 cannot even take the address until
the next cycle. So the "clear wins" arm can never swallow this write's own AW; it
only discards a *previous* write's AW, which is the conservative direction.
Holds are serial by construction (the hold keeps `hreadyout` low, so the master
cannot start the next transfer), so one epoch bit is enough.

### 2.2 The age

```systemverilog
logic [SUB_OUTSTANDING_TIMEOUT_LOG2:0] wr_hold_stuck_ctr_r;
wire wr_hold_stuck_expired = wr_hold_stuck_ctr_r[SUB_OUTSTANDING_TIMEOUT_LOG2];
wire wr_hold_age_rst = wr_hold_set | ~wr_hold_starved;
```

Reused knob, no new parameter surface: `SUB_OUTSTANDING_TIMEOUT_LOG2` (default 16
= 2^16 hclk ≈ 0.65 ms @100 MHz; overridable by
`+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2`, which the GAPS_BACKSTOP suite
already uses). `wr_hold_set` is in the reset term so a fresh hold always restarts
the age even if the previous epoch had already expired.

### 2.3 The release — `wr_hold_r` ONLY, lowest priority

```systemverilog
always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn)                   wr_hold_r <= 1'b0;
    else if (wr_hold_clr)           wr_hold_r <= 1'b0;
    else if (wr_hold_set)           wr_hold_r <= 1'b1;
    else if (wr_hold_stuck_expired) wr_hold_r <= 1'b0;   // TL-042 v2
end
```

* **Not through `synth_b_pending`** (constraint 2). `synth_b_pending` is a term of
  `wr_hold_clr`, so asserting it *disables* TL-002 wholesale for as long as it is
  high — the v1 data-plane regression. v2 never touches it.
* **Not a new term in the `ahb_sub_hreadyout` override mux** (constraint 3). The
  mux is untouched; only the register feeding rank 5 changes.
* **Below `wr_hold_set`**, so a brand-new peer write always wins over a stale
  expiry. Combined with `wr_hold_set` resetting the age, there is no cycle in
  which this mechanism can suppress a legitimate hold.

### 2.4 Bench witness (the only other line touched)

`wr_hold_stuck_sticky` → `xhb_sub_obs_word[12]` → APB `0x21F8[12]` (was a
documented spare 0; `[31:24]=0xB5` marker and `[11:0]` unchanged). Without it a
bench run cannot distinguish *"the arm never fired"* from *"the arm fired and
something else still held the bus"* — which, given §0, is the decisive question.

---

## 3. Why it cannot fire on a live write

1. **Structural.** A live write's own AW-accept sets `aw_since_hold_r`, which
   clears `wr_hold_starved` and resets the age to 0. A hold whose AW got out can
   never reach the threshold, no matter how long its W beat is backpressured.
   This is exactly the case constraint 1 was written for and the case v1's
   `ctr == 0` arm got wrong.
2. **Measured.** `test_tl042_v2_live_write_is_never_released` freezes *only*
   `s_axi_wready`, so the AW is accepted and the W beat can never complete, and
   then watches for 2× the threshold:
   `aw_accepts=1  aw_since_hold_r=1  stuck_ctr_max=1  (thresh=8192)
   expired_cycles=0  sticky=0` — the age counter reaches **1** against a
   threshold of 8192, and the write then lands byte-exact (`0xa11e0042`) once W
   backpressure lifts.
3. **Margin.** For the escape to fire at all, the AW must fail to be accepted for
   2^16 consecutive hclk (~0.65 ms @100 MHz) with the hold engaged the whole
   time. On a live link an AW is accepted in tens of cycles; the shipping design
   already treats 2^16 as "this transaction is dead" for both existing backstops.

---

## 4. Sim evidence (non-vacuity A/B, md5-pinned)

RTL file: `src/rtl/tidelink_top.sv`. Suite:
`make -C cocotb/tidelink_axi_datanode_recovery tl042v2`
(`SIM_BUILD=sim_build_tl042v2`, `+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13`
so the age is 8192 hclk; `TL042_TIMEOUT_LOG2=13` matches). One test per sim —
running the module in one go inherits `test_axi_bid_corrupt_wedges_no_fix`'s
deliberately-wedged bridge.

| arm | RTL md5 | result | logs |
|---|---|---|---|
| **pristine (HEAD `d317c98`)** | `b75d391b0f659d808ac0a4cb37310643` | see §4.1 | `armA_pristine_ALL.log` |
| **v2 patch** | `2c788a0fdb1c2a228696787816f6c487` | **3/3 PASS** | `armB_patched_ALL.log` |
| **v1 rejected candidate** | see §4.3 | see §4.3 | `armC_v1candidate_ALL.log` |

### 4.1 Pristine arm — FAIL (the non-vacuity contract)

```
RTL md5 b75d391b0f659d808ac0a4cb37310643   (== HEAD d317c98)
test_tl042_v2_escape_is_clean_and_writes_still_land   FAIL
  entry: wr_hold_r=1 hreadyout=0 ctr=0 synth_b_pending=0 xhb_raw=1
         aw_since_hold_r=None      <- the net does not exist pre-fix
  escaped_at=None  expired=None  sticky=None  r5_wr_hold_r=1
  AssertionError: wr_hold_r STILL HIGH after 24576 hclk ...
```

`make tl042v2` stops at the first failure, so tests 2/3 did not run in this arm;
test 2 is post-fix-only by construction (it probes nets that pre-fix RTL lacks)
and test 3 fails at the same (a) assertion.

### 4.2 Patched arm — PASS

```
test_tl042_v2_escape_is_clean_and_writes_still_land   PASS
  entry: mode=valid_mask wr_hold_r=1 hreadyout=0 ctr=0 synth_b_pending=0
         pipe_valid_r=0 xhb_raw=1 aw_since_hold_r=0
  escape: escaped_at=8173 (thresh=8192) wr_hold_clr@escape=0
          sbp_cycles_during=0 bvalid_seen=0 expired=1 sticky=1 all-ranks=0
  post  : hreadyout=1 raw=1 synth_b_pending=0 sbp_cycles_after=0 bvalid_seen=0
  (c)   : rearmed=True early_ready=False completed=True
          rdy_cyc=3 whs_cyc=2  die_b=0x5eed0042 == expected

test_tl042_v2_live_write_is_never_released            PASS
  aw_accepts=1 aw_since_hold_r=1 stuck_ctr_max=1 (thresh=8192)
  expired_cycles=0 sticky=0 -> die_b=0xa11e0042 == expected

test_tl042_v2_escape_with_stalled_bridge              PASS
  escaped_at=8173 wr_hold_clr@escape=0 sbp_during=0 sbp_after=0 bvalid_seen=0
  all-ranks=0  raw_after=0  hreadyout_after=0   <-- the §0 scope statement
```

### 4.3 v1 candidate arm — the new test REJECTS the fix HW already rejected

This is the arm that matters most: it shows the added assertions are not just
plausible, they actually catch the candidate silicon threw out. Pristine HEAD +
`imp/hw_gate/tl042_rejected_fix/tl042_fix_REJECTED.patch` (applies cleanly to
`d317c98`), RTL md5 `b71643857ed08bf6b5b7a6e5427891fa`:

```
test_tl042_v2_escape_is_clean_and_writes_still_land   FAIL
  escaped_at=8174  wr_hold_clr@escape=1  sbp_cycles_during=2  sbp_after=1
  AssertionError: synth_b_pending was high for 2 cycles during the escape
  window — the hold was released THROUGH the signal that disables it wholesale
```

v1 *passes* (a) — it does escape — and fails (b) on two independent assertions
(`sbp_during != 0`, `wr_hold_clr@escape == 1`). That is precisely the mechanism
the bench found and the sim missed. Note that in this sim `synth_b_pending`
cleared after 1 cycle (XHB500's `bready` was high), so the "latches permanently"
part of the rejection write-up is *not* reproduced here — the data-plane damage
comes from the level-disable itself, not from the latch, and that is enough.

---

## 5. Two deadlock-entry constructions (and why both are needed)

The wrapper-visible deadlock is `wr_hold_r=1, hreadyout=0, sub_aw_accept=0,
sub_wr_os_ctr=0, synth_b_pending=0`, no W handshake possible. Two ways to build
it, differing in one measured respect:

* **`valid_mask`** — force `s_axi_awvalid` / `s_axi_wvalid` low (the XHB500 side).
  XHB500 sees ready high, believes both beats went out, and keeps
  `xhb_sub_hreadyout_raw` **high**. Measured raw=1. This is the only construction
  in which the rank-5 release can be shown to *restore service*, so the primary
  test uses it. (The v1 pre-registration claimed end-to-end resumption was not
  provable in sim; it is — with this construction.)
* **`ready_freeze`** — force `s_axi_awready` / `s_axi_wready` low (the FC-node
  side). XHB500 cannot issue the AW it accepted, drops
  `xhb_sub_hreadyout_raw` to 0 one cycle after taking the address, and **does not
  recover when the freeze is lifted** — measured with both the AW+W freeze
  (`armB_patched_escape.log`) and the AW-only freeze (`probe_awonly.log`: raw
  still 0 after 20000 cycles, payload never landed). This is the silicon-faithful
  variant per §0.

Neither reproduces silicon's *causal entry* into the state (the ILA measured the
state; its trigger is still unidentified). The fix is a state-escape, so the state
is the right thing to test — but this is **not** an end-to-end repro and must not
be described as one.

---

## 6. What could still go wrong on silicon

1. **The wedge does not lift** (most likely, per §0). `0x21F8[12]` will read 1
   (arm fired) while the PS is still hung — that is the *expected* outcome, not a
   refutation of the mechanism. Pre-register it that way. The residual is
   `xhb_sub_hreadyout_raw = 0`, i.e. XHB500 itself, and the follow-up is §6.5.
2. **One dropped payload on a genuinely dead link.** When the escape fires,
   `ahb_sub_hreadyout` follows `raw`; if `raw` is high the master ends its data
   phase and releases HWDATA, so a deferred XHB500 wdata sample could latch
   garbage — the original TL-002 drop, for that one write. It costs one write
   after 0.65 ms of total AW starvation, versus a permanent bus hang today. State
   this trade-off explicitly rather than claiming the fix is free.
3. **Threshold mis-sizing.** The escape is only safe because 2^16 is ~4 orders of
   magnitude past any legitimate AW backpressure. Do **not** shorten
   `SUB_OUTSTANDING_TIMEOUT_LOG2` in a shipping build to "make the fix respond
   faster" — at small values the arm can fire between `wr_hold_set` and the
   AW-accept of a perfectly healthy write.
4. **Obs-word decode.** `0x21F8[12]` was a spare 0. Anything that compares that
   word for exact equality (rather than masking) will see a new value once the arm
   has ever fired. `cocotb/tidelink_v2_smoke/test_tl021_obs.py` masks, and its
   "only bit[11] differs" check compares two reads in the same run, so it is
   unaffected — but re-run it before shipping.
5. **Repeated firing is benign but visible.** If the master retries and the AW
   still cannot get out, a new epoch starts and the escape fires again every
   2^16 hclk. That is a bounded periodic release, not a lockup — but
   `0x21F8[12]` will read 1 forever once it has happened once (it is sticky by
   design; POR clears it). Sample it before *and* after an injection.
6. **The real remaining defect is the ctr==0 arming hole in `sub_wr_stuck_fire`.**
   XHB500 can be stalled (`raw=0`) with nothing outstanding on `s_axi`, and in that
   state neither backstop can act: the ERROR path is read-only since F-1, and the
   synth-B arm needs `ctr != 0`. Fixing *that* is what would actually unwedge
   die_a — but it is a separate change and it is **blocked** until
   `wr_hold_clr`'s `synth_b_pending` term is converted from a LEVEL to a PULSE.
   As shipped, every peer write issued while a synth-B drain is in progress has
   **no** TL-002 protection (`wr_hold_clr` is level-asserted), which is a latent
   data-drop hole today and is exactly what v1 turned from rare into routine. Do
   that conversion first, on its own, with its own A/B — do not bundle it here.

---

## 7. Regressions on the patched RTL (md5 `2c788a0fdb1c2a228696787816f6c487`)

| suite | how | result | log |
|---|---|---|---|
| `sim_gate_axi_datanode_recovery` (10 sims + `writehold`) | `make sim_gate_axi_datanode_recovery` | **exit 0**, 10 PASS / 0 FAIL | `regress_recovery.log`, `imp/sim_gate/axi_datanode_recovery.log` |
| `sim_gate_axi_datanode_gaps` (GAP-1 nodes + GAP-2 backstop + ECC, 17 sims) | `make sim_gate_axi_datanode_gaps` | **exit 0**, 17 PASS / 0 FAIL (`[sim_gate] PASS axi_datanode_gaps (357s)`) | `regress_gaps.log`, `imp/sim_gate/axi_datanode_gaps.log` |
| TL-021 obs word (`0x21F8`) | `make -C cocotb/tidelink_v2_smoke MODULE=test_tl021_obs TESTCASE=test_tl021_ext_stall_err_obs` | **PASS**; reads `0xb5000001` / `0xb5000801` / `0xb5000001` — bit[12] is 0 at rest, so the addition is genuinely additive | `regress_tl021_obs.log` |

`writehold` (`test_write_hold_hreadyout_waits_for_w_beat`, TL-002's own original
invariant) is inside the recovery gate and passed there.

## 8. Files

```
imp/hw_gate/tl042_v2/tl042_v2_proposed.patch     the RTL diff (not applied; tree clean)
imp/hw_gate/tl042_v2/DESIGN_NOTE.md              this file
imp/hw_gate/tl042_v2/armA_pristine_ALL.log       A/B FAIL arm  (md5 b75d391b...)
imp/hw_gate/tl042_v2/armB_patched_ALL.log        A/B PASS arm  (md5 2c788a0f...)
imp/hw_gate/tl042_v2/armC_v1candidate_ALL.log    new test rejects v1 (md5 b7164385...)
imp/hw_gate/tl042_v2/armA_pristine_escape.log    first-cut A/B (earlier test revision)
imp/hw_gate/tl042_v2/armB_patched_escape.log     first-cut A/B; records the ready-freeze
                                                 bridge-wedge that motivated valid_mask
imp/hw_gate/tl042_v2/armB_patched_livewrite.log  first standalone run of the safety test
imp/hw_gate/tl042_v2/probe_awonly.log            AW-only freeze: raw=0, no recovery
imp/hw_gate/tl042_v2/probe_validmask.log         valid-mask: raw=1, full recovery
imp/hw_gate/tl042_v2/regress_*.log               regressions
cocotb/tidelink_axi_datanode_recovery/
    test_axi_datanode_writehold.py               the three v2 tests
    Makefile                                     `tl042v2` target (additive)
```

## 9. Explicitly NOT claimed

* Not benched. No HW result exists for v2.
* Not committed; `src/rtl/tidelink_top.sv` is left at HEAD in the working tree.
* Silicon's causal ENTRY into the deadlock is still unidentified. Both sim
  constructions build the STATE, not the trigger.
* `xhb_sub_hreadyout_raw == 0` at the silicon wedge is a DERIVATION from
  `sub_stall_ctr_r`'s update equation, not a direct probe reading. If a future
  ILA build probes `xhb_sub_hreadyout_raw` directly and reads 1, §0 collapses and
  v2 becomes a complete fix. That probe is one line and worth doing before any
  v2 bench build.

## 10. Appendix — raw arm results

Full stdout for each arm is in the logs listed in §8. The one-line summaries:

```
ARM A  pristine   b75d391b0f659d808ac0a4cb37310643
  test_tl042_v2_escape_is_clean_and_writes_still_land  FAIL  (a) escaped_at=None

ARM B  v2 patch   2c788a0fdb1c2a228696787816f6c487
  test_tl042_v2_escape_is_clean_and_writes_still_land  PASS  escaped_at=8173
  test_tl042_v2_live_write_is_never_released           PASS  stuck_ctr_max=1/8192
  test_tl042_v2_escape_with_stalled_bridge             PASS  raw_after=0

ARM C  v1 rejected candidate   b71643857ed08bf6b5b7a6e5427891fa
  test_tl042_v2_escape_is_clean_and_writes_still_land  FAIL  (b) sbp_during=2
```
