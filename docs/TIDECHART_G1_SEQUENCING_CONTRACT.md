# TideChart ↔ TideLink election sequencing contract (closes G1/G2)

Status: **APPLIED in the tidelink repo** (§3.1) — **NOT YET LANDED** in the chiplet
repo or the FPGA block designs (§3.2, §6: instructions for their owners).
Evidence: both `cocotb/tidechart_tidelink_pair` tests **PASS on the real RTL port**
(`tl_data_mode_o`), no longer on a testbench backdoor. See §4.
Date: 2026-07-17 (proposal) / 2026-07-19 (applied).

---

## 1. The findings this closes

The `tidechart_tidelink_pair` co-sim (first-ever TideChart-on-real-TideLink bench)
surfaced two coupled gaps in its smoke test (`test_tc_pair_smoke.py`, README G1/G2):

* **G1 — premature election ⇒ dual-root.** TideChart's election FSM is gated on
  TideLink's `link_active`. But `link_active` is tied to `role_locked`
  (`src/rtl/tidelink_top.sv:2539` — `assign link_active = role_locked_o;`).
  `role_locked` latches early in bring-up (~6.8 µs in sim), **~5 µs before** the
  Wlink link-layer reaches data mode (FCSM ≥ state 4, after `cal_done` +
  `do_to_data_mode`, ~113 µs in sim). The election therefore leaves
  `ST_WAIT_LINKS` and settles **before any CLAIM can cross the die boundary**, so
  both dies elect themselves root — a **dual-root**, the wrong outcome for a
  2-node fabric.

* **G2 — no PKT_EXT ever observed crossing.** Because elections settled
  pre-data-mode, no TideChart extension packet (`PKT_EXT`, `tdata[47:46]==2'b10`)
  was ever seen traversing tidechart→tidelink→link→tidelink→tidechart. The
  `tc_axis` datapath had never been proven end-to-end over a real link.

The ASIC integration inherits G1 verbatim: `nanosoc_eth_chiplet.sv:357`
(`assign link_active_o = tc_link_active;`) drives the **same** `tc_link_active`
net (= tidelink `link_active` = `role_locked`) into **both** the d2d TX-aperture
gate (correct use) **and** the TideChart election gate (`u_tidechart.link_active`,
`nanosoc_eth_chiplet.sv:809` — incorrect use).

---

## 2. The contract

> **TideChart's root election must be gated on "the link can carry EXT (PKT_EXT)
> traffic", NOT on "roles are locked".**

These are two distinct link milestones on TideLink, ~5 µs apart in sim:

| Milestone | TideLink meaning | Signal today | Asserts (sim) |
|---|---|---|---|
| **roles locked** | Wlink out of reset, PHY training may start | `role_locked_o` = `link_active` | ~6.8 µs |
| **data mode** | Wlink LL enabled + FC credit/data exchange running (FCSM state ≥ 4) — the link actually **carries** FC/EXT words | *(none exported)* | ~113 µs |

`role_locked` is a necessary precondition but **not** sufficient: a CLAIM injected
into `tc_axis_tx` while the LL is not yet in data mode is accepted by the local
TX handshake but never leaves the die (the FC node has no credit / LL disabled),
so the peer never hears it and both sides self-root.

The election needs the **data-mode** milestone. TideLink does not currently export
it.

### 2.1 Survey — does an existing tidelink_top output already encode data-mode?

Surveyed every candidate output on `tidelink_top`:

