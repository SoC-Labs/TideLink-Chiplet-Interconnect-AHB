// S3 PHY swap: V2 build marker. Packaged as a GLOBAL INCLUDE so the
// define reaches the IP OOC synthesis (fileset verilog_define does not
// travel with packaged IP — see package_tidelink_ip.tcl 2026-05-19 note).
`ifndef TIDELINK_PHY_V2
`define TIDELINK_PHY_V2
`endif
