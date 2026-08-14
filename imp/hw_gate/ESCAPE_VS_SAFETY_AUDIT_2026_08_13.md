# Escape-vs-safety audit — every recovery/guard of the TL-042 shape (2026-08-13)

Branch `integ/tidelink-consolidated-2026-08-07`. READ-ONLY analysis. Nothing committed,
no RTL modified, no vendor IP touched.

**All `file:line` citations are pinned to HEAD `d317c98`** (`git show HEAD:<path>`). The
working tree was dirty at audit time and **changed underneath this audit mid-session** —
the in-progress TL-042 v2 work landed in `src/rtl/tidelink_top.sv` while it was being
read, shifting everything after ~:1830 by +6. Re-derive against HEAD, not against the
working copy, or the ranks will not line up.

## The defect class

A recovery/guard is tested for **"does the recovery FIRE?"** but not for

- **(a)** does the recovery's own state **CLEAR / return to idle**, and
- **(b)** is the **NORMAL path still correct once it has fired**?

TL-042 shipped a data-plane regression (16/16 → 0/16 byte-exact on silicon) through a
genuine non-vacuity A/B plus two green gate suites, because its test asserted only the
escape. Full write-up: `TL042_HW_RESULT_REJECTED_2026_08_13.md`.

The generalised hazard is **cross-coupling**: a recovery state bit that is also a term in
some *other* mechanism's clear / enable / bypass condition. Firing recovery A then
silently disables protection B. That is what `synth_b_pending` did to `wr_hold_r`.

Where I am inferring rather than demonstrating, I say so.

---

# What is already known, and what this audit adds

Read `docs/BUG_REGISTRY_ADDITIONS_2026_08_13.yaml` first — a lot of this ground is covered:

- **TL-042** is already registered as a *class* entry — "backstops that arm/clear on an
  intermediate signal the wedge itself suppresses" — with three instances and a caveat
  killing the head-of-line write-age timer. That class is about **arming on a suppressed
  proxy**. This audit covers the **orthogonal** axis: *what else does the recovery's state
  bit switch off once it does fire.*
- **TL-036** already logs the `WlinkGenericFCSM_6` watchdog gap. I re-derived it
  independently before finding the entry (details below as **C1**) — it is confirmation,
  not a new find, and it is correctly scoped there.
- **The in-progress TL-042 v2 fix in the working tree has already internalised the
  lesson properly.** Its tests
  (`cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_writehold.py:596`,
  `:738`) assert all three properties: the hold escapes (`:663`), `synth_b_pending`
  was never asserted during and is 0 after (`:681`, `:686`, `:689`), no synthetic B was
  injected (`:693`), **and a normal peer write still lands byte-exact afterwards**
  (`:717`, `:722`, `:727`); plus a companion proving the escape is unreachable for a live
  write (`:799-818`). Its release path touches `wr_hold_r` and one obs bit and nothing
  else. **That is the right shape — this audit does not fault it.**

**Genuinely new here (checked against both registry files — zero hits for each):**
`sub_err1_r`, `auto_anchor_pulse_q`, `force_always`, `truncated`, `reset_storm`,
`SKIP-EQUIV`, `WlinkGenericFCReplayV2_13`.

---

# ⚠ NEW AND TAPEOUT-RELEVANT

## N1. The write backstop silently disables the read backstop — and the read can then never be recovered

**Unregistered. Same signal as TL-042's, nine lines away. This is the finding as dangerous
as `synth_b_pending`/`wr_hold_clr`.**

`src/rtl/tidelink_top.sv:1898, 1906`:

```systemverilog
assign ahb_sub_hreadyout = (sub_err1_r & ~synth_b_pending) ? 1'b0 :
                           (sub_err2_r & ~synth_b_pending) ? 1'b1 : …
assign ahb_sub_hresp     = ((sub_err1_r | sub_err2_r) & ~synth_b_pending) ? 1'b1 : xhb_sub_hresp_raw;
```

Both backstops share **one** timer (`sub_osr_ctr_r`) and **one** outstanding predicate
(`sub_axi_outstanding = sub_rd_os_r | (sub_wr_os_ctr != 3'd0)`, `:1573`). So a coincident
stuck **read** and stuck **write** — entirely ordinary on a wedged link — expires them
together at cycle T:

| line | action at T | value at T+1 |
|---|---|---|
| `:1674` | `if (sub_rd_os_r) sub_err1_r <= 1'b1;` | `sub_err1_r = 1` |
| `:1857`/`:1865` | `sub_wr_stuck_fire = (sub_osr_expired\|sub_stall_expired) & (sub_wr_os_ctr!=0)` | `synth_b_pending = 1` |

