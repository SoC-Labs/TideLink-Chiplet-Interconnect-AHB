###-----------------------------------------------------------------------------
### TideLink Chiplet Subsystem - Vivado Build Driver Script
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Top-level Vivado TCL driver: creates project, sources block design,
### adds wrapper and constraints, runs synth/impl/bitstream and exports
### bitstream + .hwh for PYNQ overlay loading.
###
### Required environment variables:
###   FPGA_PART        - Xilinx part number (e.g. xc7z020clg400-1)
###   FPGA_PROJECT_DIR - Output directory for Vivado project
###   FPGA_IP_REPO     - Path to packaged IP repository
###   FPGA_TARGET_DIR  - Path to target-specific files (BD TCL, wrapper, XDC)
###   FPGA_OUTPUT_DIR  - Path for final outputs (.bit, .hwh, .xsa)
###   FPGA_NUM_JOBS    - Number of parallel jobs for synthesis/implementation
###
### Optional environment variables:
###   FPGA_ALLOW_CRITICAL_WARNINGS=1
###       Disables the generic post-phase CRITICAL_WARNING count check
###       (intended for exploratory / legacy builds). Does NOT disable
###       the per-message ERROR promotions below - those are always fatal
###       because they have been observed to cause silent constraint
###       regressions (e.g. 0/16 lane lock on hardware after a build that
###       otherwise "succeeded"). See fpga/docs/VIVADO_MSG_GATE.md.
###-----------------------------------------------------------------------------

###-----------------------------------------------------------------------------
### Vivado message gate
###-----------------------------------------------------------------------------
### Background: 2026-05-21 we lost a day to a silent constraint failure.
### Multiple CRITICAL WARNING classes were emitted at synth/impl time, the
### build still "PASSED", and the resulting bitstream produced 0/16 lane
### lock on hardware vs 14/16 on the previous bitstream. Observed in the
### broken build log (synth_1 + impl_1 runme.log):
###   [Constraints 18-359]  create_generated_clock: > 1 master pin matched
###   [Vivado 12-4739]      set_input/output_delay: No valid object(s)
###   [Designutils 20-1307] Command 'if'/'catch'/'file'/'info'/'get_files'
###                         not supported in XDC -> silently skipped
###   [Common 17-55]        set_property: empty selector
###   [Vivado 12-1411]      get_pins/get_cells empty filter result
###
### These are all classes of "the constraint was silently dropped". Treat
### them as hard errors so the build dies at the source, not on the bench.
###
### Gate has TWO layers:
###   1. set_msg_config -severity ERROR for each known-bad message ID
###      (always on, cannot be disabled by env-var; the IDs are surgical).
###   2. Post-synth / post-impl CRITICAL_WARNING count check (skippable via
###      FPGA_ALLOW_CRITICAL_WARNINGS=1 for exploratory builds).
###
### To add a new promotion: append to the list below with a comment
### explaining the failure mode it guards. To intentionally suppress a
### legitimate CRITICAL WARNING: use `set_msg_config -id <ID> -suppress`
### immediately after the promotion block, with a justification comment.
###
### See fpga/docs/VIVADO_MSG_GATE.md for the canonical list + rationale.
###-----------------------------------------------------------------------------
if {![info exists ::tidelink_msg_gate_installed]} {
    puts "==========================================="
    puts " Installing TideLink Vivado message gate"
    puts "==========================================="

    # [Constraints 18-359] create_generated_clock: > 1 master pin matched
    # -> derived clock is silently NOT created, downstream timing breaks.
    set_msg_config -id "Constraints 18-359"  -new_severity ERROR

    # [Vivado 12-4739] set_input/output_delay: No valid object(s) for -clock
    # or -ports -> the constraint becomes a no-op (clock or port unknown).
    set_msg_config -id "Vivado 12-4739"      -new_severity ERROR

    # [Designutils 20-1307] Procedural TCL ('if' / 'catch' / 'file' / 'info'
    # / 'get_files') is not supported inside an XDC. Anything guarded by
    # these is silently skipped.
    set_msg_config -id "Designutils 20-1307" -new_severity ERROR

    # [Common 17-55] 'set_property' expects at least one object - originally
    # promoted here for the same silent-drop class, but it has false-positives
    # at scale: Xilinx XPM IP (xpm_memory_xdc.tcl etc.) emits many benign
    # 17-55s during OOC IP synth. Symptomatic from 9+ SmartConnect MIs (see
    # docs/PHC_ALL_MIRROR_LOG.md). The other 4 promotions above
    # (Designutils 20-1307, Vivado 12-4739, 12-1411, Constraints 18-359) are
    # surgical and caught every real silent-drop seen in the lane-lock saga:
    #   - lindex/get_files in user XDC -> Designutils 20-1307
    #   - cascade from a dropped clock  -> Vivado 12-4739
    #   - empty get_pins/get_cells      -> Vivado 12-1411
    #   - multi-master generated_clock  -> Constraints 18-359
    # Common 17-55 adds little surgical coverage on top, so suppress it to
    # let Xilinx-IP OOC synth scale cleanly. Removing the ERROR promotion is
    # not enough on its own: tidelink_check_cw_count counts all CWs, and the
    # Xilinx-IP 17-55s would tip the count over 0 at scale too.
    set_msg_config -id "Common 17-55"        -suppress

    # [Vivado 12-1411] Empty result from get_pins / get_cells / get_ports
    # filter that then propagates as a silent no-op constraint.
    set_msg_config -id "Vivado 12-1411"      -new_severity ERROR

    # COMBINATIONAL-LOOP guard (cb33c9f-class silicon write-vanish). An
    # UN-waived combinational loop is flagged by the LUTLP-1 DRC. Intentional
    # loops are individually waived via ALLOW_COMBINATORIAL_LOOPS in
    # *_tidelink_drc.xdc, so promoting LUTLP-1 to ERROR only bites on NEW,
    # accidental loops. Wrapped in catch: get_drc_checks needs the DRC rule DB,
    # which is present in the parent session but this keeps the top-of-file
    # block robust if sourced in a bare context. The REAL enforcement is in the
    # child hooks (fpga/scripts/msg_gate_child_{promote,check}.tcl), because the
    # DRC actually runs in the synth/impl child processes, not this parent.
    catch { set_property SEVERITY {ERROR} [get_drc_checks LUTLP-1] }

    set ::tidelink_msg_gate_installed 1
}

