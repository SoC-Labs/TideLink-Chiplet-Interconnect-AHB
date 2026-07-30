# I1 FCSM bring-up regression — change-bisection & feature-ablation plan

**Scope:** analysis + sim only. No hardware, no FPGA build, no push. Produced on
branch `analysis/i1-bisect-ablation`.

**Symptom (silicon-established, 07-30):** re-pointing the 5 AXI FC nodes
(`WlinkGenericFCSM{,_1,_2,_3,_4}`) from `deps/` to `src/rtl/local_overrides/`
(commit `b98b944`, flist `flists/tidelink_fpga_v2.flist`) bricks d2d bring-up on the
KR260 eth-chiplet pair: `SWI_LANE_STATUS=0x00100000`, `cr_seen=0 crack_seen=0
cal_done=0 fcsm=0`, **both dies**. `deps/` (recovery-stripped) brings up `fcsm=4`.
The sideband node `WlinkGenericFCSM_6.v` and the `deps/` AXI nodes both bring up.

**Two silicon ablations already falsified** (per
`nanosoc-ethernet-chiplet/docs/I1_FCSM_BRINGUP_REGRESSION.md`):
- **v1** (`0853c4c`): ungate the state-1/2 emit gates until first LINK_DATA — link still down.
- **v2** (`6d85c68`): flip the AXI `disable_crc` reset default `1'h1`→`1'h0` (CRC-on) — link still down.

The branch is linear (`90fe6cc → 0853c4c → 6d85c68`), so v2 most likely **stacks on**
v1 ⇒ the combined {gate-ungated + CRC-on} ablation also failed with the identical
signature. (Could not confirm ancestry — those commits are not fetched into this clone.)

---

## Ground facts established during this analysis

**FC state encoding** (`axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala:38-44,571,578`):
`0=IDLE, 1=SEND_CREDITS1 (CR emit), 2=SEND_CREDITS2 (CRACK emit), 3=LINK_EN_WAIT,
4=LINK_IDLE, 5=LINK_DATA, 6=SEND_ACK, 7=SEND_NACK`.

**Emit datapath** (`FC.scala:444-489`): `IDLE→SEND_CREDITS1` is gated only by `en_ff2_tx`
(unchanged by the override). In `SEND_CREDITS1` the node drives `sop=1, data_id=cr_id,
word_count={credits}` on every `ll_tx.advance`; it moves to `SEND_CREDITS2` on first peer
CR/CRACK-seen. So a node **does** emit CR in state 1 regardless of the recovery gate.

**Shared link** (`WlinkTxRouter.v:2-59`): 6 channels (`auto_in_0..5`; the 5 AXI FC nodes +
sideband) are muxed onto ONE serial link. Arbitration is by **`auto_in_N_sop`** against
`curr_ch_reg` (priority/round-robin) — a channel "requests" the link by asserting `sop`.
RX is broadcast (`WlinkRxRouter.v`). **`cr_seen`/`crack_seen` are the PEER-latched CR/CRACK
detects.** So `cr_seen=0` means the peer's RX byte-aligner never latched our CR — not
necessarily that we failed to drive it.

**Node homogeneity:** `WlinkGenericFCSM_1..4.v` are byte-size-identical to `_0` (1311 lines,
`disable_crc<=1'h1` at line 713 in each). The 5 AXI nodes share one diff surface; there is
no per-node quirk to bisect.

**Sideband is the control:** `WlinkGenericFCSM_6.v` (works) carries the **same 32/32 gate
logic** (`_6.v:189,192,604,620`) AND `disable_crc<=1'h0` (`_6.v:1194`). The `deps/` AXI nodes
(work) also have `disable_crc<=1'h0` (`deps/.../WlinkGenericFCSM.v:636`). The ONLY thing that
is `disable_crc<=1'h1` is the broken AXI override — but v2 already falsified that.

