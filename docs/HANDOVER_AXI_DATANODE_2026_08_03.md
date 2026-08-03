# Handover — AXI data-node pushback: review, fix, and what's left

**Date:** 2026-08-03 · **Branch:** `fix/axi-datanode-recovery` @ `dcf0fce`
**Worktree:** `/home/dam1n19/SoCLabs/tidelink-axirec` (clean, **not pushed**, not in the freeze)
**Reader:** whoever picks this up next, or David for the decision in §7.

---

## 1. Where it stands, in one paragraph

The eth-chiplet's reported bug — *one bit-error on an AXI data-plane FC node
hard-wedges the initiator die's whole PS, JTAG-POR only* — is **resolved and
proven on silicon**. Two sessions ran in parallel on the same branch: one did a
verification review that re-characterised the defect and built the missing tests
(commits `7485f76`, `183afc2`); the other implemented the **synth-B** fix and took
it to the KR260 (`9b4c40b`, `e827199`, `dcf0fce`). On the fixed bitstream
`errinject --node B --inj-byte 0` leaves die_a **alive** (ping 2/2, SSH up) where
every previous build hard-wedged it. Three things remain open: my bug-repro tests
now assert the old broken symptom and must be re-pointed (§4), a one-cycle
AHB-illegal HRESP pulse still leaks (§5.1), and a **byte-1 injection still wedges
the board** via a different, un-investigated subsystem (§5.2).

---

## 2. What the bug actually was

Not what the earlier rounds concluded. The chain, as finally established:

1. The silicon repro injects on **byte 0 of the B (write-response) packet — the
   `data_id` routing field**. This is a *clean silent drop* of the write
   acknowledgment: measured on the B node, byte 0 produces **no FC-layer
   detection of any kind** (CRC counter flat, no NACK, no state-7). The byte-4
   control on the same node with the same arming path lights all of them, which
   is what proves those probes were live and the silence real.
2. The write **DATA already landed byte-exact** at the target over AW/W. Only the
   acknowledgment is lost.
3. TideLink's I5 backstop fired correctly and drove `HRESP=ERROR` — the ILA
   confirms this — but **abandoned the `s_axi` tracking**, leaving XHB500 waiting
   forever for a B that can never arrive.
4. So the window path was **permanently dead**: re-reading the *full* 4096-sample
   capture (rather than the ±5 samples around the trigger) shows
   `dbg_xhb_hrdyout_raw` at **0 for all 3839 post-ERROR samples, never once
   high**, with the stall counter already ramping to the next 2^16 expiry. The PS
   gets one bus error per ~2.6 ms and no data — indistinguishable from a hang.

