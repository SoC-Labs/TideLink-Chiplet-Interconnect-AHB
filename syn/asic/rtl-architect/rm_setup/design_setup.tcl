##########################################################################################
# Script: design_setup.tcl (TideLink customisation)
# Based on: Synopsys RTLA-RM U-2022.12 design_setup.tcl
#
# Customised for TideLink project using TSMC 65nm LP standard cells
# with on-the-fly CLIB creation from Milkyway frames and .db files.
#
# Environment variables (set by Makefile via common.mk):
#   MODULE        - Top-level module name
#   TIDELINK_HOME - Root of the TideLink repository
#   PHYS_IP_PATH  - Root path for physical IP libraries
#   TF_FILE       - Technology file (.tf)
#   MW_REF_LIB    - Milkyway reference library (frame)
#   DB_SS         - Slow corner .db library
#   DB_FF         - Fast corner .db library
##########################################################################################

##########################################################################################
### GENERAL
##########################################################################################

set DESIGN_NAME                 "$::env(MODULE)"
set LIBRARY_SUFFIX              ""
set DESIGN_LIBRARY              "${DESIGN_NAME}${LIBRARY_SUFFIX}"
set TECHLIB_DATA_DIR            ""
set SUPPLEMENTAL_SEARCH_PATH    "$::env(TIDELINK_HOME)/src/rtl"

##########################################################################################
### BLOCK LABEL NAMES
##########################################################################################
set INIT_DESIGN_BLOCK_NAME      "init_design"
set COMPILE_BLOCK_NAME          "compile"
set PLACE_OPT_BLOCK_NAME       "place_opt"
set CLOCK_OPT_CTS_BLOCK_NAME   "clock_opt_cts"
set CLOCK_OPT_OPTO_BLOCK_NAME  "clock_opt_opto"
set ROUTE_AUTO_BLOCK_NAME       "route_auto"
set ROUTE_OPT_BLOCK_NAME       "route_opt"

set CHIP_FINISH_FROM_BLOCK_NAME         $ROUTE_OPT_BLOCK_NAME
set CHIP_FINISH_BLOCK_NAME              "chip_finish"
set ICV_IN_DESIGN_FROM_BLOCK_NAME       $CHIP_FINISH_BLOCK_NAME
set ICV_IN_DESIGN_BLOCK_NAME            "icv_in_design"

set WRITE_DATA_FROM_BLOCK_NAME          $ICV_IN_DESIGN_BLOCK_NAME
set WRITE_DATA_BLOCK_NAME               "write_data"

set ENDPOINT_OPT_FROM_BLOCK_NAME        $ROUTE_OPT_BLOCK_NAME
set ENDPOINT_OPT_BLOCK_NAME             "endpoint_opt"
set TIMING_ECO_FROM_BLOCK_NAME          $ICV_IN_DESIGN_BLOCK_NAME
set TIMING_ECO_BLOCK_NAME               "timing_eco"
set FUNCTIONAL_ECO_FROM_BLOCK_NAME      $ICV_IN_DESIGN_BLOCK_NAME
set FUNCTIONAL_ECO_BLOCK_NAME           "functional_eco"
set FLOORPLAN_BLOCK_NAME                "floorplan"

set REDHAWK_IN_DESIGN_FROM_BLOCK_NAME   $ROUTE_OPT_BLOCK_NAME
set REDHAWK_IN_DESIGN_BLOCK_NAME        "redhawk_in_design"

##########################################################################################
### DESIGN PLANNING SETUP
##########################################################################################
set DESIGN_STYLE                "flat"
set PHYSICAL_HIERARCHY_LEVEL    "bottom"
set RELEASE_DIR_DP              ""
set RELEASE_DIR_PNR             ""

##########################################################################################
## Hierarchical PNR Variables
##########################################################################################
set SUB_BLOCK_REFS                              [list ]
set SUB_BLOCK_LIBRARIES                         [list ]
set USE_ABSTRACTS_FOR_BLOCKS                    [list ]
set CTL_FOR_ABSTRACT_BLOCKS                     [list ]
set SKIP_ABSTRACT_GENERATION                    false

