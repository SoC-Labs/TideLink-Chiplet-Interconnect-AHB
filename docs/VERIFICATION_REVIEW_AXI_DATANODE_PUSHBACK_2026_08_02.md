# Verification review — eth-chiplet AXI data-node pushback

**Date:** 2026-08-02 · **Reviewer role:** verification (assess + test, not fix) ·
**Branch:** `fix/axi-datanode-recovery` (worktree `/home/dam1n19/SoCLabs/tidelink-axirec`)
**Scope:** the bug the eth-chiplet integration pushed back to TideLink — a single
bit-error on an AXI data-plane FC node hard-wedges the initiator die's PS — plus
the verification coverage around it.

**Inputs reviewed**
- `nanosoc-ethernet-chiplet/docs/TIDELINK_SILICON_FEEDBACK.md` (P1/P2/P3)
- `nanosoc-ethernet-chiplet/docs/AXI_DATANODE_RECOVERY_GAP_2026_07_31.md`
- `nanosoc-ethernet-chiplet/tidelink/docs/HANDOVER_AXI_DATANODE_RECOVERY.md`
- `docs/AXI_DATANODE_RECOVERY_AMPLIFIER_SOUND_2026_08_01.md` + the 08-02 ILA verdict
- `docs/ila_capA_i5_fires_2026_08_02.csv` — 4096 samples of silicon ground truth,
  **re-analysed in full** for this review (prior write-ups quote only ±5 samples
  around the trigger)
- `cocotb/tidelink_axi_datanode_recovery/` (Fix G / Fix H / I5, 6 tests)
- `src/rtl/tidelink_top.sv:1461-1710` (both backstops), `src/rtl/tidelink_axinode_obs.sv` (I4)

---

## 1. Verdict on the current disposition

The 08-02 ILA verdict concluded: *"I5 FIRES CORRECTLY; the HRESP=ERROR does not
reach the PS. The wedge is UPSTREAM error-propagation, NOT tidelink. Fix G AND
Fix H both operated on a layer that was never broken; I5 is EXONERATED."*

**The first half is right. The exoneration is not.** Re-reading the full capture
rather than the trigger window changes the picture.

### 1.1 The capture proves TideLink never recovers — for the whole rest of the buffer

The published analysis stops at sample 261. Across **all 3839 samples after the
ERROR**:

| signal | value after the ERROR |
|---|---|
| `dbg_xhb_hrdyout_raw` | **0 at every single sample — never once high** |
| `dbg_i5_ext_stalled`  | 1 at every sample except the one ERROR cycle |
| `dbg_ahb_hreadyout`   | high for exactly 1 sample (the ERROR cycle-2 pulse) |
| `dbg_i5_stall_ctr`    | restarted from 0, reached 0x0efd and still ramping |
| `dbg_i5_osr_ctr` / `dbg_i5_wr_os` | 0 / 0 — I5 has cleanly abandoned |

XHB500 is **permanently stuck with HREADYOUT low**. The wrapper's ERROR
abandoned the transfer upstream but did nothing to the bridge, so the window
path is dead and the per-beat stall timer will emit another ERROR every 2^16
hclk (~2.6 ms @ 25 MHz), forever. A PS that gets one bus error per 2.6 ms with
no data is, to a host, hung — SSH keepalive dies exactly the same way. **The
observed PS symptom does not require the upstream-drop theory to explain it.**
That is a TideLink-side gap, and it is visible in the evidence already gathered.

### 1.2 The capture does not exonerate Fix H — it shows Fix H was never exercised

`dbg_i5_osr_ctr` and `dbg_i5_stall_ctr` are **identical at every sample**
(`0xfffe → 0xffff → 0x10000`, both expiring on sample 255) and `dbg_i5_wr_os`
never exceeds 1. The pre-existing per-beat `SUB_STALL_TIMEOUT` — which predates
Fix G and Fix H entirely — would have produced the same ERROR on the same cycle.
So the capture shows *a* backstop firing on *one* stalled non-posted write. It is
**not** evidence that the I5 outstanding counter works, and not evidence that the
multi-outstanding stream case is bounded. Fix H's own acceptance case has never
been observed on silicon.

### 1.3 The ILA probe set cannot answer the question it was used to answer

The 28 probes include `dbg_ahb_hresp` and `dbg_ahb_hreadyout` but **no
master-facing AHB address-phase signal** — no `ahb_sub_hsel`, no
`ahb_sub_htrans`. (The `u_fc_adapter/dbg_tx_*` probes are the TX-generator port,
a different AHB interface.) So the capture can show *that* HRESP went high; it
cannot show whether it landed in the data phase of a transfer the upstream bridge
was waiting on. §3 F-1 shows the illegal case is reachable and now reproduced in
sim.

