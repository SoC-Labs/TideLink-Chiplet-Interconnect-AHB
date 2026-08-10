// HAL rule configuration for TideLink lint flow
//
// Waive rules that conflict with AHB/AMBA/APB naming conventions or are
// style-only and not relevant to design correctness.
//
// -----------------------------------------------------------------------------
// HOW A WAIVER GETS HERE (read before adding one)
//
// Every entry is a claim that the rule cannot find a real defect in THIS block.
// A finding is fixed in the RTL unless fixing it would (a) change behaviour for
// a style rule, (b) require narrowing a wide operand, or (c) mean rewriting
// code that mitigates a known silicon issue. Where a class was only PARTLY
// unfixable the fixable instances were fixed first and the waiver records what
// is left, by site.
//
// This file is a UNIT-level ruleset. The full-chiplet lint
// (verif/lint/full/hal_rules.tcl) is a curated MERGE of the unit rulesets and
// deliberately drops rules it considers sign-off classes -- so adding a rule
// here does NOT silence it in the integration report. Anything added below
// that the merge currently drops is called out explicitly.
// -----------------------------------------------------------------------------

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
// Small integer literals (e.g. +2 for header overhead) in arithmetic — idiomatic SV
-nocheck CONSBS
// Expressions in port connections (e.g. zero-extend {2'b0, hwdata[31:20]}) —
// intentional boundary width coercions between 32-bit AHB and narrower internal buses
-nocheck EXPIPC
// Bit-select on unsigned — same set of boundary lines as EXPIPC
-nocheck BITUNS
// Function naming — repo does not use a func_ prefix convention
-nocheck FUNCNM
// Coded default case (empty default: ;) — intentional no-op when default
// assignment precedes the case statement; fully covered case is correct SV
-nocheck CDEFCV
// AMBA-mandated combinational input -> output paths. The structural equivalents
// CBPAHI/TPOUNR/SYNPRT/FDTHRU are already waived as design correctness items;
// IOCOMB is the same class (e.g. APB pready/pslverr or AHB hready combinational
// fan-out) and was the dominant noise source in the May/post-consolidation HAL
// runs (~110 of ~140 warnings). Waive to surface the genuine findings.
-nocheck IOCOMB
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
//
// 2026-08-09 re-justification (14 findings). Every one is a combinational
// path a protocol or a datapath REQUIRES; "fixing" any of them means adding a
// register stage, which is a behaviour change, not a lint fix:
//   tidelink_apb_regs   x10  paddr[4:2]/pwdata -> the per-region reg_addr /
//                            reg_wdata fan-out, and current_credit_count ->
//                            credit_count_data. This is an APB address/data
//                            decode; registering it breaks the zero-wait-state
//                            slave contract (apbs_pready tied 1).
//   tidelink_fifo_ctrl:198   addr -> translated_addr. Address translation is
//                            combinational by definition.
//   tl_addr_trans_cam:59     addr_i[23:0] -> addr_o[23:0]. The CAM replaces
//                            only addr[31:24]; the low 24 bits pass through by
//                            design (see the comment at that line).
//   tidelink_idelay_rx:226   pad_rx_i -> pad_rx_o in the USE_IDELAY=0 arm.
//                            That arm IS the documented bit-exact passthrough.
//   tidelink_rxclk_buf:87    clk_i -> clk_o. A clock buffer. Registering a
//                            clock is not a thing.
// NOTE: verif/lint/full/hal_rules.tcl currently DROPS this rule from the merge
// ("sign-off rule"), so these 14 still appear in the integration report. The
// loading concern FDTHRU exists to raise is a physical one and belongs to
// timing/SI closure, not to RTL lint; the RTL question is settled above.
-nocheck FDTHRU
// Mixed sync/async is expected with async active-low reset (hresetn)
-nocheck SYNASN
// Combinational paths crossing hierarchy — expected in a hierarchical
// design where combinational logic feeds registered logic across module
// boundaries (e.g. fifo_ctrl ↔ ahb_to_sram ↔ sram)
-nocheck CBPAHI
// Combinational outputs at top level — AHB/APB protocols are comb by design
-nocheck TPOUNR
// Combinational (async) output ports — same reason
-nocheck SYNPRT
// Large operand arithmetic — inherent to parameterised widths
-nocheck LRGOPR
// Potential overflow — intentional wrapping for circular FIFO pointers
-nocheck POIASG
// Multiple non-blocking assigns — set/clear pattern for pending regs
-nocheck MULNBA
// Parameters in port expressions — localparam addresses passed to returner
-nocheck PRMEXP
-nocheck IPRTEX
// FSM modelling style — HAL expects specific patterns, ours is valid
-nocheck BADFSM
-nocheck EXTFSM
-nocheck TRNMBT
-nocheck STMCNM
// Typedef not in package — module-local typedefs are acceptable
-nocheck TDOPKG
// Lowercase type names — SV convention for types
//
// 2026-08-09 re-justification (7 findings: state_t, puf_state_t, rx_state_t,
// tx_state_t, hw_sync_state_t, gm_state_t, sub_state_t). UCCONN is RMM §5.2.1,
// a pure NAMING rule of Warning severity — "use upper case for names of
// constants and user-defined types". The `lower_case_t` suffix is the
// SystemVerilog convention, is used consistently across this repo and its
// dependencies, and renaming a typedef changes nothing but the identifier.
// This is the same category as ALOWID / BLKLNM / SIGLEN / TASKNM / VLFLNM,
// which verif/lint/full/hal_report.py already classifies as STYLE and
// suppresses. UCCONN's absence from that list looks like an omission rather
// than a decision, and it is NOT in that file's NEVER_WAIVE set either.
// Recommendation to the integrator: add UCCONN to hal_report.py:STYLE_RULES
// rather than re-adding it to the merged ruleset. The source should not be
// de-idiomatised to satisfy a naming rule the project has consciously rejected.
-nocheck UCCONN
// Clock/reset renamed across CMSDK hierarchy (hclk→HCLK, hresetn→HRESETn)
-nocheck DIFCLK
-nocheck DIFRST
// Aliased wires — read/write target share same expression by design
-nocheck DALIAS
// FF with constant data — reset_n_d1 tied to 1'b1 for deassertion detection
-nocheck FFCSTD
// FF without synchronous reset — async reset is sufficient
-nocheck FFWNSR
// Mixed driver types on vector — token_count_r init vs runtime, harmless
//
// 2026-08-09 re-justification (9 findings). DFDRVS is NOT a multi-driver rule
// — that is MLTDRV, which this file does not waive, which the integration
// gates, and which reports ZERO across the whole chiplet. So every bit here
// still has exactly one driver; DFDRVS is reporting that different SUB-RANGES
// of a vector are driven by different constructs. The instances are:
//   apb_regs:217 release_threshold, fifo_ctrl:122 credit_count_r,
//   perf:333 trend_r, ptp:364 hw_sync_interval_r,
//   ptp_servo:133-135 servo_kp_r/ki_r/step_thresh_r
//     — a reset constant vs. a register-write value, in one always_ff.
//   tidelink_top:575/601 s_axi_awaddr / s_axi_araddr
//     — [31:0] from the XHB500 bridge instance, [35:32] tied to 4'h0 for the
//       unused top of the 36-bit AXI address (see the comment at :569).
// The AXI pair sits on the AW/AR channels, which carry a known silicon issue
// (TL-009 a2l CDC self-latch). Collapsing them into a single concatenated
// driver would be a pure renaming, but it is a renaming of the exact nets
// under investigation, so it is deliberately NOT done for a style finding.
// NOTE: dropped from verif/lint/full/hal_rules.tcl's merge as a "sign-off
// rule"; the argument above is why that classification does not fit DFDRVS.
-nocheck DFDRVS
// Unused port bits — AHB htrans[0], hresp/hrdata on write-only master,
// APB paddr upper/lower bits only [5:2] decoded. All by protocol/design.
-nocheck USEPRT
// Unconnected output naming — debug signals don't need _nc suffix
-nocheck UCOPNM
// Unconnected output ports — debug signals for cocotb probing only
-nocheck UNCONO
// Unread local registers — debug signal aliases for testbench visibility
-nocheck URDREG
// Glue logic at top level — expected for address derivation wires
-nocheck ATLGLC
// ── 2026-08-09 waivers (full-chiplet HAL pass) ───────────────────────────
// Added while driving TideLink's authored HAL findings to zero. 48 of the 138
// were FIXED in the RTL (widths, signedness, dead localparams, the PTP servo
// lock compare); these are the classes where a fix would have been worse than
// the finding. Counts are the authored TideLink instances at the time.