Both are high in the same cycle, so `sub_err1_r & ~synth_b_pending == 0` and the read's
two-cycle AHB ERROR is **suppressed**. (If `synth_b_pending` happens to clear at T+2 the
response degenerates to a single-cycle `HRESP=1` with `HREADYOUT=1` — an AHB protocol
violation. Both sub-cases are wrong.)

Then it becomes unrecoverable. `:1675` unconditionally does `sub_rd_os_r <= 1'b0`,
abandoning the read — and **both** ERROR-fire sites are gated on that same bit:
`:1645` (per-beat path) and `:1674` (I5 path) are each `if (sub_rd_os_r) sub_err1_r <= 1'b1;`.
With `sub_rd_os_r` cleared, **neither backstop can ever fire for that read again.** The
AHB master is left waiting on `xhb_sub_hreadyout_raw`, which for a lost R stays low.

**Net: a recovery firing on the write channel permanently defeats the read channel's
recovery, producing exactly the un-backstopped PS hang both mechanisms exist to prevent.**
Additionally `:1603` skips the pipeline abort while `synth_b_pending` is high, so the
wedged transfer keeps `pipe_hsel_r` asserted into XHB500 through the window.

This is a code-path reading, **not** sim-reproduced. It is falsifiable in one directed
test — see missing assertion #1. Note it interacts with TL-037 (no AXI firewall): if this
is right, the read path's only backstop is defeated exactly when the firewall is absent.

## N2. The AUTO_ANCHOR recovery beacon bypasses the SYNC-insert data-safety guard, and the RTL itself calls that path "a word-deleter"

**Unregistered. Data-corruption class, protected only behaviourally.**

`src/rtl/local_overrides/axi_chiplet_controller.sv:6730`:

```systemverilog
.swi_sync_force_always_in (swi_sync_force_always_r | winscan_force_sync
                           | ws_serve_active_r | auto_anchor_pulse_q),
```

That port is the bypass term of the guard in `src/rtl/local_overrides/WavD2DGpio_v2.v:677-680`:

```verilog
wire tx_sync_en_w = ~por_reset_scan_wrs_io_reset_out
                  &  io_swi_sync_insert_en_in
                  & (io_swi_sync_force_always_in
                     | (io_link_tx_tx_idle & (postcount == 8'h0)));
```

`(io_link_tx_tx_idle & (postcount == 8'h0))` is the guard that stops the SYNC inserter
deleting a live D2D word. Its own comment at `:668-675` says the data-safety claim *"was
untrue WITHOUT this guard"* and that `force_always` is *"Deliberately untouched."*
Asserting the AUTO_ANCHOR recovery ORs that guard away entirely.

The beacon FSM's own comment is unambiguous (`axi_chiplet_controller.sv:5027-5030`):

> *"force_always is a word-deleter (the idle-gated path is starved on this silicon, HW
> 08-05, so the beacon MUST use force_always), therefore it must NEVER run once app data
> flows."*

The only protection is behavioural: the pulse is gated on `auto_anchor_link_up &&
auto_anchor_tx_idle` (`:5013`) and permanently stopped on app-active (`:5033-5039`). So
the safety of a **data-corrupting** bypass rests entirely on a single-cycle idle
observation being race-free. Three sibling controls carry the same OR (`:6724`, `:6739`).

No test asserts a byte-exact transfer while `auto_anchor_pulse_q` is high, nor that it
drops before the first data word. Given `AUTO_ANCHOR_EN=1` is the byte-exact eth-chiplet
vehicle, this is worth a directed test before tapeout.

## N3. The RX-FIFO credit clamp fires and leaves the read pointer corrupted — and the clamp is what makes it invisible

**Unregistered. Data class. Gated test is green and asserts one thing.**

`src/rtl/fifo/tidelink_fifo_ctrl.sv:500-503` clamps credit to `MAX_CREDITS` when a
`read_complete` fires for a packet the FIFO does not hold — reachable **by design** after
a truncated packet, as the RTL comment at `:486-491` states. But `:202-204`:

```systemverilog
if (read_complete) begin
    read_ptr_nxt = read_ptr_r + RAM_ADDR_W'(read_packet_delta << 2);
end
```

is **un-gated by the clamp**. The phantom drain advances `read_ptr_r` while `write_ptr_r`
does not move, and `credit_count_r` is pinned at MAX — so the accounting reads perfectly
healthy while the read aperture is permanently offset from the write aperture. The only
resync is the software `flush` (`:211-217`).

That is the mechanism of the 2026-07-14 on-silicon corruption quoted in the same file at
`:380-383` ("a byte-exact 28-word burst read back as 26 words starting at payload[2]").
The clamp closes the over-advertise half and **makes the pointer half invisible**.

