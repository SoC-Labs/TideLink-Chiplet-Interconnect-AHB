///////////////////////////////////////////////////////////////////////////////
// tl_top_sb_selftest_pkg.sv
///////////////////////////////////////////////////////////////////////////////
// Minimal package for the scoreboard self-test. Pulls in the production
// scoreboard SOURCE FILE unmodified — nothing here is a copy of it, so the
// self-test cannot drift away from what the env compiles.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TL_TOP_SB_SELFTEST_PKG_SV
`define GUARD_TL_TOP_SB_SELFTEST_PKG_SV

package tl_top_sb_selftest_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import svt_uvm_pkg::*;
  import svt_ahb_uvm_pkg::*;

  `include "tidelink_top_system_scoreboard.sv"
  `include "tl_top_sb_selftest.sv"

endpackage

`endif // GUARD_TL_TOP_SB_SELFTEST_PKG_SV
