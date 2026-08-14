#-----------------------------------------------------------------------------
# Phase 1: init_design — create design library, analyze RTL, elaborate,
#                        MCMM, parasitic, clocks, floorplan, pre-compile check.
#
# Run with: fc_shell -f 1_init_design.tcl
#
# Environment variables (exported by Makefile + common.mk):
#   MODULE, TOP, FLIST                - design ID + filelist
#   TIDELINK_HOME                     - repo root
#   FC_DIR, SHARED_SCRIPTS,
#   FC_LIBS, FC_LOGS, FC_REPORTS      - flow paths
#   TF_FILE                           - Milkyway technology file
#   FUSION_LIB                        - NDM ref-lib (stdcell_lib)
#   CLK_NAME, CLK_PERIOD, …           - top-level clock constraints
#   FC_ASPECT_RATIO,                  - partition floorplan target
#   FC_CORE_UTILIZATION,
#   FC_CORE_OFFSET
#-----------------------------------------------------------------------------

set module_name      $::env(MODULE)
set top_module       $::env(TOP)
set design_lib_name  "${module_name}.dlib"
set fusion_lib       $::env(FUSION_LIB)
set tf_file          $::env(TF_FILE)
set shared_scripts   $::env(SHARED_SCRIPTS)
set fc_dir           $::env(FC_DIR)
set fc_logs          $::env(FC_LOGS)
set fc_reports       $::env(FC_REPORTS)
set fc_outputs       $::env(FC_OUTPUTS)
set aspect_ratio     $::env(FC_ASPECT_RATIO)
set core_util        $::env(FC_CORE_UTILIZATION)
set core_offset      $::env(FC_CORE_OFFSET)

# Named SVF — Formality reads outputs/svf/<top>.<stage>.svf in stage order.
# Without this fc_shell drops a "default-DATE_HOST_PID.svf" in CWD per
# invocation, scattering guidance across dozens of files that fm_shell
# can't decode (FM-339).
file mkdir ${fc_outputs}/svf
set_svf ${fc_outputs}/svf/${top_module}.init.svf

#-----------------------------------------------------------------------------
# Bind Liberty .db files via link_library BEFORE create_lib. fc_shell's
# auto-CLIB process inspects link_library at create_lib time to decide
# whether to embed Liberty in the assembled CLIB. If link_library has no
# .db's at create_lib time, fc_shell falls back to a physical-only CLIB
# (LIB-081 warning) and synthesis can't find AND/OR/INV cells (DWS-0103).
#
# Drop the leading "*" — it confuses fc_shell's auto-CLIB inspection,
# which then emits LIB-081 "No db files from link_library" and falls
# back to building a physical-only EXPLORE CLIB.
#-----------------------------------------------------------------------------
set_app_var link_library [list \
    $::env(DB_SS) $::env(DB_FF) \
    {*}$::env(MEM_DBS_SS) {*}$::env(MEM_DBS_FF)]
puts "INFO: \[fc_init\] link_library = [get_app_var link_library]"

#-----------------------------------------------------------------------------
# Create the design library backed by per-library NDMs:
#   stdcell_lib   (tcbn65lp 9-track std cells, LEF + 3-corner Liberty)
#   mem_frame_lib (rf_16k LEF — frames only; Liberty via link_library
#                  set above)
#-----------------------------------------------------------------------------
set lib_dir [file dirname $fusion_lib]
set ref_libs [list]
foreach lib {stdcell_lib mem_frame_lib} {
    set p ${lib_dir}/${lib}
    if {[file isdirectory $p]} { lappend ref_libs $p }
}
puts "INFO: \[fc_init\] creating $design_lib_name -technology $tf_file"
puts "INFO: \[fc_init\]   ref_libs: $ref_libs"
# create_lib refuses to overwrite an existing dlib (LIB-009). Make may
# trigger a re-run of fc_init when the upstream FUSION_LIB directory is
# touched; nuke the old dlib first so the rebuild works idempotently.
file delete -force $design_lib_name
create_lib $design_lib_name -technology $tf_file -ref_libs $ref_libs