set BLOCK_ABSTRACT_FOR_COMPILE          "$ICV_IN_DESIGN_BLOCK_NAME abstract"
set BLOCK_ABSTRACT_FOR_PLACE_OPT        "$ICV_IN_DESIGN_BLOCK_NAME abstract"
set BLOCK_ABSTRACT_FOR_CLOCK_OPT_CTS    "$ICV_IN_DESIGN_BLOCK_NAME abstract"
set BLOCK_ABSTRACT_FOR_CLOCK_OPT_OPTO   "$ICV_IN_DESIGN_BLOCK_NAME abstract"
set BLOCK_ABSTRACT_FOR_ROUTE_AUTO       "$ICV_IN_DESIGN_BLOCK_NAME abstract"
set BLOCK_ABSTRACT_FOR_ROUTE_OPT        "$ICV_IN_DESIGN_BLOCK_NAME abstract"
set BLOCK_ABSTRACT_FOR_CHIP_FINISH      "$ICV_IN_DESIGN_BLOCK_NAME abstract"
set BLOCK_ABSTRACT_FOR_ICV_IN_DESIGN    "$ICV_IN_DESIGN_BLOCK_NAME abstract"

set USE_ABSTRACTS_FOR_POWER_ANALYSIS            false
set USE_ABSTRACTS_FOR_SIGNAL_EM_ANALYSIS        false
set ABSTRACT_TYPE_FOR_MPH_BLOCKS                "flattened"
set CHECK_HIER_TIMING_CONSTRAINTS_CONSISTENCY   true
set LIBRARY_DB_PATH                             ""

set PROMOTE_CLOCK_BALANCE_POINTS                false
set PROMOTE_ABSTRACT_CLOCK_DATA_FILE            "promote_abstract_clock_data_script.tcl"

set WRITE_DATA_FOR_ETM_GENERATION               false
set WRITE_DATA_FOR_ETM_BLOCK_NAME               $ICV_IN_DESIGN_BLOCK_NAME
set WRITE_OASIS_ALLOW_INCOMPATIBLE_UNITS        false
set WRITE_GDS_ALLOW_INCOMPATIBLE_UNITS          false

##########################################################################################
### INIT_DESIGN
##########################################################################################
set NETLIST2GDS_FLOW            false
set INIT_DESIGN_INPUT           "RTL"
set INIT_DESIGN_INPUT_LIBRARY   ""
set INIT_DESIGN_INPUT_BLOCK_NAME ""
set RTL_SOURCE_FORMAT           "script"
set UNIQUIFY_OPTIONS            "-force"
set EARLY_DATA_CHECK_POLICY     "none"

##########################################################################################
### LIBRARY SETUP - on-the-fly CLIB from Milkyway frames + .db files
##########################################################################################

## No pre-compiled fusion libraries; use CLIB on-the-fly creation instead
set REFERENCE_LIBRARY           [list ]

## On-the-fly CLIB reference library creation from Milkyway frames and dbs
set CLIB_REFERENCE_LIBRARY_CONFIGURATION_FLOW_FRAME_LIST [list $::env(MW_REF_LIB)]
set CLIB_REFERENCE_LIBRARY_CONFIGURATION_FLOW_DB_LIST    [list $::env(DB_SS) $::env(DB_FF)]

## Fusion library settings (not used - using CLIB on-the-fly instead)
set FUSION_REFERENCE_LIBRARY_FRAM_LIST  [list ]
set FUSION_REFERENCE_LIBRARY_DB_LIST    [list ]
set FUSION_REFERENCE_LIBRARY_DIR        "./local_fusion_library"

set LINK_LIBRARY                ""
set COMPRESS_LIBS               false

set TCL_MULTI_VT_CONSTRAINT_FILE        "multi_vth_constraint_script.tcl"
set TCL_LIB_CELL_PURPOSE_FILE           "set_lib_cell_purpose.tcl"
set TIE_LIB_CELL_PATTERN_LIST           ""
set HOLD_FIX_LIB_CELL_PATTERN_LIST      ""
set CTS_LIB_CELL_PATTERN_LIST           ""
set CTS_ONLY_LIB_CELL_PATTERN_LIST      ""

##########################################################################################
### TECHNOLOGY
##########################################################################################
set TECH_FILE                   "$::env(TF_FILE)"
set TECH_LIB                   ""
set PARASITIC_TECH_LIB          ""
set TECH_LIB_INCLUDES_TECH_SETUP_INFO   false
set TCL_TECH_SETUP_FILE         "init_design.tech_setup.tcl"
set PHYSICAL_RULES_FILE         ""
set DESIGN_LIBRARY_SCALE_FACTOR ""
set TCL_USER_LIBRARY_SETUP_SCRIPT ""

set ENABLE_REDUNDANT_VIA_INSERTION              false
set ENABLE_POST_ROUTE_OPT_REDUNDANT_VIA_INSERTION false
set TCL_USER_REDUNDANT_VIA_MAPPING_FILE         ""
set TCL_USER_REDUNDANT_VIA_SCRIPT               ""
set ENABLE_PERFORMANCE_VIA_LADDER               false
set TCL_ANTENNA_RULE_FILE                       ""