The gated test `cocotb/tidelink_top_pair_v2/test_v2_truncated_pkt_credit.py:82` asserts
exactly one thing — `assert cred_after <= MAX_CREDITS` — and stops. Gate status:
`v2_truncated_pkt_credit PASS 9s`.

## N4. Three blocking gate suites cannot detect the thing they are named after

**Unregistered. This is why the class keeps escaping.**

- `cocotb/tidelink_error_injection/test_ei_reset_storm.py:51-62` — `_run_n` contains **no
  assert statement at all**. Four blocking tests (`:65,:70,:75,:80`) cannot fail except by
  exception. The recovery verdict is computed and discarded:
  `recoverable = fm2 in (4, 5) and fs2 in (4, 5)` (`:58`) goes only to a log line.
- `cocotb/tidelink_top_pair/test_l7_wedge_repro.py:382-394` — the **blocking**
  `nack_wedge_recovery` gate returns **PASS with a `[SKIP-EQUIV]` log** when
  `socl_l7_wdog_force_clear` is absent. Combined with **C1/TL-036** this means the gate can
  be green while the shipping sideband watchdog is dead. Its `:479-480` comment then
  declines *by written policy* to assert the FSM leaves state 7, and no packet is sent
  afterwards.
- `gaps.py:712-722` (`test_i5_traffic_behind_a_stuck_write_is_bounded`) drives 24 reads
  after the backstop and counts `reads_ok`, then **never asserts it**. A run returning 24
  wrong values passes.

Related: `test_ei_lane7_repro.py` is scored by `Makefile:1138-1140` grepping a log line,
not by asserts; `test_ei_credit_probe.py:75-85` computes a phantom-pop verdict and only
logs it, so a `wptr_runaway` regression prints `SILENT-CORRUPTION` and still exits green.

And the one test in the repo with the correct shape — `test_14_sustained_ack_drop_wedge.py`,
which asserts wedge (`:341`) → state clears (`:379`) → post-wedge data delivered (`:383`) —
is **excluded from the gate because it fails** (0/8 delivery, `Makefile:1349-1362`). The
gate is green partly *because* the test with the right shape was taken out of it.

---

# Ranked table

