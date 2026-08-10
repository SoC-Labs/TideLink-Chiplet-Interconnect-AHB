# Handover → TideLink agent: peer-write data-phase drop — fix at tidelink `ahb_sub` (Rank 1)

**From:** nanoSoC eth-chiplet integration (KR260 two-board silicon), 2026-08-06.
**One line:** die_a→die_b cross-die writes lose their DATA (die_b reads 0), because tidelink's
`ahb_sub` wrapper asserts `ahb_sub_hreadyout` **early** (at XHB500's address-accept /
early-write-response), so the AHB master releases HWDATA before the AXI W beat fires. Under
real W-channel backpressure the W beat slips and captures 0. **Fix belongs in tidelink** —
hold `ahb_sub_hreadyout` low until the W handshake completes (mirror the existing read fix).

## Should this be fixed at tidelink level? YES.
- The over-eager HREADYOUT is inside the `ahb_sub` wrapper (`tidelink_top.sv`). Only tidelink
  knows when the W handshake completes, so only tidelink can hold HREADY correctly.
- Integration-side (parent `nanosoc_eth_chiplet.sv`) **cannot** fix it: once the master
  releases HWDATA (because it saw HREADY high), no downstream register can reconstruct it.
  Three parent-side "hold" attempts (v1/v2/v3, see §5) all failed for this reason.
- tidelink already does exactly this for **reads** (`rd_pipe_r`). Rank 1 is the write mirror —
  completing an existing pattern, not inventing one. Ship via the same `local_override`.

## The bug — silicon evidence (2026-08-05, both dies)
- Deploy = both-fixes build (tidelink `9dfe1da` = 42da64b + Fix K; parent hwdata_q + AUTO_ANCHOR).
- Link fully up: `reanchored=1` BOTH dies (autonomous, R8=0), beacon done (`0x21F4=0x00bb0100`).
- `xfer_send` die_a: peer write `0x2F001000 <- 0xC0FFEE01` (CAM → die_b `0x2D001000`).
- `xfer_recv` die_b: `shared_sram_0[0x2D001000] = 0x00000000`, **5/5** writes. Address crosses,
  DATA is lost. Not an anchor problem (anchor is fixed), not a wedge (die_a stayed alive).

## Root cause (verified from RTL + g2 cycle trace)
1. `chiplet_d2d_decode` is not on the write-data path (HSELs + response mux only) — not here.
2. XHB500 (`u_xhb_sub`) samples `.hwdata` LIVE and issues its AXI W beat **1+ cycles after AW**
   (`xhb500_..._core_wdata.sv`: `write_data_valid` set at address-accept, `wdata_in` sampled
   later, `wdata_2_out_ready = s_axi_wready`).
3. `ahb_sub_hreadyout` (→ `hreadyout_peer` → decoder mux → `d2d_ahb_m_hready` → the SoC AHB
   master) is driven by `xhb_sub_hreadyout_raw` on the write **data** cycle — i.e. XHB500 says
   "accepted" at its address-accept while the W beat is still a cycle+ away
   (`tidelink_top.sv:1784-1788`). So the master sees HREADY high and **releases HWDATA after
   one data-phase cycle**.
4. g2 trace (idle link): AW at +1, W at +2 with `s_axi_wready` high the whole time, so the
   payload is still on the wire at +2 and it works. On silicon `s_axi_wready` drops for ≥1
   cycle (CDC FIFO fill / credits / a prior in-flight bufferable write), the W beat slips to
   +3+, HWDATA is already released (0), and XHB500 latches 0. **Deterministic 5/5.**
5. NB: the parent's `hready_to_peer` force (`nanosoc_eth_chiplet.sv:266`) is a **no-op** for
   this — tidelink derives readiness internally, never from `ahb_sub_hready` (your own comments
   at `:1449-1493`). The culprit is the HREADYOUT **output**, not the HREADY input.

## The fix — Rank 1 (recommended)
Mirror the read fix for writes: hold `ahb_sub_hreadyout` LOW across the write data-capture
window until the W handshake completes, so the AHB master holds HWDATA stable through any W
backpressure and XHB500 captures the correct live value whenever `wready` rises.

- **File:** `tidelink/src/rtl/tidelink_top.sv` → ship as
  `tidelink/src/rtl/local_overrides/tidelink_top.sv`, swapped in by `resolve_tidelink_flist.py`
  (the exact mechanism used for the read fix, patch 0003). TideLink's frozen pin untouched.
- **Add** (next to `rd_pipe_r`, ~:1717): a registered `wr_hold_r`
  - **set** when a peer WRITE address is latched: `ext_is_nonseq & ahb_sub_hwrite & ~pipe_valid_r`
  - **cleared** on the W handshake: `s_axi_wvalid & s_axi_wready` (`& s_axi_wlast` if bursts).
  - Use ONLY `s_axi_*` handshakes + registers so it keeps the wrapper's "no comb dependence on
    `ahb_sub_hready`" invariant (no new HREADY loop).
