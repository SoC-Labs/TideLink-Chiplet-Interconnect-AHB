# I1 FCSM override vs `role_locked=0` — root cause + fix

Branch: `strategy/i1-rolelock` (analysis; not pushed)
Date: 2026-07-30
Scope of lens: **`role_lock_reg`** in `src/rtl/local_overrides/axi_chiplet_controller.sv` — what sets/clears it and whether the I1 AXI-FCSM override can reach it.

All file:line references are into this worktree unless noted.

---

## TL;DR (headline finding)

**The I1 AXI-FCSM override CANNOT cause `role_locked=0`.** `role_lock_reg` has **no signal path** back from the five AXI `WlinkGenericFCSM{,_1..4}` nodes. Those FCSMs are held in **link/app reset by `~role_locked` itself** until role_lock latches, and the I1 diff changes **only** link-datapath logic clocked on `io_tx_clk` / reset by `io_tx_reset` (= `por_reset` = `~poresetn | ~role_locked`). Not one signal the override changes exists — let alone propagates — before `role_locked=1`.

This is the task's explicit fallback branch: *"If you CANNOT find a role_lock dependency on the FCSM (i.e. role_lock_reg should be 1), say so."* **role_lock_reg should be 1.** The true blocker for `role_locked=0` is the **mask-handshake gate on the role-lock latch** (`mask_hs_gate_open`, an anti-pattern the code's own comments say should not exist) not opening on the eth-chiplet — an I2C/mask-handshake matter, independent of the FCSM.

The memory's I1 chain is *internally* correct that `role_locked=0` is the upstream blocker (`role_locked → wlink_por_reset → fcsm=0`), but **mis-attributes** that `role_locked=0` to the FCSM override, which is downstream of role_lock (in reset). Reverting the FCSM flist most plausibly fixes a *different* symptom (all-zeros datapath / CRC-off / state-2 stall) or the A/B is confounded (see §6).

---

## 1. Exact `role_lock_reg` set/clear logic

Declared `:609`; exported as `role_locked` (`:634` `wire role_locked = role_lock_reg;`, `:643` `assign role_locked_o = role_locked;`). Register lives in the **POR-only** domain `always_ff @(posedge apb_clk or negedge poresetn)` (`:717`).

**Clear (only path):** `:720` `role_lock_reg <= 1'b0;` under `if (!poresetn)`. There is **no other** `role_lock_reg <=` clear in the file (grep confirms exactly three LHS assignments: `:720`, `:859`, `:863`). Once set it holds until POR.

**Set (two paths, both currently GATED):**
```
857  if ((nego_lock_pending_reg && mask_hs_gate_open) ||
858      (nego_lock_pending_reg && nego_lost_w)) begin
859      role_lock_reg <= 1'b1;                         // FSM/pending path
860  end else if (ctrl_reg_write && !role_locked && ctrl_reg_addr == 5'b01_000) begin
861      role_cfg_reg  <= ctrl_reg_wdata[0];
862      if (ctrl_reg_wdata[1] && mask_hs_gate_open)
863          role_lock_reg <= 1'b1;                     // direct SW-write path
```
`nego_lock_pending_reg` is set (`:790-792`) by *either* the autoneg `nego_set_role_lock_w` pulse *or* an SW W1S of `ROLE_CFG[1]` pre-lock.

So `role_lock_reg` latches iff, for a pending/SW lock intent, **`mask_hs_gate_open` is true** — *except* the lone `nego_lost_w` free pass (`:858`) on the autoneg-lost side.

### The gate
- `:706` `wire mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i;`
- `:688` `wire mask_hs_match = wlink_mask_hs_result[0] | autoneg_mask_hs_local_match;`
- `wlink_mask_hs_result` ← Wlink `.mask_hs_result_o` (`:6321`).
- `autoneg_mask_hs_local_match` ← `u_autoneg.mask_hs_local_match` (`:3391`).
- `mask_hs_bypass_i` ← from `tidelink_top` `:2564` `.mask_hs_bypass_i(HONEST_MASK_HS ? mask_hs_bypass_i : 1'b1)`. RTL default `HONEST_MASK_HS = 1'b1` (`tidelink_top.sv:158`; the "default 0" comments at `:155/:2561` are stale). **With `HONEST_MASK_HS=1` the gate is NOT force-open** — it needs a genuine handshake.

**Neither gate input consumes an AXI-FCSM output** (proven in §3–§4).

---