**Structural delta:** override `_0` adds **+7 `always @(posedge io_tx_clk)` blocks** (14→21)
and ~65 new `socl_*` register references, all in the TX-clock domain that feeds the router /
serializer. `deps/` has none of these.

---

## (a) Ranked diff surface — feature → added constructs → touches states 0-3 emit?

All line numbers are `src/rtl/local_overrides/WlinkGenericFCSM.v` unless noted. Ranked by
plausibility of touching TX-enable / CR-emit / `auto_out` `sop` in states 0-3 at reset.

### Rank 1 — Feature B: min-CR-emit gate (state 1) — TOUCHES states 0-3: **YES (state 1)**
- `localparam SOCL_L6_MIN_CR_EMITS = 8'd32` (**:64**)
- `reg socl_l6_cr_emit_count` + counter always-block (**:819-827**; increments on
  `auto_tx_out_advance & sop` while `state==1`, cleared otherwise)
- `wire socl_l6_cr_emit_gate_ok` (**:288**)
- **`_GEN_34`** state-1→2 exit gated: `(crack|cr seen) & socl_l6_cr_emit_gate_ok` (**:312-313**)
  vs deps "leave on first peer CR/CRACK-seen" (`deps:244`)
- state-1 `data_id` mux gated on `socl_l6_cr_emit_gate_ok` (**:865**)
- **Effect:** holds state 1 until 32 of THIS node's own CR emits. Directly changes when
  state 1 exits and what it drives. **Silicon status: ELIMINATED individually (v1).**

### Rank 2 — CRC-default flip — TOUCHES states 0-3: **YES (CR/CRACK packet format from t=0)**
- `out_prepend_swi_disable_crc <= 1'h1` (**:713**) vs deps `1'h0` (`deps:636`); sideband `1'h0` (`_6.v:1194`)
- **Effect:** CR/CRACK packets emitted CRC-off from reset. Only construct that differs
  between every WORKING config (deps AXI=0, sideband=0) and the broken one (override AXI=1).
  **Silicon status: ELIMINATED individually (v2).**

### Rank 3 — Feature C: min-CRACK-emit gate (state 2) — TOUCHES states 0-3: **PARTIAL (state 2 only)**
- `` `define SOCL_L7_MIN_CRACK_EMITS_VAL 8 `` (**:75-76**), `localparam SOCL_L7_MIN_CRACK_EMITS` (**:78**)
- `reg socl_l7_crack_emit_count` + counter (**:830-836**)
- `wire socl_l7_crack_emit_gate_ok` (**:291**), `wire socl_l7_crack_release` (**:292**)
- `_GEN_40/41/42/44/45` state-2 exit + CRACK-emit content gated on `crack_release` (**:316-321**)
- **Effect:** acts only in state 2, i.e. **after** the `cr_seen=0` failure point (the link
  never reaches state 2). Cannot explain `cr_seen` never flickering. This is the threshold
  I1 lowered 32→8; also covered by v1's ungate. **Near-certainly innocent for THIS symptom.**

### Rank 4 — Feature A: bring-up-forgive + `isNotExpPacket` mask — TOUCHES states 0-3: **NO (inert at cr_seen=0)**
- `reg socl_l7_reached_link_data` set at `state==5` (**:1000-1004**)
- `wire socl_l7_bringup_forgive = ~reached_link_data & cr_pkt_seen & crack_pkt_seen` (**:296-298**)
- `wire isNotExpPacket_l7 = isNotExpPacket & ~socl_l7_bringup_forgive` (**:299**)
- `send_nack_req` all 5 branches: `isNotExpPacket→_l7`, `& ~bringup_forgive & ~wdog_force_clear`
  (**:987,989,991,993,995**); combinational `_GEN_71/105/141/153` likewise
- **Why inert:** `bringup_forgive` needs BOTH peer `cr_pkt_seen` AND `crack_pkt_seen`. With
  `cr_seen=0`, `bringup_forgive≡0` ⇒ `isNotExpPacket_l7≡isNotExpPacket` and `& ~forgive ≡ &1`
  ⇒ `send_nack_req` is **bit-identical to deps** in states 0-3. And the mask only ever
  *suppresses* NACK, so it cannot manufacture a stall. **Innocent for a `cr_seen=0` failure.**

### Rank 5 — Feature D: state-7 NACK watchdog — TOUCHES states 0-3: **NO**
- `localparam SOCL_L7_WDOG_THRESHOLD = 16'h4000` (**:79**)
- `reg socl_l7_real_crc_seen` (**:1008-1011**), `reg socl_l7_wdog_cnt` (**:1016-1023**; counts
  only while `state==7`)