// UNCONN (33) — "<direction> port 'x' ... is not connected in its instance".
// ALL 33 authored instances are OUTPUT ports, deliberately left open:
//   xhb500_ahb_to_axi_bridge_chiplet_slv (15) and
//   xhb500_axi_to_ahb_bridge_chiplet_mst (14) — AXI5/ACE-Lite sidebands
//     (awdomain/awregion/awnsaid/hexokay/hnonsec/hqos/hwstrb/...) and the
//     Q-Channel low-power handshakes (clk_/pwr_qactive/qacceptn/qdeny). This
//     integration drives no Q-Channel and no AXI5 sideband; the vendor IP
//     emits them unconditionally.
//   tidelink_gpio_phy_apb_regs.noise_mode_o, axi_chiplet_controller.sb_wake /
//   generalbus_out, tidelink_addr_translator.chp1_ahb_haddr_o (NUM_CHANNELS=1)
//     — debug/optional taps with no consumer in this configuration.
// DIRECTION IS THE WHOLE ARGUMENT, and the detector for the other direction
// survives this waiver twice over:
//   * HAL UNCONI (unconnected INPUT, severity ERROR) is NOT waived here and is
//     in hal_report.py's NEVER_WAIVE set.
//   * Verilator's PINMISSING/PINCONNECTEMPTY run over the SAME filelist in the
//     same pass and are direction-gated in verilator_lint.py: outputs waived,
//     inputs and unresolved-direction pins GATED. That pass is what caught the
//     real tidelink_fifo_ahb floating-input pair, and it fires whether or not
//     the port is read inside the instantiated module — the one case UNCONI
//     could miss.
// Do NOT extend this to UNCONI.
-nocheck UNCONN

