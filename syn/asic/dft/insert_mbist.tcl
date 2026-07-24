#------------------------------------------------------------------------------
# TideLink — MBIST Insertion Wrapper (SCAFFOLD)
#
# Target memory: rf_16k (Arm/TSMC65 4096 x 32 SP register file)
#   - one instance per chiplet (TideLink RX FIFO)
#   - CTL model at /research/precompiled_mems/TSMC65/rf_16k/rf_16k.ctl
#   - Test Muxes: OFF, Retention: ON, EMA/EMAW present
#   - read-only — do not modify the CTL or .v under /research/AAA/...
#
# Two flows supported via MBIST_FLOW env var:
#   tessent — Mentor Tessent MemoryBIST (preferred, vendor-recommended)
#   custom  — hand-rolled March-C- + retention controller (fallback if
#             no Tessent licence; scaffold emits TODO only)
#
# Inputs (env):
#   MBIST_FLOW        tessent | custom            (default: tessent)
#   MEM_NAME          memory cell name            (default: rf_16k)
#   MEM_INSTANCE      hier path of macro inst     (default: u_dft_wrapper/u_top/u_fifo/u_sram/u_rf)
#   MEM_CTL_FILE      CTL test model              (default: /research/precompiled_mems/TSMC65/rf_16k/rf_16k.ctl)
#   ALGO              mats+ | march-c | march-lr  (default: march-c)
#   RUN_RETENTION     0 | 1                       (default: 1)
#   RUN_EMA_SWEEP     0 | 1                       (default: 1)
#   DESIGN            top wrapper module          (default: tidelink_dft_wrapper)
#   OUT_DIR           output dir                  (default: out/dft)
#
# Usage:
#   make -C syn/asic/dft insert_mbist
#
# A joint work commissioned on behalf of SoC Labs.
# Copyright 2026, SoC Labs (www.soclabs.org)
#------------------------------------------------------------------------------

if {![info exists env(MBIST_FLOW)]}     { set env(MBIST_FLOW)     "tessent" }
if {![info exists env(MEM_NAME)]}       { set env(MEM_NAME)       "rf_16k" }
if {![info exists env(MEM_INSTANCE)]}   { set env(MEM_INSTANCE)   "u_dft_wrapper/u_top/u_fifo/u_sram/u_rf" }
if {![info exists env(MEM_CTL_FILE)]}   { set env(MEM_CTL_FILE)   "/research/precompiled_mems/TSMC65/rf_16k/rf_16k.ctl" }
if {![info exists env(ALGO)]}           { set env(ALGO)           "march-c" }
if {![info exists env(RUN_RETENTION)]}  { set env(RUN_RETENTION)  "1" }
if {![info exists env(RUN_EMA_SWEEP)]}  { set env(RUN_EMA_SWEEP)  "1" }
if {![info exists env(DESIGN)]}         { set env(DESIGN)         "tidelink_dft_wrapper" }
if {![info exists env(OUT_DIR)]}        { set env(OUT_DIR)        "out/dft" }

set MBIST_FLOW    $env(MBIST_FLOW)
set MEM_NAME      $env(MEM_NAME)
set MEM_INSTANCE  $env(MEM_INSTANCE)
set MEM_CTL_FILE  $env(MEM_CTL_FILE)
set ALGO          $env(ALGO)
set RUN_RETENTION $env(RUN_RETENTION)
set RUN_EMA_SWEEP $env(RUN_EMA_SWEEP)
set DESIGN        $env(DESIGN)
set OUT_DIR       $env(OUT_DIR)

puts "INFO: ============================================================="
puts "INFO: TideLink MBIST-insertion scaffold"
puts "INFO:   flow          = $MBIST_FLOW"
puts "INFO:   memory        = $MEM_NAME"
puts "INFO:   instance      = $MEM_INSTANCE"
puts "INFO:   CTL           = $MEM_CTL_FILE"
puts "INFO:   algorithm     = $ALGO"
puts "INFO:   retention     = $RUN_RETENTION"
puts "INFO:   EMA sweep     = $RUN_EMA_SWEEP"
puts "INFO:   design        = $DESIGN"
puts "INFO: ============================================================="

# ---------- read-only guard --------------------------------------------------

if {![file readable $MEM_CTL_FILE]} {
    puts "ERROR: CTL file not readable: $MEM_CTL_FILE"
    puts "       The TSMC65 vendor IP must be visible via NFS / mounted."
    puts "       Do NOT modify the file in place — copy to local_overrides"
    puts "       if a fix is required."
    exit 1
}