* `link_active` / `role_locked_o` — **too early** (this is G1's root cause).
* `tl_local_link_state_o[4:0]` = `{starve, trend[1:0], level[1:0]}` — quantised
  EWMA-credit / congestion sideband (`tidelink_top.sv:377-382`). Only *meaningful*
  once data flows, but it is **not** a clean data-mode boolean: it reads `5'b0`
  in data mode when there is no congestion, so it cannot gate election.
* `tl_link_state_change_o` — one-cycle pulse on a quantised transition; not a
  level, not data-mode.
* `tl_ewma_credit_o`, IRQs (`wlink_irq`, …) — none encode "LL in data mode".

**Conclusion: no existing top-level output encodes data-mode.** The information
*does* exist internally: `axi_chiplet_controller.sv` already synchronises the
Wlink FCSM state (`sync_obs_fcsm_state_1`, sourced from Wlink `obs_fcsm_state_o`)
and already tests `== 3'd4` for its retire-autonomy logic
(`axi_chiplet_controller.sv:4423/4428/4435`). It is exposed to software only, as
APB `0x2108[19:17]` (FCSM state). It is **not** brought out as an RTL strobe.

---

## 3. Recommended fix

Two ways to honour the contract:

* **(i) firmware/agent gate (stopgap, NOT a deliverable):** defer
  `election_start` (TideChart APB `TC_CTRL[0]`) until firmware observes FCSM
  state 4 via TideLink APB `0x2108[19:17]`. This is what the passing test models
  (it holds `election_start` until the backdoor FCSM state ≥ 4). It works, but it
  is a software recipe — it violates the standing "**hardware autonomy is
  mandatory**" requirement, and on silicon it forces every integrator to poll a
  TideLink status register before arming TideChart.

* **(ii) hardware data-mode strobe (RECOMMENDED):** TideLink exports a
  `tl_data_mode_o` level (FCSM ≥ 4); TideChart's election gate consumes it in
  place of `link_active`. Autonomous, no firmware sequencing, no new APB poll.
  The internal source already exists and is already CDC-synced.

The `tc_axis` TX-aperture gate and observability use of `link_active`/`role_locked`
are **unchanged** — `link_active` stays the coarse role-locked indicator; only the
**election** gate moves to the new data-mode strobe.

### 3.1 APPLIED — (a) FPGA/ASIC RTL: export a data-mode strobe

**APPLIED 2026-07-19.** Purely additive: one new output port per level, one new
`assign`. No existing net is re-driven, re-timed or renamed; `link_active`
(`tidelink_top.sv`) is untouched. Verified against the sim gates in §5.

**Threshold — verified, not assumed.** The FCSM's own data-region test is
`state >= 3'h4` (`WlinkGenericFCSM_6.v:737`, converse `state < 3'h4` at `:1648`).
So `>= 3'd4` is right.

**The FCSM operational region is states 4..7 — and it is CLOSED.**
(An earlier revision of this doc and of the RTL comment said "states 0..5". That
was **wrong**; states 6 and 7 exist. The logic was never affected — `>= 3'd4` is
bit `[2]` for every 3-bit value — but the stated rationale was false, so it is
corrected here.)

| State | Meaning | Exits to |
|---|---|---|
| 0..3 | reset / CR / credit init — **link not carrying** | 1,2,3,4 |
| 4 | data exchange | 4,5,6,7 |
| 5 | LINK_DATA | 4,5,6,7 |
| 6 | **SEND_ACK** (transient TX) | 4,5,7 |
| 7 | **SEND_NACK** (transient TX) | 4,7 |

Next-state chain: `:776/:768/:762` (from 4), `:790/:784/:782/:780` (from 5),
`:809/:800` (from 6), `:795` (from 7). **No arc returns from {4,5,6,7} to 0..3
short of reset.** The region is absorbing, so `tl_data_mode_o` is monotonic *by
construction* (0 → 1 once, then stable until reset) — not merely observed to be.

**Is holding the strobe through 6 and 7 correct? YES — and it is required.**

* **State 6 = SEND_ACK is routine healthy traffic.** ACKs are emitted constantly
  on a working link. A strobe that dropped on state 6 would chatter continuously
  during normal operation and repeatedly re-arm `ST_WAIT_LINKS` mid-fabric. The
  bench census confirms both dies visit state 6 while the strobe is high
  (`die_a=[4,5,6] die_b=[4,5,6]`) with zero falls.
* **State 7 = SEND_NACK is a retransmission request, not a link-down event.**
  NACK→replay is the reliable-link mechanism working as designed; the packet is
  redelivered and the FSM falls back to state 4 on `auto_tx_out_advance`
  (`:795`). The link genuinely still carries traffic, so TideChart should
  continue to believe so. Dropping the gate on a recoverable, expected event
  would be actively harmful.
* **The known state-7 wedge does not change this.** The F-1 watchdog
  (`:113-172`) documents a real failure where the master wedged in state 7 for
  ~660 µs; it self-recovers. `tl_data_mode_o` deliberately stays high through
  it: this port means *"the link layer has reached its operational region"*, it
  is **not** a liveness or health indicator. TideChart's election needs a
  one-shot release, and once the election has settled a transient wedge must not
  un-elect anything. If a link-health signal is ever needed, it should be a
  **separate** port — do not overload this one.

**Why `>= 3'd4` and NOT `== 3'd4`** (this matters, and the retire-autonomy logic
next door genuinely wants the narrower `==`): on a 3-bit state, `>= 3'd4` is
*exactly* bit `[2]`. That has two consequences, both good:

1. **Glitch-free by construction.** It is a single bit taken off the far flop of
   the existing 2-flop `apb_clk` synchroniser — a direct flop output, not a
   multi-bit comparator that could decode a partially-updated CDC word.
2. **Stable across normal operation.** The FCSM moves between states 4 and 5
   during ordinary credit/data exchange. `== 3'd4` would drop LOW on every
   4->5 step, momentarily deasserting the election gate and re-arming
   `ST_WAIT_LINKS` mid-fabric. `>= 3'd4` does not move. The bench asserts zero
   falls-after-rise on both dies (§4).

Three hunks, as landed.

**A. `src/rtl/local_overrides/axi_chiplet_controller.sv` — new output port**
(the FCSM state is already synced here as `sync_obs_fcsm_state_1`):

```diff
   output wire [31:0]  obs_status_o,          // (existing observation word)
+  // Data-mode strobe: Wlink LL is in its credit/data-exchange region and the
+  // link genuinely carries FC/EXT words. Synchronous to hclk (already CDC'd).
+  output wire         data_mode_o,
   ...
+  assign data_mode_o = (sync_obs_fcsm_state_1 >= 3'd4);
```

**B. `src/rtl/tidelink_top.sv` — new top-level output, driven from the above**
(sits alongside the congestion sideband outputs, ~`:381`):

```diff
   output wire               [4:0] tl_local_link_state_o,
   output wire                     tl_link_state_change_o,
+  // Link-carries-EXT-traffic strobe for TideChart election gating (contract:
+  // docs/TIDECHART_G1_SEQUENCING_CONTRACT.md). Distinct from link_active/
+  // role_locked, which asserts ~5us earlier at role-lock, before data mode.
+  output wire                     tl_data_mode_o,
   ...
   axi_chiplet_controller ... u_chiplet_controller (
       ...
+      .data_mode_o                (tl_data_mode_o),
       ...
   );
```

`link_active` (`tidelink_top.sv:2539`) is left exactly as is.

### 3.2 TO BE LANDED BY THEIR OWNERS — (b) ASIC integration `nanosoc_eth_chiplet.sv`

**NOT APPLIED — different repo/owner.** Line numbers below were re-verified
against `nanosoc-ethernet-chiplet/src/rtl/nanosoc_eth_chiplet.sv` on 2026-07-19
and are current. Gate the election on the new strobe while leaving the d2d
TX-aperture gate on `tc_link_active` untouched:

```diff
   wire        tc_link_active;
+  wire        tc_data_mode;      // TideLink FCSM in data-exchange region (>=4)

   // ... tidelink_top instance (~:728) ...
       .link_active            (tc_link_active),
+      .tl_data_mode_o         (tc_data_mode),

   // link_active_o export + d2d TX-aperture gate stay on tc_link_active:
   assign link_active_o   = tc_link_active;        // unchanged (:357)
       .link_active_i      (tc_link_active),        // u_d2d_decode — unchanged (:507)

   // ... tidechart_shim instance (~:809): election gate moves to data-mode ...
-      .link_active                (tc_link_active),
+      .link_active                (tc_data_mode),
```

That single net swap at `nanosoc_eth_chiplet.sv:809` is the whole ASIC fix.

**Verified line map** (`nanosoc_eth_chiplet.sv`, 2026-07-19). The chiplet
instantiates `tidelink_top` **directly** at `:598` (NOT via
`tidelink_dft_wrapper` — see §6.3):

| Line | What | Action |
|---|---|---|
| `:347` | `wire tc_link_active;` | keep; **add** `wire tc_data_mode;` |
| `:357` | `assign link_active_o = tc_link_active;` | **unchanged** |
| `:507` | `u_d2d_decode.link_active_i(tc_link_active)` | **unchanged** (TX aperture) |
| `:598` | `tidelink_top ... u_tidelink (` | instance to extend |
| `:728` | `.link_active(tc_link_active)` | keep; **add** `.tl_data_mode_o(tc_data_mode)` |
| `:796` | `tidechart_shim #(` | the election consumer |
| `:809` | `.link_active(tc_link_active)` | **CHANGE to** `.link_active(tc_data_mode)` |

**Scope note for the reviewer of that swap:** `tidechart_shim`'s single
`link_active` input fans out inside `tidechart_controller` to **three**
consumers — `u_election`, `u_enum` and `u_link_state_agent`. The one-net swap
therefore moves all three to the data-mode milestone, not just the election.
That is intended and conservative (all three want "the link can carry traffic",
and data-mode is strictly later than role-lock, so nothing is released earlier
than before). It is called out here so it is a decision, not a surprise.

### 3.3 TO BE LANDED BY THEIR OWNERS — (c) FPGA block designs (KR260)

**NOT APPLIED — `fpga/targets/*/tidelink_design.tcl` is another lane's file.**

⚠️ **Correction to the original proposal.** The proposal assumed the KR260 BD
tcls need "the same one-net swap". They do **not**, because as of 2026-07-19
**no KR260 block design instantiates `tidechart_shim` at all** (`grep -rl
tidechart fpga/targets/` returns nothing). The only `link_active` consumer in
the BD is the status LED:

```tcl
# fpga/targets/kr260-pair-ptp/tidelink_design.tcl:809
connect_bd_net [get_bd_pins tidelink_0/link_active] [get_bd_ports led0]
```

That connection is **correct as-is and must NOT be changed** — the LED means
"D2D link up / roles locked", which is exactly `link_active`.

So the FPGA work is:

1. **Re-package the IP.** `tidelink_vivado_wrapper.v` has a new output port, so
   `component.xml` must be regenerated or Vivado will not show a
   `tidelink_0/tl_data_mode_o` pin. Until that happens the pin does not exist to
   connect to. ⚠️ Watch for the known **stale-IP** failure mode (a farm
   `package_ip` can ship an old IP, and a differing bitstream md5 proves
   nothing — verify the pin exists structurally in the generated BD, e.g.
   `get_bd_pins tidelink_0/tl_data_mode_o` must return non-empty).
2. **Only when a TideChart is added to a BD**, connect that new pin to the
   shim's `link_active` input. Leave `led0` on `link_active`.

No BD change is required for the current bitstreams; this change is inert on
FPGA until a TideChart is instantiated.

> Note: `tidechart_shim`/`tidechart_election_fsm` need **no** change — the FSM
> already gates purely on its `link_active` input (`tidechart_election_fsm.sv:183`,
> `if (|link_active) ...`). The contract is satisfied entirely by choosing which
> TideLink signal feeds that input.

---

## 4. Test evidence

The bench no longer models the fix — it **consumes the real port**.
`tb_tc_pair.sv` now takes `tl_data_mode_o` off each `tidelink_top` and feeds it
to that die's `tidechart_shim.link_active`, exactly as §3.2 asks the ASIC to.
The earlier backdoor-FCSM hold in Python is **gone**.

`test_tc_pair_election_datamode.py` therefore does the *opposite* of holding: it
arms `election_start` on **both dies BEFORE data mode** — the precise condition
that used to dual-root — and requires the RTL to hold them:

```
  6840ns [G1] at role_lock: link_active m=1 s=1  BUT  tl_data_mode_o m=0 s=0
             (the two milestones are distinct — this is the whole bug)
  7400ns [arm] BOTH elections armed PRE-data-mode (the G1 trigger condition)
 11400ns [hold] armed but pre-data-mode: die_a FSM=WAIT_LINKS die_b FSM=WAIT_LINKS
117720ns [data-mode] FCSM state m=4 s=4
117720ns [released] tl_data_mode_o rose  die_a@31420ns die_b@31740ns
             (election released BY THE RTL)  own_random die_a=0x0448 die_b=0x5ff1
123840ns [glitch] tl_data_mode_o falls-after-rise  die_a=0 die_b=0
123840ns [election] die_a: done=1 is_root=1 best=0x00010448 own_rand=0x0448  FSM=SETTLED
123840ns [election] die_b: done=1 is_root=0 best=0x00010448 own_rand=0x5ff1  FSM=SETTLED
123840ns [crossing] PKT_EXT delivered  die_a.rx=1 (0x800100015ff1)  die_b.rx=1 (0x800100010448)
   election armed PRE-data-mode, HELD by the RTL : PASS (tl_data_mode_o, not a bench hack)
   (a) SINGLE root across the two dies           : PASS (die_a root=1, die_b root=0)
   (b) PKT_EXT CLAIM crossed the real TideLink   : PASS
 ** TESTS=1 PASS=1 FAIL=0 SKIP=0 **
```

`test_tc_pair_smoke.py` was re-pointed at the same port and now asserts the
**stronger** property — the election stays parked *through* role_lock and is
released only at data mode:

```
  8840ns [role_lock] link_active=1 data_mode=0  die_a election FSM = WAIT_LINKS
  8840ns G1 HELD: election still parked at role_lock — gate is data-mode, not role-locked.
 75040ns [data mode] data_mode=1  die_a election FSM = SETTLED
 75040ns CROSS-BOUNDARY PROVEN: election advanced ONLY after tl_data_mode_o (and NOT at role_lock)
 81460ns [election] die_a: done=1 is_root=1  die_b: done=1 is_root=0
 ** TESTS=1 PASS=1 FAIL=0 SKIP=0 **
```

Note the smoke test's own stretch line now reports **one root** (die_a=1,
die_b=0) where it previously dual-rooted — G1 closing as a side effect, in the
very test that first exposed it.

