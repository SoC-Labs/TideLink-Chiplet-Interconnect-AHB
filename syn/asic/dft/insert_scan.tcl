#------------------------------------------------------------------------------
# TideLink — Scan Insertion Wrapper (SCAFFOLD)
#
# Purpose:
#   Wrap the standard scan-insertion flow for the chosen ATPG tool. This
#   script is a SCAFFOLD — it does not, by itself, insert scan chains. It
#   sets up the command-line and design-side knobs, defines chain
#   partitioning by clock domain, and emits placeholder calls to the chosen
#   tool. Closure (running the licensed tool, debugging DRC, balancing
#   chains) is documented as a follow-on in docs/reference/DFT_PLAN_2026_05_28.md §7.
#
# Tool flavours supported (selected via DFT_TOOL env var or -tool flag):
#   testmax   — Synopsys TestMAX / DFT Compiler (preferred for FC flow)
#   tessent   — Mentor Tessent ScanPro
#   spyglass  — Synopsys SpyGlass DFT (DRC only — no insertion)
#
# Inputs (env, with defaults):
#   DFT_TOOL          testmax | tessent | spyglass        (default: testmax)
#   SCAN_STYLE        muxd | lssd                          (default: muxd)
#   SCAN_CHAINS       integer (1..16)                      (default: 8)
#   SCAN_EN_POLARITY  active_high | active_low             (default: active_high)
#   SCAN_CLK_PERIOD   in ns                                (default: 20.0  → 50 MHz shift)
#   DESIGN            top module                           (default: tidelink_dft_wrapper)
#   NETLIST           post-synth netlist                   (required for real run)
#   OUT_DIR           output dir for scan-inserted netlist (default: out/dft)
#
# Usage:
#   # via Makefile:
#   make -C syn/asic/dft insert_scan
#   # standalone (with a real synth netlist):
#   DESIGN=tidelink_dft_wrapper NETLIST=out/synth/tdw.v dc_shell -f insert_scan.tcl
#
# A joint work commissioned on behalf of SoC Labs.
# Copyright 2026, SoC Labs (www.soclabs.org)
#------------------------------------------------------------------------------

# ---------- argument plumbing -------------------------------------------------

if {![info exists env(DFT_TOOL)]}         { set env(DFT_TOOL)         "testmax" }
if {![info exists env(SCAN_STYLE)]}       { set env(SCAN_STYLE)       "muxd" }
if {![info exists env(SCAN_CHAINS)]}      { set env(SCAN_CHAINS)      "8" }
if {![info exists env(SCAN_EN_POLARITY)]} { set env(SCAN_EN_POLARITY) "active_high" }
if {![info exists env(SCAN_CLK_PERIOD)]}  { set env(SCAN_CLK_PERIOD)  "20.0" }
if {![info exists env(DESIGN)]}           { set env(DESIGN)           "tidelink_dft_wrapper" }
if {![info exists env(OUT_DIR)]}          { set env(OUT_DIR)          "out/dft" }

set DFT_TOOL         $env(DFT_TOOL)
set SCAN_STYLE       $env(SCAN_STYLE)
set SCAN_CHAINS      $env(SCAN_CHAINS)
set SCAN_EN_POLARITY $env(SCAN_EN_POLARITY)
set SCAN_CLK_PERIOD  $env(SCAN_CLK_PERIOD)
set DESIGN           $env(DESIGN)
set OUT_DIR          $env(OUT_DIR)

puts "INFO: ============================================================="
puts "INFO: TideLink scan-insertion scaffold"
puts "INFO:   tool         = $DFT_TOOL"
puts "INFO:   style        = $SCAN_STYLE"
puts "INFO:   chain count  = $SCAN_CHAINS"
puts "INFO:   scan_en pol  = $SCAN_EN_POLARITY"
puts "INFO:   scan_clk T   = ${SCAN_CLK_PERIOD} ns"
puts "INFO:   design       = $DESIGN"
puts "INFO:   out dir      = $OUT_DIR"
puts "INFO: ============================================================="

