// N1 fix-build shim (dam). Mirrors src/rtl/v2shims/v2_tidelink_top.sv but includes
// an OVERRIDE copy of tidelink_top.sv (HEAD + N1 conditional-abandon fix), by
// absolute path, so the tracked tree is left byte-identical.
`define TIDELINK_PHY_V2
`include "/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink/imp/hw_gate/n1_repro_dam/tidelink_top_fix.sv"