| # | Mechanism | Set by | Cleared by | Dangerous fan-out | Test coverage gap | Risk |
|---|---|---|---|---|---|---|
| 1 | **`sub_err1_r`/`sub_err2_r`** read ERROR backstop `:1531,1645,1674` | `sub_osr_expired`/`sub_stall_expired`, **only `if (sub_rd_os_r)`** | one-shot `:1631` | **N1 — suppressed by `synth_b_pending` `:1898,:1899,:1906`; and `:1675` clears `sub_rd_os_r`, so it can never re-arm for that read** | Fires: `gaps.py:648`. Clears: never. Post: never (the clean read is *before*, `gaps.py:624`) | **CRITICAL — WEDGE** |
| 2 | **`synth_b_pending`** (I5 synth-B drain) `:1530,1865` | `sub_wr_stuck_fire = (sub_osr_expired\|sub_stall_expired) & (sub_wr_os_ctr!=0)` `:1857` | `synth_b_pending & s_axi_bready & (sub_wr_os_ctr<=1)` `:1870`. Latches **permanently** if XHB500 ever parks `bready` low | **term of `wr_hold_clr` `:1827`** — disables the TL-002 write-data hold wholesale. Five of its nine references disable something else (table below) | Fires: `gaps.py:579,795`. Clears: **never asserted**. Post-normal-path: only *sequentially*, never *concurrently* with the window. **TL-042 v2 does not remove this term** | **CRITICAL — DATA** |
| 3 | **`auto_anchor_pulse_q`** (AUTO_ANCHOR beacon) `acc.sv:4995-5046` | `AUTO_ANCHOR_EN & link_up & tx_idle & dwell met` `:5013-5018` | cap `:5021`, app-active `:5037` (**permanent `auto_anchor_done_q`**), link drop `:5042`, re-arm on training rise `:4999` | **N2 — ORs into `swi_sync_force_always_in` `:6730`, bypassing the SYNC-insert idle guard `WavD2DGpio_v2.v:677-680`.** RTL calls it "a word-deleter" | none asserts byte-exactness while the pulse is high, or that it drops before the first data word | **HIGH — DATA** |
| 4 | **RX-FIFO credit saturate-at-MAX** `fifo_ctrl.sv:500-503` | `read_complete` with `credit_sum > MAX_CREDITS` | comb — but the **corrupted `read_ptr_r` clears only on `flush`** | **N3 — the clamp masks the fault**: credit reads legal while `read_ptr_r`≠`write_ptr_r` (`:202-204` un-gated) | `test_v2_truncated_pkt_credit.py:82` asserts `cred_after <= MAX_CREDITS` **and nothing else** | **HIGH — DATA** |
| 5 | **`socl_l7_real_crc_seen`** → state-7 watchdog `FCSM_6.v:1620-1627` | first `crcCorruptSeen` ever | **`io_tx_reset` only — PERMANENT** | **C1 — negated ENABLE of `socl_l7_wdog_force_clear` `_6.v:646-648`.** Already logged as **TL-036** | blocking gate can PASS without exercising (N4) | **HIGH — WEDGE (registered)** |
| 6 | **`wr_hold_r`** (TL-002 peer-write hold) `:1824-1838` | `ext_is_nonseq & ahb_sub_hwrite & ~pipe_valid_r` `:1825` | W-last handshake **or `synth_b_pending`** `:1826-1827`. At HEAD the **only** escape for a stuck write is the dangerous term — the ERROR backstop is read-only (`:1645`,`:1674`) | it *is* the protection disabled by #2 | **Being fixed correctly** by TL-042 v2 in the working tree (fire+clear+post all asserted). The residual is #2's term, which v2 leaves in place | **HIGH — WEDGE (fix in flight)** |
| 7 | **Gate integrity** (`reset_storm`, `l7_wedge_repro`, `i5_traffic`) | — | — | — | **N4 — zero-assert blocking tests; PASS-without-exercise; computed-then-discarded verdicts** | **HIGH — process** |
| 8 | **a2l ACK window guard** (TL-027) + **revert rewind** (TL-032) `WlinkGenericFCReplayV2_{1,3,5}.v:80-83,163-171` | `a2l_ack_valid` rejects ACKs with `off_max > 8` | ACK back in window, or `link_revert` rewind (`_1/_3/_5` only) | contained — feeds only `a2l_link_addr_in` | **`_13` has the guard but NOT the TL-032 rewind** (`_13.v:230-254`, deliberately reverted); **`_12` has no window guard at all** (`_12.v:152-158`). Both in shipping flists. NODE=13 revert test **not gated**; the three gated a2l suites never compare a byte (`test_a2l_replay_cdc.py:551` discards all read data) | **MEDIUM — WEDGE (reachability unproven)** |
| 9 | **`TRAIN_ENTRY_FALLBACK`** `tidelink_autoneg.sv:71` | build param | n/a | **`:1283` `if (axl_rdata_r[I2C_STS_MISS_ACK] && !TRAIN_ENTRY_FALLBACK)`.** With the fallback on, a peer NACK no longer sets `train_peer_nack`/`peer_lane_fault=8'hFF`/`train_fail`/`ST_TRAIN_FAIL` — it falls through to the *success* branch `:1292-1299`. The hook **deletes peer-NACK detection**, not just re-routes it | `tidelink_autoneg_rolestrap` is in **neither** `ENVS` nor any `sim_gate_*` target. `test_train_fallback.py:139` asserts entry to `ST_TRAIN_RUN`; never `ST_TRAIN_DONE`/`EXIT` | **MEDIUM — masks a real fault** |
| 10 | **`SELF_ARM_TRAIN_EN`** `acc.sv:113` | build param (=1 on eth-chiplet) | n/a | **`:2260` `else if (local_training_mode_clr_w && !SELF_ARM_TRAIN_EN)`** disables the FSM's own `ST_TRAIN_EXIT` clear of `swi_training_mode_r`. *Reported, not personally re-verified:* also forces `role_lock_reg` `:912-913` (no clear arm) without setting the witness `mask_hs_verified_reg` | `i1_selfarm_rolelock` gated + PASS; no test asserts `swi_training_mode_r` returns to 0 on that path | **MEDIUM** |
| 11 | **`ws_rdv_timeout_q`** `acc.sv:5963,5998` | retries exhausted | `WS_ARM` `:5422` + POR | **`:5761-5762` `role_is_master && !ws_anchor_q && !ws_rdv_timeout_q && peer_ready_to_serve_w`** — setting the recovery bit disables the peer-serve fallback for the episode. `:5983-5996` says this is intentional ("exactly once per episode") | no gated test | **LOW-MED (by design)** |
| 12 | **L9/L9b/L9c mismatch masking** `FCSM_6.v:505,530-534,639` | three recovery signals | comb | `exp_pkt_not_seen_l9b = exp_pkt_not_seen_l9 & ~socl_l9b_reanchor_now & ~socl_l9c_backward` — each recovery ANDs away the mismatch→NACK protection. **Already hardened**: `fe_tx_credit_max_eff` `:514` pins a zeroed grant to 31 so `socl_l9c_back_thresh` cannot collapse to 0 and swallow every mismatch (`:510-513`) | — | **LOW — fixed precedent, cite it** |
| 13 | **TWIN-2 `ahb_inject_fault_r` sticky** `fifo_ctrl.sv:588-597` | stray unarmed AHB write pair | `flush` / reset | none | set asserted (`twin2.py:148`); **clear never tested anywhere** | **LOW — obs** |
| 14 | **Fix K BID correction** `:1864,1895` | `sub_wr_awid_r <= s_axi_awid` on every accepted AW | never (POR only) | overrides the bid on **every real B**, not just corrupted ones; safe only because `.hmaster(12'd0)` `:2474` ties awid constant | **best-covered mechanism in the repo** — `recovery.py:731-742` asserts fire + hazard-list drain + byte-exact after | **LOW (constant-assumption)** |
| 15 | **`calibrated_once_q`** `phy_align_calibrator_v2.sv:790-794` | `S_DONE && !validation_timed_out` | POR only | gates `role_locked_rise_eff`/`swreset_fall_eff` `:798-799`; `force_recal_rise` is the deliberate bypass `:859-861`. *Reported, not re-verified:* V1 `tidelink_phy_align_calibrator.sv:655` lacks the `!validation_timed_out` gate (TL-001, still live in V1) | `force_recal` suite gated and strong | **LOW-MED (V1 only)** |
| 16 | **APB bounded-stall `ext_timeout`** `:944-961,1428-1429` | `ext_stall_ctr_q == 1024` while `ext_stalled` | forced `pready` completes the txn ⇒ `ext_txn` drops ⇒ ctr resets `:954` | **none** — feeds only `tl_regs_pready/pslverr` | thin, but self-clearing and inert | **LOW** |
| 17 | **Phantom-pop `!rx_fifo_empty` qualifier** `fifo_ctrl.sv:364-365` | *preventive* qualifier — sets no state | n/a | none | **best-shaped pair in the repo**: `test_41:1802` asserts `read_ptr` did not walk; `test_42:1852` sends a real packet afterwards (last word excluded, `:1845-1851`) | **LOW** |
| 18 | Sticky obs bits `sub_wr_stuck_sticky`, `sub_err_sticky`, `xhb_stall_stuck_sticky`, `ext_stall_err_q` `:1707-1725`; `wedge_sticky_q`/`tgt_err_q`/`ini_err_q` `axinode_obs.sv:129-135`; `freq_mismatch_sticky` `clkfreq_check.sv:166` | their events | POR only | **none** — read-only into obs words, no control fan-out | n/a | **INERT** |
| 19 | Credit saturate-at-zero `fifo_ctrl.sv:444-449`; `rd_pipe_r` one-shot `:1767-1775`; `tx_err1_r` `fc_adapter.sv:317-346` | — | one-shot / comb | none | `test_32:1355`, `test_43:1983` assert the clamp; `test_33:1369` is nominally the "normal path" test but starts from a **fresh reset**, never after a saturation | **LOW** |