For this particular event the answer is inferable and favourable —
`dbg_i5_ext_stalled=1` and `dbg_ahb_hreadyout=0` throughout the ramp means the
master *was* held, so **this** ERROR was legal — but the inference is indirect and
the probe set should be fixed before the next capture.

**Net:** the upstream AXI Firewall/Timeout IP remains the right robust
mitigation, and the "error doesn't reach the PS" finding stands. But the pushback
should not be closed as "not our bug": TideLink owns F-1, F-2 and the
observability gap F-4 below.

---

## 2. Coverage assessment of the existing suite

`cocotb/tidelink_axi_datanode_recovery` (gated as `sim_gate_axi_datanode_recovery`)
is a good suite — non-vacuous, with a real discriminator (Fix G forced off). Its
coverage was one column of a 5×3 matrix.

| FC node | data_id | before this review | notes |
|---|---|---|---|
| AW | 0x80 | ✗ none | write address path |
| W  | 0x81 | ✗ none | write data path |
| B  | 0x82 | ✅ 6 tests | the entire existing suite |
| AR | 0x83 | ✗ none | read request path |
| R  | 0x84 | ✗ none | read data return — one of the two silicon wedge points |

**Injection-byte axis.** Byte 4 (pktnum) and byte 5 (payload) were covered on B
only. Byte 0 (`data_id`) — the axis the silicon ILA capture actually used — had
**no sim coverage on any node**, and it is structurally the worst case: the CRC
comparison is *gated on* `data_id === swi_data_id` (`FC.scala:157`, documented at
`cocotb/tidelink_error_injection/test_ei_crc_probe.py:34-40`), so a corrupted
data_id makes the packet not-a-data-packet. It is silently dropped: no CRC error,
no NACK, no replay. **Fix G's entire recovery mechanism is structurally blind to
it.**

*Reviewed and cleared:* `sub_rd_os_r` being a single bit (`tidelink_top.sv:1505`)
while writes got Fix H's counter is **not** a bug — XHB500 gates a new AR on
`ready_for_read = (read_counter==0 | (r_done & read_counter==1))`
(`..._core_resp.sv:233`), i.e. genuinely single-outstanding for reads.

---

## 3. Flagged defects

### 🔴 F-1 — I5 drives an AHB-ILLEGAL ERROR on the posted-write path *(new, sim-reproduced)*

`test_i5_error_is_ahb_legal` → **FAIL**:
`err1_fires=1 osr_max=8192 HRESP pulses=[{'outstanding': False, 'hreadyout': 0}]`

`ahb_sub_hresp`/`ahb_sub_hreadyout` are overridden from `sub_err{1,2}_r` alone
(`tidelink_top.sv:1703-1710`) with **no qualification that an AHB transfer is in
its data phase**:

```systemverilog
assign ahb_sub_hreadyout = sub_err1_r ? 1'b0 : sub_err2_r ? 1'b1 : ...
assign ahb_sub_hresp     = (sub_err1_r | sub_err2_r) ? 1'b1 : xhb_sub_hresp_raw;
```

I5 is deliberately HREADYOUT-blind precisely so it can catch a lost response for a
**posted** (bufferable, HPROT[2]=1) write — one XHB500's early-write-response has
already retired at the AHB layer. By construction its expiry can therefore land
when the master has nothing outstanding. AHB-Lite permits a subordinate to signal
ERROR only during the data phase of a transfer it was selected for; an upstream
AHB→AXI bridge is entitled to discard a pulse with no transfer in flight.

**Why it matters here:** this is a TideLink-side mechanism that produces the exact
reported symptom — *"HRESP=ERROR is driven and the PS never sees a bus error"* —
with no upstream defect required. It is **not** the mechanism of the captured
`--stream 0` event (there the master was held, §1.3), but the `--stream 32` repro
that wedged the board drives 32 pipelined **bufferable** writes, i.e. exactly this
path.

### 🔴 F-2 — the backstop reports an error but never restores the path *(silicon-proven AND now sim-reproduced)*

Sim status is **split**, and the split is the whole point:
- `test_i5_backstop_restores_the_path` (**PASS**) — with a *removable* fault, the
  pending NACK/replay converges once the injector is disarmed, XHB500 finally gets
  its B, and the path recovers.