## 2. `role_locked` gates the Wlink (and thus the FCSMs) into reset

- `:2916` `wire wlink_por_reset = ~poresetn | ~role_locked;`
- `:2921` `assign app_clk_reset = ~hresetn | ~role_locked;`
- Wlink instance `u_wlink` (`:6152`) receives `.por_reset(wlink_por_reset)`, `.app_clk_reset(app_clk_reset)`.

Inside `src/rtl/local_overrides/Wlink.v`:
- `:2071` `assign phy_por_reset = por_reset;`
- `:2445` `tx_link_clk_reset_wrs_io_reset_in = por_reset | out_prepend_swi_swreset;`
- `:2448` `rx_link_clk_reset_wrs_io_reset_in = por_reset | out_prepend_swi_swreset;`
- FCSM app-side `io_app_reset = app_clk_reset_scan_wrs_io_reset_out` (`:2378`, ← `app_clk_reset`).
- FCSM main `.reset(axi2wl_reset)` with `axi2wl_reset = apb_reset` (`:2298`) — APB config side only.

**⇒ While `role_locked=0`, every FCSM's link side (`io_tx_reset`/`io_rx_reset`) and app side (`io_app_reset`) are held in reset.** `fcsm=0` on both dies is a *consequence* of `role_locked=0`, identical for deps and override. The causal arrow is `role_locked → fcsm`, so `fcsm` cannot drive `role_locked`.

---

## 3. What the I1 override actually changes (deps → local_overrides)

Commit `b98b944` ("fix(fcsm): I1 — re-point AXI FCSM 0-4 … + tune state-2 CRACK gate") touches **only**: the 5 override FCSM files, 3 flists (deps→local_overrides for FCSM 0-4), and a new cocotb suite. **It does not touch `axi_chiplet_controller.sv`, `Wlink.v`, `tidelink_top.sv`, or any reset/role_lock/nego logic.**

Full `diff deps/WlinkGenericFCSM.v ↔ local_overrides/WlinkGenericFCSM.v` (representative; `_1.._4` identical pattern). **Port list is byte-identical** (37 ports, verified). Every functional change is:

| Change | Where it lives | Clock / reset |
|---|---|---|
| `SOCL_L6_MIN_CR_EMITS=32` gate on state-1 exit | `_GEN_34`, `socl_l6_cr_emit_count` | `io_tx_clk` / `io_tx_reset` |
| `SOCL_L7_MIN_CRACK_EMITS` (32→**8**) gate on state-2 exit | `socl_l7_crack_release`, `_GEN_40/41/42/44/45` | `io_tx_clk` / `io_tx_reset` |
| NACK-forgive / watchdog / re-ACK (`isNotExpPacket_l7`, `socl_l7_wdog_*`, `socl_reack_*`) | `send_nack_req`/`send_ack_req` on state 4–7 | `io_tx_clk` / `io_tx_reset` |
| `out_prepend_swi_disable_crc <= 1'h1` (CRC-off default) | link-clk always block | link-clk reset |

The APB config side (`auto_in_psel/penable/pwrite/paddr/pwdata/pready/prdata`) is **untouched by the diff** (grep of the diff for `auto_in`/`pready`/`prdata` → 0 hits). So even a *pre-role_lock* AXIL→APB write to an FC node behaves identically deps vs override.

**Every changed register is `posedge io_tx_reset`-reset and gated on link FSM `state ∈ {1,2,4,5,6,7}`** — all dead while `role_locked=0`.

---

## 4. The signal-X search: there is none

`role_lock_reg` depends only on: `poresetn`; the `ctrl_reg_*` APB register bus; `nego_set_role_lock_w`/`nego_lost_w` (autoneg FSM); and `mask_hs_gate_open`. Tracing each:

- **`mask_hs_gate_open`** — `wlink_mask_hs_result[0]` is driven in `Wlink.v` (`:486` `assign mask_hs_result_o = {hs_result_fail_q, hs_result_match_q};`) by an **`apb_reset`-domain** self-contained 0x21C sniffer (`:477-484`, `always @(posedge apb_clk or posedge apb_reset)`), latching the peer's I2C verdict byte. FCSM-independent, alive pre-role_lock. `autoneg_mask_hs_local_match` comes from the autoneg FSM's I2C mask read (`u_autoneg`, `:3391`) — a GPIO sideband, not the Wlink FC datapath.
- **`nego_set_role_lock_w` / `nego_lost_w`** — from `u_autoneg`; its pre-role_lock progression to `ST_NEGO_DONE` and the mask handshake are I2C-only. Its `train_*` / `local_swi_lane_*` inputs matter only in the post-role_lock training phase.
- **`ctrl_reg_*`** — APB decode, not FCSM-fed.
- **`poresetn`** — top-level power-on reset input (`tidelink_top.sv:226`), not FCSM-fed.