Reading the evidence:

* **link_active asserts at 6.8 µs; data mode at ~31 µs** — measured off the real
  port, and the gap is far larger than the ~5 µs originally estimated from FCSM
  readback.
* **The hold is hardware.** Both FSMs sat in `ST_WAIT_LINKS` at 11.4 µs while
  armed and while `link_active=1`. No firmware, no bench poll.
* **Glitch-free:** zero falls-after-rise on either die across the whole run.
* **Desymmetrisation is now natural, not a bench artefact.** The two dies reach
  data mode 320 ns apart (31420 vs 31740 ns), so they sample distinct
  `random_id`s (0x0448 vs 0x5ff1) on their own. Under the RTL gate the WAIT_LINKS
  exit cycle is set by `tl_data_mode_o`, **not** by when `election_start` was
  written, so the old 16-cycle arming offset no longer desymmetrises anything —
  it is retained only to keep the two APB writes from contending. The real
  master/slave asymmetry does the work.
* **(a)/(b) unchanged in substance:** exactly one root, and the non-root die's
  `best_claim` ≠ its own random, so it demonstrably adopted a claim received
  over the link — the crossing is causal to the outcome.

**Closes G1** (the identical stack that dual-rooted is single-root once the
election is held to data mode — now held by RTL) and **G2** (first proof the
`tc_axis` datapath carries TideChart traffic end-to-end over a real TideLink
pair, in both directions).