- `wire socl_l7_wdog_force_clear = (wdog_cnt==thr) & ~real_crc_seen` (**:303-305**) → `send_nack` mask
- **Why inert:** `wdog_cnt` is held at 0 unless `state==7`; `force_clear≡0` in states 0-3.
  **Innocent.**

### Rank 6 — Feature E: periodic re-ACK — TOUCHES states 0-3: **NO**
- `localparam SOCL_REACK_THRESHOLD = 16'h0100` (**:80**)
- `reg socl_reack_idle_cnt` (**:1028-1033**; counts only in states 4-5),
  `reg socl_reack_fired` (**:1038-1043**)
- `wire socl_reack_rearm` requires `state >= 3'h4` (**:330-337**) → `send_ack_req` else-branch (**:980**)
- init block seeds `socl_reack_idle_cnt=0, socl_reack_fired=0`
- **Why inert:** `rearm` is gated `state>=4`; the counter only runs in states 4-5.
  **Innocent for states 0-3.**

**Key tension:** the two features that *do* touch states 0-3 emit (B, CRC) are already
silicon-eliminated; the four that remain (A/D/E, and C which is state-2-only) are provably
inert while `cr_seen=0`. So **no single combinational feature in this diff explains the
symptom.** That is the central finding driving the plan below.

---

## (b) Feature-ablation matrix — minimal edit/`define` that NULLs each feature to deps-equivalent

Every null below is a constant-fold (no port change, elaborates in sim and synth). Applying
a null reverts exactly one feature; the rest are untouched. Apply the identical edit to all 5
AXI nodes `_0.._4` (they are homogeneous).

| # | Feature | Minimal null (one edit) | Result |
|---|---------|-------------------------|--------|
| B | min-CR gate | `:288` → `wire socl_l6_cr_emit_gate_ok = 1'b1;` (or `:64` → `= 8'd0`) | `_GEN_34`/`:865` revert to "leave on first peer-seen" = deps `:244` |
| C | min-CRACK gate | compile `+define+SOCL_L7_MIN_CRACK_EMITS_VAL=0` (uses existing `ifndef` `:75`), or `:291` → `= 1'b1;` | `crack_release≡crack_pkt_seen` ⇒ `_GEN_40..45` = deps `:252` |
| CRC | CRC-off default | `:713` → `out_prepend_swi_disable_crc <= 1'h0;` | CRC-on, matches deps `:636` / sideband `_6:1194` |
| A | bring-up-forgive | `:296` → `wire socl_l7_bringup_forgive = 1'b0;` | `isNotExpPacket_l7≡isNotExpPacket`; `& ~forgive ≡ &1` ⇒ `send_nack` = deps |
| D | NACK watchdog | `:303` → `wire socl_l7_wdog_force_clear = 1'b0;` | `& ~wdog_force_clear ≡ &1` ⇒ `send_nack` = deps |
| E | periodic re-ACK | `:330` → `wire socl_reack_rearm = 1'b0;` | `send_ack else ≡ _GEN_178` = deps `:980` |

**Full deps-equivalent ablation (the ANCHOR)** = apply ALL six nulls. This leaves the +7
`always @(posedge io_tx_clk)` blocks and their registers physically present (they become
dangling / read-only-by-nothing and should be swept by synthesis), but nulls every logic
term that feeds `state`/`data_id`/`send_ack`/`send_nack`/`disable_crc`. Its combinational and
next-state behaviour should be **logically identical to `deps/`** — provable by LEC/formal
equivalence against `deps/.../WlinkGenericFCSM.v` with zero effort in sim.