# Build-integrity & provenance helpers (Bug-class: silent-V1 / stale-packaged-IP
# / dropped-XDC). Sourced here so tl_verify_packaged_ip + tl_write_manifest are
# available at their mandatory call sites below and CANNOT be skipped. A missing
# helper is a hard error - the integrity gate must not silently no-op.
set _prov_tcl [file join [file dirname [info script]] scripts build_provenance.tcl]
if { ![file exists $_prov_tcl] } {
    puts "ERROR: build-integrity helper not found: $_prov_tcl"
    exit 1
}
source $_prov_tcl

# Helper: check CRITICAL_WARNING count after a phase. Honours
# FPGA_ALLOW_CRITICAL_WARNINGS=1 to allow legacy/exploratory builds.
# The per-message ERROR promotions above are NOT bypassed by this env-var.
proc tidelink_check_cw_count { phase_name } {
    set cw_count [get_msg_config -count -severity {CRITICAL WARNING}]
    puts "\[tidelink_msg_gate\] CRITICAL_WARNING count after $phase_name : $cw_count"

    if { $cw_count <= 0 } {
        return
    }

    if { [info exists ::env(FPGA_ALLOW_CRITICAL_WARNINGS)]
         && $::env(FPGA_ALLOW_CRITICAL_WARNINGS) == "1" } {
        puts "\[tidelink_msg_gate\] FPGA_ALLOW_CRITICAL_WARNINGS=1 set - proceeding despite $cw_count CRITICAL WARNING(s)."
        return
    }

    puts "==========================================="
    puts " TideLink Vivado message gate FAILED"
    puts " Phase   : $phase_name"
    puts " CW count: $cw_count"
    puts "-------------------------------------------"
    puts " Dumping WARNING + CRITICAL WARNING rules"
    puts " (look in $phase_name/runme.log for the"
    puts "  exact messages and their IDs)."
    puts "-------------------------------------------"
    if { [catch { puts [get_msg_config -rules] } _err] } {
        puts "(get_msg_config -rules unavailable: $_err)"
    }
    puts "-------------------------------------------"
    puts " To bypass this check for an exploratory"
    puts " build, set FPGA_ALLOW_CRITICAL_WARNINGS=1"
    puts " in the environment. This does NOT disable"
    puts " the per-message ERROR promotions - those"
    puts " IDs will still hard-fail the build."
    puts " See fpga/docs/VIVADO_MSG_GATE.md."
    puts "==========================================="
    exit 1
}

