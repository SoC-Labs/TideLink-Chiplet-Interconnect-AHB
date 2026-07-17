# tidechart_tidelink_pair — TideChart ↔ TideLink integration smoke (gap F18)

First-ever co-simulation of **TideChart** with a real **TideLink pair**.

TideChart is verification-green standalone (60/60 cocotb + UVM, feature F18 in
`docs/TIDELINK_FPGA_VERIFICATION_PLAN.md`) but had **never** been wired to a
TideLink pair — not on silicon, not even a two-die integration smoke in
simulation. This bench closes that gap in sim. It is the precondition
(masterplan Priority-7 item) for any F18 hardware work.

## What it is

`tb_tc_pair.sv` stands up the proven two-die TideLink V2 pair (two
`tidelink_top`, cross-wired GPIO PHY) and, on **both** dies, attaches a
`tidechart_controller` via the ASIC `tidechart_shim`, wired to the exact ports
the chiplet integration uses:

| TideLink port | direction | TideChart (via shim, link port 0) |
|---|---|---|
| `tc_axis_tx_*` (48-bit) | TideChart → TideLink | election/enum/link-state-agent TX |
| `tc_axis_rx_*` (48-bit) | TideLink → TideChart | remote `PKT_EXT` (2'b10) words |
| `link_active` | TideLink → TideChart | gates the election FSM |
| `tl_local_link_state_o` / `tl_link_state_change_o` | TideLink → TideChart | congestion sideband |
| `tl_bcast_ack_i` | TideChart → TideLink | `local_bcast_ack_o` |

The shim/controller run at `NUM_PORTS=2` (the well-tested default): link port 0 =
this die's tidelink, port 1 tied off. Reference for the wiring:
`~/SoCLabs/nanosoc-ethernet-chiplet/src/rtl/{tidechart_shim,nanosoc_eth_chiplet}.sv`
(read-only). `tidechart_shim.sv` is compiled directly from that repo (read-only).

The bench REUSES, unchanged, the sibling pair bench:
`cocotb/tidelink_top_pair/{pad_skid.sv, tb_phc_model.sv}` (harness cells) and its
`PairTB` Python bring-up class + register map (imported by the test). Instance
names (`u_master`/`u_slave`) and `m_`/`s_` signal names are kept identical so the
import works verbatim. The one change vs `tb_top.sv`: the TideChart ports are
wired to the shims instead of tied off.

## Files

| File | Purpose |
|---|---|
| `tb_tc_pair.sv` | top: TideLink pair + TideChart on each die (derived from `tidelink_top_pair/tb_top.sv`) |
| `test_tc_pair_smoke.py` | the smoke test (imports `PairTB` from the pair bench) |
| `Makefile` | VCS + cocotb; V2 flist + tidechart flist + chiplet shim |
| `README.md` | this file |

## Run

```bash
cd cocotb/tidechart_tidelink_pair
make                    # dump on (waves.vcd)
TB_TOP_NO_DUMP=1 make   # dump off (faster; used for the transcript below)
```

Simulator = VCS (same as the pair bench). Always a V2 build
(`TIDELINK_PHY_V2` rides in `flists/tidelink_fpga_v2.flist`). The test uses the
pair-bench `force_calibrator_sim_bypass()` convention (S_VALIDATE shortcut).

## What is proven (result: **PASS 1/1**)

Transcript tail (`TB_TOP_NO_DUMP=1 make`):

```
 1600ns [die_a TideChart] DEVICE_CLASS=0x0001  PORT_COUNT=2
 2720ns [link DOWN] die_a election FSM = WAIT_LINKS (1)  TC_STATUS=0x000000f8  link_active=0
 7840ns [bring-up] role_locked master=1 slave=1 (PASS)
 8840ns [link UP] die_a election FSM = SETTLED (4)
 8840ns CROSS-BOUNDARY PROVEN: TideChart election advanced ONLY after TideLink asserted link_active.
12960ns [cal] SWI_LANE_STATUS M=0x460300ff S=0x460300ff  cal M=DONE S=DONE
81460ns [election] die_a: done=1 is_root=1  die_b: done=1 is_root=1  (FSM m=SETTLED s=SETTLED)
141700ns [bcast] die_a drove tc_tx_tvalid for 0 cy; die_b rx_bcast_count 0 -> 0 => PKT_EXT crossed: False
 ** TESTS=1 PASS=1 FAIL=0 SKIP=0 **
```

1. **(a) Elaborate/compile** — the combined stack (TideLink V2 pair + two
   TideChart controllers via the chiplet shim) compiles and runs under VCS. The
   `tidelink_top` FPGA build already **exposes** every port TideChart needs
   (`tc_axis_*`, `link_active`, `tl_local_link_state_o`, …) — the pair `tb_top`
   merely tied them off. **No FPGA-build signal gap for the tc_axis/link_active
   attach.**
2. **(b) Link still comes up with TideChart attached** — `role_lock` both dies,
   `cal_done` both dies (`SWI_LANE_STATUS=0x460300ff`), reusing the pair's
   `test_01` bring-up. TideChart's presence on the datapath does not break the
   link.
3. **(c) Cross-boundary observation (the F18 point)** — TideChart consumes a
   **real TideLink event**. With `election_start` armed while the link is down,
   die_a's election FSM **parks in `ST_WAIT_LINKS`** (`election_done=0`); it
   advances to `ST_SETTLED` **only after** tidelink asserts `link_active`. That
   transition is gated *solely* on the tidelink output — a genuine
   TideLink → TideChart hand-off, and discriminating (it provably does **not**
   self-advance without the link).

## Gaps found (honest — these are the deliverable's real value)

### G1 — `link_active` (=`role_locked`) precedes data-mode ⇒ premature election / DUAL-ROOT
`tidelink_top.sv:2539` ties `link_active = role_locked_o`. `role_locked` latches
early in bring-up (~7840ns here) — **long before** the link can carry TideChart
`PKT_EXT` traffic, which needs the Wlink LL "to-data-mode" bootstrap
(`do_to_data_mode`, run after `cal_done` at ~13000ns). TideChart's election is
gated on `link_active`, so it starts and **SETTLES at 8840ns as `is_root=1`
before any CLAIM can cross the die boundary**. Result observed: **both dies
elect themselves root (`is_root=1/1`) — a dual-root**, the incorrect outcome for
a 2-node fabric where exactly one node should win.

*Where it exists in the ASIC integration:* `nanosoc_eth_chiplet.sv:357`
(`assign link_active_o = tc_link_active`) forwards the same `link_active`; the
timing coupling is inherited, not introduced by this bench.

*What the FPGA/ASIC build needs:* either (i) TideChart must defer
`election_start` until the link is in **data mode** (gate on Wlink LL enabled /
`cal_done` + data-mode, not bare `role_locked`), or (ii) tidelink must expose a
distinct "link-carries-EXT-traffic" strobe for TideChart to gate on, leaving
`link_active` as the coarse role-locked indicator. This is a **sequencing
contract** to nail down before F18 hardware. (Note: the bench also arms die_a's
election early on purpose — to prove the parked→advance in (c) — which
compounds the effect; but even a data-mode-armed election on die_b alone
self-rooted, because die_a was already terminal in `ST_SETTLED`.)

### G2 — no TideChart `PKT_EXT` observed crossing the real link
The stretch broadcast (die_a `TC_CONG_CTRL` enable+trigger) drove
`tc_axis_tx_tvalid` for **0 cycles** and die_b's `rx_bcast_count` stayed `0`. So
in this run **no TideChart EXT packet was observed traversing
tidechart→tidelink→link→tidelink→tidechart**. Two candidate causes, not yet
separated (both are follow-up work, not harness bugs — the crossbar TX mux at
`tidechart_crossbar.sv:191-228` *does* forward agent broadcasts at lowest
priority):
  * the link-state agent did not emit (agent enable/trigger sequencing vs. the
    post-election controller state), and/or
  * the election CLAIM that *did* flood (at ~8840ns, pre-data-mode — see G1) was
    accepted by the local tidelink TX handshake but dropped because the LL was
    not yet enabled, so it never reached the peer.

A proper single-root election (both dies armed **after** data-mode, CLAIM
actually crossing) is the natural next test and the real proof that the
`tc_axis` datapath carries TideChart traffic end-to-end. It is deliberately
**not** claimed here.

## How this grows into the L4 verification-plan work

This smoke is the sim precondition (masterplan Priority-7). Next steps toward
the F18 "two-die integration smoke (election+enum+route)" and eventual hardware:

1. **Resolve G1 first** — decide the election-start sequencing contract
   (data-mode gate vs. new strobe), then add a test that arms both dies'
   elections **in data mode** and asserts a **single** root + correct
   `uplink_port`. That closes G2 by construction (CLAIM must cross).
2. **Enum + route** — after single-root, drive `enum_start`, assign IDs, and
   read back `TC_ROUTE_RD` hop/port to prove DFS enumeration over the live link.
3. **PHC/timestamp cross-check** — the shim also carries the congestion
   sideband; a later test can correlate a TideChart link-state event with a
   TideLink PHC timestamp (`d2d_phc_*`).
4. **FPGA BD wiring (a future lane)** — instantiate `tidechart_shim` next to the
   `tidelink_top` IP in the KR260 block designs (`fpga/targets/kr260-*`), giving
   TideChart its own APB aperture, and re-run election/enum on silicon. The RTL
   port surface is already present (proven by (a)); the remaining work is BD
   plumbing + an APB address for the TideChart register block, **plus the G1
   sequencing fix** so election does not self-root at role-lock.
```