Shorthand: `recovery.py` = `cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_recovery.py`;
`gaps.py` = `.../test_axi_datanode_gaps.py`; `writehold.py` = `.../test_axi_datanode_writehold.py`;
`twin2.py` = `cocotb/tidelink_fifo_twin2/test_twin2.py`; `test_32/33/41/42/43` = `cocotb/tidelink_fifo/test_tidelink_fifo.py`;
`acc.sv` = `src/rtl/local_overrides/axi_chiplet_controller.sv`. Unqualified `:NNNN` = `src/rtl/tidelink_top.sv`.

---

# The three missing assertions

## #1 — a stuck READ must still get a legal AHB ERROR when a stuck WRITE times out in the same cycle

Target: `cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_gaps.py`, beside
`test_i5_read_stuck_errors_legally:600`. **This is the highest-value missing test in the repo.**

1. Leave **both** a read and a bufferable write outstanding (`sub_rd_os_r == 1` **and**
   `sub_wr_os_ctr != 0`) and starve both responses so one `sub_osr_ctr_r` expiry serves both.
2. `assert err1_fires > 0` — the read ERROR still fires.
3. `assert` the response is a **legal two-cycle** ERROR (`HREADYOUT==0 & HRESP==1` then
   `HREADYOUT==1 & HRESP==1`) — reuse the `illegal` checker already in `_err_watch`
   (`gaps.py:287-319`).
4. `assert synth_b_pending == 0` and `sub_err1_r == sub_err2_r == 0` after the event.
5. Issue a **clean read** afterwards and assert it returns the right data — proving the
   read backstop re-armed rather than being permanently disabled by `:1675`.

Step 5 is the one that should fail today.

## #2 — a peer write must land byte-exact **while** `synth_b_pending` is HIGH

Target: same file, beside `test_i5_backstop_restores_the_path:761`.

