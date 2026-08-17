// TL-042 prototype build shim (CONTROL / unpatched).
// Mirrors src/rtl/v2shims/v2_tidelink_top.sv but includes the local VERBATIM
// HEAD copy of tidelink_top.sv by absolute path, so the shared source is never
// compiled and never touched.
`define TIDELINK_PHY_V2
`include "/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink/imp/hw_gate/tl042_recovery_proto/tidelink_top_orig.sv"