#-----------------------------------------------------------------------------
# Common host options, PG_NETS — needs ref_libs already loaded
#-----------------------------------------------------------------------------
source ${fc_dir}/scripts/setup.tcl

#-----------------------------------------------------------------------------
# Read RTL via the shared filelist parser:
#   - parse_flist on $FLIST
#   - analyze + elaborate $top_module
#   - MCMM (scen_slow / scen_fast)
#   - read_parasitic_tech (TLU+)
#   - create_clock + I/O delays for $CLK_NAME
#   - set_scenario_status -setup true *
# After elaborate a current block exists; design-scoped app_options can be
# applied next.
#-----------------------------------------------------------------------------
puts "INFO: \[fc_init\] sourcing shared FC.read_design.tcl"
source ${shared_scripts}/tidelink.FC.read_design.tcl

source ${fc_dir}/scripts/setup_design_options.tcl

#-----------------------------------------------------------------------------
# Optional: overlay partition-specific constraints (multi-clock, CDC)
#-----------------------------------------------------------------------------
# read_sdc FAILURE IS FATAL (blocker ASIC-3, 2026-08-14).
#
# fc_shell's SDC interpreter stops at the first erroring line and
# silently discards the whole remainder of the file (CMD-081 + SDC-5) —
# but `read_sdc` still returns Tcl rc=0, so `catch` does NOT trip
# (measured: fc_shell U-2022.12, PROBE3a). Between 2026-06-03 and
# 2026-08-14 this cost every build the TX eye, the PHC output delay, the
# pad_rx datapath cap and the lane-skew check, and `make fc` still
# reported success because the Makefile only greps for FC_STAGE_OK.
#
# The only reliable detection is to redirect the read and inspect the
# text: fail on any CMD-0xx / SDC-x error, and require the explicit
# completion marker that constraints.sdc prints on its last line.
set extra_sdc ${fc_dir}/inputs/constraints.sdc
if {[file exists $extra_sdc]} {
    puts "INFO: \[fc_init\] overlaying $extra_sdc"
    file mkdir $fc_logs
    foreach scen_name {scen_slow scen_fast} {
        if {[sizeof_collection [get_scenarios -quiet $scen_name]] == 0} { continue }
        current_scenario $scen_name
        set _sdc_log ${fc_logs}/read_sdc.${scen_name}.log
        redirect -tee -file $_sdc_log { read_sdc $extra_sdc }

        set _fp [open $_sdc_log r]; set _txt [read $_fp]; close $_fp
        set _bad 0
        if {[regexp {stopped at line ([0-9]+) due to error} $_txt -> _badline]} {
            puts "ERROR: \[fc_init\] $scen_name: SDC overlay ABORTED at ${extra_sdc}:${_badline}"
            set _bad 1
        }
        if {[regexp {Errors reading SDC file} $_txt]} {
            puts "ERROR: \[fc_init\] $scen_name: read_sdc reported errors (SDC-5)"
            set _bad 1
        }
        if {![regexp {TIDELINK_SDC_OVERLAY_COMPLETE} $_txt]} {
            puts "ERROR: \[fc_init\] $scen_name: completion marker absent — the SDC overlay did not run to the end"
            set _bad 1
        }
        if {$_bad} {
            puts "ERROR: \[fc_init\] Constraints are INCOMPLETE. Every timing number this"
            puts "ERROR: \[fc_init\] build would produce is void. See $_sdc_log."
            puts "ERROR: \[fc_init\] Not touching FC_STAGE_OK."
            exit 1
        }
        puts "INFO: \[fc_init\] $scen_name: SDC overlay read complete (marker seen)"
    }
}