##########################################################################################
### MCMM SCENARIO/MODE/CORNER SETUP
##########################################################################################
set TCL_MCMM_SETUP_FILE                ""
set TCL_PARASITIC_SETUP_FILE            ""
set TCL_MODE_CORNER_SCENARIO_MODEL_ADJUSTMENT_FILE ""
set TCL_POCV_SETUP_FILE                 ""
set TCL_AOCV_SETUP_FILE                 ""
set TCL_PVT_CONFIGURATION_FILE          ""
set PREROUTE_CTS_PRIMARY_CORNER         ""

## Scenario activation
set COMPILE_ACTIVE_SCENARIO_LIST        ""
set PLACE_OPT_ACTIVE_SCENARIO_LIST      ""
set CLOCK_OPT_CTS_ACTIVE_SCENARIO_LIST  ""
set ROUTE_OPT_ACTIVE_SCENARIO_LIST      ""
set CLOCK_OPT_OPTO_ACTIVE_SCENARIO_LIST "$ROUTE_OPT_ACTIVE_SCENARIO_LIST"
set ROUTE_AUTO_ACTIVE_SCENARIO_LIST     "$ROUTE_OPT_ACTIVE_SCENARIO_LIST"
set CHIP_FINISH_ACTIVE_SCENARIO_LIST    ""
set ICV_IN_DESIGN_ACTIVE_SCENARIO_LIST  ""
set ENDPOINT_OPT_ACTIVE_SCENARIO_LIST   ""
set TIMING_ECO_ACTIVE_SCENARIO_LIST     ""
set ROUTE_FOCUSED_SCENARIO              ""

##########################################################################################
### LOGICAL INPUTS
##########################################################################################
set DCRM_RESULTS_DIR            "./results"
set DCRM_FINAL_DESIGN_ICC2      "ICC2_files"

set RTL_SOURCE_FILES            { }
set FC_RTL_READ_SCRIPT          "${DESIGN_NAME}.FC.read_design.tcl"
set FM_RTL_READ_SCRIPT          ""
set UPF_MODE                    "none"

set VERILOG_NETLIST_FILES       ""
set UPF_FILE                    ""
set UPF_SUPPLEMENTAL_FILE       ""
set UPF_UPDATE_SUPPLY_SET_FILE  ""

set SAIF_FILE_LIST              ""
set SAIF_FILE_POWER_SCENARIO    ""
set SAIF_FILE_SOURCE_INSTANCE   ""
set SAIF_FILE_TARGET_INSTANCE   ""

##########################################################################################
### PHYSICAL INPUTS
##########################################################################################
set TCL_FLOORPLAN_FILE                  ""
set DEF_FLOORPLAN_FILES                 ""
set DEF_READ_OPTIONS                    "-add_def_only_objects all"
set DEF_RESOLVE_PG_NETS                 true
set TCL_ADDITIONAL_FLOORPLAN_FILE       ""
set SITE_SYMMETRY_LIST                  ""
set DEF_SCAN_FILE                       ""
set TCL_FLOORPLAN_RULE_SCRIPT           ""
set TCL_USER_SPARE_CELL_PRE_SCRIPT      ""
set TCL_USER_SPARE_CELL_POST_SCRIPT     ""
set SWITCH_CONNECTIVITY_FILE            ""
set ENABLE_FLOORPLAN_CHECKS             true

##########################################################################################
### DFT SETUP - disabled for initial RTL exploration
##########################################################################################
set DFT_INSERT_ENABLE                   false
set DFT_CONFIGURATION                   "SCAN"
set DFT_INTERNAL_SCAN_CHAIN_COUNT       8
set DFT_WRAPPER_CHAIN_COUNT             4
set DFT_COMPRESSION_SCAN_CHAIN_COUNT    64
set DFT_CLOCK_LIST                      "hclk"
set DFT_RESET_INFO                      {{hresetn 1}}
set DFT_CONSTANT_INFO                   {{scan_mode 1}}
set DFT_PORTS_FILE                      "dft_ports.tcl"
set DFT_SETUP_FILE                      "scan_configuration.fc.tcl"
set DFT_TEST_POINT_FILE                 "dft_user_defined_testpoints.tcl"
set TCL_DFT_PRE_IN_COMPILE_SETUP_FILE   ""
set TCL_CONSTRAINTS_SETUP_FILE          ""
set TCL_USER_DFT_REPLACEMENT_SCRIPT     ""
set OPTIMIZATION_FREEZE_PORT_LIST       ""