set part        $env(FPGA_PART)
set project_dir $env(FPGA_PROJECT_DIR)
set ip_repo     $env(FPGA_IP_REPO)
# PHC IP repo (packaged separately from tidelink). Optional — if unset, the
# PHC IP is assumed absent and the BD's PHC tie-off path is used. Block
# designs that instantiate the PHC IP will fail update_ip_catalog without it.
if { [info exists env(FPGA_PHC_IP_REPO)] && $env(FPGA_PHC_IP_REPO) ne "" } {
    set phc_ip_repo $env(FPGA_PHC_IP_REPO)
} else {
    set phc_ip_repo ""
}
set target_dir  $env(FPGA_TARGET_DIR)
set output_dir  $env(FPGA_OUTPUT_DIR)

if { [info exists env(FPGA_NUM_JOBS)] } {
    set num_jobs $env(FPGA_NUM_JOBS)
} else {
    set num_jobs 4
}

puts "==========================================="
puts " TideLink Chiplet Subsystem FPGA Build"
puts " Part:    $part"
puts " Project: $project_dir"
puts " IP Repo: $ip_repo"
puts " Target:  $target_dir"
puts " Output:  $output_dir"
puts " Jobs:    $num_jobs"
puts "==========================================="

# STEP 1: Create Vivado project
create_project tidelink_project $project_dir -part $part -force
# SoC Labs 2026-06-21 (turnaround): let synth/impl use more host threads (QoR-neutral).
set_param general.maxThreads 8

# Optional BOARD_PART (2026-07-09, KR260 port). Zynq UltraScale+ targets (Kria
# KR260, xck26) drive the PS/DDR/MIO configuration from the board preset, which
# requires the board_part set on the project before the BD is sourced. The Z2
# targets set no FPGA_BOARD_PART, so this is a no-op there (bare-part flow
# unchanged). If a board part is named but not installed in this Vivado, fail
# loudly here rather than let the BD silently mis-preset the PS.
if { [info exists env(FPGA_BOARD_PART)] && $env(FPGA_BOARD_PART) ne "" } {
    set _bp $env(FPGA_BOARD_PART)
    if { [llength [get_board_parts -quiet $_bp]] == 0 } {
        # Board files ship in Vivado's XilinxBoardStore; refresh the catalog once
        # in case they were installed after this Vivado's board cache was built.
        catch { xhub::refresh_catalog [xhub::get_xstores] }
        catch { update_board_part_repos }
    }
    if { [llength [get_board_parts -quiet $_bp]] == 0 } {
        puts "ERROR: FPGA_BOARD_PART='$_bp' not found in this Vivado's board catalog."
        puts "       Install the Kria board files (XilinxBoardStore) or fix the id."
        exit 1
    }
    set_property BOARD_PART $_bp [current_project]
    puts "BOARD_PART: set to $_bp"
}

# STEP 2: Add IP repositories (tidelink + optional PHC)
if { $phc_ip_repo ne "" } {
    set_property ip_repo_paths [list $ip_repo $phc_ip_repo] [current_project]
} else {
    set_property ip_repo_paths $ip_repo [current_project]
}
update_ip_catalog

# SoC Labs 2026-06-21 (turnaround): shared persistent IP cache so unchanged Xilinx
# OOC sub-IP (axi_smc ~4m52s, axi_smc_data ~3m43s, PS7, clk_wiz, ahb bridges) is
# REUSED across builds instead of re-synthesised on every `create_project -force`.
# Survives the project wipe (cache lives outside the project dir). Keyed on IP
# config+part+tool, so a genuine IP-config change correctly misses. Zero effect on
# placement/routing/timing (the pad_clk_rx eye is untouched). NEVER under /research/AAA.
if { [info exists ::env(FPGA_IP_CACHE_DIR)] && $::env(FPGA_IP_CACHE_DIR) ne "" } {
    file mkdir $::env(FPGA_IP_CACHE_DIR)
    config_ip_cache -use_cache_location $::env(FPGA_IP_CACHE_DIR)
    puts "IP CACHE: using $::env(FPGA_IP_CACHE_DIR)"
}

# STEP 3: Source block design
source $target_dir/tidelink_design.tcl

# PHY link/pad clock /2 divider RTL — MUST be in the source fileset (with the
# compile order updated) BEFORE create_root_design, because the BD instantiates
# it via `create_bd_cell -type module -reference tidelink_phy_clk_div2`. Module
# references only resolve in automatic-compile-order mode against a file already
# in sources_1. Added here (not in tidelink_design.tcl, which only builds the BD)
# so it lands in the project fileset the same way as the board wrapper below.
set phy_clk_div_v [lindex [glob -nocomplain $target_dir/tidelink_phy_clk_div2.v] 0]
if { $phy_clk_div_v ne "" } {
    add_files -norecurse $phy_clk_div_v
    update_compile_order -fileset sources_1
    puts "INFO: added PHY /2 clock divider $phy_clk_div_v"
} else {
    puts "WARNING: tidelink_phy_clk_div2.v not found in $target_dir - BD module-ref will fail"
}