#-----------------------------------------------------------------------------
# Gap C (ASIC_TSMC65) — false_path the explicit SDFFRPQ/SDFFSRPQ async
# reset pins. When the substitution is active these flops are
# instantiated as RTL primitives with R / SN as async-reset inputs, but
# the sc12 Liberty doesn't tag the reset arcs with `preset` so
# fc_shell's timer treats them as data inputs and hold-times the
# source-to-reset paths (caused a -4.71 ns scen_fast hold WNS on the
# first attempt). Apply false_path here in full-fc_shell Tcl, where
# get_pins -hier -filter / sizeof_collection are available (SDC mode
# rejects them, see inputs/constraints.sdc note).
foreach scen_name {scen_slow scen_fast} {
    if {[sizeof_collection [get_scenarios -quiet $scen_name]] == 0} { continue }
    current_scenario $scen_name
    set _wav_async_pins [get_pins -hier -quiet \
        -filter "lib_pin_name == R || lib_pin_name == SN"]
    if {[sizeof_collection $_wav_async_pins] > 0} {
        set_false_path -to $_wav_async_pins
        puts "INFO: \[fc_init\] $scen_name: [sizeof_collection $_wav_async_pins] Wav R/SN async-reset endpoints false_path'd"
    } else {
        puts "INFO: \[fc_init\] $scen_name: no R/SN pins found (ASIC_TSMC65 not active or pre-elaborate)"
    }
}

#-----------------------------------------------------------------------------
# §4 + §5 (from constraints.sdc) — source-synchronous RX constraints that
# CANNOT be expressed in fc_shell's SDC interpreter and must live here.
#
#   §4  set_max_delay on pad_rx[*] -> gpiorx_*/link_data_pad_clk_reg*
#       - the selector needs `-hier -filter` (SDC mode: CMD-010)
#       - `-datapath_only` is PrimeTime-only; fc_shell wants
#         `-ignore_clock_latency` (SDC/Tcl mode alike: CMD-010).
#         Measured 2026-06-01, logs_b10_datapath_only_20260601.
#   §5  set_data_check on the lane bundle
#       - fc_shell's `-to` takes a SINGLE port; a bus collection trips
#         CMD-013, so it must be issued one bit at a time.
#
# This is a re-land of 2474be6 + 8e6c351 (reverted by 51d7d43 / f960ae0).
# ⚠ HISTORY: the one build that ran WITH these constraints correctly
# applied (b11, 2026-06-02) closed route_opt at setup WNS -0.40 /
# hold WNS -1.51 / 140 NVE, versus -0.06 / -0.22 for the shipping build
# that silently dropped them. The constraints are correct; the design
# does not currently meet them. Do not "fix" that by deleting them again
# — widen the budget knobs below and record the number that was used.
#
# Values are re-derived here rather than read from the SDC's Tcl vars,
# because those do not survive into this scope (measured: variables set
# inside read_sdc are not visible to the caller).
#-----------------------------------------------------------------------------
set _t_ui_ns       4.0
set _rx_dp_max     [expr {$_t_ui_ns / 5.0}]   ;# RX_DATAPATH_MAX_NS
set _rx_bus_skew   [expr {$_t_ui_ns / 20.0}]  ;# RX_BUS_SKEW_NS

foreach scen_name {scen_slow scen_fast} {
    if {[sizeof_collection [get_scenarios -quiet $scen_name]] == 0} { continue }
    current_scenario $scen_name

    # §4 — per-lane pad→capture datapath cap
    set _rx_caps [get_cells -hier -quiet \
        -filter "full_name =~ *gpiorx_*/link_data_pad_clk_reg*"]
    if {[sizeof_collection $_rx_caps] > 0} {
        set_max_delay -ignore_clock_latency $_rx_dp_max \
            -from [get_ports {pad_rx[*]}] \
            -to   $_rx_caps
        puts [format "INFO: \[fc_init\] %s: set_max_delay -ignore_clock_latency %.2f ns from pad_rx -> %d link_data_pad_clk_reg caps" \
                $scen_name $_rx_dp_max [sizeof_collection $_rx_caps]]
    } else {
        puts "ERROR: \[fc_init\] $scen_name: pad_rx capture-flop selector matched 0 cells."
        puts "ERROR: \[fc_init\]   Expected *gpiorx_*/link_data_pad_clk_reg* (144 on the"
        puts "ERROR: \[fc_init\]   2026-06 netlist). A Wlink/Chisel regen has renamed it."
        puts "ERROR: \[fc_init\]   Refusing to build with the source-sync RX cap missing."
        exit 1
    }

    # §5 — lane-bundle skew, one bit at a time
    set _rx_pad_clk  [get_ports pad_clk_rx -quiet]
    set _rx_pad_bits [get_ports {pad_rx[*]} -quiet]
    if {[sizeof_collection $_rx_pad_clk] > 0 && [sizeof_collection $_rx_pad_bits] > 0} {
        set _n_skew 0
        foreach_in_collection _p $_rx_pad_bits {
            set_data_check -from $_rx_pad_clk -to $_p -setup $_rx_bus_skew
            set_data_check -from $_rx_pad_clk -to $_p -hold  $_rx_bus_skew
            incr _n_skew
        }
        puts [format "INFO: \[fc_init\] %s: set_data_check (setup+hold) %.2f ns on %d pad_rx bits vs pad_clk_rx" \
                $scen_name $_rx_bus_skew $_n_skew]
    } else {
        puts "ERROR: \[fc_init\] $scen_name: pad_clk_rx / pad_rx[*] not resolved — lane-skew check cannot be applied"
        exit 1
    }
}