---

## 5. No-regression evidence

Run individually on the applied change (`source ./set_env.sh`,
`TIDELINK_PHY_V2=1`):

| Gate | Result |
|---|---|
| `sim_gate_retire_plumb` | **PASS** (291 s) |
| `sim_gate_tc_smoke` | **PASS** (22 s) |
| `sim_gate_tc_election` | **PASS** (7 s) |
| `sim_gate_v2_data` | **PASS** (19 s) |
| `sim_gate_v1elab` | **PASS** (24 s) |
| `sim_gate_asicelab_v2` | **PASS** (14 s) |

`retire_plumb` is the one that mattered: the retire-autonomy logic taps the
*same* `sync_obs_fcsm_state_1` register (`axi_chiplet_controller.sv:4423/4428/
4435`) with the narrower `== 3'd4`. The new export **reads** that register and
drives nothing into it, so retire autonomy is untouched — confirmed by the gate.

`v1elab` matters too: `sync_obs_fcsm_state_1` is declared and driven
**unconditionally** (outside `\`ifdef TIDELINK_PHY_V2`), so the new port is valid
in V1 builds as well as V2.

---

## 6. Landing checklist / gotchas for the other owners

**6.1 Order.** The chiplet swap (§3.2) depends only on the tidelink RTL, which is
applied. It can land immediately.