# ---------- BIST controller interface description ---------------------------
#
# The MBIST controller exposes the following APB-visible interface (TBD
# offsets — see DFT_PLAN §4.3). The DFT wrapper instantiates the
# controller and wires it to:
#   - the rf_16k macro pins (clk, A, D, CEN, WEN, GWEN, Q, EMA, EMAW, RET1N)
#   - a multiplexer that selects between functional (cmsdk_ahb_to_sram)
#     and BIST drive of the macro
#   - the APB shim for SW-visible status
#
# Status word (read at APB offset 0x04 of the BIST regs):
#   bit 0 — done
#   bit 1 — pass
#   bits 23:8 — first failing address (when !pass)

# ---------- flow dispatcher --------------------------------------------------

switch -- $MBIST_FLOW {

    tessent {
        puts "INFO: stage 1 (tessent) — licence check"
        if {![info exists env(MGLS_LICENSE_FILE)]
            && ![info exists env(LM_LICENSE_FILE)]} {
            puts "ERROR: MGLS_LICENSE_FILE / LM_LICENSE_FILE not set."
            puts "       Tessent MemoryBIST requires Mentor licence."
            puts "       Action: confirm with admin or rerun with MBIST_FLOW=custom"
            puts "       See docs/reference/DFT_PLAN_2026_05_28.md §7.4."
            exit 1
        }

        puts "INFO: stage 2 (tessent) — set up MemoryBIST"
        puts "  TODO: read_design \$env(NETLIST)"
        puts "  TODO: read_memory_lib $MEM_CTL_FILE"
        puts "  TODO: set_current_design $DESIGN"
        puts "  TODO: set_context dft -prefix memorybist"

        puts "INFO: stage 3 (tessent) — extract memory, create BIST"
        puts "  TODO: extract_memories"
        puts "  TODO: set_dft_specification_requirements -memorybist on"
        puts "  TODO: add_dft_signals -create_from_ports"

        puts "INFO: stage 4 (tessent) — algorithm selection"
        switch -- $ALGO {
            mats+    { puts "  TODO: set_test_algorithms -name mats_plus" }
            march-c  { puts "  TODO: set_test_algorithms -name march_c_minus" }
            march-lr { puts "  TODO: set_test_algorithms -name march_lr" }
        }
        if {$RUN_RETENTION} {
            puts "  TODO: set_test_algorithms -append -name data_retention -hold_time 1ms"
        }
        if {$RUN_EMA_SWEEP} {
            puts "  TODO: set_test_algorithms -append -name march_c_minus -ema_values {000 011 111}"
        }

        puts "INFO: stage 5 (tessent) — generate, integrate, write"
        puts "  TODO: process_dft_specification"
        puts "  TODO: extract_icl"
        puts "  TODO: write_dft_inserted_design $OUT_DIR/${DESIGN}_mbist.v"
        puts "  TODO: write_patterns $OUT_DIR/${DESIGN}_mbist.stil -format stil"
    }

    custom {
        puts "WARN: custom MBIST controller path — RTL not yet authored."
        puts ""
        puts "Closure tasks (see DFT_PLAN §4.1 + §4.3):"
        puts "  1. Author src/rtl/asic/tidelink_mbist_ctrl.sv with:"
        puts "       - March-C- pattern generator (counter + state machine)"
        puts "       - 32-bit data ramp / inverse-ramp / walking-1"
        puts "       - retention timer (10\^5 cycles ~= 1 ms at 100 MHz)"
        puts "       - EMA sweep state, drives rf_16k EMA\[2:0\] in {000,011,111}"
        puts "       - signature compactor (CRC-16 over Q\[31:0\] xor expected)"
        puts "       - APB shim at offset 0x4000 with done/pass/fail_addr/sig"
        puts "  2. Author src/rtl/asic/tidelink_sram_mbist_mux.sv that muxes:"
        puts "       - functional (cmsdk_ahb_to_sram) drive when mbist_en=0"
        puts "       - controller drive when mbist_en=1"
        puts "       - functional readback Q forwarded both modes"
        puts "  3. Wire mbist_en / mbist_done / mbist_pass / clk into wrapper"
        puts "     (already stubbed in tidelink_dft_wrapper.sv)"
        puts "  4. Add cocotb env cocotb/tidelink_mbist/ with at minimum:"
        puts "       - test_mbist_clean_pass — all cells good → pass=1"
        puts "       - test_mbist_inject_stuck_at — force a Q bit stuck → pass=0, fail_addr correct"
        puts "       - test_mbist_retention_hold — verify hold timer fires after writes"
        puts "  Estimated effort: 1.5 weeks engineer."
    }

    default {
        puts "ERROR: unknown MBIST_FLOW: $MBIST_FLOW (expected: tessent | custom)"
        exit 1
    }
}

puts "INFO: ============================================================="
puts "INFO: MBIST-insertion scaffold complete (no real work done — TODO above)"
puts "INFO: see docs/reference/DFT_PLAN_2026_05_28.md §4 + §7 for closure tasks"
puts "INFO: ============================================================="
