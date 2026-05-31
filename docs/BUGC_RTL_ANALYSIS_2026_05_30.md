# BUG C — RTL Analysis: S→M doorbell does not deliver

**Date:** 2026-05-30
**Branch:** `fix/fcsm-l7-wedge-watchdog` (commit `cbcd4ef`, build #5)
**Scope:** Read-only analysis of the doorbell path; no RTL changes.

---

## 1. Executive summary

The doorbell datapath through the SoC Labs RTL (tidelink_apb_regs →
tidelink_returner → tidelink_fc_adapter → Wlink TideLink FC node →
peer FC adapter RX → peer APB at 0x024) is **fully symmetric**: there
is **no `role`, `is_master`, `nego_*`, `swi_role_*` or `ROLE_CFG`
gate anywhere on this path**, in either direction. Both sides
instantiate the same parameterised `tidelink_fifo` /
`tidelink_fc_adapter` blocks, and `deploy_pair.sh` writes the same
`PAIR_BASE_ADDR=0x44032000` to both. The FC packet built by the
returner-interception logic (`{PKT_SIDEBAND, rtn_addr[13:0],
rtn_hwdata}`) and decoded on the far side
(`fc_rx_cfg_paddr = rx_addr_offset[APB_ADDR_W-1:0]`) is identical
regardless of role.

Therefore the asymmetry is **NOT in the SoC Labs sideband path**.
The most likely root cause sits in the layer below — the Wlink FC
node / FCSM credit flow — and specifically in the slave→master
direction's `auto_tx_out_advance` / FCSM state-machine wedge that
the current branch's `fix/fcsm-l7-wedge-watchdog` is trying to
recover. The bug visible at the application APB level (slave's
DOORBELL writes never appear at master's `0x024`) is a *symptom* of
the slave's TideLink-FC TX being unable to push *any* SIDEBAND/data
packet onto the link, not a defect in the doorbell address path.

A secondary, smaller asymmetry exists in board configuration (`die_b`
uses `tidelink-flip.bin` and `swi_phase_offset = 3`), but neither
touches the SIDEBAND data path.

---

## 2. Doorbell-path tracelist (M→S vs S→M side-by-side)

| Stage | Master rings (M→S) | Slave rings (S→M) |
| --- | --- | --- |
| **APB write** | M:`0x44032014` ← any value | S:`0x44032014` ← any value |
| **APB decode** (`tidelink_apb_regs.sv:204-213`) | `apb_region==0` ∧ `paddr[4:2]==3'h5` → `doorbell_trigger ← 1` for 1 cy | identical |
| **`pair_base_addr`** (`tidelink_apb_regs.sv:198`, reset from `TIDELINK_PAIR_BASE` param=0; SW-written to `0x44032000` by `deploy_pair.sh:329`) | `0x4403_2000` | `0x4403_2000` |
| **Returner ch-1 inputs** (`tidelink_fifo.sv:319-321`) | `interrupt_1=doorbell_trigger`, `write_addr_1=pair_base_addr+0x024=0x44032024`, `write_data_1=credit_count_data` | identical |
| **Returner FSM** (`tidelink_returner.sv:111-148`) | latches addr/data, issues AHB write to FC adapter rtn slave | identical |
| **FC adapter interception** (`tidelink_fc_adapter.sv:269-296`) | `rtn_addr_offset = rtn_haddr[13:0] = 14'h2024`, then `rtn_fc_word = {2'b01, 14'h2024, hwdata}` | identical |
| **TX arbiter / skid** (`tidelink_fc_adapter.sv:419-451`) | `sideband_grant` priority over TX aperture; pushed to `tl_fc_a2l_*` | identical |
| **Wlink TideLink FC node** (`Wlink.v` → `TideLinkToWlink.v` → `WlinkGenericFCSM_6.v`) | a2l_valid/data crosses async via `WlinkGenericFCSM_6` → IO_TX framer → pads | **a2l_valid/data BUILDS UP but is not draining: `auto_tx_out_advance` low / FCSM state stuck (see MEMORY: Bug A 2026-05-29 evening)** |
| **Peer pads / IO_RX / FCSM_6 RX** | observes data_pkt with data_id=`tidelinktl swi_data_id_1`, pushes to `io_app_l2a_data` | (slave's tx never made it; peer's RX sees no packet) |
| **Peer FC adapter RX FSM** (`tidelink_fc_adapter.sv:475-559`) | `rx_pkt_type==01` (SIDEBAND) → `rx_state_r` walks IDLE→ADDR→DATA → drives APB master | (no incoming valid → no APB cycle on master) |
| **Peer APB write** (`tidelink_fc_adapter.sv:570-580`) | `fc_rx_cfg_paddr = rx_addr_offset[11:0] = 12'h024`, psel/penable/pwrite | (never issued on master) |
| **Peer APB regs** (`tidelink_apb_regs.sv:294-310`) | `acc1_write` ⇒ `doorbell_response_acc += pwdata[15:0]` (saturating) | (no acc1_write seen) |

Note: `rtn_haddr[13:0] = 0x024 + (pair_base_addr[13:0]=0x2000) = 0x2024`. The peer's RX uses `[APB_ADDR_W-1:0]` = the lower 12 bits = `0x024`, which is exactly REG_DOORBELL_RESP_ACC. The high bits `0x2` are part of the encoded sideband payload but are dropped at the APB master. This is symmetric.

---

## 3. Role-dependent signals found

I searched `tidelink_top.sv`, `tidelink_fc_adapter.sv`,
`tidelink_returner.sv`, `tidelink_apb_regs.sv`,
`tidelink_fifo.sv`, `axi_chiplet_controller.sv`,
`tidelink_autoneg.sv`, `Wlink.v`/`local_overrides/Wlink.v`, and
`TideLinkToWlink.v` for `role`, `is_master`, `is_slave`, `swi_role_*`,
`role_lock*`, `ROLE_CFG`, `nego_*`.

**Asymmetric paths that exist:**

| Signal/path | Asymmetry | Affects doorbell? |
| --- | --- | --- |
| `wl_apb_pwrite` gate (`axi_chiplet_controller.sv:1265-1308`) | Slave forces `wl_apb_pwrite=0` unless `apb_debug_unlock_i=1` (deploy_pair sets it). Gates **external APB → Wlink APB** writes. | No — TideLink APB at 0x44032xxx (where 0x14/0x24 live) is a *different* APB subordinate from the Wlink APB at 0x44030xxx. SW write at `0x44032014` reaches `tidelink_apb_regs` regardless. |
| `i2c_*_reset`, `i2c_*_o` muxing (`axi_chiplet_controller.sv:811-1144`) | Pure I2C autoneg only. | No |
| `role_strap_i`, `role_effective`, `role_locked` (`axi_chiplet_controller.sv:343-368`) | Role lock controls `wlink_por_reset` and HW POR sequencing. | Once both sides have `role_locked=1` (deploy_pair confirms via ROLE_CFG bit[1]=1), the FC adapter path is identical. |
| `nego_lock_pending_reg`, `mask_hs_*` (controller) | Only affects `role_lock` latching. | No |
| `tidelink-flip.bin` for `die_b` (deploy_pair.sh:106) | Different XDC pin map for the flipped ribbon cable. | No (pinout only — RTL identical) |
| `swi_phase_offset` (deploy_pair.sh: 0 vs 0x60000) | Per-side serdes phase. | No (data path bit‑level only) |
| `tidelink_addr_translator` (CAM-based remap) | Optional remap on `ahb_sub` (peer aperture) path only. | **No** — doorbell rides FC SIDEBAND, which **bypasses** addr_translator entirely. |

**No role-dependent gate sits on the doorbell datapath.** Both
sides' returner channel 1 fires on `doorbell_trigger`, latches into
the FC adapter, joins the arbiter at priority 1, and is emitted to
`tl_fc_a2l_data` on next ready.

---

## 4. Address-translation analysis

There are two translators in the codebase:

1. **`tidelink_addr_translator.sv` + `tl_addr_trans_cam.sv` +
   `tl_addr_trans_regs.sv`** — CAM-based, sits on the **`ahb_sub`**
   path (the AHB→XHB500→Wlink_AXI peer aperture). It is *not* in
   the FC SIDEBAND path used by the doorbell. The FC adapter feeds
   `tl_fc_a2l_*` directly into the Wlink TideLink FC node.

2. **`tidelink_addr_translation.sv`** — MEMORY notes this as
   intentionally dormant ("NOT INSTANTIATED — use only for >8
   ranges"). Not in build.

**Therefore the doorbell's destination address is purely:**

```
target_byte_addr = pair_base_addr + 0x024              (returner)
fc_packet        = {PKT_SIDEBAND, byte_addr[13:0], hwdata}   (fc adapter TX)
peer_apb_paddr   = byte_addr[11:0]                      (fc adapter RX)
                 = 0x024                                  (both sides)
```

Both sides land at offset `0x024` of `tidelink_apb_regs`, which is
exactly `REG_DOORBELL_RESP_ACC`. Symmetric.

There is **no master/slave-conditional address rewrite anywhere** on
this path. A misaddressed S→M write would land at the wrong APB
offset and increment some *other* register — the observation that
master's REG_DOORBELL_RESP_ACC stays at *exactly* `0` (not stuck at
some other value, not partially incremented) is consistent with **no
SIDEBAND packet ever arriving**, not with mis-decoded address bits.

---

## 5. Ranked hypotheses

### H1 (★★★ most likely) — Slave-side Wlink FCSM cannot push outbound packets

The slave's TideLink-FC TX path (everything from
`tl_fc_a2l_valid/data` onwards inside Wlink's `WlinkGenericFCSM_6`)
is the **only place where master and slave behaviour can already be
shown asymmetric on this very repo**. MEMORY `bugA_master_tx_block`
records the exact symptom — "slave Wlink FCSM stuck at state 4" —
and the current branch carries an explicit watchdog
(`fix/fcsm-l7-wedge-watchdog`) targeting this. The FC adapter's TX
arbiter on slave is presenting `rtn_fc_valid=1` with `rtn_fc_word`
correctly assembled, but the skid buffer cannot drain because
`tl_fc_a2l_ready` stays low (FCSM not granting `auto_tx_out_advance`).

If H1 is the cause, the same wedge should *also* block slave→master
*data packets*, *credit returns*, and *PTP servo timestamps* — not
just doorbells. The fact that PTP servo also reportedly doesn't
converge in S→M direction on the same build is consistent.

**Cheapest experiment:**
- On master, read REG_RELEASED_CREDITS_ACC (`0x020`) after slave
  emits an AHB data write. If acc stays at 0 too (not just
  doorbell-acc), H1 is confirmed: nothing crosses S→M.
- On slave, read `tx_dropped_cnt_r` (16-bit counter in
  `tidelink_fc_adapter.sv:196` — currently not exposed via APB but
  visible in ILA; the L10/L11 wedge watchdog increments it). If it
  saturates while rtn_fc_valid stays high, FCSM is starving the
  arbiter.
- ILA: `tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/tl2wl_io_obs_fcsm_state` (3-bit) on slave — confirm stuck at non-0/non-7.

### H2 (★★) — Slave's returner-channel-1 trigger never asserts

If `doorbell_trigger` on slave's `tidelink_apb_regs` is somehow
masked (e.g. by a reset condition not on master, or by the
self-clearing pulse colliding with `ctrl_flush_r` / `ctrl_lock_r`),
the returner never fires and no packet is launched. Highly unlikely
because: (a) `tidelink_apb_regs.sv:202` unconditionally pulses
`doorbell_trigger` for one cycle on a write to `0x14` regardless of
any role/lock state, and (b) the W1C trigger uses the same decode on
both sides.

**Cheapest experiment:**
- Add a 4-bit edge counter on slave's `doorbell_trigger` and route
  to an unused APB read slot (or to ILA via mark_debug). If it
  ticks 100 times when SW rings doorbell, H2 is falsified.
- Or simply read `u_tidelink_fifo/u_apb_regs/doorbell_trigger` via
  ILA — it should pulse on each `apb_write` to `0x014`.

### H3 (★) — Slave's returner busy/wedged on a higher-priority channel

The returner has fixed priority 0>1>2. If channel-0 (credit release)
or channel-2 (reset doorbell) is permanently pending on slave but
cannot complete (e.g. because the FC adapter rtn skid is wedged —
which is itself H1-like), it will starve channel-1.

**Cheapest experiment:**
- Read `returner_busy` (`tidelink_apb_regs.sv:42`, surfaced in
  STATUS reg bit[0] at `0x010`) on slave during the test. If
  permanently high, the returner is wedged.
- Read `master_error` (STATUS bit[3]) — set on `hresp=1` after retry
  exhaustion. If set, the returner saw repeated bus errors.

### H4 (★) — `pair_base_addr` on slave was never written or got cleared

If slave's `pair_base_addr` is `0` (POR default), then slave's
returner addresses target `0x024` instead of `0x44032024`. Then
`rtn_haddr[13:0] = 14'h0024` and the encoded byte_addr in the FC
packet is `0x0024` instead of `0x2024`. The peer's APB master still
strips to `0x024`, so **this would still land at REG_DOORBELL_RESP_ACC
correctly on master**. So H4 is *not* sufficient by itself to
explain the missing increment — but worth checking because the
MEMORY note `★★ TideLink AHB address map` documents 12h of debug
caused by exactly this kind of base-addr confusion.

**Cheapest experiment:**
- Read slave's REG_PAIR_BASE (`0x44032000`) — should read back
  `0x44032000`. If `0`, deploy_pair didn't take.

### H5 (low-prob) — Asymmetric FC adapter parameter elaboration

Both sides instantiate `tidelink_top` with `TIDELINK_PAIR_BASE=0x0`
(the wrapper default), and the parameter only affects the **reset
value** of the run-time-writable `pair_base_addr` register. Since
`deploy_pair.sh` overwrites this on both sides via APB, the param
default is irrelevant. No other parameter (RAM_ADDR_W, FC_DATA_W,
APB_ADDR_W) is plumbed asymmetrically.

**Cheapest experiment:** none needed — falsified by parameter
inspection in `tb_top.sv` (both sides `=32'h44032000`) and
`tidelink_design.tcl` (single CONFIG.TIDELINK_PAIR_BASE = 0).

---

## 6. RTL-fix proposal (only if H1 is confirmed)

The doorbell path itself does **not** need any RTL fix — it is
correctly symmetric. The fix must live in one of two places:

**Option A (preferred, in-scope for this branch):** Extend the
existing `fix/fcsm-l7-wedge-watchdog` so that the slave-side FCSM's
state-7→IDLE recovery also fires when **the FCSM is stuck at state
4 with `a2l_valid=1` for > N cycles AND `auto_tx_out_advance=0`**
(i.e. a TX-starvation watchdog, not just a NACK-clear watchdog).
This would unblock the doorbell exactly the way the existing
state-7 watchdog unblocked NACK recovery. The watchdog already
exists in the same file (`local_overrides/Wlink.v` / commit
`f5633f1`), so adding a sibling counter on state-4 is mechanically
identical.

**Option B (in `tidelink_fc_adapter.sv`):** Surface the
`tx_dropped_cnt_r` (line 196) into the APB read mux at a free
Region 0 slot, so SW (and hwtest scripts) can detect L10/L11 wedge
events without ILA. This is observability, not a fix, but it makes
H1 falsifiable from SW in seconds instead of requiring ILA capture.

**Do not propose changes to `tidelink_returner.sv`,
`tidelink_fc_adapter.sv` (TX path), or `tidelink_apb_regs.sv` for
this bug** — they are correct and symmetric.

---

## Appendix: files inspected (all read-only)

- `/home/dam1n19/SoCLabs/tidelink/src/rtl/tidelink_top.sv` (lines 40-100, 580-700, 840-900, 1005-1200, 1750-1850)
- `/home/dam1n19/SoCLabs/tidelink/src/rtl/tidelink_fc_adapter.sv` (full)
- `/home/dam1n19/SoCLabs/tidelink/src/rtl/fifo/tidelink_returner.sv` (full)
- `/home/dam1n19/SoCLabs/tidelink/src/rtl/fifo/tidelink_apb_regs.sv` (full)
- `/home/dam1n19/SoCLabs/tidelink/src/rtl/fifo/tidelink_fifo.sv` (lines 1-340)
- `/home/dam1n19/SoCLabs/tidelink/src/rtl/tidelink_addr_translator.sv` (interface only)
- `/home/dam1n19/SoCLabs/tidelink/src/rtl/tidelink_apb_addr_ctrl.sv` (lines 1-100)
- `/home/dam1n19/SoCLabs/tidelink/deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv` (role/APB mux blocks)
- `/home/dam1n19/SoCLabs/tidelink/deps/axi-chiplet-controller/logical/wlink/TideLinkToWlink.v` (full)
- `/home/dam1n19/SoCLabs/tidelink/deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_6.v` (state machine + advance signals)
- `/home/dam1n19/SoCLabs/tidelink/pynq_host/scripts/deploy_pair.sh` (role/strap/PAIR_BASE writes)
- `/home/dam1n19/SoCLabs/tidelink/fpga/targets/pynq-z2-pair-all/tidelink_design.tcl` (BD address map)