> A *stronger* anchor that also removes the structural footprint: **overwrite the override
> files with the `deps/` contents** (or point the flist back at `deps/` — already known to
> come up). Contrast this with the six-null anchor to separate "logic term" from "added-
> register footprint" (see plan step A2).

---

## (c) Ordered bisection plan with discriminating observables

**Discriminating observable throughout:** the AXI-node CR/CRACK handshake reaching
`cr_seen=1 → crack_seen=1 → cal_done=1 → fcsm=4`, bilateral, read at `SWI_LANE_STATUS
@ 0x2E03_2108` over the `eth_ss_0` backdoor (same criterion the bench already uses). A single
partial step (`cr_seen` flickers to 1 even once) is itself a discriminator — the current
failure is `cr_seen` *never* flickering.

**Sim vs board (read this first):** every ablation EDIT is sim-clean (constant-fold), and sim
can PROVE a null is faithful (LEC vs deps) and catch gross breakage. But per the documented
sim/silicon gap, **no existing sim reproduces the bring-up failure** — it lacks (1) RX
LinkLayer byte-align latency after reset, (2) the 5-way mux contention, (3) async two-die
reset-release / clock-phase, (4) `cal_done` coupling. So each **verdict** ("does it come up?")
currently needs a **board cycle (~1.5 h)**. Front-load all logic-equivalence proofs in sim to
avoid wasting board cycles on unfaithful nulls. Building the missing 2-die + mux + RX-align +
async-reset TB (the doc's ask) would migrate the whole plan into sim — recommended before
burning many board cycles.

### Step A — the fork (do this FIRST; it is the test the doc never ran)

The doc tested SINGLE-feature ablations (v1=B-gate, v2=CRC). It never ran the **full
deps-equivalent ablation**. That one test cleanly forks the entire hypothesis space:

- **A1 (board, 1 cycle): six-null anchor** — apply all six nulls (matrix above), build, deploy both dies.
  - **Comes up (fcsm=4)** ⇒ cause is a **LOGICAL INTERACTION** among the features (every
    single/pair tested so far failed, so it is a combination) ⇒ go to Step B.
  - **Stays down (`cr_seen=0`)** ⇒ cause is **STRUCTURAL / TIMING** — the mere footprint of
    the override (added io_tx_clk registers, synthesis/placement, or a flist/packaging
    effect), independent of every logic term ⇒ go to Step C. **Logical feature-bisection is
    then futile — do not run Step B.**

- **A2 (board, 1 cycle, only if A1 stays down): byte-identical file test** — replace the five
  override files with **verbatim `deps/` contents** (same path, so the flist and packaging
  are unchanged), build, deploy.
  - **Comes up** ⇒ the break is in the override RTL's *added structure* (the +7 always-blocks
    / registers perturbing CR launch or RX align), not in the flist/packaging.
  - **Stays down** ⇒ the break is in the **re-point mechanism itself** (flist include order,
    IP-packaging, incdir) — not the FCSM RTL at all. (Note: the FCSM files are included by
    explicit path in `tidelink_fpga_v2.flist`, and `+incdir+local_overrides` precedes
    `+incdir+src/rtl`, so an incdir-shadowing bug is unlikely but this test proves it.)

### Step B — logical interaction bisection (only if A1 comes up)

Binary-search by RESTORING features (un-null) from the anchor, highest-ranked first:

- **B1 (board): restore {B + CRC}** together (keep A/D/E nulled).
  - Breaks ⇒ interaction lives in {B, CRC} → B2.
  - Stays up ⇒ interaction lives in {A, D, E} → B3. *(This would overturn the "inert"
    analysis above — high-value, treat A/D/E as the must-test bucket.)*