**This overturned the 07-31/08-01/08-02 disposition** ("Fix G and Fix H operated
on a layer that was never broken; I5 is EXONERATED; the wedge is upstream"). The
error-propagation observation was real, but it was not the mechanism: the wedge
was TideLink's own un-restored path. Two corollaries worth keeping:
- The capture never exercised Fix H at all — `osr_ctr` and `stall_ctr` are
  identical at every sample and `wr_os` never exceeds 1, so the pre-existing
  per-beat timer would have fired identically.
- The old ILA probe set had **no master-facing AHB address-phase signal**, so it
  structurally could not answer the legality question it was being used for.

---

## 3. The fix, and why OKAY not SLVERR

`tidelink_top.sv` — when a write's B is lost long enough to trip the
outstanding-response backstop, latch `synth_b_pending` and inject a **synthetic B
into XHB500's `s_axi`** (`bvalid=1, bid=sub_wr_awid_r`), muxed with the
controller's real B. XHB500 retires the write through its own response path and
**re-idles**, so the path is restored. The direct `sub_err{1,2}_r` override is
gated off while synth-B is active.

The response code is a real design fork, and HW settled it:

- **SLVERR wedged the board anyway.** The PS treats SLVERR as "write failed" and
  **retries**; the still-armed injector re-drops each retry's response, so `wr()`
  never returns, `error_inject_off()` never runs, and the injector stays armed —
  a self-sustaining wedge, ILA-captured.
- **OKAY works and is truthful.** A byte-0 flip corrupts only the B node's
  routing field; the data landed. The only lost thing is the acknowledgment, so
  OKAY correctly retires the write with no retry loop.

Cost, stated plainly: OKAY *masks* the lost acknowledgment — the PS believes a
write succeeded, which data-wise it did. That is sound for a `data_id`-routing
corruption. It would **not** be sound for a fault class that can corrupt write
DATA without tripping CRC; see §7.

---

## 4. ⚠ Immediate action: my tests now assert the old broken symptom

`cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_gaps.py` (mine) detects
"the backstop fired" by catching a `RuntimeError` from `HRESP=ERROR`. Under the
OKAY fix, firing manifests as a **clean completion** — which is the entire point.
The tests' *invariants* still hold; their *detection* is stale. The other session
deliberately did not rewrite them (my active file) and flagged it for
coordination. This is the top of the to-do list.

**Measured against the fixed RTL, 2026-08-03, HEAD `dcf0fce`** (not inherited
from the other session's table — re-run for this handover):

```
axi_datanode_gaps            FAIL    143s     <- 5 GAP-1 PASS, then the first
                                                 backstop test fails and the
                                                 gate stops there
xfail_i5_ahb_legal           XFAIL    28s     <- F-1 residual genuinely present
xfail_i5_clean_drop          XCHG     23s     <- signature no longer matches:
                                                 THE DEFECT IS FIXED
```

`XCHG` on `xfail_i5_clean_drop` is the sentinel working exactly as designed — a
fix flips a known-defect sentinel visibly instead of silently, which is why it
was registered as a sentinel rather than left failing. Note `XCHG` **fails the
gate**, deliberately: it demands a human decision, and the decision here is
"promote to a positive regression" (below).

| test | now | why | re-point to |
|---|---|---|---|
| `test_i5_backstop_restores_the_path` | FAIL @ `assert fired` | OKAY raises no RuntimeError | detect firing via `dut.u_master.synth_b_pending` / `sub_err1_r`, keep the "next clean access works" assert |
| `test_i5_rearms_after_abort` | FAIL @ `assert first=="ERROR"` | both trips complete via OKAY | assert both trips *complete* and that synth-B fired twice |
| `test_i5_clean_drop_leaves_path_usable` | now RECOVERs | **the fix works** | flip from XFAIL sentinel to a **positive blocking regression** |
| `test_i5_error_is_ahb_legal` | still FAIL | genuine residual, §5.1 | leave as XFAIL sentinel |
| GAP-1 per-node tests (5) | PASS | unaffected | no change |

Gate wiring to update at the same time: `sim_gate_xfail_i5_clean_drop` should be
**promoted** out of `SIM_GATE_SENTINELS` into `SIM_GATE_ALL_SUITES` once
re-pointed, and the three re-pointed tests folded back into
`sim_gate_axi_datanode_gaps`. Re-run `make sim_gate_inventory` afterwards — it
cross-checks scored-vs-invoked and will catch a half-done move.

---

## 5. Open items, ranked

### 5.1 F-1 residual — a one-cycle AHB-illegal HRESP pulse (low risk, known fix)
After `synth_b_pending` clears, a `sub_err2_r` pulse can still leak
`ahb_sub_hresp=1` with no transfer in its data phase. Benign on HW (the upstream
bridge discards an `outstanding=False` pulse — die_a survived), but AHB-illegal.
**Clean fix:** fire the ERROR path for stuck **reads** only; synth-B owns stuck
writes end-to-end, so no ERROR pulse is ever produced for a write. Deferred — it
needs a ~1.5 h rebuild and the OKAY-vs-ERROR sign-off in §7.

Note the wider point this defect came from: I5 is deliberately HREADYOUT-blind so
it can catch a lost response for a **posted** (bufferable) write the bridge has
already retired — and a retired master cannot be legally errored in-band at all.
For posted writes the error is architecturally *unreportable* via HRESP and must
go out-of-band (§5.3). Reachability today is nil: XHB500 takes the
early-write-response path iff `hprot[2]`, TideLink drives `{3'h0, xhb_sub_hprot}`,
and that bit comes straight from the top-level `eth_ss_0_hprot[2]`; the ILA shows
the captured write held HREADYOUT low for the whole ramp, i.e. **non-bufferable**.
So F-1 is latent on this rig. The open question is an integration one: *which
master in the shipping SoC can drive HPROT[2]=1 into the window?*

### 5.2 🔴 byte-1 injection still hard-wedges the board — different subsystem, uninvestigated
`errinject --node B --inj-byte 1` (the `word_count` header field) **still wedges
die_a** on the fixed bitstream. The RX framer reads the wrong packet length and
desyncs — this is upstream of the AXI FC nodes, in the Wlink link layer, and no
AXI-node backstop can address it. **The reported bug is closed; this is a
separate, still-open hard-wedge on the same command.** Do not let the "resolved"
headline hide it.

### 5.3 The header-ECC question — possibly the most serious thing here, and unresolved
The Wlink packet header carries a MIPI-style **correcting** ECC
(`WlinkEccSyndrome.v` — no enable input, `corrected`/`corrupted` outputs, RX
decodes from the corrected header, TX computes it over the *uncorrupted* header).
On that reading a single-bit `data_id` flip ought to be **repaired at the
receiver**. It is not — and the ECC counters
(`obs_ecc_correct{ed,ted}_cnt_q`) never move.

**But that zero proves nothing yet, and must not be quoted as if it does.** The
instrument control says so: corrupting **byte 3 — the ECC byte itself** — also
leaves those counters at 0, so they never move even for the one input that must
move them. Either the ECC is inert or the probe is mis-placed; I could not
distinguish the two, so no conclusion is claimed in either direction.

**Resolve this first.** Find a probe that moves for a known ECC-byte corruption.
If the header ECC really is inert, a single-bit header wire error silently
mis-routes or mis-frames a response between FC nodes — a link-integrity defect
larger than anything else in this document, and §5.2's byte-1 HW wedge is
empirical support for exactly that hypothesis.

### 5.4 Coverage debt (from the review, unchanged)
Sideband FCSM_6 (0xA1) injection — no test at any node. AHB **bursts** over the
window — every window test is single-beat. Simultaneous bidirectional window
traffic. Backstop expiry racing a legitimately-completing response. Injection
*during* bring-up, either side of the boundary Fix G moved. Byte-0 on the other
four nodes. Repeated/soak injection (every test injects once; the consumer's
report is about the *second and subsequent* transfers).

### 5.5 Sim/silicon divergence still unexplained (F-5)
Byte-4 injection recovers byte-exact on all five nodes in sim, yet `--inj-byte 4`
hard-wedged die_a on 2026-08-01. The tb does no BID matching and has a zero-wait
terminus. Closing it needs the BID-checking BFM ("Construction B"), not more of
the current tb. **Do not read a green per-node sim row as silicon-proven.**

### 5.6 TideChart P3 (re-confirmed open, unrelated to this fix)
`force_root` (TC_CTRL[2]) is never consumed — it occurs exactly once in the tree,
in a comment (`tidechart_apb_regs.sv:176`). TC_CTRL[3] is documented "reset" but
wired to `rt_clear` (`:319`) — it does not clear `election_done`. And
`sim_gate_tc_pair_election` asserts `n_roots==1` and passes while silicon sees
dual-root.

---

## 6. How to re-run everything

```bash
cd /home/dam1n19/SoCLabs/tidelink-axirec
source ./set_env.sh                     # MANDATORY — without it every suite
                                        # "fails" in 4-5 s and looks like an
                                        # RTL catastrophe

# the coverage suite (5 per-node + 3 backstop-semantics), blocking
make sim_gate_axi_datanode_gaps
# the known-defect sentinels
make sim_gate_xfail_i5_ahb_legal
make sim_gate_xfail_i5_clean_drop
# wiring cross-check — catches scored-but-never-invoked
make sim_gate_inventory

# single tests / the byte-by-byte diagnostic
cd cocotb/tidelink_axi_datanode_recovery
make test_axi_r_error_recovers
DIAG_BYTE=0 make test_diag_byte0_detection_path   # 0=data_id 3=ECC 4=pktnum
```

HW: boards `kr260_01` (die_a, 10.22.24.159) / `kr260_02` (die_b, .153). Lease
first, **never chained with board ops in one shell call**. JTAG POR is
`~/bin/kpor kr260-01 --wait` on mapstone-dev. The acceptance run is
`bringup_pair_release.sh` → fcsm=4 both → clean eye-gate write →
`errinject --node B --inj-byte 0 --stream 0` → **die_a must stay alive**, then a
clean peer write must still succeed byte-exact (that second step is F-2 closed,
and was impossible before this fix).

---

## 7. Decisions needed from David

1. **Ratify OKAY-vs-SLVERR.** HW evidence is decisive (OKAY is the only variant
   that keeps die_a alive), but it is a deliberate design choice to complete a
   write whose acknowledgment was lost. Revisit if a fault class can corrupt
   write DATA without tripping CRC.
2. **Whether §5.2 (byte-1 link-layer wedge) blocks the freeze.** The reported bug
   is closed; this one is not, and it wedges a board from the same command.
3. **Whether §5.3 (header ECC) gets a session before tapeout.** If the ECC is
   inert, it is a link-integrity issue that outranks everything else here.
4. **Push / freeze integration.** This branch is not pushed and not in
   `integ/freeze-2026-07-31`. Consumers on stale pins: `nanosoc-simple-chiplet`,
   heterogeneous-testing compute-leg, compute-chiplet.

---

## 8. Map

| commit | what |
|---|---|
| `7485f76` | review: 10 gap tests, F-1/F-2 found, gate wiring (mine) |
| `183afc2` | byte-by-byte diagnostic, HW-proof plan, RTL fix proposals, ECC correction (mine) |
| `9b4c40b` | synth-B (SLVERR) restores the stuck XHB500 write |
| `e827199` | SLVERR → **OKAY**; HW-proven on die_a |
| `dcf0fce` | HW-proof + scope doc |

| doc | what |
|---|---|
| `docs/VERIFICATION_REVIEW_AXI_DATANODE_PUSHBACK_2026_08_02.md` | the review: evidence, F-1…F-6, coverage matrix, HW plan §7, fix proposals §8 |
| `docs/AXI_DATANODE_OKAY_FIX_HWPROOF_2026_08_02.md` | the fix: HW evidence, sim table, OKAY rationale, follow-ups |
| `docs/ila_capA_i5_fires_2026_08_02.csv` | 4096-sample silicon ground truth — **read all of it, not the trigger window** |
| `docs/VERIFICATION_PLAN.md` | §3.3 node×byte coverage axis; F-1…F-6 in the §6 backlog |

**Standing lesson from this round, worth carrying forward:** every reversal here
came from re-reading evidence that was already in hand — the full ILA capture
rather than its trigger window, and an instrument control that showed a probe
never moved for its own known-good input. Verify the instrument before
theorising about the DUT.