# AHB-Lite BRAM terminus for TideLink's ahb_mng manager port — SAME
# module-reference requirement as the /2 divider above: the BD instantiates it
# via `create_bd_cell -type module -reference tidelink_ahb_mng_bram`, so the
# terminus .v AND the two CMSDK library cells it wraps (cmsdk_ahb_to_sram +
# cmsdk_fpga_sram) MUST be in sources_1 with the compile order updated BEFORE
# create_root_design. The terminus .v is a per-target file (glob on
# $target_dir, exactly like tidelink_phy_clk_div2.v); the CMSDK cells come from
# the Arm BP210 package via $CMSDK_DIR / $CMSDK_FPGA_SRAM_V (see set_env.sh and
# the cmsdk_fpga_sram workaround — fpga_sram is missing from some BP210 installs
# so it is resolved through its own env var).
set ahb_mng_bram_v [lindex [glob -nocomplain $target_dir/tidelink_ahb_mng_bram.v] 0]
if { $ahb_mng_bram_v ne "" } {
    add_files -norecurse $ahb_mng_bram_v
    if { [info exists ::env(CMSDK_DIR)] } {
        set cmsdk_ahb_to_sram_v $::env(CMSDK_DIR)/logical/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v
        if { [file exists $cmsdk_ahb_to_sram_v] } {
            add_files -norecurse $cmsdk_ahb_to_sram_v
            puts "INFO: added CMSDK cmsdk_ahb_to_sram $cmsdk_ahb_to_sram_v"
        } else {
            puts "WARNING: cmsdk_ahb_to_sram.v not found at $cmsdk_ahb_to_sram_v - BRAM terminus elaboration will fail"
        }
    } else {
        puts "WARNING: CMSDK_DIR not set - cmsdk_ahb_to_sram.v cannot be added, BRAM terminus elaboration will fail"
    }
    if { [info exists ::env(CMSDK_FPGA_SRAM_V)] && [file exists $::env(CMSDK_FPGA_SRAM_V)] } {
        add_files -norecurse $::env(CMSDK_FPGA_SRAM_V)
        puts "INFO: added CMSDK cmsdk_fpga_sram $::env(CMSDK_FPGA_SRAM_V)"
    } else {
        puts "WARNING: CMSDK_FPGA_SRAM_V unset or missing - cmsdk_fpga_sram.v cannot be added, BRAM terminus elaboration will fail"
    }
    update_compile_order -fileset sources_1
    puts "INFO: added AHB-Lite BRAM terminus $ahb_mng_bram_v"
} else {
    puts "WARNING: tidelink_ahb_mng_bram.v not found in $target_dir - BD module-ref will fail"
}

set design_name tidelink_design
create_bd_design $design_name
create_root_design ""

# STEP 4: Add board-level wrapper
add_files $target_dir/tidelink_design_wrapper.v
set_property top tidelink_design_wrapper [current_fileset]

