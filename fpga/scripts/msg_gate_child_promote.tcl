###-----------------------------------------------------------------------------
### TideLink - Vivado message gate: CHILD-run promotion installer
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
### David Mapstone (d.a.mapstone@soton.ac.uk)  Copyright (C) 2026, SoC Labs
###-----------------------------------------------------------------------------
### WHY THIS EXISTS
###
### build_design.tcl installs the set_msg_config -> ERROR promotions in the
### PARENT Vivado session, but `launch_runs synth_1` / `impl_1` fork CHILD
### processes with their OWN Tcl interpreter and message-config state. The
### parent's promotions do NOT propagate into the child, so a CRITICAL WARNING
### (or a combinational-loop DRC) emitted DURING synth/route was never promoted
### and the parent's post-phase count saw "0". This file re-installs the
### promotions INSIDE the child; it is wired as STEPS.SYNTH_DESIGN.TCL.PRE and
### STEPS.ROUTE_DESIGN.TCL.PRE so the severity changes are active BEFORE the
### step emits its messages / runs its DRC. Idempotent.
###
### Canonical list + rationale: fpga/docs/VIVADO_MSG_GATE.md. Keep in sync with
### the Layer-1 block in fpga/build_design.tcl and package_tidelink_ip.tcl.
###-----------------------------------------------------------------------------

# [Constraints 18-359] create_generated_clock: > 1 master pin matched -> derived
#   clock silently NOT created, downstream timing breaks.
catch { set_msg_config -id "Constraints 18-359"  -new_severity ERROR }
# [Vivado 12-4739] set_input/output_delay: No valid object(s) -> no-op constraint.
catch { set_msg_config -id "Vivado 12-4739"      -new_severity ERROR }
# [Designutils 20-1307] procedural TCL not supported inside XDC -> silently skipped.
catch { set_msg_config -id "Designutils 20-1307" -new_severity ERROR }
# [Vivado 12-1411] empty get_pins/get_cells/get_ports filter -> silent no-op constraint.
catch { set_msg_config -id "Vivado 12-1411"      -new_severity ERROR }
# [Common 17-55] suppressed (benign Xilinx-IP OOC noise) - matches build_design.tcl.
catch { set_msg_config -id "Common 17-55"        -suppress }

# COMBINATIONAL-LOOP guard (cb33c9f-class): an unintended combinational loop
# (e.g. the ahb_sub HREADY loopback that vanished silicon writes) is flagged by
# the LUTLP-1 DRC. INTENTIONAL loops are individually waived in *_tidelink_drc.xdc
# via ALLOW_COMBINATORIAL_LOOPS, so LUTLP-1 only fires on UN-waived (i.e. new,
# accidental) loops - exactly the regression class we want to hard-fail. Promote
# the DRC check to ERROR so write_bitstream's DRC dies at the source. The
# msg_gate_child_check.tcl POST hook ALSO runs report_drc -checks LUTLP-1
# explicitly, because write_bitstream's pre-DRC has historically ignored the
# severity change in Vivado 2024.1 (see the note in *_tidelink_drc.xdc).
catch { set_property SEVERITY {ERROR} [get_drc_checks LUTLP-1] }