TL-042 v2 already proves *its own* escape is clean and does not route through
`synth_b_pending`. What is still untested is the **pre-existing** `| synth_b_pending` term
at `:1827`, which v2 does not remove: when the I5 backstop fires for its own reasons, the
TL-002 hold is off for the whole drain window.

1. Arm the I5 write backstop (lose a B) so `synth_b_pending` asserts.
2. **While `synth_b_pending == 1`**, present a peer AHB write (bufferable, `HPROT[2]=1`)
   and back-pressure `s_axi_wready` for ≥1 cycle.
3. `assert landed == D_CONCURRENT` — byte-exact at the far side.
4. `assert wr_hold_r_seen_high_during_window` — the hold engaged **despite** the backstop.
5. `assert synth_b_pending == 0` within `N_outstanding + margin` cycles, and `sub_wr_os_ctr == 0`.

Step 4 is what fails on the RTL as written. If it does, the fix is to qualify the term —
e.g. release `wr_hold_r` on a synth-B *edge* for the hold's own epoch rather than holding
`wr_hold_clr` asserted at level — which is exactly the discipline TL-042 v2 already
applies to its own path.

## #3 — after the credit clamp fires, the pointers must still be coherent and the next packet byte-exact

Target: `cocotb/tidelink_top_pair_v2/test_v2_truncated_pkt_credit.py:82`, immediately after
the existing `assert cred_after <= MAX_CREDITS`.

```python
ctrl = tb.top("s").u_tidelink_fifo.u_fifo_mem      # credit_count lives here (:47)
rp = int(ctrl.read_ptr_r.value); wp = int(ctrl.write_ptr_r.value)
assert rp == wp, (
    f"CLAMP MASKED A POINTER DESYNC: read_ptr={rp} write_ptr={wp} after draining a "
    f"truncated packet. Credit reads legal ({cred_after}) but the read aperture is "
    f"offset from the write aperture — tidelink_fifo_ctrl.sv:202-204 advances read_ptr "
    f"un-gated by the :500 clamp. This is the 2026-07-14 silicon signature.")

# and the (b) half: the normal path must still work with NO intervening flush
await tb.ahb_tx_write_packet("m", make_packet([0x600D0000 | i for i in range(6)]), gap=4)
...
assert got == expected, "packet after the credit clamp did not read back byte-exact"
```

If `rp == wp` cannot hold by construction, the right invariant is
`(wp - rp) mod SIZE == bytes_committed_not_yet_read`. Either way: **something** must tie
the pointers to the clamped credit, and today nothing does.

---

# Detail and provenance

## `synth_b_pending` — complete fan-out (`src/rtl/tidelink_top.sv` @ HEAD)

| line | expression | effect |
|---|---|---|
| `:1603` | `else if (sub_err1_r & ~synth_b_pending)` | pipeline abort **skipped** while high |
| `:1827` | `wr_hold_clr = … \| synth_b_pending` | **disables the TL-002 hold** |
| `:1865` | `if (sub_wr_stuck_fire) synth_b_pending <= 1'b1;` | set |
| `:1870` | `else if (synth_b_pending & s_axi_bready & (sub_wr_os_ctr <= 3'd1))` | clear |
| `:1873` | `s_axi_bvalid = s_axi_bvalid_ctrl \| synth_b_pending` | injects synthetic B |
| `:1874` | `s_axi_bresp = synth_b_pending ? 2'b00 : s_axi_bresp_ctrl` | **masks a real SLVERR to OKAY** for the whole window |
| `:1895` | `s_axi_bid = (s_axi_bvalid_ctrl \| synth_b_pending) ? sub_wr_awid_r : …` | Fix K |
| `:1898`/`:1899` | `(sub_err{1,2}_r & ~synth_b_pending)` | **suppresses the read ERROR** |
| `:1906` | `((sub_err1_r \| sub_err2_r) & ~synth_b_pending)` | **suppresses the ERROR HRESP** |

Five of nine references disable a different protection. That density is itself the
finding: `synth_b_pending` was reused as a general-purpose *"the backstop owns this
transaction now"* mode bit, and each reuse silently widened its blast radius. Any future
work on this region should give the backstop a **narrow** output (one clear, one B beat)
and stop using it as a mode.

**Permanent-latch path.** The clear at `:1870` requires `s_axi_bready`. Because
`s_axi_bvalid = … | synth_b_pending` (`:1873`), the drain is self-sustaining *provided
XHB500 keeps `bready` asserted* — it retires one outstanding write per cycle and clears at
`sub_wr_os_ctr <= 1`. If XHB500 ever parks `bready` low, `synth_b_pending` latches high
forever, `wr_hold_clr` is then permanently asserted, and the TL-002 hold can **never**
engage again until reset. Nothing in the RTL or the tests establishes that XHB500's
`bready` is unconditionally high.