#-----------------------------------------------------------------------------
# Functional-mode DFT case analysis + the divided link clocks
#                                             (blocker ASIC-1, 2026-08-14)
#
# `scan_mode` is a bare top-level input (src/rtl/tidelink_top.sv:336) that
# selects six live WavClockMux cells sitting at the root of the Wlink app
# domain, all 8 TX serialisers, all 8 TX word clocks and all 8 RX capture
# + word clocks. With it unconstrained, fc_shell propagates BOTH mux legs,
# so the 10 ns `scan_clk` lands on the functional logic:
#
#   MEASURED on signoff.design, 2026-08-14:
#     registers clocked by scan_clk, no case analysis : 14747 / 21962
#     registers clocked by scan_clk, scan_mode = 0    :     0
#
# Consequences of leaving it: the link domain is timed at 10 ns instead of
# its real period; the `{scan_clk}` async group false-paths every
# Wlink<->core arc; and both ends of the a2l/l2a synchronisers collapse
# onto one clock. The SGDC has had this right all along —
# cdc/tidelink_top.sgdc:57-60 and :133 — the STA set never got it.
#
# ⚠ Case analysis ALONE is not sufficient and must never be enabled
# without the generated clocks below:
#   MEASURED: with scan_mode = 0 and no divided-clock declaration,
#   check_timing reports TCK-002 = 9610 register clock pins with NO
#   fanin clock (baseline: 3). Those 9610 flops become completely
#   untimed — strictly worse than being timed on the wrong clock.
#
# The divided clocks are provably ÷16 free-running 4-bit counters:
#   TX  src/rtl/local_overrides/WavD2DGpioTx.v:136,332-337 -> :330 ~count[3]
#   RX  src/rtl/local_overrides/WavD2DGpioRx.v:214,542-547 -> :313 ~adj_count[3]
# and the FPGA flow has carried the equivalent constraint since
# fpga/targets/kr260-pair-flip-ptp/kr260_tidelink_timing.xdc:465-467.
#
# Gate: FC_SCAN_CASE_ANALYSIS=off reverts to the (broken) legacy
# behaviour for A/B comparison. Default on.
#-----------------------------------------------------------------------------
set _scan_ca on
if {[info exists ::env(FC_SCAN_CASE_ANALYSIS)]} { set _scan_ca $::env(FC_SCAN_CASE_ANALYSIS) }

