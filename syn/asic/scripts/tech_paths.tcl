#-----------------------------------------------------------------------------
# TideLink ASIC tech paths — canonical TCL include for fc_shell / lm_shell /
# pt_shell / fm_shell scripts.
#
# EVERY path here comes from the environment. There are NO built-in defaults,
# deliberately: a default pointing at one lab's mount is a path that resolves
# on exactly one machine and fails everywhere else in a way that reads as a
# missing FILE rather than as a missing SETTING. Unset, this file names the
# variable instead.
#
# Set them once per machine in <repo>/site.env — see site.env.example, which
# documents every variable below. syn/asic/common.mk includes that file and
# exports the result, so a `make -C syn/asic/...` invocation carries them in.
#
# Sourced from: setup.tcl, create_fusion_lib.tcl, extract_etm.tcl
#-----------------------------------------------------------------------------

# ── helpers: tech_env / tech_env_opt — Tcl procs, NOT SDC commands, so this
#    file must be sourced from full-fc_shell Tcl scope, not via read_sdc.

# REQUIRED. Aborts naming the variable and saying what it locates. The abort
# is an `error`, not a `puts`+`exit`, so a caller that genuinely wants to probe
# can catch it — but nothing catches it by default, which is the point.
proc tech_env {var what} {
    if {[info exists ::env($var)] && $::env($var) ne ""} {
        return $::env($var)
    }
    error "\[tech_paths\] $var is not set — it locates $what.\n\
           \       Copy site.env.example to site.env at the repo root, set $var\n\
           \       there, or export it in your environment. There is no default:\n\
           \       this flow will not guess one site's filesystem layout."
}

# OPTIONAL. Returns "" and says so once. Used for collateral the tidelink
# partition does not itself instantiate (the pad ring, the chip-top macros) —
# an integrating chip-top flow sets these; a partition run does not need them.
proc tech_env_opt {var what} {
    if {[info exists ::env($var)] && $::env($var) ne ""} {
        return $::env($var)
    }
    puts "INFO: \[tech_paths\] $var unset — $what unavailable (chip-top only)"
    return ""
}

#-----------------------------------------------------------------------------
# Base paths.
#-----------------------------------------------------------------------------
set standard_cell_base_path  [tech_env STANDARD_CELL_BASE_PATH \
    "the foundry standard-cell install root (the directory holding Front_End/ and Back_End/)"]
set cln65lp_tech_path        [expr {[info exists ::env(CLN65LP_TECH_PATH)] && $::env(CLN65LP_TECH_PATH) ne "" \
                                    ? $::env(CLN65LP_TECH_PATH) \
                                    : "${standard_cell_base_path}/Back_End"}]
set io_base_path             [tech_env_opt IO_BASE_PATH "the foundry IO/pad library root"]
set pmk_base_path            [tech_env_opt PMK_BASE_PATH "the Arm power-management-kit physical IP drop"]
set ret_base_path            [tech_env_opt RET_BASE_PATH "the Arm retention-cell physical IP drop"]

#-----------------------------------------------------------------------------
# Standard-cell technology files.
#
# The tech file and the LEF must describe the SAME metal stack. Their release
# directories are NOT necessarily the same string — that asymmetry is
# foundry-shipped, so both are named individually rather than assembled from a
# single release variable.
#-----------------------------------------------------------------------------
set cln65lp_tech_file       [tech_env TF_FILE \
    "the Milkyway technology file for the metal stack this design targets"]
set cln65lp_lef_file        [tech_env STANDARD_CELL_LEF_FILE \
    "the standard-cell LEF for the metal stack this design targets"]

#-----------------------------------------------------------------------------
# Standard-cell timing libraries — three corners.
#
# Variable names keep the SoC-Labs project-wide 0p72/0p80/0p88V label
# convention so chip-top scripts can pick the right corner-set by name; the
# operating point each .db was actually characterised at is stated in that
# file's own Liberty header, which is the only place it cannot go stale.
#-----------------------------------------------------------------------------
set standard_cell_lef_file                  ${cln65lp_lef_file}
set standard_cell_gds_file                  [expr {[info exists ::env(STANDARD_CELL_GDS_FILE)] ? $::env(STANDARD_CELL_GDS_FILE) : ""}]
set standard_cell_db_file_ss_0p72v_125C     [tech_env DB_SS "the slow-corner (max-delay) standard-cell .db"]
set standard_cell_db_file_tt_0p80v_25C      [tech_env DB_TT "the typical-corner standard-cell .db"]
set standard_cell_db_file_ff_0p88v_m40C     [tech_env DB_FF "the fast-corner (min-delay) standard-cell .db"]
set standard_cell_antenna_file              [expr {[info exists ::env(STANDARD_CELL_ANTENNA_FILE)] ? $::env(STANDARD_CELL_ANTENNA_FILE) : ""}]

