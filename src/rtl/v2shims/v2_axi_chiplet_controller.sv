// V2 build shim: per-file define + include of the shared source.
// Per-file defines survive IP packaging where fileset/global mechanisms do
// not (3 failed attempts logged on feat/phy-v2-integration, 2026-06-11).
`define TIDELINK_PHY_V2
`include "axi_chiplet_controller.sv"