## C1 — `WlinkGenericFCSM_6` watchdog (confirms TL-036)

`src/rtl/local_overrides/WlinkGenericFCSM_6.v:646-648`:

```verilog
wire        socl_l7_wdog_force_clear =
              (socl_l7_wdog_cnt == SOCL_L7_WDOG_THRESHOLD)
              & ~socl_l7_real_crc_seen;
```

`socl_l7_real_crc_seen` is a **permanent latch** (`_6.v:1620-1627`: set on the first
`crcCorruptSeen`, cleared only by `io_tx_reset`), so one CRC error ever permanently kills
the state-7 NACK watchdog. `WlinkGenericFCSM.v:309-315` documents exactly this as the bug
and fixes it by replacing the sticky proxy with `socl_l7_wdog_progress =
auto_tx_out_advance`, keeping the old form only behind `` `ifdef TL033_LEGACY_WDOG ``.

**Verified:** at HEAD **all six** variants ship the sticky form. In the **working tree**,
`WlinkGenericFCSM.v` and `_1`/`_2`/`_3`/`_4` have been given the `ifdef`/fixed form and
`_6` has not (`_6.v` is unmodified). `TL033_LEGACY_WDOG` is defined **nowhere** in any
flist, Makefile, tcl or shell script, so the fixed variants compile fixed. `_6` is the
TideLink link FSM (`TideLinkToWlink.v:149`, `WlinkGenericFCSM_6 wlink_tidelinktl`) and is
in both shipping flists (`flists/tidelink_fpga_v2.flist:316`,
`flists/tidelink_top_full_asic_v2.flist:321`). This matches TL-036 exactly; the only thing
this audit adds is that **the in-flight fix currently lands 5 of 6 and must not be
committed without `_6`.**

## `wr_hold_r` at HEAD — the escape *is* the hazard

`:1825` sets on `ext_is_nonseq & ahb_sub_hwrite & ~pipe_valid_r`; `:1826-1827` clears on
W-last **or** `synth_b_pending`. The AW and W channels feed independent FC nodes
(`:1814-1817`), so a wedged link can accept the AW while `wready` never rises — leaving
`wr_hold_r` high and `ahb_sub_hreadyout` low forever (`:1902`). The ERROR backstop cannot
help: both fire sites are `if (sub_rd_os_r)` (`:1645`, `:1674`), i.e. **read-only** since
the F-1 fix. So at HEAD the sole anti-wedge release for a stuck write hold is the term
that disables the hold wholesale. TL-042 v2 in the working tree adds an independent
release and is the right answer; it does not remove the `:1827` term, which is why
missing assertion #2 still stands.

## a2l replay overrides — the `_13`/`_12` asymmetry

Shipping flists **do** use the local overrides (this supersedes the older "not yet wired
to the shipping flist" note): `flists/tidelink_fpga_v2.flist:269,272,276,281,284` and
`flists/tidelink_top_full_asic_v2.flist:283,290,298,304`.

- `_1` (AW, `WlinkGenericFCSM.v:616`), `_3` (W, `_1.v:594`), `_5` (B, `_2.v:594`) —
  window guard **+** TL-032 revert rewind (`_1.v:163-171`).
- `_13` (TideLink sideband, `WlinkGenericFCSM_6.v:999`) — window guard only
  (`_13.v:136-139`); revert rewind **deliberately removed**, rationale `_13.v:230-248`.
- `_12` (l2a, `WlinkGenericFCSM_6.v:957`) — **no window guard at all**; `a2l_link_addr <=
  link_ack_addr` unconditional (`_12.v:152-158`).

The `_13` rationale is partly verifiable: `a2l_fc_replay_link_revert_addr =
~ack_seen_before ? 5'h0 : (link_ack_addr + 1)` (`WlinkGenericFCSM_6.v:1127,559-560`), and
with monotone ACKs `off_max = rbin_new - a2l_link_addr` stays small, so **I could not
construct a reachable freeze for `_13`** — stated rather than inflated. The
mutual-exclusivity claim in the `_1/_3/_5` comment **is verified**: ACK is tag `3'h2`,
revert is tag `3'h3`, both decoded from the same `ack_nack_fifo_io_rdata[18:16]`
(`WlinkGenericFCSM_6.v:1125-1127`).

The test posture is the weak part: gated suites are NODE=1/3/5 only (`Makefile:555-568`);
the NODE=13 module carrying the only revert-recovery and genuine-full coverage is not
gated; and `run_revert_recovery` (`cocotb/tidelink_a2l_replay_cdc/test_a2l_replay_cdc.py:551`)
asserts the guard clears (`:647`) but **discards every word it reads** — no byte compared.

## Templates that already get it right