# ---------- placeholder gate: bail out if no licence is in the environment ----

proc check_tool_license {tool} {
    switch -- $tool {
        testmax  { return [expr {[info exists ::env(SNPSLMD_LICENSE_FILE)]
                                 || [info exists ::env(SYNOPSYS_LICENSE_FILE)]}] }
        tessent  { return [expr {[info exists ::env(MGLS_LICENSE_FILE)]
                                 || [info exists ::env(LM_LICENSE_FILE)]}] }
        spyglass { return [expr {[info exists ::env(SPYGLASS_HOME)]}] }
        default  { return 0 }
    }
}

if {![check_tool_license $DFT_TOOL]} {
    puts "ERROR: $DFT_TOOL licence env not set (SNPSLMD_LICENSE_FILE /"
    puts "       MGLS_LICENSE_FILE / SPYGLASS_HOME). Scaffold cannot continue."
    puts ""
    puts "       Action: configure the licence file or rerun with"
    puts "       DFT_TOOL=spyglass for pre-scan DRC-only mode."
    puts ""
    puts "       This is expected at scaffold time — see"
    puts "       docs/reference/DFT_PLAN_2026_05_28.md §7.4 for the licence list."
    exit 1
}

# ---------- design data preparation ------------------------------------------

# These steps are tool-common (read library / read netlist / link).
# They are stubbed because the real Makefile and licence-aware caller
# decides which db / lib / netlist to point at.

puts "INFO: stage 1 — read libraries (TSMC65 stdcell + rf_16k CTL)"
puts "  TODO: source ../fusion-compiler/scripts/setup.tcl"
puts "  TODO: read_db \$env(TSMC65_DB) \$env(RF_16K_DB)"

puts "INFO: stage 2 — read post-synth netlist"
puts "  TODO: read_verilog \$env(NETLIST)"
puts "  TODO: current_design \$DESIGN"
puts "  TODO: link"

# ---------- DRC pre-checks ---------------------------------------------------

puts "INFO: stage 3 — DFT DRC (pre-insertion)"

# Mark non-scannable instances. These are the modules with hand-crafted
# 2-FF CDC synchronisers; scan-replacing them breaks metastability
# handling. Reference: DFT_PLAN §6.2.
set dont_scan_patterns {
    "*u_phc_cdc*"
    "*WavMultibitSync*"
    "*WavDemetReset*"
    "*WavDemetSet*"
    "*thresh_sync*"
    "*noise_mode_sync*"
    "*clear_toggle_sync*"
    "*_rd_sync*"
    "*xhb500_sync*"
    "u_rf"
    "*u_tidelink_sram*u_rf*"
}

foreach pat $dont_scan_patterns {
    puts "  TODO: set_dont_scan \[get_cells -hier $pat\] -filter \"is_hierarchical == false\""
}

# ---------- clock and reset configuration ------------------------------------

puts "INFO: stage 4 — clock and reset configuration"

# Real clocks (functional) — referenced by name. These must already exist
# in the SDC fed to synth. During scan-shift they are gated; during
# capture they are functional (or replaced by scan_clk for stuck-at).
set functional_clocks {hclk phc_clk user_ref_clk pad_clk_rx apb_clk link_clk}

puts "  Functional clocks (will be muxed with scan_clk in test mode):"
foreach c $functional_clocks { puts "    $c" }
puts "  Test clock: scan_clk (period ${SCAN_CLK_PERIOD} ns)"

# Per-tool clock declaration
switch -- $DFT_TOOL {
    testmax {
        puts "  TODO: set_dft_signal -view spec -type ScanClock -port scan_clk \\"
        puts "        -timing {45 95}"
        puts "  TODO: set_dft_signal -view existing_dft -type ScanClock -port scan_clk"
    }
    tessent {
        puts "  TODO: add_clocks scan_clk -period ${SCAN_CLK_PERIOD}"
        puts "  TODO: add_test_mode_settings scan_mode -tied_value 1"
    }
}

