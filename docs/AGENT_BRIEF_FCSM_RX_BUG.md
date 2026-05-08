# Agent brief: TideLink FC RX `cr_pkt` detection bug (SHORTCOMINGS 14a/14b)

## What you're solving

A deep RTL bug in the Wlink/TideLink FC stack: the master and slave
both *send* TideLink credit packets correctly but neither *sees* the
peer's cr_pkts, so the FCSM is permanently stuck in `SEND_CREDITS1`
(state `3'b001`) and the link never carries any payload data.

The link itself comes up — `link_status @ 0x234 = 0x18` on both
sides (`tx_active=1`, `rx_active=1`, `in_error_state=0`). All other
FC channels (AXI, GB, data_ids `0x08-0x84`, `0xa0`) bring up fine.
Only the TideLink FC channel (`cr_id=0x44`, `data_id=0xa1`, FC
channel index `6`) fails.

This is the same bug that surfaces as:
- `SHORTCOMINGS.md` **item 14b** — `test_top_autoneg_basic` autoneg
  succeeds but A→B AHB traffic never reaches B's FIFO (UVM symptom).
- `SHORTCOMINGS.md` **item 14a** — the bring-up issue mentioned in
  the "Remaining" paragraph (FPGA bring-up with `mask_hs_bypass=1`
  still doesn't carry traffic). Phase 2C/2D peer-mask handshake is
  complete and unrelated; the *remaining* hardware-validation
  blocker is this FCSM bug.

## Definitive evidence already captured

`memory/project_tidelink_fpga_bringup.md` (2026-05-08 ILA capture)
documents the smoking gun. Master state across 4096 ILA samples
post-deploy:

```
state[2:0] = 3'b001 (SEND_CREDITS1) — stuck
sop = 1; data_id = 0x44; word_count = 0x1F1F  ← Cat(ne_rx_credit_max,
                                                  ne_tx_credit_max)
tl2wl_..._tx_out_sop = 1, advance = 1 in 576/4096 samples (14%)
                                ← TxRouter DOES grant; cr_pkts ARE sent
```

Slave state is identical. Per
`deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala`
lines 457-470, `state` stays at `SEND_CREDITS1` until
`(crack_pkt_seen_tx || cr_pkt_seen_tx) && ll_tx.advance` together.
`ll_tx.advance` does fire (we see it). So the failure is that
`cr_pkt_seen_tx` (which is fed by RX-side detection of the peer's
cr_pkts) never asserts. **Conclusion: the bug is on the RX-side
detection path for the TideLink FC channel.**

Pad-RX captures earlier in the same session showed `cr_id=0x44`
reaching master's `pad_rx`. So the deserialised packet *is*
arriving on the wire — it's just not being routed to the
TideLink FC channel's `cr_pkt_seen_rx` signal.

## Most-likely culprit

Either:
1. `WlinkRxRouter` (in
   `deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/LinkLayer.scala`,
   look for `RxRouter` or the demux-by-`data_id` block) is
   decoding `data_id=0x44` to the wrong FC channel, or skipping
   it entirely.
2. The TideLink-specific FC node's `cr_pkt_seen_rx` logic is
   wrong (different shape from the AXI/GB FC nodes that work,
   even though it should have been identical).

Bias toward (1) because all other FC channels work — the difference
is mostly in the routing decode, not the per-channel logic.

## Concrete next step

Rebuild with additional ILA probes to confirm whether the RX
router decodes `0x44` to channel 6 at all. The build infrastructure
is already in place:

- `fpga/build_design.tcl` sources `fpga/insert_debug_core.tcl`
  when `FPGA_INSERT_DEBUG_CORE=1`.
- `fpga/targets/pynq-z2-pair-{all,flip-all}/pynq_z2_tidelink_timing.xdc`
  contains baked debug-core constraints + `set_property SEVERITY
  {Warning} [get_drc_checks LUTLP-1]` + the dbg_hub clock fix
  (`connect_debug_port dbg_hub/clk → clk_wiz_0_clk_out1`) needed
  because the auto-selected `pad_clk_rx_IBUF` doesn't run when
  the peer is silent.

Add `(* mark_debug = "true" *)` attributes to:
- `cr_pkt_seen_rx` and `cr_pkt_seen_tx` (in the TideLink FC
  `tidelinktl` block, generated from FC.scala)
- `ll_rx_valid` and `ll_rx_data_id` (in `WlinkRxRouter` or
  `LL_RX`)
- `auto_in_X_data_id` for *each* channel of `WlinkRxRouter` —
  this is the critical signal: it says which FC channel the
  router has decoded the incoming `data_id` to. If channel 6's
  `auto_in_6_data_id` never sees `0x44`, the bug is in the
  upstream decode. If it does see `0x44` but `cr_pkt_seen_rx`
  doesn't follow, the bug is in the per-channel cr_pkt detect.

Rebuild iteration: ~25 min wall-clock per side. Then ILA capture
via SSH tunnel `localhost:3121 → mapstone-dev:3121`, JTAG TCK at
1 MHz (`PARAM.FREQUENCY 1000000`), `run_hw_ila -trigger_now` for
free-running capture. Working `.tcl` script is at
`/tmp/ila_capture_run.tcl` from the prior session.

## Reproducers

### UVM (faster — same RTL behaviour, ms-scale debug loop)

```sh
cd uvm/tidelink_top_system
make run TEST=test_top_autoneg_basic
```

Expected current behaviour: autoneg succeeds (A `won=1`, B `lost=1`,
ROLE_CFG `0x02 / 0x03`, `link_status=0x18` on both sides via the
DIAG read at line 90), then 6 `SB_A2B mismatch` UVM_ERRORs because
B's FIFO returns 0 for every payload word.

If you fix the RX router / cr_pkt detection, this test will pass
end-to-end. The DIAG block I added is a useful extension point — add
checks on FCSM state register if you wire one up.

### FPGA pair

The full deploy + stress flow lands via fpgahub now — see
`docs/FPGAHUB_DEPLOY_PROPOSAL.md` for the onboarding sequence.
Briefly:

```sh
fpgahub --addr mapstone-dev.ecs.soton.ac.uk pair lease acquire bridge1 \
    --user $(whoami) --ttl 1800
fpgahub actions run pynq_z2_02_pl deploy_pair
fpgahub actions run pynq_z2_03_pl deploy_pair
# (stress_pair tests are blocked by a separate peer-agent SSH-topology
#  issue right now; for FCSM ILA capture you don't need to run stress —
#  just deploy + connect the Vivado HW Manager via the SSH tunnel.)
```

The submodule `deps/axi-chiplet-controller` is currently in a `git
bisect` state at `74d4c52` (pre-Phase 2). That's deliberate operator
activity hunting this bug — leave it alone. To rebuild a probed
bitstream you may need to `git bisect reset` first, then add the
`mark_debug` attrs to the FC.scala / Wlink.scala / Wlink.v paths.

## Files to touch (start here)

- `deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/FC.scala`
  lines 457-470 — the `SEND_CREDITS1` exit condition; primary suspect's
  upstream signals.
- `deps/axi-chiplet-controller/wav-wlink-hw/src/main/scala/LinkLayer.scala`
  — `WlinkRxRouter` / RX demux of `data_id`.
- `deps/axi-chiplet-controller/logical/wlink/Wlink.v` and
  `WlinkGenericFCSM_6.v` — generated Verilog. The user has
  already added `(* mark_debug *)` to the FCSM `state` reg (kept
  through synth/place/route).
- `fpga/insert_debug_core.tcl` and the per-target XDC for the
  ILA insertion flow.

## Files to leave alone

- `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv` and
  `axi_chiplet_controller.sv` — Phase 2 peer-mask work is complete
  and unrelated to this bug. The submodule is in a bisect state at
  pre-Phase-2; if you need to rebuild against current main, do
  `git bisect reset && git checkout main` first.

## Pointers to related context

- `docs/SHORTCOMINGS.md` items 14a (peer-mask, complete) and 14b
  (autoneg-traffic, deferred — *this brief*).
- `~/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/
  project_tidelink_fpga_bringup.md` — the live bring-up state with
  ILA evidence, captured 2026-05-08.
- `~/.claude/plans/peer-mask-handshake.md` — Phase 2 plan; helpful
  background but the issues there are resolved.
- `pynq_host/scripts/wlink_probe.sh` — canonical board-side
  diagnostic; use first when investigating a specific board.

## Constraints

- Lab boards `pynq_z2_02_pl` and `pynq_z2_03_pl` are leased via
  fpgahub `bridge1`. Acquire/release with `fpgahub --addr
  mapstone-dev.ecs.soton.ac.uk pair lease {acquire,release} bridge1`.
- Don't write to `AHB_TX (0x4400_0000)` from the PYNQ Linux PS until
  the link is verified up — wedges the SmartConnect AXI-Lite-to-AHB
  bridge and takes the board offline (requires power-cycle). UVM is
  the safer iteration loop for this bug.
- The fpgahub-driven deploy uses `pynq-z2-pair-all` for the master
  (die_a) and `pynq-z2-pair-flip-all` for the slave (die_b);
  bitstreams need to be mirrored RPi pinouts so the cross-cable
  wires up correctly.

## Definition of done

UVM `test_top_autoneg_basic` passes (autoneg + A→B AHB packet
round-trip), AND on FPGA `wlink_probe.sh` shows non-zero credit/data
counters on both sides after a doorbell ring (currently zero on
slave). Document the fix in a new `SHORTCOMINGS.md` patch — close out
14b, update 14a's "Remaining" line, and add a note to the bring-up
memory.
