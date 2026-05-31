# Build #4 RTL-diff diagnosis vs Build #3 (dda0a0e → 573e767)

**Date:** 2026-05-29 (read-only analysis, no code changes)
**Baseline (Build #3, working):** `dda0a0e`
**Regressed (Build #4, broken):** `573e767` (submodule `axi-chiplet-controller @ 9ad2570`)
**Companion:** `docs/BUILD4_HW_VALIDATION_2026_05_29.md`

## 1. Executive summary

The regression is **not** caused by `mark_debug` synthesis folds on the returner path. The user's commit list under-counted: an intermediate commit `e72db73` ("cleanup: verification gap fills...") **stripped 134 lines from `tidelink_top.sv`** — removed the `dbg_shim_sel` Region-9 mux block, deleted `tidelink_fcsm_debug.sv` (214 L) and `tidelink_phy_align_regs.sv` (171 L). That's a much larger RTL surface than the prompt described.

The FCSM master-state-7 (SEND_NACK) / slave-state-4 (LINK_IDLE) wedge is described **verbatim** by the existing override in `local_overrides/WlinkGenericFCSM_6.v:1-66` (L7 bringup forgive). Since that override is **byte-identical** between builds, the trigger is upstream. The most credible mechanism is **bilateral ILA insertion**: Build #3 had ZERO marked nets and an empty `pynq_z2_tidelink_drc.xdc`; Build #4 connects ~334 nets to a new `u_dbg_int` core via 190 lines of `connect_debug_port` directives. The placement perturbation breaks the symmetric race window the L7-forgive gate depends on. Returner busy is a **downstream symptom**.

## 2. Complete RTL diff inventory (dda0a0e → 573e767)

### 2.1 `mark_debug` attributes added (commit ebbde0e)

**`src/rtl/tidelink_top.sv`** (FC-node boundary + HW_SYNC gate):
`tl_fc_a2l_valid` L492, `tl_fc_a2l_data` L493, `tl_fc_a2l_ready` L494, `tl_fc_l2a_valid` L495, `tl_fc_l2a_data` L496, `tl_fc_l2a_accept` L497, `tx_router_idle` L520, `fc_rx_fifo_ready` L607.

**`src/rtl/tidelink_fc_adapter.sv`** (RX FSM observability):
`fc_rx_fifo_valid` L77 (port), `fc_rx_fifo_addr` L79 (port), `rx_state_r` L424, `rx_pkt_type` L432, `rx_is_fifo` L437.

**`src/rtl/tidelink_ptp.sv`** (HW_SYNC FSM):
`ptp_rx_msg_type_r` L143, `hw_sync_force_en_r` L149, `hw_sync_trigger` L156, `hw_seq_num_r` L157, `tx_pending_r` L172.

**`src/rtl/fifo/tidelink_apb_regs.sv`** (pclk-domain, CDC accepted):
`pair_credit_counter` L318, `pair_credit_counter_en` L319.

**Submodule `axi-chiplet-controller @ 9ad2570`, `logical/wlink/ShortPacketToWlink.v`:**
`auto_tx_out_sop` L6 (port), `auto_tx_out_advance` L11 (port), `tx_fifo_io_wfull` L34, `tx_fifo_io_rempty` L35.

**Total: 24 mark_debug attributes (20 repo + 4 submodule).** `insert_debug_core.tcl` groups by base register name; fan-out produced the ~334 connected nets in `pynq_z2_tidelink_drc.xdc`.

### 2.2 RTL files deleted by commit 59e35e5

All five deletions verified **unreferenced** by any flist used by the FPGA target:

| Deleted | Live counterpart | Flist using live |
|---|---|---|
| `src/rtl/tidelink_apb_regs.sv` | `src/rtl/fifo/tidelink_apb_regs.sv` | `tidelink_fpga.flist:31` |
| `src/rtl/tidelink_fifo.sv` | `src/rtl/fifo/tidelink_fifo.sv` | `tidelink_fpga.flist:32` |
| `src/rtl/tidelink_fifo_ctrl.sv` | `src/rtl/fifo/tidelink_fifo_ctrl.sv` | `tidelink_fpga.flist:28` |
| `src/rtl/tidelink_returner.sv` | `src/rtl/fifo/tidelink_returner.sv` | `tidelink_fpga.flist:30` |
| `src/rtl/{asic,fpga,generic}/tidelink_sram.sv` | `src/rtl/fifo/{...}/tidelink_sram.sv` | `tidelink_{asic,fpga,generic}.flist` |

Deleted shadows had **different content** (e.g. `src/rtl/tidelink_returner.sv` md5 `0820df87…` vs live `b47cf2dc…`) but `grep -rn returner flist/ fpga/` returns only `src/rtl/fifo/tidelink_returner.sv`. No FPGA flist resolves to a deleted path.

### 2.3 Additional deletions by e72db73 (NOT in user's commit list)

- `src/rtl/tidelink_fcsm_debug.sv` (214 L, bind module — disabled since 2026-05-25)
- `src/rtl/tidelink_phy_align_regs.sv` (171 L, paddr 0x120-0x13F shim)
- 134-line strip of `tidelink_top.sv` (dbg_shim_sel mux arm + bind comment block)

All affected flists updated in the same commit. Lint-clean post-removal.

### 2.4 RTL moves
None. `formal/` → `xprop/` (12 files) is documentation only.

## 3. Returner-busy clearing path analysis

`src/rtl/fifo/tidelink_returner.sv` (live FPGA-flist returner):

- `busy = (state_r != ST_IDLE)` (L96)
- ST_DATA_PHASE → ST_IDLE only when `hready=1 && !hresp` (L181-188)
- `hready` chain: returner → `ahbm_hready` of `tidelink_fifo` → `rtn_hready` in `tidelink_fc_adapter.sv:245`: `rtn_hready = rtn_pending_r ? skid_can_accept : 1'b1;`
- `skid_can_accept` is downstream of the Wlink FC TX skid (fc_adapter L250-265)

**No mark_debug touches the clearing path.** None of `state_r`, `hready`, `rtn_hready`, `skid_can_accept`, `rtn_pending_r` carry `mark_debug`. `pair_credit_counter` mark_debug (HW report R-1) sits in the pclk APB-read domain — independent of the returner FSM clock chain, cannot block clearing.

**Mechanism for stuck-busy:** `skid_can_accept` → 0 → `rtn_hready` → 0 → returner wedges in ST_DATA_PHASE. This is **expected downstream behaviour** when FCSM master is at state 7 (SEND_NACK) refusing to drain new TX. Returner-busy is a **secondary symptom** of the FCSM wedge.

## 4. FCSM state-7 analysis

State encoding from `WlinkGenericFCSM_6.v` (`reg [2:0] state`): 0=IDLE, 1=TX_CR, 2=TX_CRACK, 3=post-credit, 4=LINK_IDLE, 5=LINK_DATA, 6=transitional, 7=SEND_NACK.

**State 7 was reachable in Build #3.** The encoding hasn't changed: `git diff dda0a0e..573e767 -- src/rtl/local_overrides/` returns empty. The override header (L1-66) describes the **exact Build #4 symptom**: "master FCSM wedges at state 7 (SEND_NACK) with CRC error counter = 0. Slave FCSM sits at state 4 (LINK_IDLE)." Author's diagnosis: a transient `isNotExpPacket` during bringup recal latches `send_nack_req` and the L7 forgive gate doesn't fire because `cr_pkt_seen_tx_demet & crack_pkt_seen_tx_demet` is never bilaterally true.

**Submodule c0a69ff → 9ad2570:** verified diff is **only** the 4 mark_debug attributes on `ShortPacketToWlink.v` — 6 insertions, 4 deletions, all attribute lines. **No Scala regen.** State 7 was not newly synthesisable; FCSM logic is bit-identical RTL.

**What's different is P&R.** With 334 newly-marked debug nets, Vivado's SLICE placement of `u_chiplet_controller/u_wlink/llrx/` and the FCSM `send_nack_req` register shifts. Build #3 had a deterministic recal where `cr_pkt_seen` + `crack_pkt_seen` consistently latched on both sides before any framer transient could enqueue `isNotExpPacket`. Build #4's altered placement pushes one side's `crack_pkt_seen` past the forgive window in 100% of deploys.

Consistent with the observed instability: PHY-layer convergence dropped from rock-solid (Build #3) to 2/5 cal_done=1 (Build #4).

## 5. Flist resolution check

All 14 flists + 12 FPGA-target TCLs searched for `tidelink_returner` and `tidelink_apb_regs`. Every hit resolves to `src/rtl/fifo/...` which exists at 573e767. `flist/tidelink_phy_align_regs.flist` was deleted in the same commit (e72db73) that deleted the source.

**No flist used by `pynq-z2-pair-all` / `pynq-z2-pair-flip-all` resolves to a missing file.** HW report R-3 (cleanup broke a flist) is **falsified**.

## 6. Ranked hypotheses

### H-1 (~60%): ILA placement perturbs LL_RX framer → reproducible SEND_NACK wedge

334-net ChipScope core inserted via `insert_debug_core.tcl` (none in Build #3) competes with the LL_RX framer + FCSM for SLICE placement around `u_chiplet_controller/u_wlink/llrx/` and `tl2wl/wlink_tidelinktl/`. The L7-forgive gate (`WlinkGenericFCSM_6.v:44-66`) requires bidirectional `cr_pkt_seen & crack_pkt_seen` — perturbed placement reliably breaks the symmetric race.

**Predicted:** master state 7, slave state 4, returner_busy=1, deterministic. **Matches HW report 100%.**

**Experiment:** rebuild with `FPGA_INSERT_DEBUG_CORE=0`, keep mark_debug attrs. ~45 min build + 1 deploy. If wedge clears, ILA placement is the trigger.

### H-2 (~20%): L7 forgive too narrow for bringup_pair_converge recal cycle

L7-forgive sticky `socl_l7_reached_link_data` only arms after FCSM reaches state 5 once. If recal prevents either side reaching state 5, forgive never arms. Build #3 may have been a lucky bringup.

**Experiment:** disable bringup_pair_converge recal in pynq_host (skip slot0=0x3 write per memory note `tidelink_interface_fcsm_bug`). If Build #4 then links, recal is the trigger.

### H-3 (~10%): `e72db73` removed APB Region-9 mux still expected by SW

Cleanup removed the dbg_shim_sel mux for paddr 0x120-0x13F. Region 9 now reads 0 (`src/rtl/fifo/tidelink_apb_regs.sv:529-533` default arm). If runtime SW writes 0x4403_2128/30/38 expecting an ACK with side-effects, that ACK is silent.

**Experiment:** `grep -rn "0x4403_2128\|0x44032128\|2128\b" pynq_host/ uvm/` for stale SW references.

### H-4 (~7%): `pair_credit_counter` mark_debug breaks pclk→hclk CDC fold

`tidelink_apb_regs.sv:318-319` adds mark_debug to pclk-domain registers. Vivado preserves net name + may skip auto-sync infer → previously inferred 2-FF sync degrades. **Does NOT explain state-7 SEND_NACK wedge** — orthogonal symptom.

**Experiment:** revert ONLY the two mark_debug lines, rebuild. If wedge persists (likely), kill this hypothesis.

### H-5 (~3%): submodule `9ad2570` mark_debug on `auto_tx_out_advance` breaks FCSM↔ShortPacket handshake

`auto_tx_out_advance` is FCSM credit input. Mark_debug may prevent timing-driven duplication into `_GEN_71`, costing a cycle on state-7 → state-4 recovery.

**Experiment:** revert submodule to `c0a69ff`, rebuild.

---

## Recommended first action

Run **H-1**: `FPGA_INSERT_DEBUG_CORE=0` build on 573e767. Isolates ILA-core insertion (placement) vs mark_debug attributes (per-net folds). HW report R-1 (pair_credit_counter mark_debug breaks returner) is **falsified** by §3 — no synth-fold path through `pair_credit_counter` reaches `state_r` or `rtn_hready`.

If H-1 links, workaround is `FPGA_INSERT_DEBUG_CORE=0` for production deploys; enable only for targeted captures. Long-term fix: add SLICE/pblock constraints in `pynq_z2_tidelink.xdc` to fence LL_RX framer + FCSM_6 so ILA placement cannot perturb them.