- **Apply** at the `ahb_sub_hreadyout` assign (`:1784-1788`): prepend `wr_hold_r ? 1'b0 :`
  ahead of the final `xhb_sub_hreadyout_raw` term — same shape as the `rd_pipe_r ? 1'b0` line.
- This is backpressure-depth-independent (the master holds HWDATA until the W actually lands).

**Deadlock guard (please review):** `wr_hold_r` MUST clear on the W handshake, not on a fixed
count. Confirm `s_axi_wready` genuinely rises for the peer write (it does — the datanode target
W face, `axi_tgt_0_w_ready`) so the hold always releases. A hold that never clears would stall
the peer AHB master → PS wedge. This is the one thing that needs your eyes on the actual FSM.

## Verification — and a real gap
- **g2 sim is BLIND to this bug.** `verif/g2_soc_pair::test_peer_write_crosses_to_die_b` PASSES
  regardless (idle link holds `s_axi_wready` high, W always at +2). We added
  `test_peer_write_survives_w_backpressure` + `test_diag_q_hold` (cocotb only, RTL untouched),
  but forcing `s_axi_wready` low **corrupts Wlink transport** rather than cleanly reproducing
  the drop, and the sim's fixed 1-cycle SoC→bridge capture means it cannot distinguish the
  fragile/parent-hold variants. So a green g2 does NOT validate this fix.
- **The real test is the KR260 bench.** Recipe: deploy `RUN_AFI=0` (the AFI fix wedges die_a's
  PS on load even canary-off; also export `TIDELINK_HOME`), turnkey bring-up until
  `reanchored=1` both dies, WAIT for `0x21F4` done=1 (the ~8s AUTO_ANCHOR force_always burst
  DELETES app writes until done), then `xfer_send`/`xfer_recv` soak — expect die_b SRAM =
  payload (LAND), die_a alive. Scripts: `pynq_host/scripts/kr260_eth_bringup_pair.sh`,
  `kr260_eth_run.sh xfer_send|xfer_recv`, `eth_tlapb_poke.py anchorobs|epoch`.
- **Better sim (suggested):** to make g2 a true regression, model the W backpressure at the
  Wlink INGRESS (credit/CDC) rather than forcing `s_axi_wready` — so the W beat slips without
  decoupling Wlink's internal accept from the wire. That's the missing piece to catch this in
  CI.

## Cleanup once Rank 1 lands
Delete the parent workaround `d2d_ahb_m_hwdata_q` register in
`nanosoc_eth_chiplet.sv` (~:281-323) and feed raw `.ahb_sub_hwdata(d2d_ahb_m_hwdata)` (:630).
It's insufficient anyway (see §5) and becomes dead once the master holds HWDATA.

## What's already validated on silicon (context — do NOT re-litigate)
- **Autonomous re-anchor**: both dies, R8=0. Works.
- **Fix K (`9dfe1da`)**: die_a wedge improved from write #3 → #6. The XHB500 hazard-list
  BID-mismatch wedge is fixed. A **residual intermittent wedge** remains (wedged at #6) — that
  is the physical W-byte-0 / marginal-eye class (WNS +0.484 ns, ILA-class), NOT hazard-list,
  NOT this data-drop. Separate workstream.

## §5 — parent-side attempts (why they failed, so you don't repeat them)
All in `nanosoc_eth_chiplet.sv`, all INSUFFICIENT:
- committed 1-cycle `hwdata_q` delay — timing-fragile (aligns only on idle link).
- v1 (registered addr-accept) — double-pulsed, re-captured the released 0. Silicon: 5/5 drop.
- v2 (dph_peer gated) — same double-capture.
- v3 (capture-once + `cap_done_r`, parent commit `1b2ae18`) — logically holds but unverifiable
  (g2 blind) and still parent-side, so it cannot beat the master having released the data.
Conclusion: the fix must stop the master releasing early → HREADYOUT-hold in tidelink (Rank 1).

## Provenance
- tidelink working tree HEAD `9dfe1da` (42da64b + Fix K). Parent pointer at it (65f0c5d),
  parent HEAD `1b2ae18`.
- Both-fixes bitstream snapshot: `<eth-chiplet-scratch>/bit_bothfixes/` (die_a 5d4b2d39,
  die_b 414fa7e7). Full run write-up: parent `docs/OVERNIGHT_HW_CAMPAIGN_2026-08-05.md`.
- Note: `9dfe1da` (Fix K) and `c6cc6eb` (sim-grafts: ANCHOR_LEN ifdef + SIM_BUILD `_autoanchor`
  key) are divergent siblings off 42da64b — converge them on the branch when you land Rank 1.