// FSMIDN (7) — severity NOTE, not a warning: "FSM for state register 'x' has
// been recognized". It is HAL telling you its FSM extraction worked. There is
// nothing to fix and nothing to review; suppressing it stops 7 informational
// lines from being counted as design findings.
-nocheck FSMIDN

// TRGGLT (1, severity NOTE) — tl_addr_trans_cam:89, the `found` early-exit
// flag in the priority encoder. Single procedural driver, one always @(*),
// and the final value is stable within the block, so this is not the
// multi-driver/fc_shell-blocking class. The ascending-loop-with-flag form is
// a DELIBERATE QoR choice (documented at that line: it synthesises as a
// parallel priority tree rather than a cascading mux chain), and this design
// is already in P&R — restructuring it for a note is not a trade worth making.
-nocheck TRGGLT

// CONSTC (4) — constant conditional expression. All four are compile-time
// configuration folding, which is what parameters are for:
//   tidelink_addr_translator:97  if (NUM_CHANNELS > 1)   [instantiated with 1]
//   tidelink_ptp:372             PHC_LOCK_GATE_EN == 0   [0 in the shipped cfg]
//   tidelink_top:1017            configuration select
//   tidelink_top:2129            the STUB_PTP/STUB_SERVO elaboration guard
// The dead branch is the POINT: the arm not taken must not be synthesised.
-nocheck CONSTC

// BADSYS (1) — tidelink_top:2130, `$error` inside an `initial` block that
// checks an illegal STUB_PTP/STUB_SERVO combination at elaboration. HAL is
// reporting that synthesis ignores the system task, which is correct AND
// intended: the guard exists to stop a bad parameterisation reaching a
// simulator or an elaborator, and it must not emit hardware.
-nocheck BADSYS

// REDOPR (3) — wide reduction OR. All three are the standard
// "reference-a-signal-so-it-is-not-reported-unused" idiom, feeding a wire with
// no consumer, which synthesis removes entirely — so the "complex logic"
// REDOPR warns about is never built:
//   tidelink_idelay_rx:230  (|phase_tap_i) in the USE_IDELAY=0 passthrough arm
//   tidelink_top:1204       |{eye_force_phase_en/val, eye_force_slip_val}
//   tidelink_top:1334       |{lane_mismatch_pulse, lane_dwell_min_dist}
-nocheck REDOPR

