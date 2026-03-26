// HAL rule configuration for TideLink lint flow
//
// Waive rules that conflict with AHB/AMBA naming conventions or are
// style-only and not relevant to design correctness.

// ── Naming convention waivers ─────────────────────────────────────
// AHB signal names (hclk, hresetn, hsel, etc.) are defined by the
// AMBA spec and cannot follow HAL's default _I/_O/_CK/_rst suffixes.
-nocheck INPTNM
-nocheck OUTPNM
-nocheck CLKSNM
-nocheck RSTNAM
-nocheck MODLNM
-nocheck RGOPNM
-nocheck IDLENG

// ── Style waivers ─────────────────────────────────────────────────
// Numeric literals in port widths (e.g. [31:0]) are standard practice
-nocheck STYVAL
// Line length — 120 chars is acceptable for modern editors
-nocheck MAXLEN
// Per-port and per-signal comments are overkill for clear code
-nocheck COMIOP
-nocheck COMDEC
-nocheck COMEND
// Parameter base/width — defaults are fine for simple integer params
-nocheck PRMVAL
-nocheck PRMBSE

// ── Structural waivers ───────────────────────────────────────────
// Tied outputs (hreadyout=1, hresp=0) are by design for zero-wait-state
-nocheck TIELOG
// Feedthrough paths (hwdata→reg_wdata, reg_rdata→hrdata) are intentional
-nocheck FDTHRU
// Mixed sync/async is expected with async reset
-nocheck SYNASN
