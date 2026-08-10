# Simulation Tests

The practical catalogue: every simulation environment in the tree, whether it is
gated, and the exact command to run it. Strategy, CI status and the traps are in
[Verification](verification.md).

Every command on this page was checked against the Makefile that provides it.
Where a command could not be verified, the page says so.

## Before anything else

```bash
cd $TIDELINK_HOME
source ./set_env.sh
export PATH="$VCS_HOME/bin:$VERDI_HOME/bin:$PATH"   # set_env.sh does NOT do this
export TIDELINK_PHY_V2=1                            # most V2 work needs it
```

Simulator is VCS (`SIM = vcs`, `TOPLEVEL_LANG = verilog` in every cocotb
Makefile). `PYTHONPATH` picks up `$(TIDELINK_HOME)/python` for the TideLink
packet-encoding helpers. Forgetting `set_env.sh` fails **every** suite in 4-5
seconds and mimics an RTL break — see
[Verification](verification.md#the-4-5-second-whole-gate-failure).

## Command cheat sheet

| Goal | Command |
|---|---|
| Full pre-merge gate | `make sim_gate` |
| Smoke gate (14 suites) | `make sim_gate_quick` |
| List the gate without running it | `make sim_gate_inventory` |
| One gate suite | `make sim_gate_<target>` (e.g. `make sim_gate_v2_data`) |
| One cocotb env, default module | `make -C cocotb/<suite>` |
| One cocotb test module | `make -C cocotb/<suite> MODULE=test_<name>` |
| The 28 unit envs | `make -C cocotb regression` |
| One unit env via the aggregate | `make -C cocotb <envname>` |
| Unit-env coverage | `make -C cocotb coverage` |
| UVM: build | `make -C uvm/<env> compile` |
| UVM: one test | `make -C uvm/<env> run TEST=<test_name>` |
| UVM: all tests in an env | `make -C uvm/<env> run_all` |
| UVM: waves | `make -C uvm/<env> waves TEST=<test_name>` |
| X-prop formal | `make -C xprop regression` |
| Clean everything | `make clean_all` |

:::{danger}
**Never `make -n sim_gate`.** The dry run used to fabricate `PASS` status
files. The macro now refuses (`Makefile:234-249`), but the habit is the hazard.
Use `make sim_gate_inventory`.
:::

## The gated suites

43 blocking suites and 2 sentinels. This table maps each **suite name** (what
appears in `imp/sim_gate/<name>.status`) to its make target and the bench it
runs. Regenerate the authoritative list with `make sim_gate_inventory`.

| Suite | `make` target | Bench | Module / configuration |
|---|---|---|---|
| `t31_autonomous_training_exit` | `sim_gate_t31` | `cocotb/tidelink_top_pair` | `test_31_autonomous_training_exit`, `SIM_BUILD=sim_build_l4` |
| `t32_die_a_first_zombie_retry` | `sim_gate_t32` | `cocotb/tidelink_top_pair` | `test_32_die_a_first_zombie_retry`, `BYPASS_AUTONEG=1`, `sim_build_l5` |
| `t33_arm_stagger_episode_bind` | `sim_gate_t33` | `cocotb/tidelink_top_pair` | `test_33_arm_stagger_episode_binding`, shares `sim_build_l5` |
| `t30_autonomous_fc_handoff` | `sim_gate_t30` | `cocotb/tidelink_top_pair` | `test_30_autonomous_fc_handoff`, shares `sim_build_l4` |
| `nack_wedge_recovery` | `sim_gate_nack_wedge_recovery` | `cocotb/tidelink_top_pair` | `test_l7_wedge_repro` **and** `test_13_ack_drop_recovery` |
| `apb_fc_cfg_preempt` | `sim_gate_apb_preempt` | `cocotb/tidelink_top_pair` | `test_apb_fc_cfg_preempt` — locks a PS hang that costs a power cycle |
| `fch_apb_watchdog` | `sim_gate_fch_wdog` | `cocotb/tidelink_top_pair` | `test_fch_apb_watchdog` — same PS-hang class |
| `zeropoke_por` | `sim_gate_zeropoke` | `cocotb/tidelink_top_pair` | `test_zeropoke_por`, `+define+TB_TOP_NEGO_CFG_RESET=97`, own `sim_build_zeropoke` |
| `retire_en_plumb` | `sim_gate_retire_plumb` | `cocotb/tidelink_top_pair` | `test_31_...` again with `RETIRE_EN=0` — the A/B negative control |
| `v1_elab` | `sim_gate_v1elab` | `cocotb/tidelink_top_pair` | build-only, `TIDELINK_PHY_V2=0`, fresh `sim_build_v1elab` |
| `v2_pair_data` | `sim_gate_v2_data` | `cocotb/tidelink_top_pair_v2` | `EPOCH_PROFILE=zero MODULE=test_v2_pair_data` |
| `v2_pair_sustained` | `sim_gate_v2_sustained` | `…_pair_v2` | `test_v2_pair_sustained` |
| `v2_truncated_pkt_credit` | `sim_gate_v2_trunc_credit` | `…_pair_v2` | `test_v2_truncated_pkt_credit` |
| `v2_isolated_write` | `sim_gate_v2_isolated_write` | `…_pair_v2` | `test_v2_isolated_write_dataloss` |
| `v2_mbox_writeprotect` | `sim_gate_v2_mbox_writeprotect` | `…_pair_v2` | `test_v2_mbox_apb_writeprotect` |
| `v2_autonomous_sync_detect` | `sim_gate_v2_syncdet` | `…_pair_v2` | `test_v2_autonomous_sync_detect` |
| `v2_winscan_fsm` | `sim_gate_v2_winscan` | `…_pair_v2` | `test_v2_winscan_fsm` |
| `v2_perf_ctrl` | `sim_gate_v2_perf` | `…_pair_v2` | `test_v2_perf_ctrl` |
| `v2_reduced_lane` | `sim_gate_v2_reduced_lane` | `…_pair_v2` | `test_v2_reduced_lane` |
| `v2_txgen` | `sim_gate_v2_txgen` | `…_pair_v2` | `test_v2_txgen`, `SIM_BUILD=sim_build_txgen` |
| `v2_mask_hs_bilateral` | `sim_gate_v2_mask_hs_bilateral` | `…_pair_v2` | `BYPASS_AUTONEG=0 HONEST_STRAPS=1 MODULE=test_v2_mask_hs_bilateral` |
| `v2_lane_mask_oddlane` | `sim_gate_v2_oddlane` | `…_pair_v2` | `test_v2_lane_mask_sweep LANE_MASK=0xE5 SIM_BUILD=sim_build_oddlane` |
| `v2_lane_mask_position` | `sim_gate_v2_lane_position` | `…_pair_v2` | `test_v2_lane_mask_sweep LANE_MASK=0x65 SIM_BUILD=sim_build_pos` |
| `v2_lane_mask_negctl` | `sim_gate_v2_oddlane_negctl` | `…_pair_v2` | `test_v2_lane_mask_negctl` |
| `epoch_silicon` | `sim_gate_epoch_silicon` | `…_pair_v2` | `EPOCH_PROFILE=silicon`, `+define+TB_TOP_EPOCH_ANCHOR_FORCE`, `test_v2_pair_data` |
| `epoch_anchor_plumb` | `sim_gate_epoch_anchor_plumb` | `…_pair_v2` | `EPOCH_PROFILE=silicon EPOCH_ANCHOR=1`, `test_v2_pair_data` — the parameter A/B |
| `fifo_rx_phantom_pop` | `sim_gate_fifo` | `cocotb/tidelink_fifo` | default module; build dir wiped first |
| `fifo_rx_twin2_tree` | `sim_gate_fifo_twin2_tree` | `cocotb/tidelink_fifo_twin2` | `SIM_BUILD=sim_build_gate_twin2 sim` |
| `errinj_regressions` | `sim_gate_errinj` | `cocotb/tidelink_error_injection` | `test_ei_sync_collision`, `test_ei_reset_storm`, `test_ei_credit_probe` |
| `f14a_crc_catch` | `sim_gate_f14a_crc_catch` | `cocotb/tidelink_error_injection` | `test_ei_lane7_repro` + a log-signature assertion |
| `force_recal_w1p` | `sim_gate_force_recal` | `cocotb/tidelink_force_recal` | three arms: `RTL=v2`, `RTL=v1`, `pair` |
| `txgen_unit` | `sim_gate_txgen_unit` | `cocotb/tidelink_txgen` | default module |
| `txgen_negctl` | `sim_gate_txgen_negctl` | `cocotb/tidelink_txgen` | `TXGEN_NEGCTL=1` — credit gate compiled out |
| `txgen_ext_hijack` | `sim_gate_txgen_ext_hijack` | `cocotb/tidelink_txgen` | `test_txgen_ext_hijack`, `SIM_BUILD=sim_build_hijack` |
| `axinode_obs` | `sim_gate_axinode_obs` | `cocotb/tidelink_axinode_obs` **+** `cocotb/tidelink_apb_regs` | second arm is `MODULE=test_region_f_decode` |
| `tc_pair_smoke` | `sim_gate_tc_smoke` | `cocotb/tidechart_tidelink_pair` | `test_tc_pair_smoke` — needs `TIDECHART_HOME` + `CHIPLET_HOME` |
| `tc_pair_election_datamode` | `sim_gate_tc_election` | `cocotb/tidechart_tidelink_pair` | `test_tc_pair_election_datamode` |
| `eth_relay_m0` | `sim_gate_eth_m0` | `cocotb/eth_tidelink_pair` | `test_eth_relay_smoke` — needs `ETH_SS_HOME` |
| `eth_relay_m1` | `sim_gate_eth_m1` | `cocotb/eth_tidelink_pair_m1` | `test_eth_relay_m1` |
| `eth_regs_shape_a` | `sim_gate_eth_shape_a` | `cocotb/eth_tidelink_pair_shape_a` | `test_eth_regs_shape_a` |
| `asic_v1_elab` | `sim_gate_asicelab` | direct VCS | `flists/tidelink_top_full_asic.flist`, `-top tidelink_top` |
| `asic_v2_elab` | `sim_gate_asicelab_v2` | direct VCS | `flists/tidelink_top_full_asic_v2.flist` — the tape-out synth default |
| `dft_wrapper_elab` | `sim_gate_dftelab` | direct VCS | same flist **+** `src/rtl/asic/tidelink_dft_wrapper.sv`, `-top tidelink_dft_wrapper` |

**Sentinels** (scored separately; `XFAIL` is the *expected* result and is never
a pass):

| Sentinel | `make` target | Bench | Module |
|---|---|---|---|
| `xfail_f14b_datamode_wedge` | `sim_gate_xfail_f14b` | `cocotb/tidelink_error_injection` | `test_ei_link_glitch` |
| `xfail_epoch_shipping_corrector` | `sim_gate_xfail_epoch_shipping` | `cocotb/tidelink_top_pair_v2` | `EPOCH_PROFILE=silicon MODULE=test_v2_pair_data`, own `sim_build_epoch_shipping` |

### The quick gate

`make sim_gate_quick` runs 14 suites (`SIM_GATE_QUICK_SUITES`, `Makefile:1206`):
`t30_autonomous_fc_handoff`, `v2_pair_data`, `v2_autonomous_sync_detect`,
`v2_winscan_fsm`, `v2_perf_ctrl`, `v2_reduced_lane`, `v2_truncated_pkt_credit`,
`fifo_rx_phantom_pop`, `v1_elab`, `asic_v1_elab`, `asic_v2_elab`,
`apb_fc_cfg_preempt`, `fch_apb_watchdog`, `zeropoke_por`. The two PS-hang locks
are in the quick gate deliberately — they are cheap and guard a failure that
costs a bench trip.

### Parked gate targets (authored, not scored)

These targets exist and can be run by hand, but are **not** in
`SIM_GATE_ALL_SUITES`, so nothing scores them.

| Target | Suite name | Why parked |
|---|---|---|
| `sim_gate_xhb` | `v2_xhb_window_bridge` | the pair testbench does not model the peer-side XHB500 target memory (a testbench gap, not an RTL one) |
| `sim_gate_nack_wedge_sustained` | `nack_wedge_sustained` | `test_14_sustained_ack_drop_wedge` **fails** — a real pre-existing recovery-datapath limitation, tracked non-blocking |
| `sim_gate_v2_fc_contiguous` | `v2_fc_contiguous` | run on demand |
| `sim_gate_fifo_twin2` | `fifo_rx_twin2` | **superseded** — its Makefile note says "DO NOT PROMOTE THIS TARGET"; it pins a stale fork of the FIFO RTL. `fifo_rx_twin2_tree` replaced it |

## The cocotb environment catalogue

60 directories under `cocotb/`, 55 with a Makefile. Three axes matter: is it in
`make -C cocotb regression` (the `ENVS` list, 28 entries, `cocotb/Makefile:7`),
is it in `make sim_gate`, or is it neither.

:::{warning}
**`make -C cocotb regression` is the unit half only.** `ENVS` covers 28 of the
55 environments with a Makefile. Every paired-die, ethernet, TideChart, txgen
and error-injection environment is **excluded by design** and gated by
`make sim_gate` instead. Any figure from `make -C cocotb coverage` therefore
describes the unit half, not the design.
:::

### Unit / module environments

| Directory | What it verifies | In `ENVS` | Gated |
|---|---|---|---|
| `tidelink_fifo` | FIFO mem + ctrl + APB regs as the FIFO subsystem | yes | `fifo_rx_phantom_pop` |
| `tidelink_fifo_twin2` | RX-FIFO write-side twin; `ENABLE_AHB_WRITE` posture | no | `fifo_rx_twin2_tree` |
| `fifo_rx_twin2` | the older twin-2 bench with frozen pre-fix RTL copies (`FIFO_SRC=unfixed` negative control) | no | superseded |
| `tidelink_returner` | 3-channel credit-return AHB master | yes | — |
| `tidelink_apb_regs` | APB register file; PTP mailbox write-protect; Region F decode | yes | `axinode_obs` (2nd arm) |
| `tidelink_apb_addr_ctrl` | register bank of the dormant segment translator | yes | — |
| `tidelink_addr_translator` | CAM-based address translation | yes | — |
| `tidelink_fc_adapter` | FC TX/RX + sideband adapter | yes | — |
| `tidelink_ptp` | single-phase PTP state machine | yes | — |
| `tidelink_ptp_servo` | hardware PTP servo block | yes | — |
| `tidelink_phc_cdc` | PHC ↔ AHB handshake CDC | yes | — |
| `tidelink_perf` | performance-counter block | yes | — |
| `tidelink_perf_congestion` | congestion-estimator characterisation | yes | — |
| `tidelink_mul_iter` | iterative signed×unsigned multiplier used by the servo | yes | — |
| `tidelink_autoneg` | autoneg FSM, role lock, I²C arbitration | yes | — |
| `tidelink_autoneg_rolestrap` | `ROLE_FROM_STRAP` red/green: `MODE=trap` (=0) vs `MODE=fix` (=1) | no | — |
| `tidelink_idelay_rx` | per-lane IDELAYE2 wrapper passthrough | yes | — |
| `tidelink_rxclk_buf` | recovered-RX-clock BUFG wrapper | yes | — |
| `tidelink_clkfreq_check` | clk_wiz output sanity helper | yes | — |
| `tidelink_eye_regs` | V1 eye-sweep register file | yes | — |
| `tidelink_phy_align_calibrator` | the calibrator FSM | yes | — |
| `tidelink_force_recal` | the `SWI_FORCE_RECAL` W1P, across both calibrator copies | no | `force_recal_w1p` |
| `tidelink_lane_deskew` | cross-lane deskew unit test | no | — |
| `tidelink_deskew_bubble` | deskew unit testbench (bubble behaviour) | no | — |
| `tidelink_axinode_obs` | AXI data-node observability word (Region F) | no | `axinode_obs` |
| `tidelink_txgen` | TX traffic generator: inert-when-disarmed, credit gate, ownership hand-off | no | `txgen_unit`, `txgen_negctl`, `txgen_ext_hijack` |
| `tidelink_a2l_replay_cdc` | isolates the a2l replay-FIFO CDC and the "false-FULL on first write" bug | no | — |
| `tidelink_cdc_tear` | silicon-faithful a2l/l2a ACK-pointer CDC-tear / false-FULL self-heal | no | — |
| `wav_d2d_gpio_tx` | `WavD2DGpioTx` training-pattern mux | yes | — |
| `wavd2d_gpiorx_clkbuf` | `WavD2DGpioRx` in-PHY BUFG restructure (`USE_CLKBUF=0` bit-exact) | yes | — |
| `wavd2d_gpiorx_t3a` | T3a self-aligning RX comma hunt | yes | — |
| `wavd2d_gpiorx_t3a_off` | `USE_T3A=0` legacy passthrough | yes | — |
| `wavd2d_gpiorx_t3a_timeout` | T3a silent-peer `MAX_HUNT` timeout fallback | yes | — |
| `honest_mask_hs` | `HONEST_MASK_HS` red/green: `MODE=legacy` (=0) vs `MODE=honest` (=1) | no | — |

### Integration / paired-die environments

| Directory | What it verifies | In `ENVS` | Gated |
|---|---|---|---|
| `tidelink` | the legacy `src/rtl/tidelink.sv` wrapper | yes | — |
| `tidelink_ahb` | `tidelink_ahb` wrapper + AHB-to-APB bridge; also the C-driver-in-the-loop test | yes | — |
| `tidelink_top` | `tidelink_top` internal data path with FC loopback | yes | — |
| `tidelink_system` | paired stress suite, two subsystems back to back over FC crossover | yes | — |
| `tidelink_py_pair` | Python-driven paired-board sim / bug regressions | yes | — |
| `tidelink_top_pair` | two cross-wired `tidelink_top` — the bring-up chain regression (61 test modules) | no | 10 suites |
| `tidelink_top_pair_v2` | two cross-wired V2 `tidelink_top` with whole-word epoch-skew injection (43 test modules) | no | 16 suites + 1 sentinel |
| `tidelink_top_pair_skewed` | asymmetric per-lane pad skid (ribbon-cable skew) | no | — |
| `tidelink_top_pair_wordskew` | whole-word variant of the above | no | — |
| `tidelink_top_pair_drift` | independent, slightly drifting master/slave clocks | no | — |
| `tidelink_v2_smoke` | single-die V2 elaboration + APB liveness (~30 s) | no | — |
| `tidelink_error_injection` | the F14 error-injection / recovery matrix | no | `errinj_regressions`, `f14a_crc_catch`, `xfail_f14b_datamode_wedge` |
| `deskew_handoff_lottery` | sim mirror of the KR260 intermittent-delivery bug | no | — |
| `crc_diag` | link-layer header-CRC root-cause bench | no | — |
| `tidechart_tidelink_pair` | TideChart ↔ TideLink pair integration | no | `tc_pair_smoke`, `tc_pair_election_datamode` |
| `eth_tidelink_pair` | Ethernet-over-TideLink M0 integration smoke | no | `eth_relay_m0` |
| `eth_tidelink_pair_m1` | M1 — through the real `ethernet_ss_ahb` matrix | no | `eth_relay_m1` |
| `eth_tidelink_pair_shape_a` | real MAC / HA1588 registers driven across the link | no | `eth_regs_shape_a` |
| `eth_ptp_chain` | Ethernet PTP chain | no | — |
| `eth_ptp_phc_subsystem` | first functional sim of `ethernet_ss_ahb_phc` | no | — |

### Not test environments

| Directory | What it is |
|---|---|
| `lint` | the Verilator strict-lint and XDC/SV anti-pattern lint wrappers (`make sim_synth_mode`, `make xdc_lint`) |
| `common` | shared helpers, including a vendored `fpgahub_sdk` |
| `debug` | bug-bisect probes, force-injection harnesses and silicon-fingerprint reproducers, deliberately excluded from regression. Includes `debug/sim_robust` (`make sim_robust`) and `debug/wlink_pair` |
| `xhb_window_skew_debug` | an instrumentation module only — **no Makefile, no testbench, no pass criterion**. Gating a microscope would assert that its own measurements never change |
| `asic_nego_cfg_plumb`, `tidelink_fcsm_silicon_ratio` | directories with no Makefile |

## UVM

Seven environments, all with the same Makefile interface.

```bash
source ../../set_env.sh                      # printed by `make help`
make -C uvm/tidelink_top_system compile
make -C uvm/tidelink_top_system run TEST=test_top_single_packet
make -C uvm/tidelink_top_system run_all
make -C uvm/tidelink_top_system waves TEST=test_top_single_packet   # +define+WAVES_VCD
make -C uvm/tidelink_top_system coverage                            # urg over sim_build/simv.vdb
make -C uvm/tidelink_top_system clean
make -C uvm/tidelink_top_system help
```

Variables: `TEST` (default `test_top_single_packet`), `SEED` (default
`random`), `VERBOSITY` (default `UVM_MEDIUM`), `SOCLABS_NANOSOC_TECH_DIR` (for
XHB500), and `GATE=1` (flattened FC netlist + probe-free `top_gate.sv`).
`uvm/tidelink_top_system` also exposes `make wlink_regen`, which forces a Chisel
regeneration of the Wlink Verilog (needs Java 8+ and sbt).

| Environment | `run_all` test list |
|---|---|
| `uvm/tidelink` | `tidelink_register_test`, `tidelink_single_packet_test`, `tidelink_random_test`, `tidelink_stall_test` |
| `uvm/tidelink_fc_adapter` | `..._tx_test`, `..._sideband_test`, `..._rx_test`, `..._full_test` |
| `uvm/tidelink_integration` | `..._loopback_test`, `..._credit_test`, `..._stress_test` |
| `uvm/tidelink_system` | 15 tests: `test_single_packet`, `test_bidirectional`, `test_back_to_back`, `test_max_packet`, `test_credit_exhaustion`, `test_credit_threshold`, `test_sideband_stress`, `test_interleaved_types`, `test_error_injection`, `test_reset_recovery`, `test_long_running`, `test_pair_credit_underflow`, `test_partial_packet_abandon`, `test_error_recovery`, `test_throughput_latency` |
| `uvm/tidelink_top_system` | 10 tests: `test_top_single_packet`, `test_top_bidirectional`, `test_top_back_to_back`, `test_top_max_packet`, `test_top_credit_exhaustion`, `test_top_reset_recovery`, `test_top_long_running`, `test_top_mixed_traffic`, `test_top_coordinated_reset`, `test_top_addr_translate` |
| `uvm/tidelink_ptp_chain` | `test_chain_convergence`, `test_chain_lock_propagation`, `test_chain_step_recovery`, `test_chain_b_unlock_c_holds`, `test_chain_stress`, `test_chain_force_enable`, `test_chain_gate_functional` |
| `uvm/tidelink_ptp_stress` | `ptp_idle_baseline_test`, `ptp_all_saturated_test` |

`uvm/tidelink_top_system` carries more tests on disk than `run_all` runs —
`TESTS_ALIGN` (four `test_align_*` PHY-alignment tests) and
`TESTS_EXPERIMENTAL` (`test_top_ahb_passthrough`) are separate lists, run with
`make run TEST=<name>`. Autoneg and lane-mask tests are also present as source
files without being in any list.

:::{warning}
**`uvm-top-system` compiles but its tests do not currently pass.** Link
training completes and the FC-layer FCSM never leaves state 1, so every packet
test's scoreboard reads TX ≠ RX. This was classified as the already-tracked
backlog item **#14b**, not a new defect, and the CI job stays
`allow_failure: true`. `uvm-ptp-chain` and `uvm-ptp-stress` received the same
build fix but their suites have not yet been run. See
[Verification](verification.md#ci-what-actually-runs).
:::

## Running one suite by hand

Three verified, load-bearing examples.

**The V2 paired-die bench** — the profile is a *compile-time* knob, so each
profile gets its own `SIM_BUILD` automatically:

```bash
cd cocotb/tidelink_top_pair_v2
make EPOCH_PROFILE=zero      MODULE=test_v2_pair_data
make EPOCH_PROFILE=staircase MODULE=test_v2_pair_data
make EPOCH_PROFILE=silicon   MODULE=test_v2_pair_data
# negative control — forces EPOCH_ANCHOR_EN=0 on both dies:
make EPOCH_PROFILE=silicon EPOCH_ANCHOR_DIS=1 MODULE=test_v2_pair_epoch_negctl
# all four stages in order:
make v2_gate
```

Other knobs on this bench (all from `cocotb/tidelink_top_pair_v2/Makefile`):
`BYPASS_AUTONEG` (1 = SW-driven role lock, the default; 0 = autonomy),
`HONEST_STRAPS=1` (straps 0 **and** `DEBUG_UNLOCK_DEFAULT=0`, so the only
opener is a genuine `mask_hs_match`), `EPOCH_ANCHOR=1`, `EYE_FAULT=1`,
`LANE_MASK=`, `PREFIX_FC=1`, `SKID_BITS=`, `DUMP=1`, `EXTRA_DEFINES=`.

**The autonomy bench** — copy the environment exactly; these are environment
variables, not make variables:

```bash
cd cocotb/tidelink_top_pair
TIDELINK_PHY_V2=1 BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \
  EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" \
  SIM_BUILD=sim_build_l4 COCOTB_RESOLVE_X=ZEROS \
  make MODULE=test_31_autonomous_training_exit
```

`test_32` and `test_33` need `BYPASS_AUTONEG=1` and `SIM_BUILD=sim_build_l5`
instead — `test_32` arms autoneg *itself* via register writes and asserts the
FSM parks in `ST_BYPASS` pre-arm, so a `BYPASS_AUTONEG=0` build fails its own
precondition.

**The recovery bench** — this directory is shared, so always use a private
build directory:

```bash
cd cocotb/tidelink_error_injection
make SIM_BUILD=sim_build_zd MODULE=test_ei_recovery_ladder
```

:::{warning}
`SIM_BUILD` set in the **environment** is silently ignored by benches that use
`SIM_BUILD :=` — a `:=` assignment beats an environment value. Pass it as a
make **command-line** variable (`make SIM_BUILD=...`), which beats both `:=`
and `?=`. This once caused two concurrent runs to share a build directory,
producing a SIGKILLed simulator and a stale-simv skip
(`docs/SIM_GATE_COVERAGE.md` §9.1).
:::

## Adding a new cocotb suite

1. **Pick the layer.** Module behaviour → a new `cocotb/<suite>/`. Paired-die or
   system behaviour → extend `tidelink_top_pair` / `tidelink_top_pair_v2`
   rather than forking a third pair bench.

2. **Create the directory.** Copy the closest existing environment. The minimum
   is a `Makefile`, a `tb_top.sv`, and one or more `test_*.py`. The Makefile
   shape (see `cocotb/tidelink_fifo/Makefile`):

   ```make
   SIM             = vcs
   TOPLEVEL_LANG   = verilog
   TIDELINK_HOME  ?= $(realpath $(CURDIR)/../..)
   export TIDELINK_HOME
   VERILOG_SOURCES = $(CURDIR)/tb_top.sv
   TOPLEVEL        = tb_top
   MODULE          = test_<name>
   COMPILE_ARGS   += -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb
   COMPILE_ARGS   += -f $(TIDELINK_HOME)/flists/<module>.flist
   include $(shell cocotb-config --makefiles)/Makefile.sim
   ```

3. **Add the staleness guard.** If the DUT arrives via `-f <flist>`, `make`
   cannot see it. Add:

   ```make
   include $(TIDELINK_HOME)/cocotb/flist_deps.mk
   _TL_FLIST   := $(TIDELINK_HOME)/flists/<module>.flist
   _flist_deps := $(_TL_FLIST) $(call flist_srcs,$(_TL_FLIST))
   CUSTOM_COMPILE_DEPS += $(_flist_deps)
   ```

   If instead you name the DUT sources explicitly in `VERILOG_SOURCES` or
   `CUSTOM_COMPILE_DEPS`, `make` tracks them and the include is unnecessary
   (`cocotb/tidelink_txgen/Makefile` does this).

4. **Add a flist entry if you added RTL** — to **both** the FPGA and ASIC
   flists. A one-sided edit is a split brain: one flow elaborates, the other
   does not, and the three elaboration suites in the gate exist because that
   has already reached a trunk.

5. **Register it in the gate.** Three edits in the top-level `Makefile`:

   ```make
   # a) a target using the macro
   sim_gate_<name>:
   	$(call sim_gate_run,<suite_name>,\
   	  $(MAKE) -C cocotb/<suite> SIM_BUILD=sim_build_gate_<name> \
   	    COCOTB_RESULTS_FILE=sim_build_gate_<name>/res.xml MODULE=test_<name>)

   # b) the suite name in SIM_GATE_ALL_SUITES   (Makefile:1183)
   # c) an invocation line in the `sim_gate` aggregate (Makefile:1246+):
   #    @$(MAKE) --no-print-directory sim_gate_<name>
   ```

   Give the suite its **own** `COCOTB_RESULTS_FILE` inside its own build dir.
   cocotb's execution rule is `$(COCOTB_RESULTS_FILE): $(SIM_BUILD)/simv` with
   the default `./results.xml` shared by every module of a bench — if anything
   re-creates it in the wrong window, the sub-make prints `'results.xml' is up
   to date` and **runs nothing while exiting 0**.

   If your suite needs a sibling repo, add a `SIM_GATE_REQUIRE` line
   (`Makefile:858`) so a missing checkout fails *your* suite loudly instead of
   silently skipping.

6. **Add it to the clean glob** if the bench directory is not already covered
   by `sim_gate_clean_builds` (`Makefile:1220-1245`).

7. **Prove the wiring.** `make sim_gate_inventory` must end with
   `OK — every declared suite is invoked`. A scored-but-uninvoked suite makes
   the entire gate unpassable.

8. **Validate the target on its own** — `make sim_gate_<name>` — never with
   `-n`, and never as part of the aggregate the first time.

## Debugging

### Waves

| Bench family | How |
|---|---|
| `tidelink_top_pair_v2` | dumping is **off** by default (full bring-up VCDs exceed 4 GB). `make DUMP=1 ...` adds `+vcs+dumpvars+waves.vcd` |
| `tidelink_top_pair` | dumping is **on** by default; `TB_TOP_NO_DUMP=1` turns it off (which is what every gate suite does) |
| unit benches | `SIM_ARGS += +vcs+dumpvars+waves.vcd` unconditionally |
| Verdi GUI | `make gui MODULE=<module>` in any bench that defines it (e.g. `cocotb/tidelink_fifo`, `cocotb/tidelink_top_pair`, `cocotb/tidelink_top_pair_v2`) |
| UVM | `make -C uvm/<env> waves TEST=<name>` (adds `+define+WAVES_VCD`) |

### Common failure signatures

| Signature | Cause |
|---|---|
| **Every** suite fails in 4-5 s | `set_env.sh` not sourced, or VCS not on `PATH`. Read one `imp/sim_gate/<suite>.log` before theorising |
| `sim_gate: vcs not in PATH` | the `sim_gate_env_check` guard doing its job |
| A suite scored `MISS` | its `.status` file was never written — the target was not invoked. Run `make sim_gate_inventory` |
| `'results.xml' is up to date` | cocotb skipped the simulation and will still exit 0. Give the suite its own `COCOTB_RESULTS_FILE` |
| `simv up to date` after an RTL edit | the stale-`simv` trap. `rm -rf <suite>/sim_build*` and re-run |
| Sentinel reports `XERR` | the harness or environment broke — commonly a co-scheduled Vivado build SIGKILLing the simulator. Never co-schedule Vivado with `sim_gate` |
| Sentinel reports `XCHG` | the pinned defect's behaviour moved in some direction. A human must look; do not re-baseline the signature to make it green |
| `MISSING DEPENDENCY …` in a `tc_pair_*` / `eth_*` log | sibling repo not checked out; set `TIDECHART_HOME` / `CHIPLET_HOME` / `ETH_SS_HOME` |

### The stale-build trap, restated

`make sim_gate` cleans build directories first, using **globs**, because an
enumerated list rots. Ad-hoc runs get no such protection. After **any** RTL or
flist edit outside the gate:

```bash
rm -rf cocotb/<suite>/sim_build*
```

Two flist-sourced benches on this branch have neither the `flist_deps.mk` guard
nor a gate-side clean — `cocotb/honest_mask_hs` and `cocotb/tidelink_fifo_twin2`
(the latter is gated as `fifo_rx_twin2_tree`). Clean those by hand. Details and
citations in [Verification](verification.md#2-a-stale-simv-silently-testing-old-rtl).