// LOGORP (1) — tidelink_top:1890, `(s_axi_bvalid_ctrl | synth_b_pending) ?`.
// Both operands verified 1-bit, so `|` and `||` are identical in hardware.
// This line is inside the TL-009 synthetic-B / corrupted-BID mitigation for a
// KNOWN SILICON WEDGE on the AW/W/B channels. `|` and `||` differ on X in
// simulation (`||` can resolve X|1 to 1). Perturbing a wedge mitigation's
// X-behaviour to satisfy a style rule is not a trade this design can afford.
-nocheck LOGORP

// USEPAR (5 residual; 7 genuinely-dead localparams were DELETED instead —
// HTRANS_IDLE/HTRANS_NONSEQ/HSIZE_WORD in tidelink_fc_adapter, HTRANS_IDLE/
// HTRANS_NONSEQ in tidelink_ptp, NS_PER_SECOND and MBOX_SUB_NS_OFFSET in
// tidelink_ptp_servo). What is left is not dead code:
//   tidelink_idelay_rx:96  IDELAY_GRP  — documentary BY DESIGN. Vivado rejects
//     a string-typed parameter in an (* IODELAY_GROUP *) attribute, so the
//     attribute uses a literal; the parameter records the value that literal
//     and the XDC must agree on. Deleting it deletes the contract.
//   tidelink_idelay_rx:106 REFCLK_MHZ  — used at IDELAYE2.REFCLK_FREQUENCY,
//     inside the USE_IDELAY=1 arm that the ASIC parameterisation prunes.
//   tidelink_top:94  USE_PHY_V2        — used at `if (USE_PHY_V2)`, whose
//     false arm (the only one built today) elaborates empty.
//   tidelink_top:1024 TXGEN_CGD_EFF    — used at u_tx_gen.CREDIT_GATE_DIS
//     inside `if (TXGEN_PRESENT)`.
//   tidelink_perf:34 FC_DATA_W         — an interface-width parameter every
//     instantiator passes; removing it would break those instantiations for a
//     style finding.
// The last four are "unused only in the configuration HAL elaborated", which
// is a statement about the parameterisation, not about the code.
-nocheck USEPAR

// MXUANS (5 residual) — expression with both signed and unsigned operands.
// The 5 fixable instances WERE fixed (tidelink_mul_iter:70 and the
// raw_offset_r/raw_delay_r sign-extensions in tidelink_ptp_servo now use a
// size cast, which preserves signedness, instead of a hand-written sign bit
// inside a concatenation). The residue is in the PI servo, where mixing is
// deliberate and the mix is what makes the arithmetic correct:
//   ptp_servo:586  needs_phase_step_r || (offset_r >  $signed(thresh)) ||
//                                        (offset_r < -$signed(thresh))
//     — a 1-bit unsigned flag OR-ed with two signed comparisons. `||` operands
//       are self-determined booleans; there is no width or sign interaction.
//   ptp_servo:599/602  the anti-windup guards, which test integral_r[31] /
//     offset_r[31] (unsigned bit-selects) alongside a signed add.
//   ptp_servo:632/634  current_frac_r - (pi_p_term_r + mul_result[63:32]).
//     current_frac_r is the unsigned Q0.32 frequency word; per LRM 11.8.1 one
//     unsigned operand makes the whole expression unsigned, which is exactly
//     the 32-bit wrapping arithmetic a frequency accumulator needs.
// These are correct as written and are covered by cocotb/tidelink_ptp_servo
// (SRV-006 anti-windup, SRV-012 PI reference). Rewriting live PI arithmetic on
// a tapeout branch to remove a signedness annotation is not worth the risk.
-nocheck MXUANS

// CMSDK-specific warnings that leak through
-nocheck OLDALW
-nocheck LOGNEG
-nocheck LOGAND
-nocheck BOUINC
-nocheck MEMRNM
-nocheck MICAWS
-nocheck BBXSIG
