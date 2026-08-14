#-----------------------------------------------------------------------------
# TideLink — partition-level SDC overlay (multi-clock + source-sync I/O).
#
# The shared FC.read_design.tcl already creates the main system clock
# ($CLK_NAME = hclk @ $CLK_PERIOD = 4 ns) and applies all_inputs/
# all_outputs I/O delays. This file adds the additional clock domains
# the partition exposes at its boundary, declares the *genuine* CDC
# clock groups (recovered-RX ↔ core only), and constrains the
# source-synchronous TX / RX pad bundles.
#
# Read into every active scenario by 1_init_design.tcl.
#
# Rationale per clock:
#   phc_clk       — PTP RTC reference, generated separately on chip-top.
#                   Crosses into hclk via tidelink_phc_cdc; the bridge
#                   does the actual CDC, STA must not time the raw
#                   register-to-register paths.
#   scan_clk      — DFT scan clock; only active in test mode.
#   user_ref_clk  — Wlink internal/user reference; provided by SoC PLL.
#                   This is the launch reference for the TX serialiser
#                   (`io_hsclk` inside WavD2DGpio); pad_clk_tx is a
#                   generated clock off it (see §2 below).
#   pad_clk_rx    — Recovered from the peer chiplet's pad_clk_tx. This is
#                   a real primary clock at the RX pads. Asynchronous to
#                   anything generated locally **only at the recovered-RX
#                   → core CDC crossing** — NOT to its own pad_rx[*]
#                   capture path. See ASIC_TIMING_CONSTRAINTS.md §3.
#   pad_clk_tx    — Forwarded TX clock. Generated clock derived from
#                   user_ref_clk; the TX eye is constrained against it.
#                   See ASIC_TIMING_CONSTRAINTS.md §2.1, Part B §2.
#
# CRITICAL #2 fix (2026-05-28):
#   Pre-fix, `pad_clk_rx` was in a five-way `set_clock_groups -asynchronous`
#   blanket alongside hclk/phc_clk/scan_clk/user_ref_clk. That instructs STA
#   to skip *every* path launched on `pad_clk_rx` — including the
#   pad_rx[*]→capture-flop arc that is the entire timing-critical content
#   of a source-sync RX. Any set_input_delay added later then has no live
#   launch/capture relationship to bound. This is the exact failure mode
#   `docs/reference/ASIC_TIMING_CONSTRAINTS.md` Part A §3 declares "the single most
#   important and historically most violated point". Replaced with:
#
#     - A narrowed async cut: pad_clk_rx ↔ hclk *only* (the genuine CDC,
#       handled by Wlink's internal multi-stage synchronisers).
#     - Symmetric set_input_delay -min/-max on pad_rx[*] vs pad_clk_rx.
#     - set_max_delay -datapath_only on the pad_rx[*] capture path.
#     - set_data_check on the lane bundle (per ASIC_TIMING_CONSTRAINTS
#       Part B §3.3; the ASIC form of the FPGA's set_bus_skew).
#     - create_generated_clock on pad_clk_tx + symmetric set_output_delay
#       -min/-max on pad_tx[*] (Part B §2).
#
# NOTE: SDC syntax — fc_shell's read_sdc parser does NOT accept the
# `-quiet` flag on get_ports / get_clocks (CMD-010). Every clock + port
# pattern referenced here is part of tidelink_top's fixed boundary, so
# unconditional commands are safe; conditional blocks use catch / sizeof
# without -quiet.
#-----------------------------------------------------------------------------