Copy these rather than inventing a fourth shape:

- `cocotb/tidelink_force_recal/test_force_recal_pair.py:257`
  `test_03_bilateral_force_recal_relinks_byte_exact` — fires (`:294`), both dies back to
  `CAL_S_DONE` (`:304`), then byte-exact traffic both directions (`:312-313`). Best in repo.
- `writehold.py:596` `test_tl042_v2_escape_is_clean_and_writes_still_land` — the new one;
  escape (`:663`), recovery state clean during and after (`:681,:686,:689,:693`), normal
  write byte-exact after (`:727`). This audit's recommendation is that **every** new
  backstop test be written in this shape.
- `recovery.py:682` `test_axi_bid_corrupt_recovers_fixk` — fires (`:735`), hazard list
  drains to idle (`:739`), last write byte-exact (`:742`).
- `test_41`/`test_42` (`cocotb/tidelink_fifo/test_tidelink_fifo.py:1755,1811`) — the
  guard's no-op is proven *including the pointer* (`:1802`), and a real packet is read back
  afterwards (`:1852`).

## Corrections made during this audit

- An intermediate finding held that `_1/_2/_3/_4` ship the sticky-disarmed watchdog and
  that the TL-033 fix was committed. **Both wrong.** At HEAD all six are sticky; the
  `ifdef` fix exists only as **uncommitted working-tree changes** covering five of six.
- An intermediate finding held that `fe_tx_credit_max_eff` is a fix "applied only to `_6`
  and missing from the other five". **Misleading** — the L9/L9b/L9c machinery it protects
  exists only in `_6` (`WlinkGenericFCSM.v:300` says the lighter variants have "no L9
  layer"), so its absence elsewhere is correct, not a gap.
- Initial `tidelink_top.sv` line numbers were taken from the working tree, which then
  moved. All citations in this document are re-pinned to HEAD `d317c98`.

## Honest negatives

- The APB bounded-stall watchdog (`:944-961`) is **clean**: self-clearing, zero fan-out
  into any other mechanism. No finding.
- The sticky observability bits (`:1707-1725`, `axinode_obs.sv:129-135`,
  `clkfreq_check.sv:166`) are **clean**: they feed only obs words and no control logic.
- The phantom-pop `!rx_fifo_empty` qualifier is **clean**: it prevents state from being set
  rather than setting recovery state, and has no fan-out.
- `ext_data_pend_r` (`tidelink_tx_gen.sv:196-203`) has a structurally frozen state if
  `gen_owns` rises while it is 1, but `can_take` (`:207`) requires
  `ext_idle = ~ext_htrans[1] && !ext_data_pend_r`, so entry with `pend=1` is blocked. **No
  finding.**
- The `read_packet_active_r` path (`fifo_ctrl.sv:364-393`) lacks the
  `!read_packet_active_r` qualifier its write-side twin has (`:257-259`). I could **not**
  construct a corrupting sequence (offset 0 re-reads the same header while `read_ptr_r` is
  frozen), so this is an asymmetry worth a comment, **not** a bug. Speculative, labelled.
- Fix K's bid override is a no-op today because `.hmaster(12'd0)` (`:2474`) ties `awid`
  constant. LOW, and I found no reachable failure.
- `drainguard` — **no such identifier exists in the repo.** The name in older notes refers
  to the `synth_b_pending` "backstop drain (guard)" comment at `:1827` and the SOAK-DRAIN
  FIX at `:1676-1683`.

## Scope of the search

All of `src/rtl/**` (incl. `local_overrides/`, `fifo/`, `asic/`, `v2shims/`) grepped for
timeout / expired / watchdog / stuck / backstop / recover / guard / fallback / force /
escape / drain / abort / retry / replay / saturate / underflow / clamp / self_arm / sticky /
park patterns, plus a structural grep for recovery-named signals on the RHS of any `_clr` /
`_clear` / `_en` / `_ok` / `_valid` / `_ready` assignment, then a per-signal whole-tree
fan-out grep on each recovery state bit found. All of `cocotb/**` for the corresponding
tests and their gate membership (`Makefile:1359-1383`, `imp/sim_gate/*.status`), plus both
registry files for novelty.

**Answer to "is there anything as dangerous as `synth_b_pending`/`wr_hold_clr`?" — yes, two
new ones.** N1 (the write backstop suppressing the read backstop, then `:1675` making the
read unrecoverable) is the same signal, nine lines away, and unregistered. N2 (AUTO_ANCHOR
ORing away a guard the RTL itself calls a word-deleter) is data-class on the byte-exact
eth-chiplet vehicle. N3 is a green gated test asserting one thing while the pointer it
should be protecting walks. Everything else I found is either already registered, already
being fixed correctly, or inert — and I have said which is which.
