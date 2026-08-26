///////////////////////////////////////////////////////////////////////////////
// tl_top_sb_selftest_top.sv
///////////////////////////////////////////////////////////////////////////////
// No DUT. The scoreboard under test is a pure UVM component; the
// tidelink_top_system env's quarantine is a DUT/TB port-rot problem that has
// nothing to do with the checker being exercised here.
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

// Same include order the env testbenches use: UVM, then the AMBA VIP package,
// then this harness's own package.
`include "uvm_pkg.sv"
`include "svt_ahb.uvm.pkg"
`include "tl_top_sb_selftest_pkg.sv"

module tl_top_sb_selftest_top;

  import uvm_pkg::*;
  import tl_top_sb_selftest_pkg::*;

  initial begin
    run_test("tl_top_sb_selftest");
  end

endmodule