##########################################################################################
### ENDPOINT_OPT SETUP
##########################################################################################
set ENDPOINT_OPT_MAX_PATHS              "10000"
set ENDPOINT_OPT_SLACK_THRESHOLD        "-0.001"
set ENDPOINT_OPT_TARGET_SCENARIOS       "*"
set ENDPOINT_OPT_LOOP                   1
set ENDPOINT_OPT_PATH_GROUP_FILTER      ""

##########################################################################################
### CHIP FINISH SETUP
##########################################################################################
set CHIP_FINISH_METAL_FILLER_PREFIX             "RM_filler"
set CHIP_FINISH_NON_METAL_FILLER_PREFIX         $CHIP_FINISH_METAL_FILLER_PREFIX
set CHIP_FINISH_SIGNAL_EM_CONSTRAINT_FORMAT     "ITF"
set CHIP_FINISH_SIGNAL_EM_CONSTRAINT_FILE       ""
set CHIP_FINISH_SIGNAL_EM_SAIF                  ""
set CHIP_FINISH_SIGNAL_EM_SCENARIO              ""
set CHIP_FINISH_SIGNAL_EM_FIXING                false

##########################################################################################
### ICV IN-DESIGN SETUP
##########################################################################################
set ICV_IN_DESIGN_DRC_CHECK_RUNSET              ""
set ICV_IN_DESIGN_DRC_CHECK_RUNDIR              "z_check_drc"
set ICV_IN_DESIGN_DRC_USER_DEFINED_OPTIONS      ""
set ICV_IN_DESIGN_DRC_FILL_VIEW_DATA            "read"
set ICV_IN_DESIGN_DRC_CELL_VIEWS                "frame"
set ICV_IN_DESIGN_DRC_EXCLUDED_CELL_TYPES       ""
set ICV_IN_DESIGN_DRC_EXCLUDED_CELL_TYPES_SYNDP ""
set ICV_IN_DESIGN_DRC_EXCLUDED_CELL_TYPES_SYNPNR ""
set ICV_IN_DESIGN_DRC_EXCLUDED_CELL_TYPES_FINISH ""
set ICV_IN_DESIGN_DRC_IGNORE_CHILD_CELL_ERRORS  false
set ICV_IN_DESIGN_DRC_IGNORE_CHILD_CELL_ERRORS_SYNDP    false
set ICV_IN_DESIGN_DRC_IGNORE_CHILD_CELL_ERRORS_SYNPNR   false
set ICV_IN_DESIGN_DRC_IGNORE_CHILD_CELL_ERRORS_FINISH   false
set ICV_IN_DESIGN_DRC_SELECT_RULES              ""
set ICV_IN_DESIGN_DRC_SELECT_RULES_SYNDP        ""
set ICV_IN_DESIGN_DRC_SELECT_RULES_SYNPNR       ""
set ICV_IN_DESIGN_DRC_SELECT_RULES_FINISH        ""
set ICV_IN_DESIGN_DRC_UNSELECT_RULES            ""
set ICV_IN_DESIGN_DRC_UNSELECT_RULES_SYNDP      ""
set ICV_IN_DESIGN_DRC_UNSELECT_RULES_SYNPNR     ""
set ICV_IN_DESIGN_DRC_UNSELECT_RULES_FINISH      ""
set STREAM_FILES_FOR_MERGE                      ""

set ICV_IN_DESIGN_DRC                           true
set ICV_IN_DESIGN_ADR                           false
set ICV_IN_DESIGN_ADR_RUNDIR                    "z_adr"
set ICV_IN_DESIGN_ADR_USER_DEFINED_OPTIONS      ""
set ICV_IN_DESIGN_POST_ADR_RUNDIR               "z_post_adr"
set ICV_IN_DESIGN_ADR_DPT_RULES                 ""
set ICV_IN_DESIGN_ADR_DPT_RUNDIR                "z_adr_with_dpt"
set ICV_IN_DESIGN_POST_ADR_DPT_RUNDIR           "z_post_adr_with_dpt"
set ICV_IN_DESIGN_ADR_SELECT_RULES              ""