# STEP 5: Add constraints
# Pin assignment XDC — used in synthesis and implementation
set pin_xdc [lindex [glob -nocomplain $target_dir/*_tidelink.xdc] 0]
if { $pin_xdc ne "" } {
    add_files -fileset constrs_1 $pin_xdc
} else {
    puts "WARNING: no pin XDC found at $target_dir/*_tidelink.xdc"
}

# Timing XDC — implementation only (set_property USED_IN_SYNTHESIS false)
set timing_xdc [lindex [glob -nocomplain $target_dir/*_tidelink_timing.xdc] 0]
if { $timing_xdc ne "" } {
    add_files -fileset constrs_1 $timing_xdc
    set_property USED_IN_SYNTHESIS false \
        [get_files $timing_xdc]
    set_property USED_IN_IMPLEMENTATION true \
        [get_files $timing_xdc]
} else {
    puts "WARNING: no timing XDC found at $target_dir/*_tidelink_timing.xdc"
}

# DRC waiver XDC — separate file so save_constraints (which rewrites the
# timing XDC during debug-core insertion) can't strip our SEVERITY +
# ALLOW_COMBINATORIAL_LOOPS overrides. Applied during impl only (the
# combinatorial loop is post-route DRC).
set drc_xdc [lindex [glob -nocomplain $target_dir/*_tidelink_drc.xdc] 0]
if { $drc_xdc ne "" } {
    add_files -fileset constrs_1 $drc_xdc
    set_property USED_IN_SYNTHESIS false \
        [get_files $drc_xdc]
    set_property USED_IN_IMPLEMENTATION true \
        [get_files $drc_xdc]
}

# IDELAY XDC — SoC Labs §9 structural fix. Separate file (NOT *_timing.xdc,
# which another agent owns). Carries the IODELAY_GROUP binding for the
# per-lane IDELAYE2 + IDELAYCTRL and the IOB-policy for pad_rx[*]. Applied
# in BOTH synth and impl so the IODELAY_GROUP string attribute on the cells
# is honoured by the placer/router.
#
# INCLUSION GATE (2026-05-21, fix/xdc-declarative): on a USE_IDELAY=0 build
# there are NO IDELAYE2 / IDELAYCTRL cells, so the get_cells selectors inside
# the XDC would return empty and the msg gate would hard-fail with
# Common 17-55 / Vivado 12-1411. Add the file ONLY when FPGA_USE_IDELAY=1.
# Default = 0 (preserves current pair-all/pair-flip-all behaviour where the
# RTL parameter USE_IDELAY defaults to 0). Set FPGA_USE_IDELAY=1 in the
# environment (Makefile) on builds that instantiate IDELAYE2.
set fpga_use_idelay 0
if { [info exists env(FPGA_USE_IDELAY)] && $env(FPGA_USE_IDELAY) == "1" } {
    set fpga_use_idelay 1
}
set idelay_xdc [lindex [glob -nocomplain $target_dir/*_tidelink_idelay.xdc] 0]
if { $idelay_xdc ne "" && $fpga_use_idelay == 1 } {
    add_files -fileset constrs_1 $idelay_xdc
    set_property USED_IN_SYNTHESIS true \
        [get_files $idelay_xdc]
    set_property USED_IN_IMPLEMENTATION true \
        [get_files $idelay_xdc]
    puts "INFO: FPGA_USE_IDELAY=1 - including $idelay_xdc"
} elseif { $idelay_xdc ne "" } {
    puts "INFO: FPGA_USE_IDELAY!=1 - skipping $idelay_xdc (no IDELAYE2 cells expected)"
}

# COMMON-EXTERNAL-REFERENCE XDC — same INCLUSION-GATE reasoning as the IDELAY XDC
# above. *_tidelink_extrefclk.xdc constrains the `pad_refclk_in` port, which only
# exists in the BD when FPGA_TIDELINK_EXTREFCLK=1. Adding it on a default build
# would leave get_ports empty -> [Vivado 12-1411] -> hard ERROR under the message
# gate. XDC cannot self-guard (procedural Tcl in an XDC is [Designutils 20-1307],
# also promoted to ERROR), so the gate has to live here.
# The file relocates one data lane off an HDGC ball and puts the shared reference
# there, making the two dies MESOCHRONOUS. See fpga/docs/KR260_NEXT_WEEK_PLAN.md.
set fpga_extrefclk 0
if { [info exists env(FPGA_TIDELINK_EXTREFCLK)] && $env(FPGA_TIDELINK_EXTREFCLK) == "1" } {
    set fpga_extrefclk 1
}
set extref_xdc [lindex [glob -nocomplain $target_dir/*_tidelink_extrefclk.xdc] 0]
if { $extref_xdc ne "" && $fpga_extrefclk == 1 } {
    add_files -fileset constrs_1 $extref_xdc
    set_property USED_IN_SYNTHESIS true       [get_files $extref_xdc]
    set_property USED_IN_IMPLEMENTATION true  [get_files $extref_xdc]
    puts "INFO: FPGA_TIDELINK_EXTREFCLK=1 - including $extref_xdc (MESOCHRONOUS: shared reference clock)"
} elseif { $extref_xdc ne "" } {
    puts "INFO: FPGA_TIDELINK_EXTREFCLK!=1 - skipping $extref_xdc (no pad_refclk_in port; local PS-derived link clock)"
}

# STEP 6: Generate block design outputs
# Be specific about WHICH BD - using *.bd matches nested SmartConnect
# sub-designs which can only be generated by their parent.
generate_target all [get_files ${design_name}.bd]

# STEP 7: Update compile order
update_compile_order -fileset sources_1

# STEP 7.5: Packaged-IP integrity gate (stale-packaged-IP trap).
# Runs BEFORE synthesis: verify every flist-referenced RTL source matches the
# copy ipx::package_project imported into $ip_repo/src/. If an RTL file was
# edited but `make package_ip` was not re-run, build_design would otherwise
# synthesise the OLD sources (memory: project_farm_package_ip_stale). Hard-fails
# (exit 1) on any content mismatch so the stale build dies here, not on silicon.
tl_verify_packaged_ip $ip_repo

# STEP 8: Synthesis
puts "Starting synthesis..."
# S3 PHY swap (2026-06-11): TIDELINK_PHY_V2=1 injected at the synth-run level
# (a *fileset* verilog_define does NOT bake into a packaged IP — proven
# 2026-05-19, see package_tidelink_ip.tcl).
#
# !! MEASURED 2026-07-09 — READ BEFORE TRUSTING THE COMMENT THIS REPLACES !!
# The old comment claimed this reaches "top + OOC IP runs". IT DOES NOT. At this
# point in the script the ONLY synthesis run that exists is synth_1; Vivado
# auto-creates the packaged IP's out-of-context run
# (tidelink_design_tidelink_0_0_synth_1) later, inside launch_runs. Verified on a
# real build: that OOC runme.log shows
#     synth_design -top tidelink_design_tidelink_0_0 ... -mode out_of_context
# with ZERO -verilog_define, while synth_1's shows two. WavD2DGpio.v and
# axi_chiplet_controller.sv both compile in that OOC run.
#
# Consequence: the three `ifdef TIDELINK_PHY_V2 blocks inside the packaged IP
# (src/rtl/local_overrides/axi_chiplet_controller.sv) have been DEAD in every
# FPGA bitstream. The shipped builds are "V2" because the flist packages the V2
# SOURCES (deps/tidelink-phy), not because the define did anything.
#
# That is left ALONE here on purpose. Making TIDELINK_PHY_V2 reach the OOC run
# would switch on three previously-dead code blocks in a silicon-proven
# configuration — a behaviour change that needs its own validation, not a
# drive-by fix. So PHY_V2 keeps its historical (top-only) scope.
#
# TIDELINK_EPOCH_ANCHOR is different: its `ifdef lives in WavD2DGpio.v, INSIDE
# the packaged IP, so it is worthless unless it reaches the OOC run. For anchor
# builds only, we create the BD's IP runs up-front (create_ip_run) so they exist
# and can be targeted. Blast radius: anchor builds only; the default path below
# is byte-for-byte what it always was.
#
# Defines MUST be accumulated into ONE MORE_OPTIONS string: set_property
# REPLACES the property, so a second independent set_property would silently
# drop the first define — a silent-V1 relapse via a different door.
set _epoch_anchor 0
if { [info exists ::env(TIDELINK_EPOCH_ANCHOR)] && $::env(TIDELINK_EPOCH_ANCHOR) == 1 } {
    set _epoch_anchor 1
}

# Anchor builds: materialise the OOC IP runs NOW so the loop below can see them.
if { $_epoch_anchor } {
    set _bd_file [get_files ${design_name}.bd]
    if { [catch { export_ip_user_files -of_objects $_bd_file -no_script -sync -force -quiet } _e] } {
        puts "WARNING: export_ip_user_files: $_e"
    }
    if { [catch { create_ip_run [get_files -of_objects [get_fileset sources_1] $_bd_file] } _e] } {
        puts "WARNING: create_ip_run: $_e"
    }
    puts "EPOCH_ANCHOR: IP runs materialised; synthesis runs now = [get_runs -filter {IS_SYNTHESIS}]"
}

set _phy_v2 0
if { [info exists ::env(TIDELINK_PHY_V2)] && $::env(TIDELINK_PHY_V2) == 1 } { set _phy_v2 1 }

foreach _r [get_runs -filter {IS_SYNTHESIS}] {
    set _defs {}
    # PHY_V2: historical scope — top-level synthesis run only (see note above).
    if { $_phy_v2 && [string equal $_r "synth_1"] } { lappend _defs TIDELINK_PHY_V2 }
    # EPOCH_ANCHOR: must reach the packaged IP's OOC run, so apply to every run.
    if { $_epoch_anchor }                          { lappend _defs TIDELINK_EPOCH_ANCHOR }
    if { [llength $_defs] == 0 } { continue }
    set _more_opts ""
    foreach _d $_defs { append _more_opts "-verilog_define $_d " }
    set _more_opts [string trim $_more_opts]
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
        -value $_more_opts -objects $_r
    puts "verilog_define injected into run $_r : $_more_opts"
}
# Message-gate CHILD hooks (fixes the parent-session blindness). launch_runs
# forks a child Vivado with its OWN msg-config + CW counters, so the parent's
# promotions and tidelink_check_cw_count never saw synth's messages. Install the
# promotions PRE-synth (so CWs are promoted at emission) and re-run the CW-count
# gate POST-synth (so it counts the CHILD's messages, not the parent's).
set _mg_promote [file join [file dirname [info script]] scripts msg_gate_child_promote.tcl]
set _mg_check   [file join [file dirname [info script]] scripts msg_gate_child_check.tcl]
set_property STEPS.SYNTH_DESIGN.TCL.PRE  $_mg_promote [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.TCL.POST $_mg_check   [get_runs synth_1]

launch_runs synth_1 -jobs $num_jobs
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "Synthesis status: $synth_status"
if { [string match "*ERROR*" $synth_status] } {
    puts "ERROR: Synthesis failed!"
    exit 1
}

# Message gate: fail-fast if any CRITICAL WARNING slipped through synth.
# Per-message ERROR promotions above will already have hard-errored the
# run; this count check catches the long tail of CW classes we have not
# yet enumerated. Bypassable via FPGA_ALLOW_CRITICAL_WARNINGS=1.
tidelink_check_cw_count "synth_1"

# STEP 8.5: Insert ILA debug core for nets marked (* mark_debug = "true" *).
# Skipped silently if no marks present.
if { [info exists env(FPGA_INSERT_DEBUG_CORE)] && $env(FPGA_INSERT_DEBUG_CORE) == "1" } {
    set debug_tcl [file join [file dirname [info script]] insert_debug_core.tcl]
    if { [file exists $debug_tcl] } {
        puts "Inserting debug core via $debug_tcl..."
        source $debug_tcl
    }
} else {
    # NO-ILA build: the RTL's (* mark_debug *) attrs survive into the synth DCP
    # and opt_design auto-processes them; a constant-foldable marked net (e.g.
    # after the 2026-06-03 deskew rewire folded an FC-word path) then aborts
    # impl_1 with Chipscope 16-213 ("probeN has 48 unconnected channels").
    # Strip MARK_DEBUG just before opt_design via an impl_1 pre-hook so no
    # auto-debug core forms. Scoped here (else-branch) so ILA targets are
    # unaffected. See fpga/strip_mark_debug.tcl.
    set strip_tcl [file join [file dirname [info script]] strip_mark_debug.tcl]
    if { [file exists $strip_tcl] } {
        set_property STEPS.OPT_DESIGN.TCL.PRE $strip_tcl [get_runs impl_1]
        puts "No-ILA build: MARK_DEBUG strip hook set on impl_1 opt_design pre-step ($strip_tcl)."
    }
}

# STEP 9: Implementation + Bitstream
#
# SoC Labs 2026-06-16 (RX-capture-skew determinism fix): enable phys_opt_design
# (post-place + post-route) on impl_1. The pad_rx[n] -> IDELAYE2 -> capture path
# (set_max_delay 8 ns, xdc (3b)) violates on the NON-FLIP target because the
# IDELAY output net `pad_rx_o[n]` has fanout ~17 (feeds the calibrator AND every
# lane's link_data_pad_clk capture reg), giving a ~4 ns route that pushes the
# absolute capture delay past 8 ns. Whether the captured sample lands inside the
# calibrator's centred eye then depends on per-build placement -> the per-deploy
# link-up "lottery" (die_a aligns <1%/load) and the per-lane data corruption.
# phys_opt_design replicates the high-fanout driver and re-times/re-places the
# critical net, shrinking that route so the 8 ns ceiling is met deterministically
# -> eye-centre is reproducible -> link aligns every load. AggressiveExplore +
# AlternateReplication specifically target high-fanout-net replication.
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]

# Message-gate CHILD hooks on impl_1 (route child). The parent's promotions and
# tidelink_check_cw_count were BLIND to the route child's messages, and the
# LUTLP-1 combinational-loop DRC (the cb33c9f silicon-write-vanish class) only
# has meaning on a ROUTED design. Wire PRE-route to promote LUTLP-1 -> ERROR and
# POST-route to run the child-visible CW gate + the comb-loop DRC on the routed
# design + the USR_ACCESS stamp, all BEFORE write_bitstream in the same run.
set_property STEPS.ROUTE_DESIGN.TCL.PRE  $_mg_promote [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.TCL.POST $_mg_check   [get_runs impl_1]

# Export the git-SHA low32 into the child env so msg_gate_child_check.tcl can
# stamp it into the bitstream USR_ACCESS register (route POST, before
# write_bitstream). ONLY for a clean tree: a -dirty build is not reproducible
# from a commit, so it must NOT be mislabelled with a SHA (leave the var unset
# -> the child skips the stamp rather than lying about provenance).
set _gsha [tl_git_sha [tl_repo_root]]
if { ![string match "*-dirty" $_gsha] && [regexp {^[0-9a-fA-F]{8,}} $_gsha] } {
    set ::env(TIDELINK_GIT_USR_ACCESS) "0x[string range $_gsha end-7 end]"
    puts "USR_ACCESS: exporting git SHA low32 = $::env(TIDELINK_GIT_USR_ACCESS) to impl child"
} else {
    if { [info exists ::env(TIDELINK_GIT_USR_ACCESS)] } { unset ::env(TIDELINK_GIT_USR_ACCESS) }
    puts "USR_ACCESS: tree dirty/unknown ($_gsha) - NOT stamping a commit SHA"
}

puts "Starting implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs $num_jobs
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "Implementation status: $impl_status"
if { [string match "*ERROR*" $impl_status] } {
    puts "ERROR: Implementation failed!"
    exit 1
}

# Message gate: fail-fast if any CRITICAL WARNING slipped through impl.
# Impl re-evaluates the *_timing.xdc and *_drc.xdc constraints, so a new
# crop of constraint-mismatch CWs can appear here that did not in synth.
# Bypassable via FPGA_ALLOW_CRITICAL_WARNINGS=1.
tidelink_check_cw_count "impl_1"

# STEP 10: Export outputs (.bit, .hwh for PYNQ, .xsa for Vitis)
file mkdir $output_dir

set bit_file [glob -nocomplain $project_dir/tidelink_project.runs/impl_1/*.bit]
if { $bit_file ne "" } {
    file copy -force $bit_file $output_dir/tidelink.bit
    puts "Bitstream copied to $output_dir/tidelink.bit"

    # Provenance manifest next to the shipped .bit so the artefact is
    # self-identifying (commit + PHY V1/V2 marker + resolved flist + submodule
    # pins + USR_ACCESS + target + host + date). Written from INSIDE the build so
    # it cannot be forgotten the way the post-hoc make_bitstream_manifest.sh
    # could. Kills the silent-V1 / stale-IP "which build is this?" blind spot.
    tl_write_manifest $output_dir/tidelink_manifest.json [file tail $target_dir] $output_dir/tidelink.bit
}

# .hwh is required for PYNQ - it's the IP-XACT flat hardware description.
# Look for it in the BD's hw_handoff directory.
set hwh_file [glob -nocomplain $project_dir/tidelink_project.gen/sources_1/bd/$design_name/hw_handoff/${design_name}.hwh]
if { $hwh_file eq "" } {
    # Fallback path used by older Vivado versions
    set hwh_file [glob -nocomplain $project_dir/tidelink_project.srcs/sources_1/bd/$design_name/hw_handoff/${design_name}.hwh]
}
if { $hwh_file ne "" } {
    file copy -force $hwh_file $output_dir/tidelink.hwh
    puts ".hwh copied to $output_dir/tidelink.hwh"
} else {
    puts "WARNING: .hwh file not found - PYNQ overlay loading will fail"
}

# Export hardware platform (.xsa) - useful for Vitis and as a self-contained
# bundle (the .xsa is just a zip containing .bit + .hwh + metadata).
write_hw_platform -fixed -include_bit -force $output_dir/tidelink_design.xsa

# 2026-05-24 (Agent C recommendation): preserve the routed DCP + timing
# summary report alongside the bitstream, so post-build report_timing
# analysis works without needing to re-run the build. The next build's
# launch_runs would otherwise wipe these from tidelink_project.runs/impl_1/
# (Agent C found build #18 DCP was already lost to build #19's startup
# the same day).
set routed_dcp [glob -nocomplain $project_dir/tidelink_project.runs/impl_1/*_routed.dcp]
if { $routed_dcp ne "" } {
    file copy -force [lindex $routed_dcp 0] $output_dir/tidelink_design_wrapper_routed.dcp
    puts "Routed DCP copied to $output_dir/tidelink_design_wrapper_routed.dcp"
}
set timing_rpt [glob -nocomplain $project_dir/tidelink_project.runs/impl_1/*_timing_summary_routed.rpt]
if { $timing_rpt ne "" } {
    file copy -force [lindex $timing_rpt 0] $output_dir/tidelink_design_wrapper_timing_summary_routed.rpt
    puts "Timing summary copied to $output_dir/tidelink_design_wrapper_timing_summary_routed.rpt"
}

puts "==========================================="
puts " Build complete!"
puts " Bitstream: $output_dir/tidelink.bit"
puts " HWH:       $output_dir/tidelink.hwh"
puts " XSA:       $output_dir/tidelink_design.xsa"
puts "==========================================="

close_project