if {$_scan_ca eq "off"} {
    puts "WARNING: \[fc_init\] FC_SCAN_CASE_ANALYSIS=off — scan_clk will propagate"
    puts "WARNING: \[fc_init\]   into functional logic (14747/21962 sinks on the 2026-06"
    puts "WARNING: \[fc_init\]   netlist). Every link-domain timing number will be void."
} else {
    # 1. Hold the DFT controls inactive in mode `func`. Mirrors
    #    cdc/tidelink_top.sgdc:57-60. scan_in is a data port, left alone.
    foreach scen_name {scen_slow scen_fast} {
        if {[sizeof_collection [get_scenarios -quiet $scen_name]] == 0} { continue }
        current_scenario $scen_name
        foreach _p {scan_mode scan_shift scan_asyncrst_ctrl} {
            set _pc [get_ports $_p -quiet]
            if {[sizeof_collection $_pc] > 0} {
                set_case_analysis 0 $_pc
            } else {
                puts "ERROR: \[fc_init\] $scen_name: DFT port '$_p' not found — cannot pin it for mode func"
                exit 1
            }
        }
        puts "INFO: \[fc_init\] $scen_name: set_case_analysis 0 on scan_mode/scan_shift/scan_asyncrst_ctrl"
    }

    # 2. Declare the ÷16 word clocks so the flops the case analysis just
    #    took off scan_clk have a real clock. Per lane: lane 0's mux
    #    output is the whole-PHY link clock (WavD2DGpio.v:986,988) but the
    #    other seven feed the deskew block, so all 16 are declared.
    #
    #    Selector strategy: try the mux-output pin first (the actual link
    #    clock node), then the divider flop output. Whichever resolves is
    #    used; if NEITHER resolves the run aborts, because proceeding
    #    would strand 9610 flops with no clock.
    proc _tl_first_pin {patterns} {
        foreach pat $patterns {
            set c [get_pins -hierarchical -quiet $pat]
            if {[sizeof_collection $c] > 0} { return [list $pat $c] }
        }
        return [list "" ""]
    }

    # Anchor preference per lane: the WavD2DGpio{Tx,Rx} instance's
    # io_link_clk output port (survives while the hierarchy is intact —
    # which it is here, post-elaborate), then the mux output, then the
    # divider flop. Measured 2026-08-14 on the FLATTENED post-route
    # netlist: only *gpiotx_0/count_reg[3]/QN and *gpiorx_*/count_reg[3]/Q
    # resolve; the hierarchical pins are gone, and TX lanes 1-7 have been
    # merged into lane 0. That is expected there and is why lanes 1-7 are
    # best-effort. Lane 0 is mandatory in BOTH directions: WavD2DGpio.v:986
    # and :988 make gpiotx_0 / gpiorx_0's mux output THE whole-PHY TX / RX
    # link clock.
    proc _tl_word_clock {dir lane name master_port master_clk cands} {
        upvar 1 _created _created
        lassign [_tl_first_pin $cands] _pat _pin
        if {$_pat eq ""} {
            if {$lane == 0} {
                puts "ERROR: \[fc_init\] $dir lane 0 word-clock anchor not found. Tried: $cands"
                puts "ERROR: \[fc_init\]   Lane 0 IS the PHY $dir link clock (WavD2DGpio.v:986/:988)."
                puts "ERROR: \[fc_init\]   With scan_mode pinned to 0 and no divided clock declared,"
                puts "ERROR: \[fc_init\]   the whole $dir link domain would be untimed (measured:"
                puts "ERROR: \[fc_init\]   9610 register clock pins with no fanin clock). Aborting."
                exit 1
            }
            puts "INFO: \[fc_init\] $dir lane $lane: no distinct divider (merged into lane 0) — skipped"
            return ""
        }
        if {[string match "*count_reg*" $_pat] && $dir eq "RX"} {
            puts "CRITICAL WARNING: \[fc_init\] RX lane $lane fell back to the raw count_reg"
            puts "CRITICAL WARNING: \[fc_init\]   anchor. adj_count = count + io_phase_offset"
            puts "CRITICAL WARNING: \[fc_init\]   (WavD2DGpioRx.v:219) is COMBINATIONAL, so the declared"
            puts "CRITICAL WARNING: \[fc_init\]   clock has the right FREQUENCY but not the calibrated"
            puts "CRITICAL WARNING: \[fc_init\]   PHASE. STA owner must review the edge relationship."
        }
        create_generated_clock -name $name -source [get_ports $master_port] \
            -divide_by 16 -add -master_clock $master_clk $_pin
        puts "INFO: \[fc_init\] $name <- $master_clk /16 at '$_pat'"
        return $name
    }

    set _tx_word_clks [list]
    set _rx_word_clks [list]
    foreach lane {0 1 2 3 4 5 6 7} {
        set _n [_tl_word_clock TX $lane "link_tx_word_clk_${lane}" \
                    user_ref_clk user_ref_clk [list \
                        "*gpiotx_${lane}/io_link_clk" \
                        "*gpiotx_${lane}/io_link_clk_mux/io_o_z" \
                        "*gpiotx_${lane}/count_reg\[3\]/QN" \
                        "*gpiotx_${lane}/count_reg\[3\]/Q"]]
        if {$_n ne ""} { lappend _tx_word_clks $_n }

        set _n [_tl_word_clock RX $lane "link_rx_word_clk_${lane}" \
                    pad_clk_rx pad_clk_rx [list \
                        "*gpiorx_${lane}/io_link_clk" \
                        "*gpiorx_${lane}/io_link_clk_mux/io_o_z" \
                        "*gpiorx_${lane}/io_link_clk_mux/io_i_a" \
                        "*gpiorx_${lane}/count_reg\[3\]/Q"]]
        if {$_n ne ""} { lappend _rx_word_clks $_n }
    }

    # 3. Re-derive the async groups. The word clocks are DERIVED from
    #    user_ref_clk / pad_clk_rx and must sit in their master's group —
    #    they must NOT inherit scan_clk's group, which is what previously
    #    false-pathed every Wlink<->core arc. This supersedes the group
    #    set declared in constraints.sdc (expect UIC-030 overlap notes).
    foreach scen_name {scen_slow scen_fast} {
        if {[sizeof_collection [get_scenarios -quiet $scen_name]] == 0} { continue }
        current_scenario $scen_name
        set_clock_groups -asynchronous -name tidelink_link_domains \
            -group [get_clocks {hclk}] \
            -group [get_clocks {phc_clk}] \
            -group [get_clocks {scan_clk}] \
            -group [get_clocks [concat {user_ref_clk pad_clk_tx_fwd} $_tx_word_clks]] \
            -group [get_clocks [concat {pad_clk_rx} $_rx_word_clks]]
    }
    puts "INFO: \[fc_init\] async groups re-derived with [llength $_tx_word_clks] TX + [llength $_rx_word_clks] RX word clocks"
}