#-----------------------------------------------------------------------------
# IO library (chip-top pad ring — NOT used by the tidelink partition, but kept
# here for re-use by the integrating chip-top flow). Optional throughout.
#-----------------------------------------------------------------------------
set io_lef_file                         [tech_env_opt IO_LEF_FILE      "the pad-ring LEF"]
set io_gds_file                         [tech_env_opt IO_GDS_FILE      "the pad-ring GDS"]
set io_db_file_ss_0p72v_125C            [tech_env_opt IO_DB_SS         "the slow-corner pad .db"]
set io_db_file_tt_0p80v_25C             [tech_env_opt IO_DB_TT         "the typical-corner pad .db"]
set io_db_file_ff_0p88v_m40C            [tech_env_opt IO_DB_FF         "the fast-corner pad .db"]
set io_antenna_file                     [tech_env_opt IO_ANTENNA_FILE  "the pad-ring antenna rules"]

#-----------------------------------------------------------------------------
# Memory macros — referenced for chip-top integration but not all are
# instantiated in the tidelink partition itself. tidelink_top uses rf_16k;
# sram_32k + ROM are chip-top-only and require SOCLABS_PROJECT_DIR to point at
# the parent project.
#-----------------------------------------------------------------------------
set _soclabs_project_dir [expr {
    [info exists ::env(SOCLABS_PROJECT_DIR)] && $::env(SOCLABS_PROJECT_DIR) ne "" ? $::env(SOCLABS_PROJECT_DIR) :
    ([info exists ::env(TIDELINK_HOME)] && $::env(TIDELINK_HOME) ne "" ? $::env(TIDELINK_HOME) :
     [file normalize [file dirname [info script]]/../../..])}]

set SRAM_32K_PATH            ${_soclabs_project_dir}/memories/sram_32k
set SRAM_32K_lef_file        ${SRAM_32K_PATH}/sram_32k.lef
set SRAM_32K_gds_file        ${SRAM_32K_PATH}/sram_32k.gds2
set SRAM_32K_lib_file_ss     ${SRAM_32K_PATH}/sram_32k_ssgnp_0p72v_0p72v_125c.lib
set SRAM_32K_lib_file_tt     ${SRAM_32K_PATH}/sram_32k_tt_0p80v_0p80v_25c.lib
set SRAM_32K_lib_file_ff     ${SRAM_32K_PATH}/sram_32k_ffgnp_0p88v_0p88v_m40c.lib
set SRAM_32K_db_file_ss      ${SRAM_32K_PATH}/sram_32k_ssgnp_0p72v_0p72v_125c.db
set SRAM_32K_db_file_tt      ${SRAM_32K_PATH}/sram_32k_tt_0p80v_0p80v_25c.db
set SRAM_32K_db_file_ff      ${SRAM_32K_PATH}/sram_32k_ffgnp_0p88v_0p88v_m40c.db

set ROM_VIA_PATH            ${_soclabs_project_dir}/memories/bootrom
set ROM_VIA_lef_file        ${ROM_VIA_PATH}/rom_via.lef
set ROM_VIA_gds_file        ${ROM_VIA_PATH}/rom_via.gds2
set ROM_VIA_lib_file_ss     ${ROM_VIA_PATH}/rom_via_ssgnp_0p72v_0p72v_125c.lib
set ROM_VIA_lib_file_tt     ${ROM_VIA_PATH}/rom_via_tt_0p80v_0p80v_25c.lib
set ROM_VIA_lib_file_ff     ${ROM_VIA_PATH}/rom_via_ffgnp_0p88v_0p88v_m40c.lib
set ROM_VIA_db_file_ss      ${ROM_VIA_PATH}/rom_via_ssgnp_0p72v_0p72v_125c.db
set ROM_VIA_db_file_tt      ${ROM_VIA_PATH}/rom_via_tt_0p80v_0p80v_25c.db
set ROM_VIA_db_file_ff      ${ROM_VIA_PATH}/rom_via_ffgnp_0p88v_0p88v_m40c.db

#-----------------------------------------------------------------------------
# rf_16k macro — the actual SRAM the tidelink partition instantiates. REQUIRED:
# without it there is no design. Kept consistent with the SRAM_32K naming so
# chip-top scripts can pick the right corner-set with a single switch.
#-----------------------------------------------------------------------------
set _rf_16k_path             [tech_env MEM_PATH \
    "the compiled rf_16k macro directory (.lef/.gds2/.db); MEM_BASE/rf_16k on most installs"]
set RF_16K_PATH              $_rf_16k_path
set RF_16K_lef_file          ${_rf_16k_path}/rf_16k.lef
set RF_16K_gds_file          ${_rf_16k_path}/rf_16k.gds2
set RF_16K_db_file_ss        ${_rf_16k_path}/rf_16k_ss_1p08v_1p08v_125c.db
set RF_16K_db_file_tt        ${_rf_16k_path}/rf_16k_tt_1p20v_1p20v_25c.db
set RF_16K_db_file_ff        ${_rf_16k_path}/rf_16k_ff_1p32v_1p32v_m40c.db

puts "INFO: \[tech_paths\] sourced — standard_cell_base_path = $standard_cell_base_path"