- **B2 (board): restore B only** (CRC nulled).
  - Breaks ⇒ B alone is active under the anchor context (contradicts v1 → suspect v1's ungate
    was not equivalent to nulling B here; compare edits).
  - Stays up ⇒ the culprit is the **B×CRC interaction** (neither alone breaks, both together
    do — exactly the untested cell of the doc's matrix). Isolated.
- **B3 (board): restore D+E, then bisect** — restore {D}, observe; then {E}. Each a board cycle.

### Step C — structural/timing escalation (only if A1 stays down and A2 comes up)

No logic ablation will find it. Instead:
- Static-timing diff the **CR launch path** (FC `auto_out_{sop,data_id}` → TxRouter →
  serializer → pad) deps vs override; look for a launch-edge / cadence shift introduced by
  the added io_tx_clk fan-in. The bench already reports WNS +0.304 ns, hold ≈ −22 ns — margin
  is thin.
- Reduce the footprint incrementally: delete the +7 always-blocks in halves (they are
  logically dead once A1's nulls are in place) and re-time/re-build, to find which added
  sequential group shifts the CR launch. This is a synth/timing bisection, not a logic one.

### Iteration budget

- Sim/analysis (free, do first): LEC each null vs deps; prove the six-null anchor ≡ deps.
- Board: **1 cycle for A1** decides logical-vs-structural. Then ≤ log2(features) more if
  logical (B-path: 2-3 cycles), or A2 + timing escalation if structural.
- The whole feature axis is isolated in **~1 + ≤3 board cycles**, versus the doc's
  one-feature-per-rebuild approach.

---

## (d) Single best guess at the culprit — and why

**Primary guess: it is NOT one isolated recovery-logic term — it is the aggregate
STRUCTURAL / TIMING FOOTPRINT of the recovery logic** (the +7 `always @(posedge io_tx_clk)`
blocks / ~65 added registers fanning into the state and emit datapath), degrading the
source-synchronous CR launch — or its cadence under 5-way router contention — so the peer's
RX byte-aligner never latches the first CR (`cr_seen` stays 0).

Why this over any single feature:
1. **Both logical ablations left the signature byte-identical.** v1 (gate) and v2 (CRC), and
   most likely their linear-stacked combination, all reproduce `0x00100000` exactly. A single
   logic-term culprit would have to shift the failure under at least one of those ablations;
   it did not.
2. **The failure is on the RX-latch side, not TX-emit.** `cr_seen` is peer-latched via
   broadcast RX. The node provably still drives `cr_id` in state 1 (FC.scala emit path is
   unchanged; the gate only holds the state, it does not gate `sop`). "Never latched by the
   peer" points at launch timing / alignment, which added TX-clock logic can perturb.
3. **The sim/silicon gap is exactly a timing/structure gap.** Sim passes because it models no
   RX byte-align latency, no 5-way contention, no async two-die reset phase — precisely where
   a footprint bug hides and a pure logic bug would not.
4. **A/D/E are provably inert at `cr_seen=0`** (forgive needs cr+crack seen; watchdog needs
   state 7; re-ACK needs state≥4), and C acts only in state 2 (after the failure point). So
   the logical surface that *could* act is just {B, CRC} — both already eliminated.

**Fallback guess, IF the Step-A1 anchor comes up (i.e. the cause IS logical):** **Feature B,
the min-CR-emit gate, acting in interaction** (most likely B×CRC, the one untested cell) —
because B is the only feature that changes *what/when* state 1 emits and that multiplies CR
contention on the shared link, and it has only ever been ablated **alone** (v1). Rank C/A/D/E
below it exactly as in section (a).

**What I explicitly cannot determine without a board cycle (must-test bucket):** whether the
six-null anchor comes up (the logical-vs-structural fork); whether v2 truly stacked on v1
(combined ablation) — the commits are not in this clone; and whether the +7 added io_tx_clk
always-blocks shift the CR launch timing (needs STA, not RTL reading). These are the
unknowns the plan is built to resolve in the fewest iterations.
