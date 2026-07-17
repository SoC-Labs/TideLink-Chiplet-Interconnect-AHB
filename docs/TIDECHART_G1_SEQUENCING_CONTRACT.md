# TideChart ↔ TideLink election sequencing contract (closes G1/G2)

Status: **PROPOSAL** (RTL changes below are NOT applied — reference/read-only trees).
Evidence: `cocotb/tidechart_tidelink_pair/test_tc_pair_election_datamode.py` — **PASS**.
Date: 2026-07-17.

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

### 3.1 PROPOSAL diff — (a) FPGA/ASIC RTL: export a data-mode strobe

**NOT APPLIED** (shared/reference RTL). Three hunks.

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

### 3.2 PROPOSAL diff — (b) ASIC integration `nanosoc_eth_chiplet.sv`

**NOT APPLIED** (read-only reference). Gate the election on the new strobe while
leaving the d2d TX-aperture gate on `tc_link_active` untouched:

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

That single net swap at `nanosoc_eth_chiplet.sv:809` is the whole ASIC fix. The
FPGA BD fix is identical in spirit: when `tidechart_shim` is instantiated next to
`tidelink_top` in the KR260 block designs, connect its `link_active` port to the
new `tl_data_mode_o` pin of the TideLink IP, not to the IP's `link_active` pin.
(`link_active` still drives the BD's status/LED and any TX-aperture gate.)

> Note: `tidechart_shim`/`tidechart_election_fsm` need **no** change — the FSM
> already gates purely on its `link_active` input (`tidechart_election_fsm.sv:183`,
> `if (|link_active) ...`). The contract is satisfied entirely by choosing which
> TideLink signal feeds that input.

---

## 4. Test evidence

`test_tc_pair_election_datamode.py` — the sibling of the smoke test — proves the
fixed sequencing on the real pair. It:

1. **Holds** `election_start` deasserted on both dies (it simply never writes
   `TC_CTRL[0]`) until the pair is genuinely in data mode:
   `role_lock → cal_done → do_to_data_mode`, verified by **FCSM state ≥ 4 on both
   dies** (this is exactly milestone-2 of the contract; the bench reads it by
   backdoor, modelling what `tl_data_mode_o` would carry).
2. Arms both elections in data mode, 16 cycles apart. (The offset is a **bench
   artefact, not part of the contract**: `PUF_ENABLE=0` ⇒ `puf_seed=0`, and the
   two dies share one reset, so their election LFSRs step in lockstep; arming on
   the same cycle would give identical `random_id`s — a legitimate TIE. Real
   silicon never resets two dies on the same cycle; the offset models that.)
3. Monitors both dies' `tc_axis_rx` for accepted `PKT_EXT` election words.

Transcript (`TB_TOP_NO_DUMP=1 MODULE=test_tc_pair_election_datamode make`):

```
  1600ns [die_a TideChart] DEVICE_CLASS=0x0001  PORT_COUNT=2
  6840ns [bring-up] role_locked master=1 slave=1 (PASS)  link_active m=1 s=1
 10960ns [cal] SWI_LANE_STATUS M=0x440300ff S=0x440300ff  cal M=DONE S=DONE
113040ns [data-mode] FCSM state m=4 s=4 (>=4 == LL credit/data-exchange region)
113600ns [arm] both elections armed in data mode (16-cy offset)  own_random die_a=0x5d8c die_b=0xffff
162120ns [election] die_a: done=1 is_root=0 best=0x00014a16 own_rand=0x5d8c  FSM=SETTLED
162120ns [election] die_b: done=1 is_root=1 best=0x00014a16 own_rand=0x4a16  FSM=SETTLED
162120ns [crossing] PKT_EXT ELECTION words delivered  die_a.rx=1 (first=0x800100014a16)  die_b.rx=1 (first=0x800100015d8c)
   (a) SINGLE root across the two dies           : PASS (die_a root=0, die_b root=1)
   (b) PKT_EXT CLAIM crossed the real TideLink   : PASS (die_a.rx=1, die_b.rx=1)
 ** TESTS=1 PASS=1 FAIL=0 SKIP=0 **
```

Reading the evidence:

* **link_active asserts at 6.8 µs; data mode at 113 µs** — the G1 gap (~5 µs in
  sim; larger on silicon at the deployed link rate) made concrete.
* **(a) single root:** die_b wins (its `random_id 0x4a16 < 0x5d8c`); die_a settles
  `is_root=0` with an uplink toward die_b. Exactly one root. **Closes G1** — the
  identical stack that dual-rooted in the smoke test is single-root once the
  election is held to data mode.
* **(b) PKT_EXT crossed — both directions:** die_a.rx received die_b's claim
  `0x8001_0001_4a16` and die_b.rx received die_a's claim `0x8001_0001_5d8c`
  (`[47:46]=2'b10`=PKT_EXT, subtype `0x0001`=ELECTION_CLAIM). The non-root die's
  `best_claim` (`0x00014a16`) ≠ its own random (`0x5d8c`) — it demonstrably
  **adopted the peer's claim received over the link**, so the crossing is causal
  to the outcome. **Closes G2** — first proof the `tc_axis` datapath carries
  TideChart traffic end-to-end over a real TideLink pair.

---

## 5. Tapeout risk if unfixed

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