**6.2 Unconnected is safe.** Every other `tidelink_top` instantiator (≈20
benches) uses named port connections and simply leaves the new output
unconnected — legal, injects no X, and harmless. No other bench needed a change.

**6.3 `tidelink_dft_wrapper.sv` — FIXED (was finding F7).**
`src/rtl/asic/tidelink_dft_wrapper.sv` forwards `link_active`, `d2d_reset_o`,
`role_locked_o`, `tl_local_link_state_o` but originally had **no**
`tl_data_mode_o`, so the G1 fix reached the FPGA path only — the wrong half of
the design for a tapeout review. Now applied: new output port + `.tl_data_mode_o
(tl_data_mode_o)` on the `tidelink_top` instantiation. Passthrough is direct,
matching local convention (`any_test_mode` feeds only `.scan_mode`; no status
output is test-gated).

> ⚠️ **Coverage gap found while fixing this: `tidelink_dft_wrapper.sv` is in NO
> flist** (`grep -rl tidelink_dft_wrapper flists/` is empty) and no `sim_gate`
> elaborates it — both `sim_gate_asicelab*` gates run `-top tidelink_top`. So
> nothing in CI would have caught the missing port, and nothing will catch the
> next one. It was verified here by hand:
> ```
> vcs -full64 -sverilog -f flists/tidelink_top_full_asic_v2.flist \
>     src/rtl/asic/tidelink_dft_wrapper.sv syn/asic/sim_stubs/rf_16k_stub.v \
>     -top tidelink_dft_wrapper        # => rc 0, 78 modules
> ```
> **Recommend adding a `sim_gate_dftelab` doing exactly that.** Owner: whoever
> owns the Makefile/flists (not this lane).