The FCSM's *outputs* (`auto_tx_out_*`, `io_app_l2a_*`, `io_rx_crc_err`, `auto_in_prdata/pready`) feed the Wlink link layer / app FIFO / its own APB read-data — **none reach `role_lock_reg`, the mask gate, `poresetn`, or the autoneg FSM.**

**Conclusion: no shared signal X exists.** The override cannot set/clear/gate `role_lock_reg`.

---

## 5. So why is `role_locked=0` on the eth-chiplet? (real culprit to trace)

Given `HONEST_MASK_HS=1` and `mask_hs_bypass_i=0` (honest builds per `fpga/docs/KR260_PAIR_ONCHIP_PLAN.md`), `role_lock` latches only if the **mask handshake genuinely completes** (`mask_hs_match=1`) or on the autoneg-lost free pass. The eth-chiplet bring-up *writes* `ROLE_CFG=0x02` (SW path). That sets `nego_lock_pending_reg` (`:790`) but **`role_lock_reg` never latches while `mask_hs_gate_open` stays 0** (`:857`/`:862`). With no genuine peer-mask verdict arriving (I2C sideband to the ethernet peer not completing the mask exchange, and/or `nego_en=0` so no autoneg local-match and no `nego_lost_w`), the gate never opens ⇒ `role_locked=0` ⇒ `wlink_por_reset=1` ⇒ `fcsm=0`, `cal_state=0`, `training=0`. **This is identical with deps FCSM.**

This is the *anti-pattern* the code's own comments disclaim:
- `:767-778` — role_lock is a MUTUAL CLOCK ENABLE; making it wait on the verdict leaves "a die that never receives a verdict permanently gating its own PHY clock — a hard, bilateral, unrecoverable dead link"; integrity "enforced HERE instead" via `mask_hs_verified_reg`.
- `:4691-4701` — the integrity boundary was *relocated off* `role_locked` onto `mask_hs_verified_reg` (gates autonomous RETIRED operation), claiming "role_lock … latch exactly as before."

But the latch at `:857-863` **still gates role_lock on `mask_hs_gate_open`** for the won/SW paths. The relocation was done for RETIRED-entry (`:4701`) but **not completed on the role-lock latch itself.**

---

## 6. Reconciling with the "revert-FCSM-fixes-bring-up" A/B

Two non-exclusive explanations, both consistent with §1–§5:

1. **Different symptom.** The override's CRC-off default + `SOCL_L7_MIN_CRACK_EMITS` gate can stall the AXI FC in state 2 at the ~40 ns silicon ratio (all-zeros) — this *is* FCSM-related and *is* fixed by the deps revert. But that is the **datapath**, not `role_locked`. If the ILA read `role_locked=0` on the eth-chiplet, that is a *separate* mask-handshake blocker the deps revert does not address.
2. **Confounded A/B.** The "deps works" reference may be the **KR260 tidelink pair** (zero-poke `NEGO_CFG_RESET=0x61`, I2C healthy ⇒ autoneg mask-match ⇒ role_lock latches), while "override breaks" is the **eth-chiplet** (different integration; I2C/mask handshake to the ethernet peer may not complete). That changes *two* variables (FCSM **and** target/flow) — exactly the "check what else is dirty before an A/B one-variable" trap in memory. Needs confirmation with the eth-chiplet integration params (`HONEST_MASK_HS`, `NEGO_CFG_RESET`, whether the tidelink I2C pins reach a responsive peer) — outside this repo/worktree.

**Recommended confirmation (no build):** on the eth-chiplet build, read `OBS_MASK_HS` (bit[16] `autoneg_mask_hs_local_match`, [21] `wlink_mask_hs_result[0]`, [23] `mask_hs_verified_reg`) and `NEGO_STATUS` (0x2094, `nego_state/won/lost`). If `mask_hs_match=0` with the deps FCSM too, the FCSM is exonerated and the culprit is the mask gate, as predicted here.

---

## 7. The fix — decouple `role_lock_reg` from the mask-handshake gate