- `test_i5_clean_drop_leaves_path_usable` (**FAIL**) — the silicon-faithful case:
  a byte-0 (`data_id`) corruption is a clean silent drop with nothing to replay.
  The backstop fires (`clean-drop write: ERROR`) and then **the next clean write
  also returns HRESP=ERROR**, with the fault already removed. The window path is
  permanently dead after one lost response, exactly as the ILA shows.

The existing suite only ever models faults that are *recoverable by replay*, which
is why it could not see this. **This is the first sim reproduction of the captured
on-silicon wedge** — the blind spot the consumer's handover asked to be closed
("HOW TO PRODUCE A MATCHING SIM TEST"). The earlier conclusion that the tb cannot
model it was wrong; it just needed byte 0 instead of byte 4/5, and it gives the
team the fast triage loop that a ~1.5 h build + bench cycle was standing in for.

### ⚪ F-3 — shared age counter: hypothesised, then REFUTED as reachable

`sub_axi_progress = sub_r_done | sub_b_done` (`tidelink_top.sv:1563`) zeroes the
single `sub_osr_ctr_r` whenever **any** beat on **either** channel retires, so in
principle a stuck transaction can be kept un-timed-out by unrelated traffic — the
same defect class Fix H fixed one level down. **Measured: the route is closed.**
XHB500 serialises the sub port, so with a posted write's B outstanding a following
read does not complete and no concurrent progress can be generated. The read is
instead bounded by a *legal* ERROR (`err1_fires=1 osr_max=8192`, pulse
`outstanding: True`). Recorded as a latent smell with a regression
(`test_i5_traffic_behind_a_stuck_write_is_bounded`) that will catch it if the sub
port ever pipelines across channels.

### 🟠 F-4 — no observability for "a backstop fired"

Region F (I4, `tidelink_axinode_obs.sv`) exposes AXI-node stall and resp-error
stickies but has **no bit for `sub_err1_r` / `sub_osr_expired` / `sub_stall_expired`**.
From APB there is no way to tell whether a backstop fired, which one, or how many
times — which is why diagnosing this needed a purpose-built ILA at all. Two spare
sticky bits (plus a 2-bit "which backstop" code) would have replaced a ~1.5 h
build and a JTAG session. Same complaint as `TIDELINK_SILICON_FEEDBACK.md` P2's
observability item, one layer in.

### 🟠 F-5 — sim/silicon divergence on *detectable* errors

All five nodes now recover byte-exact in sim from a byte-4 (pktnum) injection
(§4.1). But on silicon `errinject --node B --inj-byte 4` **hard-wedged die_a**
(2026-08-01 round). Sim says recover, silicon says hard-wedge, for the same node
and the same byte. So the acceptance gate being met in sim must **not** be read as
met on silicon. Known tb limitations that could account for it: the AHB master
does no BID matching, and the far terminus is a zero-wait BRAM. Closing this needs
the BID-checking BFM already identified as "Construction B", not more of the
current tb.

### 🟡 F-6 — TideChart P3 items are still open in RTL *(independently re-confirmed today)*

In `../tidechart/src/rtl/`:
- **`force_root` (TC_CTRL[2]) is never consumed.** It occurs exactly once in the
  tree — in a comment (`tidechart_apb_regs.sv:176`). The module's only control
  outputs are `election_start` and `enum_start`; the election FSM has no force
  input. The documented software override does not exist.
- **TC_CTRL[3] is documented as "reset" but is wired to `rt_clear`**
  (`tidechart_apb_regs.sv:319`) — it clears the route table, not `election_done`.
  The silicon observation is correct and the register map is wrong as written.
- The gated `sim_gate_tc_pair_election` asserts `n_roots == 1` and passes while
  silicon sees dual-root — a live sim/silicon divergence. The sim gives the two
  dies distinct `random_id`s; silicon ships both dies `DEVICE_CLASS=0x0001` with a
  PUF-derived id, and the 256-cycle default `election_timeout` is shorter than the
  D2D round trip. `TC_ERROR[2] dual_root` is never asserted-on by any test.

---

## 4. New tests

`cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_gaps.py` — 10 tests.
`make gaps_nodes` / `make gaps_backstop` / `make gaps`. One test per sim (a second
`run_bringup_full()` in one sim does not re-POR cleanly). GAP-2 builds with
`+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13` so the backstop fires inside a
sim-able window.

### 4.1 Results (2026-08-02, `fix/axi-datanode-recovery`)

**GAP-1 — per-node injection (byte 4 / pktnum). The consumer's stated acceptance
gate, now met in sim on all five nodes.**