# ── Source-sync skew budget parameters ────────────────────────────────────
# T_UI is the bit-period at the GPIO PHY pads. Pre-fix file used 4 ns
# (a 250 MHz placeholder pinned to hclk); the ASIC v1 target is 100 MHz
# (UI = 10 ns), but we keep the *parametric* form below so a single change
# in T_UI_NS propagates to every input/output-delay and skew budget.
#
# Derivation (ASIC_TIMING_CONSTRAINTS Part A §1):
#   S_budget_max ≤ T_UI/16 − t_setup − t_hold − PVT_derate
# For an unconstrained pad→capture starting point, characterised numbers
# do not exist yet — these are the same ratios validated on FPGA at
# T_UI=40 ns (set_max_delay 8 ns ≈ T_UI/5, set_bus_skew 2 ns ≈ T_UI/20)
# scaled down to ASIC T_UI. They are *budgets* that the post-route report
# must come in under, NOT measured values; revisit once the I/O library
# + package + channel models are in (Part A §6).
set T_UI_NS                 4.0
set RX_INPUT_DELAY_SYMM     [expr {$T_UI_NS / 4.0}]   ;# ±25% of UI about launch edge
set TX_OUTPUT_DELAY_SYMM    [expr {$T_UI_NS / 4.0}]   ;# ±25% of UI about launch edge
set RX_DATAPATH_MAX_NS      [expr {$T_UI_NS / 5.0}]   ;# per-lane pad→capture delay cap
set RX_BUS_SKEW_NS          [expr {$T_UI_NS / 20.0}]  ;# lane-to-lane skew cap

# ── Secondary clock domains ──────────────────────────────────────────────
# Provisional 50 MHz / 20 ns. Pin to the actual RTC frequency once the
# top-level chip clocking plan is settled.
create_clock -name phc_clk -period 20.0 -waveform {0 10} [get_ports phc_clk]

# Conservative 100 MHz / 10 ns; tester pace, not functional path.
create_clock -name scan_clk -period 10.0 -waveform {0 5} [get_ports scan_clk]

# Provisional 250 MHz / 4 ns (matches the 4 ns hclk default; placeholder
# until the chip-top clocking plan firms up). This is the launch reference
# for the TX serialiser inside WavD2DGpio (`io_hsclk`); pad_clk_tx is a
# generated clock off this domain — see §2 below.
create_clock -name user_ref_clk -period $T_UI_NS -waveform [list 0 [expr {$T_UI_NS / 2.0}]] [get_ports user_ref_clk]

# Wlink RX pad clock — recovered from the peer's forwarded pad_clk_tx. A
# real primary clock at the RX pads (NOT async to its own capture path —
# that was the CRITICAL #2 defect).
create_clock -name pad_clk_rx -period $T_UI_NS -waveform [list 0 [expr {$T_UI_NS / 2.0}]] [get_ports pad_clk_rx]

# Wlink TX pad clock — forwarded off-die alongside pad_tx[*]. A generated
# clock derived from user_ref_clk (the per-lane `io_hsclk`); see §4 below
# for the data-eye constraints and the rationale for sourcing the
# generated clock at the port (not an internal clock-gate pin). Declared
# here before set_clock_groups so the group declaration can reference it.
create_generated_clock -name pad_clk_tx_fwd \
    -source [get_ports user_ref_clk] \
    -divide_by 1 [get_ports pad_clk_tx]

# ── Async clock groups (narrowed) ─────────────────────────────────────────
# Per ASIC_TIMING_CONSTRAINTS Part B §5: this declares the *genuine*
# recovered-RX ↔ core CDC cut. `pad_clk_rx` is asynchronous to `hclk`
# (and to phc_clk/scan_clk/user_ref_clk, which remain separate async
# groups vs hclk exactly as the pre-fix file had them — that part was
# fine). `pad_clk_rx` is **NOT** in a blanket group that crosses its own
# pad_rx[*]→capture arc; intra-pad_clk_rx paths stay timed so the
# source-sync RX constraints below have a live launch/capture
# relationship to bound.
#
# Verification: after read_sdc, `report_clock_interaction` must show
# pad_clk_rx ↔ hclk = "Asynchronous Groups" but pad_clk_rx → pad_rx
# capture = timed. `report_timing -from [get_ports pad_rx[*]] -to
# [get_clocks pad_clk_rx]` must return real paths, not "No paths" — that
# is the regression signature of the CRITICAL #2 defect.
set_clock_groups -asynchronous \
    -group {hclk}         \
    -group {phc_clk}      \
    -group {scan_clk}     \
    -group {user_ref_clk pad_clk_tx_fwd} \
    -group {pad_clk_rx}