Complete the relocation the code already started (`:4701`): make `role_lock_reg` latch on the **lock intent** (SW W1S of `ROLE_CFG[1]`, or the autoneg `nego_set_role_lock` pulse) **without** waiting on `mask_hs_gate_open`. Integrity stays enforced by the unchanged `mask_hs_verified_reg` (`:779-780`, consumed at `:4701`).

### RTL change (`axi_chiplet_controller.sv`, `:857-863`)
```systemverilog
// role_locked is a MUTUAL CLOCK ENABLE (gates wlink_por_reset @:2916 =>
// this die's forwarded pad_clk_tx = the peer's pad_clk_rx). It must latch on
// the lock INTENT and hold, NEVER wait on the mask-handshake verdict.
// Integrity is enforced downstream by mask_hs_verified_reg (:779, gates
// autonomous RETIRED operation @:4701), which fails closed recoverably
// instead of bricking the forwarded clock. (was: gated on mask_hs_gate_open)
if (nego_lock_pending_reg) begin
    role_lock_reg <= 1'b1;
end else if (ctrl_reg_write && !role_locked && ctrl_reg_addr == 5'b01_000) begin
    role_cfg_reg  <= ctrl_reg_wdata[0];
    if (ctrl_reg_wdata[1])
        role_lock_reg <= 1'b1;
end else if ( ... unchanged ... )
```
Also loosen the `nego_lock_pending_reg` clear (`:793`) so pending clears once the lock latches regardless of the gate:
```systemverilog
else if (nego_lock_pending_reg)   // was: && (mask_hs_gate_open || nego_lost_w)
    nego_lock_pending_reg <= 1'b0;
```

### Why it is safe
- **Preserves every proven-healthy path.** On KR260 (autoneg + healthy I2C) the gate already opens, so role_lock latches at the same `ST_NEGO_DONE` moment; on bypass builds the gate was force-open. Behavior there is unchanged (role_lock may latch ≤1 cyc *earlier* — the SAFE direction).
- **Aligned with the F3 lesson, opposite of what regressed.** The reverted F3 made role_lock latch **later** (wait for the verdict) → `fcsm` stalled at 2 on silicon. This fix latches **earlier/unconditionally** → the direction the F3 note says is required ("make role_lock independent of the verdict TIMING").
- **No SHAM reintroduced.** `mask_hs_verified_reg` is untouched (still driven from genuine `mask_hs_match` alone, `:779-780`) and still gates autonomous RETIRED entry (`:4701`). A strap/bypass still cannot forge autonomous operation. The 07-24 honesty fix is preserved.
- **Fixes the eth-chiplet.** SW `ROLE_CFG=0x02` now latches role_lock → Wlink out of reset → FCSM/calibrator run → `nego_en & role_locked & swi_training_mode_r` can fire.

### Verification required before landing (NOT done here — analysis only)
1. `make sim_gate` on this branch (esp. `v2_mask_hs_bilateral`, `honest_mask_hs`, `nack_wedge_recovery`, the pair_data suites, UVM `top_system`).
2. Add a directed cocotb test: `HONEST_MASK_HS=1`, `mask_hs_bypass=0`, no peer verdict, SW `ROLE_CFG=0x02` ⇒ assert `role_locked=1` within N cycles (repro→regression).
3. Confirm §6 on the eth-chiplet build (read `OBS_MASK_HS`) to prove role_lock — not the datapath — was the eth-chiplet blocker.
4. ASIC note: this is a controller (not FCSM) change; re-check the `tidelink_top_full_asic*` netlists — but it removes a gate, it does not repoint a netlist.

---

## Appendix — key citations
- role_lock: decl `:609`; alias `:634/:643`; POR clear `:720`; set `:857-863`; pending set `:790-792`, clear `:793`.
- gate: `:706`, `:688`; `mask_hs_bypass_i` fold `tidelink_top.sv:2564`, `HONEST_MASK_HS` default `tidelink_top.sv:158`.
- reset: `:2916/:2921`; Wlink inst `:6152`; `Wlink.v:2071/2378/2445/2448/2298`.
- mask sniffer: `Wlink.v:470-486` (apb_reset domain).
- autoneg: `u_autoneg` `:3300-3392`; `mask_hs_local_match` `:3391`.
- integrity witness: `:712/:779-780`; RETIRED gate `:4691-4701`.
- I1 commit scope: `b98b944` (FCSM + flists + cocotb only).
- FCSM diff: all changes `io_tx_clk`/`io_tx_reset`, state 1-7; ports byte-identical.