#-----------------------------------------------------------------------------
# Post-constraint assertions (blocker ASIC-3). These are the checks that
# would have caught the 2026-06 silent constraint loss on the day it
# happened. They are cheap and they run before any placement work.
#-----------------------------------------------------------------------------
current_scenario scen_slow
set _assert_fail 0

# (a) The TX eye must exist.
#
#     NOT `get_timing_paths -to [get_ports pad_tx[*]]` — that returns 1
#     even on the broken shipping build, because FC.read_design.tcl gives
#     all_outputs a meaningless hclk-referenced delay. Measured
#     2026-08-14 on signoff.design: to pad_tx[*] = 1 both before and
#     after the fix. Such a check is a vacuous gate.
#
#     The discriminating form is "-to [get_clocks pad_clk_tx_fwd]", which
#     is non-empty only if §2 of the overlay actually landed. Measured:
#       shipping build (overlay aborted at :168) : 0 paths
#       fixed overlay                           : 1 path
set _tx_paths [get_timing_paths -to [get_clocks pad_clk_tx_fwd] -max_paths 1]
if {[sizeof_collection $_tx_paths] == 0} {
    puts "ERROR: \[fc_init\] ASSERT FAILED: nothing is timed against pad_clk_tx_fwd."
    puts "ERROR: \[fc_init\]   The TX eye (constraints.sdc §2) did not land. This is the"
    puts "ERROR: \[fc_init\]   exact 2026-06 silent-constraint-loss signature."
    set _assert_fail 1
} else {
    puts "INFO: \[fc_init\] ASSERT ok: TX eye landed (paths timed to pad_clk_tx_fwd)"
}

