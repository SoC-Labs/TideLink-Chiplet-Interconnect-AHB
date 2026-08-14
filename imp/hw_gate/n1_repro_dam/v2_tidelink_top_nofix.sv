// N1 control-build shim (dam). Includes an OVERRIDE copy of tidelink_top.sv at
// plain HEAD (NO fix), by absolute path, so the tracked tree is left byte-identical.
`define TIDELINK_PHY_V2
`include "/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink/imp/hw_gate/n1_repro_dam/tidelink_top_nofix.sv"