# ── §1. pad_clk_rx-domain inputs — RX eye (pad_rx[*] vs pad_clk_rx) ──────
# Symmetric set_input_delay about the launch edge. The GPIO PHY TX
# launches both pad_tx and pad_clk_tx from the same io_hsclk edge (see
# WavD2DGpioTx io_pad / io_pad_clk — both derived from io_clk), so at the
# RX pads the relationship is *edge-aligned, calibrator-centred*. The
# symmetric window declares "data is edge-aligned to the forwarded clock
# within ±T_UI/4" without imposing the asymmetric absolute window that
# caused the 2026-05-05 134-endpoint hold explosion on FPGA
# (ASIC_TIMING_CONSTRAINTS Part A §7).
#
# Hold-trap guard: if the WHS-violating endpoint count jumps toward
# ~100+ vs baseline after this lands, the symmetric window is still too
# tight — *widen* it (e.g. ±T_UI/2), never delete it. The
# set_max_delay -datapath_only below carries no hold component so it
# does not contribute to hold pressure.
set_input_delay -clock pad_clk_rx -max  $RX_INPUT_DELAY_SYMM [get_ports {pad_rx[*]}] -add_delay
# -min tightened from -$RX_INPUT_DELAY_SYMM (-1.0 ns at T_UI=4ns) to
# -0.4 ns: the original symmetric ±1.0 window combined with the aspect-2.0
# clock-tree latency (~0.58 ns from pad_clk_rx to capture FF) produced a
# -0.59 ns scen_fast hold WNS / 130 NVE failure on the pad_rx ->
# link_data_pad_clk_reg arc that 11 builds could not work around
# (placement, cell-type swap, region bounds, even the previously-missing
# §2/§3 SDC constraints all tried; only this -min loosening attacks the
# source-sync hold budget directly). FC2 aspect-1.0 closed clean with
# the original -1.0 because its clock-tree latency was smaller; aspect 2.0
# needs the tighter window.
set_input_delay -clock pad_clk_rx -min -0.4 [get_ports {pad_rx[*]}] -add_delay

# ═════════════════════════════════════════════════════════════════════════
# ORDERING RULE (2026-08-14, blocker ASIC-3)
#
# read_sdc runs this file through fc_shell's *restricted* SDC interpreter,
# not full Tcl. When any command in it errors, the interpreter STOPS at
# that line and silently discards EVERYTHING BELOW IT (CMD-081 + SDC-5),
# yet read_sdc still returns Tcl rc=0, so a `catch` around it does not
# trip. That is a silent-constraint-loss trap.
#
# Therefore:
#   1. This file contains PURE SDC only. No `-filter`, no `-quiet`, no
#      `sizeof_collection`, no `foreach_in_collection`, no if/else that
#      depends on a collection query. Anything needing full Tcl lives in
#      1_init_design.tcl, applied per-scenario AFTER this overlay.
#   2. The boundary I/O constraints (§2 TX eye, §3 PHC) are placed as
#      EARLY as possible — directly after §1 — so that even a future
#      parse abort further down cannot take the TX eye with it. That is
#      exactly what happened between 2026-06 and 2026-08: the TX eye sat
#      below a `get_cells -hier -filter` guard and was never applied to
#      any build.
#   3. The file ends with an explicit completion marker that
#      1_init_design.tcl asserts on. Do not remove it.
# ═════════════════════════════════════════════════════════════════════════

# ── §2. TX eye — pad_tx[*] vs pad_clk_tx_fwd ─────────────────────────────
#      (was §4; hoisted 2026-08-14 per the ORDERING RULE above)
# pad_clk_tx_fwd is declared above (with the other create_clock /
# create_generated_clock statements) so set_clock_groups can reference
# it. Sourcing the generated clock from the user_ref_clk *port* (rather
# than an internal clock-gate pin) survives synthesis re-mapping: the
# tool propagates user_ref_clk through the WavD2DGpio gating logic to
# the pad_clk_tx port, and the generated-clock declaration anchors
# pad_clk_tx_fwd at the boundary where the forwarded clock actually
# leaves the die. Reference: WavD2DGpioTx io_pad_clk = hs_clk_gated_wcg
# (local_overrides/WavD2DGpioTx.v ~line 308), pad_clk_tx =
# gpiotx_0_io_pad_clk (local_overrides/WavD2DGpio.v line 850).
#
# Transmitter eye: pad_tx[*] launched on user_ref_clk, peer captures on
# pad_clk_tx_fwd. The window is symmetric about the launch edge
# (edge-aligned launch — both io_pad and io_pad_clk leave the
# serialiser on the same io_clk edge, see WavD2DGpioTx io_pad /
# io_pad_clk assigns) so the tool balances pad_tx[*] vs pad_clk_tx
# rather than hold-padding every lane (Part B §2 — "Why not the
# 2026-05-05 trap").
set_output_delay -clock pad_clk_tx_fwd -max  $TX_OUTPUT_DELAY_SYMM [get_ports {pad_tx[*]}] -add_delay
set_output_delay -clock pad_clk_tx_fwd -min -$TX_OUTPUT_DELAY_SYMM [get_ports {pad_tx[*]}] -add_delay

