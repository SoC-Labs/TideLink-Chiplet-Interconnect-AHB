# CRC-injection matrix (verification-closure P0, lane 2)

Invariant: every packet the TX injector corrupts AND the RX CRC counter detects must lead to the
whole stream (plus one clean health message afterwards) being delivered exactly once, in order,
byte-exact. A shot that fires without the counter moving is `ERROR`, never a pass.

Code: `cocotb/tidelink_axi_datanode_recovery/` - `crc_matrix_core.py` (classifier `classify()`, node
adapters, shot engine), `test_crc_matrix.py` (one env-driven case per sim), `crc_matrix_cases.py`
(tiers), `run_crc_matrix.py` (runner). Truth sources: `ri_hit_{m,s}` (tb_top.sv, RTL `err_inj` term at a
packet advance = packets actually corrupted), the APB CRC counter (node base + 0x20), RX FIFO read-out
(sideband) / slave-die AHB BRAM bus monitor and returned read data (AXI).

Classes: EXACT, LOST, STRAY, DUP, INERT, ERROR (precedence ERROR > LOST > STRAY > DUP).

## Axes
node {sb 0xA1, AW 0x80, W 0x81, B 0x82, AR 0x83, R 0x84} x position {first, second, mid,
second_to_last, last; followers = packets after it} x size {S 4 pkts, L 16 pkts / 8 ops, X 32 / 16}
x direction {ab, ba - sideband only} x gap {0, 4, 16, 256, 2048 hclk} x profile {zero, silicon}.
* silicon = `EPOCH_PROFILE=silicon`: v37 S2M whole-word skew + `EPOCH_ANCHOR_EN=1` (ref clock is already the
  40 ns silicon ratio in this bench).
* AXI cases are master-initiated (the slave die's `ahb_sub` is tied off in this tb): AW/W/AR transmit m->s,
  B/R s->m, so both link directions are covered per node. AXI writes are POSTED so followers launch inside
  the NACK->replay window; reads are single-outstanding, so they never have followers.

## Must-fail controls (run first; any failure = HARNESS_BROKEN, matrix not run)
ctl_ship_default (shipping `disable_crc` reset values), ctl_readback (0x23C holds), ctl_live_{sb,W}
(right DataID, real injector: fired 1 and CRC +1), ctl_inert_{sb,W} (wrong DataID: fired 0, CRC +0,
stream exact = INERT), ctl_detect_sense_{sb,W} (CRC check off: CRC +0 and corrupted data delivered),
ctl_counts_sb (3 shots = 3 counter increments), mutants: sideband `+define+SOCL_L9_ALWAYS` (pre-TL-059 RTL,
sideband first/mid must go non-EXACT), and (gate/nightly) pre-Fix-G AXI mutant
(`socl_l7_reached_link_data` forced 0 after the clean precondition) on all five AXI nodes.

## Shipping CRC default (exposure)
FPGA/KR260 flist (`tidelink_fpga_v2.flist`): `WlinkGenericFCSM{,_1..4}` are the `src/rtl/local_overrides`
copies, which reset `out_prepend_swi_disable_crc <= 1` (CRC checking OFF; SoC Labs "Bug-C"), and nothing in
the shipping bring-up writes SM_CONTROL bit16. FCSM_6 (sideband) resets 0 (CRC on). ASIC flist
(`tidelink_top_full_asic_v2.flist`): FCSM 0-4 are the `deps` copies, reset 0 (CRC on) but without the SoC Labs
recovery FSM. Consequence: on the FPGA build a single-bit AXI-payload error is invisible (CRC +0, wrong data
lands, no NACK) unless software sets bit16=0 in each AXI node's SM_CONTROL (0x1014/0x1114/0x1214/0x1314/0x1414).
The matrix AXI cases write that bit over APB first (readback checked); `ctl_detect_sense_W` runs at the
shipping default and must show the silent corruption; `ctl_ship_default` fails if the reset values change.

## Targets and measured runtimes (VCS 2022.06, this host, see evidence dir)
| tier | make target | cases | workers | wall |
|---|---|---|---|---|
| quick | `make sim_gate_crc_matrix_quick` (also in `sim_gate` and `sim_gate_quick`, suite `crc_matrix_quick`) | 11 controls + 5 | 2 | ~4 min (serial: 6.5 min) |
| gate | `make sim_gate_crc_matrix_gate` (NOT in the aggregate) | 16 controls + 23 | 3 | 6.5 min measured |
| nightly | `make crc_matrix_nightly` (`CM_JOBS=4`) | 16 controls + ~220 | 4 | not run (estimate ~25 s/case) |
Per case: ~20-25 s (about 8 s of VCS sim plus startup); compile ~25 s per build per worker.
Full-gate launch line:
`cd <worktree> && { set +u; source set_env.sh; } && CHIPLET_HOME=/home/dam1n19/SoCLabs/td-bisect/pinned-chiplet-home-1ef68f1 TIDECHART_HOME=/home/dam1n19/SoCLabs/td-bisect/ethchip-pinbump-2026-08-19/tidechart make sim_gate`