| test | node | result | evidence |
|---|---|---|---|
| `test_axi_r_error_recovers` | R 0x84 | **PASS** | `class=RECOVER value_ok=True nack_fired=True crc_errs_rose=True` |
| `test_axi_r_error_wedges_no_fix` | R 0x84 | **PASS** (discriminator) | Fix G off → `class=ERROR nack_fired=False` — not vacuous |
| `test_axi_ar_error_recovers` | AR 0x83 | **PASS** | `RECOVER`, byte-exact, NACK fired |
| `test_axi_aw_error_recovers` | AW 0x80 | **PASS** | `RECOVER`, byte-exact, NACK fired |
| `test_axi_w_error_recovers` | W 0x81 | **PASS** | `RECOVER`, byte-exact, NACK fired |

Read the caveat in **F-5** before quoting this as the gate being closed.

**GAP-2 — I5 backstop semantics, asserted for the first time.**

| test | property | result |
|---|---|---|
| `test_i5_error_is_ahb_legal` | ERROR lands in a real data phase | **FAIL → F-1** — `err1_fires=1 osr_max=8192`, pulse `outstanding: False` |
| `test_i5_clean_drop_leaves_path_usable` | clean access works after a *silently dropped* response (the silicon case) | **FAIL → F-2** — next clean write returns HRESP=ERROR with the fault removed |
| `test_i5_backstop_restores_the_path` | clean access works after a *removable* fault | **PASS** |
| `test_i5_traffic_behind_a_stuck_write_is_bounded` | traffic behind a stuck posted write is bounded, not hung | **PASS** — bounded by a *legal* ERROR (`outstanding: True`); refutes F-3 as reachable |
| `test_i5_rearms_after_abort` | a 2nd lost response is also bounded | **PASS** (`trip 1st: ERROR`, `trip 2nd: ERROR`) |

### 4.2 Gate wiring (done)

| gate target | contents | status |
|---|---|---|
| `sim_gate_axi_datanode_gaps` | the 8 passing tests (5 GAP-1 + 3 GAP-2) | **blocking — PASS, 190 s** |
| `sim_gate_xfail_i5_ahb_legal` | F-1 | **XFAIL** sentinel (27 s) |
| `sim_gate_xfail_i5_clean_drop` | F-2 | **XFAIL** sentinel (32 s) |

`SIM_GATE_ALL_SUITES` 47→48, `SIM_GATE_SENTINELS` 2→4, and
`make sim_gate_inventory` reports *"OK — every declared suite is invoked"*, so
none of this is scored-but-never-run (the failure mode found in the 07-30 audit).
The two defects are registered as sentinels rather than left failing, so a fix
flips them XFAIL→XCHG visibly instead of silently.

---

## 5. Other exercise axes likely to find more bugs

Ranked by expected yield, **not yet written**:

1. **Sideband FCSM_6 (0xA1) injection.** The mailbox / PTP / perf path has *no*
   error-injection test at any node, and FCSM_6 is the one node whose CRC default
   is ON — the natural control for the AXI nodes' CRC-off default.
2. **AHB bursts (INCR4/8/16, WRAP) over the window.** Every window test is
   single-beat. `sub_r_done` is gated on `rlast`, and the `pipe_valid_r` /
   `rd_pipe_r` interaction with SEQ beats is unexercised. Bursts are how a real
   CPU cache-line fill reaches the aperture.
3. **Simultaneous bidirectional window traffic** — both dies initiating into each
   other's aperture at once. Never tested; the credit rings and the shared
   backstop counter are both global.
4. **Backstop expiry racing a legitimately-completing response** (`sub_osr_expired`
   in the same cycle as `sub_b_done`). The RTL zeroes the trackers on expiry while
   a real B is retiring — a tracker desync window.
5. **Injection during bring-up**, before LINK_DATA, where `socl_l7_bringup_forgive`
   is legitimately armed — the boundary Fix G moved. Nothing tests either side of it.
6. **byte-0 injection on the remaining four nodes** — F-5's clean-drop axis applied
   to AW/W/AR/R, not just B.
7. **Repeated / soak injection.** Every test injects once; the silicon report is
   explicitly about the *second and subsequent* transfers.

---

## 6. VPLAN changes

Applied to `docs/VERIFICATION_PLAN.md`:
- new §3.6 coverage matrix — "AXI FC node × injection byte", so a 4-of-5-nodes
  hole cannot recur silently;
- backlog entries for F-1 … F-6 with their owning tests;
- `gaps_nodes` promoted into `sim_gate_axi_datanode_recovery` (all green);
- GAP-2 backstop tests registered as **XFAIL sentinels**, not blocking gates,
  while F-1/F-2 are open — so a fix flips them visibly rather than silently;
- the ILA probe-set limitation (§1.3) recorded as an instrument gap.