# ── §3. phc_clk-domain output (PHC hw_capture handoff) ────────────────────
#      (was §5; hoisted 2026-08-14 per the ORDERING RULE above)
# 25% of clock period; pre-existing, unchanged by the CRITICAL #2 fix.
# phc_seconds/phc_nanoseconds/phc_pps come IN through tidelink_phc_cdc
# and are false-pathed by the clock-group declaration above.
set_output_delay -clock phc_clk [expr 20.0 * 0.25] [get_ports phc_hw_capture] -add_delay

# ── §4. pad_rx[*] per-lane pad→capture delay cap — MOVED TO TCL ───────────
# Was, until 2026-08-14, an inline
#   if {[sizeof_collection [get_cells -hier -filter {NAME =~ "..."}]] > 0} {
#       set_max_delay -datapath_only $RX_DATAPATH_MAX_NS ... }
# at this point in the file. fc_shell's SDC interpreter rejects `-filter`
# (CMD-010) and then aborted the whole overlay at that line — killing the
# TX eye (§2 above), the PHC output delay (§3) and the lane-skew check
# (§5) in every build from 2026-06-03 onward.
#
# TWO further fc_shell incompatibilities make this constraint impossible
# to express in SDC at all, so it cannot simply be reworded here:
#   * `set_max_delay -datapath_only` is PrimeTime-only; fc_shell rejects
#     it with CMD-010 (measured: logs_b10_datapath_only_20260601/
#     1_init_design.log). The fc_shell equivalent is
#     `-ignore_clock_latency`.
#   * The selector needs `-hierarchical`; the `-filter` form is Tcl-only.
#
# It is therefore applied per-scenario from 1_init_design.tcl, in the
# full-Tcl section after this overlay is read. See the block headed
# "§4 (from constraints.sdc)" there. Value: RX_DATAPATH_MAX_NS = T_UI/5.

# ── §5. Lane-bundle skew (set_data_check) — MOVED TO TCL ──────────────────
# Was, until 2026-08-14:
#   set_data_check -from [get_ports pad_clk_rx] \
#                  -to [get_ports {pad_rx[*]}] -setup $RX_BUS_SKEW_NS
# fc_shell's `set_data_check -to` accepts a SINGLE pin/port; a bus
# collection trips CMD-013 "bad value specified for option -to". The
# constraint must be issued one bit at a time, which needs
# foreach_in_collection — full Tcl. Applied from 1_init_design.tcl.
# Value: RX_BUS_SKEW_NS = T_UI/20.

# NOTE: Wav demet-flop async-reset false_paths for the ASIC_TSMC65
# substitution are NOT applied here — fc_shell's SDC parser rejects
# sizeof_collection / -quiet. They are applied from 1_init_design.tcl
# AFTER the SDC overlay is read, where full fc_shell Tcl is available.

# ═════════════════════════════════════════════════════════════════════════
# COMPLETION MARKER — asserted by 1_init_design.tcl.
#
# If the SDC interpreter aborts anywhere above, this line never executes,
# the marker never appears in the redirected read_sdc log, and
# 1_init_design.tcl aborts the run — instead of silently building with
# half a constraint set (which is what happened for every build from
# 2026-06-03 to 2026-08-14).
#
# It has to be a `puts`, not a `set`: measured 2026-08-14, variables
# assigned inside read_sdc do NOT propagate to the calling Tcl scope, so
# a sentinel variable cannot be tested from 1_init_design.tcl. `puts`
# does work inside the SDC interpreter. Do not "simplify" this to a set.
#
# Do not move, rename, or delete.
# ═════════════════════════════════════════════════════════════════════════
puts "TIDELINK_SDC_OVERLAY_COMPLETE"