**6.5 Corrected comment text for `axi_chiplet_controller.sv` (finding F8).**
The applied port comment contains one false sentence — "FCSM states are 0..5" —
which must be corrected in place (lane B1 owns that file; this lane did not
edit it). Replace:

```
    // FCSM states are 0..5; 4 and 5 are the data-exchange region (see
    // WlinkGenericFCSM_6.v `state >= 3'h4`), so bit[2] is the exact predicate.
```

with:

```
    // The FCSM's operational region is states 4..7 (4=data exchange,
    // 5=LINK_DATA, 6=SEND_ACK, 7=SEND_NACK); 0..3 are reset/CR/credit init.
    // That region is CLOSED — no arc returns to 0..3 short of reset — so
    // bit[2] is exactly "the LL has reached its operational region", and it is
    // monotonic by construction. Holding through 6/7 is INTENDED: SEND_ACK is
    // routine healthy traffic and SEND_NACK is a retransmission request, not a
    // link-down event. This port is NOT a link-health/liveness signal; if one
    // is ever needed it must be a separate port.
    // See docs/TIDECHART_G1_SEQUENCING_CONTRACT.md §3.1.
```

**6.4 The FPGA IP must be re-packaged** before the pin is connectable — see §3.3.

---

## 7. Tapeout risk if unfixed

**Dual-root is a silent, post-tapeout, multi-die connectivity failure.**

TideChart's root election chooses the fabric's spanning-tree root; enumeration
(`enum_fsm`) then DFS-walks from the root to assign IDs and install `route_table`
uplink/downlink ports. With two roots:

* Neither chiplet installs an uplink toward the other (each thinks it *is* the
  root, so `uplink_valid=0` on both). The spanning tree never spans the die
  boundary.
* DFS enumeration cannot cross the boundary ⇒ the peer chiplet's ports are never
  enumerated; `route_table` has **no route** to them.
* Every TideChart-managed cross-chiplet operation — enumeration, route lookup,
  congestion/link-state broadcast coordination, any future management/debug fan-out
  — is misrouted or dropped. In a 2-chiplet Ethernet fabric this means the second
  chiplet's MAC ports are **unreachable and unmanaged**.

The failure is **invisible in single-die bring-up and in any test that arms
election before data mode** (it "passes" as `is_root=1`). It first appears only
when two real dies are wired together and expected to form one fabric — i.e. at
multi-chiplet bring-up, after tapeout, where an RTL fix costs a respin. Gate the
election on the data-mode strobe (§3) before committing the multi-die integration.
```


