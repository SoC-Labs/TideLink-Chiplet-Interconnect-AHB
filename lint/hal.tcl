// HAL rule configuration for TideLink lint flow
//
// Waive rules that conflict with AHB/AMBA/APB naming conventions or are
// style-only and not relevant to design correctness.

// ── Naming convention waivers ─────────────────────────────────────
// AHB/APB signal names (hclk, hresetn, hsel, apbs_psel, etc.) are
// defined by the AMBA spec and cannot follow HAL's default suffixes.
-nocheck INPTNM
-nocheck OUTPNM
-nocheck CLKSNM
-nocheck RSTNAM
-nocheck MODLNM
-nocheck RGOPNM
-nocheck IDLENG
// Uppercase variable names — CMSDK IP uses ALL-CAPS ports (HCLK, HADDR, etc.)
-nocheck LCVARN

// ── Style waivers ─────────────────────────────────────────────────
// Numeric literals in port widths (e.g. [31:0]) are standard practice
-nocheck STYVAL
// Line length — 120 chars is acceptable for modern editors
-nocheck MAXLEN
// Per-port and per-signal comments are overkill for clear code
-nocheck COMIOP
-nocheck COMDEC
-nocheck COMEND
// Always-block comments — not required for well-structured code
-nocheck COMBLK
// Parameter base/width — defaults are fine for simple integer params
-nocheck PRMVAL
-nocheck PRMBSE
// Compiler directives (`ifdef/`endif) — used in CMSDK IP, acceptable
-nocheck CDWARN
-nocheck COMDIR
// Block labels — meaningful code structure over mandatory labelling
-nocheck NOBLKN
// Missing begin/end in single-statement if/always — acceptable style
-nocheck NBGEND
// Empty default case statements — intentional no-op for completeness
-nocheck EMPSTM
// Numeric suffix in identifiers (e.g. pending_0, interrupt_1) — by design
-nocheck NUMSUF
// Separate line for each signal declaration — acceptable grouping
-nocheck SEPLIN

// ── Structural waivers ───────────────────────────────────────────
// Tied outputs are by design:
//   - hreadyout=1, hresp=0 (zero-wait-state AHB slave)
//   - apbs_pready=1, apbs_pslverr=0 (zero-wait-state APB slave)
-nocheck TIELOG
// Feedthrough paths are intentional:
//   - hwdata→reg_wdata, reg_rdata→hrdata (AHB-to-reg bridge)
//   - haddr→translated_haddr (address translation)
//   - apbs_pwdata→accumulator, accumulator→apbs_prdata (APB regs)
-nocheck FDTHRU
// Mixed sync/async is expected with async active-low reset (hresetn)
-nocheck SYNASN
// Combinational paths crossing hierarchy — expected in a hierarchical
// design where combinational logic feeds registered logic across module
// boundaries (e.g. fifo_ctrl ↔ ahb_to_sram ↔ sram)
-nocheck CBPAHI