# Reset configuration. The existing scan_asyncrst_ctrl port should
# hold all async resets de-asserted during shift.
puts "  TODO: set_dft_signal -view spec -type Reset -port hresetn   -active_state 0"
puts "  TODO: set_dft_signal -view spec -type Reset -port poresetn  -active_state 0"
puts "  TODO: set_dft_signal -view spec -type Reset -port phc_resetn -active_state 0"
puts "  TODO: set_dft_signal -view spec -type Constant -port scan_asyncrst_ctrl \\"
puts "        -active_state 1  ;# in test mode, gate async resets to inactive"

# ---------- scan-enable and scan-mode declaration ----------------------------

puts "INFO: stage 5 — test-mode signal declaration"

set scan_en_active [expr {[string equal $SCAN_EN_POLARITY active_high] ? 1 : 0}]

puts "  TODO: set_dft_signal -view spec -type ScanEnable -port scan_en \\"
puts "        -active_state $scan_en_active"
puts "  TODO: set_dft_signal -view spec -type TestMode -port test_mode \\"
puts "        -active_state 1"

# ---------- chain partitioning ------------------------------------------------

puts "INFO: stage 6 — chain partitioning ($SCAN_CHAINS chains)"

# Chain plan from DFT_PLAN §3.2. Final balancing is left to the tool
# auto-balance pass; these are seeds.
set chain_specs {
    {0 hclk        "AHB / app domain"}
    {1 hclk        "Wlink hclk side"}
    {2 hclk        "XHB500 + addr translator"}
    {3 link_clk    "Wlink TX/RX link domains"}
    {4 pad_clk_rx  "RX capture / IDELAY tap"}
    {5 phc_clk     "PTP capture"}
    {6 apb_clk     "APB regs + gpio_phy regs"}
    {7 hclk        "spare / balance"}
}

foreach spec $chain_specs {
    lassign $spec idx clk note
    if {$idx >= $SCAN_CHAINS} { continue }
    puts "  chain\[$idx\] (clock $clk) — $note"
    puts "    TODO: set_scan_path -name chain_$idx -clock $clk \\"
    puts "          -scan_data_in scan_in\[$idx\] -scan_data_out scan_out\[$idx\]"
}

# ---------- run the tool ------------------------------------------------------

puts "INFO: stage 7 — run insertion + auto-balance"

switch -- $DFT_TOOL {
    testmax {
        puts "  TODO: dft_drc                              ;# DRC pre-insertion"
        puts "  TODO: preview_dft                          ;# preview chains"
        puts "  TODO: insert_dft                           ;# do the insertion"
        puts "  TODO: dft_drc                              ;# DRC post-insertion"
    }
    tessent {
        puts "  TODO: analyze_dft_specification"
        puts "  TODO: insert_test_logic"
        puts "  TODO: report_dft_specification"
    }
    spyglass {
        puts "INFO: spyglass mode: DRC only, no insertion."
        puts "  TODO: invoke spyglass -tcl spyglass_dft.tcl"
    }
}

# ---------- output ------------------------------------------------------------

puts "INFO: stage 8 — write scan-inserted netlist"
puts "  TODO: file mkdir $OUT_DIR"
puts "  TODO: write_verilog $OUT_DIR/${DESIGN}_scan.v"
puts "  TODO: write_scandef $OUT_DIR/${DESIGN}.scandef"
puts "  TODO: write_test_protocol $OUT_DIR/${DESIGN}.spf"

puts "INFO: ============================================================="
puts "INFO: scan-insertion scaffold complete (no real work done — TODO above)"
puts "INFO: see docs/reference/DFT_PLAN_2026_05_28.md §7 for closure tasks"
puts "INFO: ============================================================="