## IMPLEMENTED 2026-07-19 (lane B3) — on real RTL, both proofs now run off the hardware port
**RTL, purely additive (3 hunks):** `local_overrides/axi_chiplet_controller.sv` gains `data_mode_o`
= `sync_obs_fcsm_state_1[2]`; `tidelink_top.sv` gains `tl_data_mode_o`; the FPGA IP wrapper forwards
it. **`link_active` untouched.**
**Threshold CONFIRMED not assumed:** FCSM states are 0-5 and its own data-region test is
`state >= 3'h4` (`WlinkGenericFCSM_6.v:737`, converse `:1648`).
**Glitch-free for a structural reason:** on a 3-bit state, `>= 3'd4` IS bit `[2]` — a single bit off
the far flop of the existing 2-flop `apb_clk` synchroniser, so there is no multi-bit decode across a
partially-updated CDC word. It is also **stable across FCSM 4<->5**, whereas the retire logic's
`== 3'd4` would drop low on every 4->5 step and re-arm `ST_WAIT_LINKS` mid-fabric. Bench monitor
asserts zero falls-after-rise: **0 on both dies.**
**Stronger proof than before:** the test now ARMS BOTH DIES PRE-DATA-MODE (the exact condition that
used to dual-root) and requires the RTL to hold them — parked in `WAIT_LINKS` at 11.4us while armed
with `link_active=1`, released at data mode, single root, PKT_EXT crossing both ways. The Python
backdoor-FCSM hold is GONE.
**Measured:** `link_active` @6.84us vs `tl_data_mode_o` @31.42us — the gap is **much larger than the
~5us this doc estimated**. The dies reach data mode **320 ns apart naturally**, so `random_id`s
desymmetrise on their own; the old 16-cycle arming offset is now **vestigial** under an RTL gate.
**No regression:** `retire_plumb` PASS (the export only READS the signal), plus tc_smoke,
tc_election, v2_data, v1elab, asicelab_v2. V1 elab passing confirms the source register is outside
`` `ifdef TIDELINK_PHY_V2 ``.

### ⚠️ THREE CORRECTIONS TO THE PLAN OF RECORD
1. **The "one-net swap" moves THREE consumers, not one** — `u_election`, `u_enum` and
   `u_link_state_agent` all share the shim's single `link_active`. Intended and conservative
   (data-mode is strictly later) but it must be **a decision, not a surprise**.
2. 🔴 **The FPGA BD premise was WRONG: no KR260 BD instantiates `tidechart_shim` at all**, so there
   is no net to swap. The only `link_active` use is `led0`, correct as-is. The real FPGA work is
   **re-packaging the IP so the pin exists** — and verify it structurally
   (`get_bd_pins tidelink_0/tl_data_mode_o`), given the known stale-IP trap.
3. ⚠️ **`tidelink_dft_wrapper.sv` does NOT forward the new port.** Harmless today (the chiplet
   instantiates `tidelink_top` directly, `:598`) but **if the ethernet chiplet is ever re-routed
   through the DFT wrapper the strobe is silently lost and G1 RETURNS.**
### Chiplet edit (verified line map, NOT applied)
Add `wire tc_data_mode`; add `.tl_data_mode_o(tc_data_mode)` at `:728`; change **only** `:809` to
`tc_data_mode`. Leave `:357` and `:507` on `tc_link_active`.
### Unrelated latent issue spotted in-file
`src/rtl/tidelink_top.sv` has a **pre-existing duplicate `wire ext_stalled`** (now :850 and :1322;
in HEAD at :829/:1301). VCS elaborates and all gates pass, but it looks like a genuine latent
collision worth a separate look.

## POST-REVIEW (2026-07-19) — F7 applied, F8 answered
**F7 APPLIED:** `src/rtl/asic/tidelink_dft_wrapper.sv` now declares `tl_data_mode_o` and connects it
at the `tidelink_top` instantiation, so the G1 fix reaches the ASIC top.
🔴 **GATE HOLE FOUND WHILE FIXING IT: `tidelink_dft_wrapper.sv` IS IN NO FLIST AT ALL**
(`grep -rl tidelink_dft_wrapper flists/` is empty) **and neither ASIC gate elaborates it** — both
`sim_gate_asicelab*` run `-top tidelink_top`. So **nothing in CI would have caught the missing port,
and nothing will catch the next one.** Verified the fix by hand instead (`-top tidelink_dft_wrapper`
against the ASIC V2 flist → rc 0, 78 modules). **RECOMMEND a `sim_gate_dftelab`.** Note this also
means F7's practical blast radius today is smaller than "HIGH" implies — the wrapper is not in the
current tapeout build path — but the fix is right regardless, and the ungated-top question needs an
owner: *if the DFT wrapper is the intended ASIC top, why is it in no flist; if it is not, what is it for?*
### F8 ANSWERED: behaviour CORRECT, the comment was FALSE
**States 6 and 7 exist: 6 = SEND_ACK, 7 = SEND_NACK** (`WlinkGenericFCSM_6.v:768`, `:776`; the F-1
watchdog header names state 7 SEND_NACK).
- **The region {4,5,6,7} is CLOSED** — 4→{4,5,6,7}, 5→{4,5,6,7}, 6→{4,5,7}, 7→{4,7}; **no arc returns
  to 0-3 short of reset** ⇒ `tl_data_mode_o` is **monotonic BY CONSTRUCTION**, not merely observed.
- **State 6 is routine healthy traffic** (ACKs fire constantly); a strobe that dropped on SEND_ACK
  would chatter and re-arm `ST_WAIT_LINKS` mid-fabric. Bench FCSM census: both dies visit **[4,5,6]**
  while the strobe is high, **zero falls** — the open question is now measured fact.
- **State 7 is a retransmission request, not link-down** — NACK→replay is the reliable-link mechanism
  working; the FSM returns to 4 on `auto_tx_out_advance` (`:795`). Dropping the gate on a recoverable
  expected event would be actively harmful.
- ⚠️ **DESIGN STATEMENT, do not overload this port later:** `tl_data_mode_o` means *"the LL reached
  its operational region"*. It is **NOT a liveness/health indicator** and deliberately stays high
  through the documented state-7 wedge — election needs a one-shot release, and a transient wedge
  must not un-elect a settled fabric. **If a link-health signal is ever wanted it must be a SEPARATE
  port.**
⚠️ Also seen: `v1elab`/`asicelab` FAILED on first run with `getcwd: cannot access parent directories`
and a missing `simv.daidir` — **a stale/colliding build dir from concurrent lanes, not a port error**;
both pass after `rm -rf` of the build dirs. Same class as the known co-scheduling hazard.