# (b) The RX eye must exist — the CRITICAL #2 regression signature that
#     constraints.sdc:116-120 asks for by name: pad_rx[*] -> pad_clk_rx
#     must return real paths, not "No paths". If pad_clk_rx ever gets put
#     back into a blanket async group, this goes to zero.
set _rx_paths [get_timing_paths -from [get_ports {pad_rx[*]}] -to [get_clocks pad_clk_rx] -max_paths 1]
if {[sizeof_collection $_rx_paths] == 0} {
    puts "ERROR: \[fc_init\] ASSERT FAILED: no pad_rx[*] -> pad_clk_rx path."
    puts "ERROR: \[fc_init\]   The source-sync RX capture arc is not timed (CRITICAL #2 regression)."
    set _assert_fail 1
} else {
    puts "INFO: \[fc_init\] ASSERT ok: RX capture arc timed (pad_rx[*] -> pad_clk_rx)"
}

# (c) Both scenarios must carry clock uncertainty (blocker ASIC-2). A
#     signoff corner with zero uncertainty proves nothing.
foreach scen_name {scen_slow scen_fast} {
    if {[sizeof_collection [get_scenarios -quiet $scen_name]] == 0} { continue }
    current_scenario $scen_name
    set _u [get_attribute -quiet [get_clocks $clk_name] setup_uncertainty]
    if {$_u eq "" || $_u == 0} {
        puts "ERROR: \[fc_init\] ASSERT FAILED: $scen_name has setup_uncertainty='$_u' on $clk_name."
        puts "ERROR: \[fc_init\]   A corner with zero uncertainty is not a signoff corner."
        set _assert_fail 1
    } else {
        puts "INFO: \[fc_init\] ASSERT ok: $scen_name $clk_name setup_uncertainty = $_u"
    }
}

if {$_assert_fail} {
    puts "ERROR: \[fc_init\] constraint assertions failed — not touching FC_STAGE_OK."
    exit 1
}
current_scenario scen_slow

#-----------------------------------------------------------------------------
# Initialise floorplan — partition target: aspect 1.0, util 0.85
#-----------------------------------------------------------------------------
puts "INFO: \[fc_init\] initialize_floorplan aspect=$aspect_ratio util=$core_util offset=$core_offset"
# fc_shell U-2022.12 initialize_floorplan options:
#   -control_type   core | die  (not "aspect_ratio")
#   -shape          R | L | T | U  (R = rectangle = aspect-1.0 default)
#   -side_ratio     {a b}        — aspect ratio = a/b
#   -core_utilization ratio
initialize_floorplan \
    -control_type core \
    -shape R \
    -side_ratio [list $aspect_ratio 1.0] \
    -core_utilization $core_util \
    -core_offset $core_offset

#-----------------------------------------------------------------------------
# Macro placement — pin the rf_16k FIFO RAM to a die corner.
#-----------------------------------------------------------------------------
source ${fc_dir}/scripts/place_memories.tcl

#-----------------------------------------------------------------------------
# Port-to-edge assignment — Wlink PHY on TOP, AHB busses on BOTTOM,
# APB + PHC time on LEFT, clocks/resets/DFT on RIGHT.
#-----------------------------------------------------------------------------
source ${fc_dir}/scripts/place_pins.tcl

#-----------------------------------------------------------------------------
# Power-ground mesh — VDD/VSS supply nets, M1 std-cell rails, M5/M6
# mesh, and macro long-pin straps. Built BEFORE compile_fusion runs
# std-cell placement so the placer dodges the straps.
#-----------------------------------------------------------------------------
source ${fc_dir}/scripts/pg_mesh.tcl

#-----------------------------------------------------------------------------
# Pre-compile sanity checks
#-----------------------------------------------------------------------------
file mkdir $fc_reports
redirect -tee -file ${fc_logs}/init_check_lib.log {
    report_design
    report_clocks
    report_scenarios
}

redirect -tee -file ${fc_logs}/precompile_checks.log {
    compile_fusion -check_only
}

#-----------------------------------------------------------------------------
# Save block: ${design_lib}/${top}/init.design
#-----------------------------------------------------------------------------
save_block
save_lib $design_lib_name
save_block -as ${design_lib_name}:${top_module}/init.design

puts "FC_STAGE_OK: init"
exit
