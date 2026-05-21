#-----------------------------------------------------------------------------
# TideLink ASIC tech paths — canonical TCL include for fc_shell / lm_shell /
# pt_shell / fm_shell scripts.
#
# Mirrors the SoC-Labs project-wide tech-paths header. Every path here can be
# overridden via the matching uppercase environment variable so this file
# stays portable across user homes (the project ships defaults that resolve
# on a typical /research/AAA install; the user-specific TSMCHOME locations
# referenced below need an env override on systems that don't have them
# installed).
#
# Sourced from: setup.tcl, create_fusion_lib.tcl, extract_etm.tcl
#-----------------------------------------------------------------------------

# ── helper: env_or_default — Tcl proc, NOT an SDC command, so this file
#    must be sourced from full-fc_shell Tcl scope, not via read_sdc.
proc env_or_default {var def} {
    if {[info exists ::env($var)] && $::env($var) ne ""} {
        return $::env($var)
    }
    return $def
}

#-----------------------------------------------------------------------------
# Base paths.
# Override on a per-system basis via the env var of the same name (uppercase)
# — e.g. CLN65LP_TECH_PATH=/path/to/TSMCHOME/Back_End make fc.
#-----------------------------------------------------------------------------
set standard_cell_base_path  [env_or_default STANDARD_CELL_BASE_PATH \
    /home/dwn1c21/SoC-Labs/phys_ip/TSMC/65/CMOS/LP/stclib/9-track/tcbn65lp-set/tcbn65lp_220a_FE/TSMCHOME/digital]
set cln65lp_tech_path        [env_or_default CLN65LP_TECH_PATH \
    ${standard_cell_base_path}/Back_End]
set io_base_path             [env_or_default IO_BASE_PATH \
    /home/dwn1c21/SoC-Labs/phys_ip/TSMC/65/CMOS/LP/IO2.5V/iolib/linear/tpdn65lpnv2od3_200a_FE/TSMCHOME/digital]
set pmk_base_path            [env_or_default PMK_BASE_PATH \
    /research/AAA/phys_ip_library/arm/tsmc/cln16fcll001/sc9mcpp96c_pmk_svt_c24/r2p0]
set ret_base_path            [env_or_default RET_BASE_PATH \
    /research/AAA/phys_ip_library/arm/tsmc/cln16fcll001/sc9mcpp96c_rklo_lvt_svt_c20_c24/r1p0]

#-----------------------------------------------------------------------------
# cln65lp technology files — TSMC tcbn65lp 9-layer T2 stack.
#-----------------------------------------------------------------------------
set cln65lp_tech_file       ${cln65lp_tech_path}/milkyway/tcbn65lp_200a/techfiles/tsmcn65_9lmT2.tf
set cln65lp_lef_file        ${cln65lp_tech_path}/lef/tcbn65lp_200a/lef/tcbn65lp_9lmT2.lef

#-----------------------------------------------------------------------------
# Standard-cell library (tcbn65lp 9-track / 220a release).
# Three corners (TSMC NLDM library names):
#   tcbn65lpwc — worst case (max-delay) ↔ SS in SoC-Labs nomenclature
#   tcbn65lptc — typical case            ↔ TT
#   tcbn65lpbc — best case (min-delay)  ↔ FF
# Variable names keep the SoC-Labs project-wide 0p72/0p80/0p88V label
# convention so chip-top scripts can pick the right corner-set by name.
#-----------------------------------------------------------------------------
set standard_cell_lef_file                  ${cln65lp_lef_file}
set standard_cell_gds_file                  ""
set _std_db_path                            ${standard_cell_base_path}/Front_End/timing_power_noise/NLDM/tcbn65lp_220a
set standard_cell_db_file_ss_0p72v_125C     ${_std_db_path}/tcbn65lpwc.db
set standard_cell_db_file_tt_0p80v_25C      ${_std_db_path}/tcbn65lptc.db
set standard_cell_db_file_ff_0p88v_m40C     ${_std_db_path}/tcbn65lpbc.db
set standard_cell_antenna_file              [env_or_default STANDARD_CELL_ANTENNA_FILE ""]

#-----------------------------------------------------------------------------
# Arm IO library (chip-top pad ring — NOT used by the tidelink partition,
# but kept here for re-use by the integrating chip-top flow).
#-----------------------------------------------------------------------------
set io_lef_file                         ${io_base_path}/Back_End/lef/tpdn65lpnv2od3_140b/mt_2/9lm/lef/tpdn65lpnv2od3_9lm.lef
set io_gds_file                         ${io_base_path}/gds2/io_gppr_cln16fcll001_t18_mv08_fs18_rvt_dr_9m_2xa1xd3xe2z_fc.gds2
set io_db_file_ss_0p72v_125C            ${io_base_path}/Front_End/timing_power_noise/NLDM/tpdn65lpnv2od3_200a/tpdn65lpnv2od3wc.db
set io_db_file_tt_0p80v_25C             ${io_base_path}/Front_End/timing_power_noise/NLDM/tpdn65lpnv2od3_200a/tpdn65lpnv2od3tc.db
set io_db_file_ff_0p88v_m40C            ${io_base_path}/Front_End/timing_power_noise/NLDM/tpdn65lpnv2od3_200a/tpdn65lpnv2od3bc.db
set io_antenna_file                     ${io_base_path}/milkyway/9m_2xa1xd3xe2z_fc/io_gppr_cln16fcll001_t18_mv08_fs18_rvt_dr_antenna.clf

#-----------------------------------------------------------------------------
# Memory macros — referenced for chip-top integration but not all are
# instantiated in the tidelink partition itself. tidelink_top uses rf_16k
# (precompiled, /research/precompiled_mems/TSMC65). sram_32k + ROM are
# chip-top-only and require SOCLABS_PROJECT_DIR to point at the parent
# project; left as env-driven paths.
#-----------------------------------------------------------------------------
set _soclabs_project_dir [env_or_default SOCLABS_PROJECT_DIR \
    [env_or_default TIDELINK_HOME [file normalize [file dirname [info script]]/../../..]]]

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
# rf_16k macro — the actual SRAM the tidelink partition instantiates.
# Kept consistent with the SoC-Labs SRAM_32K naming so chip-top scripts
# can pick the right corner-set with a single switch.
#-----------------------------------------------------------------------------
set _rf_16k_path             [env_or_default MEM_PATH /research/precompiled_mems/TSMC65/rf_16k]
set RF_16K_PATH              $_rf_16k_path
set RF_16K_lef_file          ${_rf_16k_path}/rf_16k.lef
set RF_16K_gds_file          ${_rf_16k_path}/rf_16k.gds2
set RF_16K_db_file_ss        ${_rf_16k_path}/rf_16k_ss_1p08v_1p08v_125c.db
set RF_16K_db_file_tt        ${_rf_16k_path}/rf_16k_tt_1p20v_1p20v_25c.db
set RF_16K_db_file_ff        ${_rf_16k_path}/rf_16k_ff_1p32v_1p32v_m40c.db

puts "INFO: \[tech_paths\] sourced — standard_cell_base_path = $standard_cell_base_path"