set ICV_IN_DESIGN_METAL_FILL                    false
set ICV_IN_DESIGN_METAL_FILL_RUNSET             ""
set ICV_IN_DESIGN_METAL_FILL_RUNDIR             "z_icvFill"
set ICV_IN_DESIGN_METAL_FILL_USER_DEFINED_OPTIONS ""
set ICV_IN_DESIGN_METAL_FILL_FIX_DENSITY_ERRORS "false"
set ICV_IN_DESIGN_METAL_FILL_SELECT_LAYERS      ""
set ICV_IN_DESIGN_METAL_FILL_COORDINATES        ""
set ICV_IN_DESIGN_METAL_FILL_TIMING_DRIVEN_THRESHOLD ""
set ICV_IN_DESIGN_METAL_FILL_TRACK_BASED        "off"
set ICV_IN_DESIGN_METAL_FILL_ECO_THRESHOLD      ""
set ICV_IN_DESIGN_POST_METAL_FILL_RUNDIR        "z_MFILL_after"
set ICV_IN_DESIGN_METAL_FILL_TRACK_BASED_PARAMETER_FILE "auto"
set ICV_IN_DESIGN_BASE_FILL                     false
set ICV_IN_DESIGN_BASE_FILL_RUNSET              ""
set ICV_IN_DESIGN_BASE_FILL_RUNDIR              "z_icvFill"
set ICV_IN_DESIGN_BASE_FILL_FOUNDRY_NODE        ""
set ICV_IN_DESIGN_ENABLE_ALL_LAYER_CHECK        true

##########################################################################################
### REDHAWK / REDHAWK-SC SETUP
##########################################################################################
set REDHAWK_SC_DIR                      ""
set REDHAWK_DIR                         ""
set REDHAWK_GRID_FARM                   ""
set REDHAWK_PAD_FILE_NDM                ""
set REDHAWK_PAD_FILE_PLOC               ""
set REDHAWK_PAD_CUSTOMIZED_SCRIPT       ""
set REDHAWK_FREQUENCY                   ""
set REDHAWK_TEMPERATURE                 ""
set REDHAWK_SCENARIO                    ""
set REDHAWK_MCMM_SCENARIO_CONFIG        ""
set REDHAWK_USE_FC_POWER                false
set REDHAWK_ANALYSIS_NETS               ""

##########################################################################################
### Variables for pre and post plugins
##########################################################################################
if {![info exist TCL_USER_INIT_DESIGN_POST_SCRIPT]} {
        set TCL_USER_INIT_DESIGN_POST_SCRIPT    ""
}
set TCL_USER_CONDITIONING_PRE_SCRIPT            "user_conditioning_pre_script.tcl"
set TCL_USER_CONDITIONING_POST_SCRIPT           ""
set TCL_USER_ESTIMATION_PRE_SCRIPT              ""
set TCL_USER_ESTIMATION_POST_SCRIPT             ""
set TCL_USER_SPLIT_CONSTRAINTS_PRE_SCRIPT       ""
set TCL_USER_SPLIT_CONSTRAINTS_POST_SCRIPT      ""
set TCL_USER_COMMIT_PRE_SCRIPT                  ""
set TCL_USER_COMMIT_POST_SCRIPT                 ""
set TCL_USER_FLOORPLANNING_PRE_SCRIPT           ""
set TCL_USER_FLOORPLANNING_POST_SCRIPT          ""
set TCL_USER_METRICS_PRE_SCRIPT                 ""
set TCL_USER_METRICS_POST_SCRIPT                ""
set TCL_USER_EXPLORE_PRE_SCRIPT                 ""
set TCL_USER_EXPLORE_POST_SCRIPT                ""

if {[file exists ./rm_setup/fc_setup.tcl]} {
        echo "RM-info    : Importing settings from Fusion Compiler RM fc_setup.tcl"
        rm_source -file ./rm_setup/fc_setup.tcl  -print "fc_setup.tcl"
}

##########################################################################################
### System Variables (DO NOT CHANGE)
##########################################################################################
set ELABORATE_LABEL_NAME                "elaborate"
set INIT_DESIGN_LABEL_NAME              "init_design"
set CONDITIONING_LABEL_NAME             "conditioning"
set ESTIMATION_LABEL_NAME               "estimation"
set SPLIT_CONSTRAINTS_LABEL_NAME        "split_constraints"
set COMMIT_LABEL_NAME                   "commit"
set BLOCK_CONDITIONING_LABEL_NAME       "block_conditioning"
set TOP_CONDITIONING_LABEL_NAME         "top_conditioning"
set FLOORPLANNING_LABEL_NAME            "floorplanning"
set BLOCK_ESTIMATION_LABEL_NAME         "block_estimation"
set TOP_ESTIMATION_LABEL_NAME           "top_estimation"
set METRICS_LABEL_NAME                  "metrics"
set EXPLORE_DESIGN_LABEL_NAME           "explore_design"
set RTL_OPT_LABEL_NAME                  "rtl_opt"
set SPLITS_LABEL_NAME                   "splits"

puts "RM-info : Completed script [info script]\n"
