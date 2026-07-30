// V2 build shim: per-file define + include of the shared source.
// Per-file defines survive IP packaging where fileset/global mechanisms do
// not (3 failed attempts logged on feat/phy-v2-integration, 2026-06-11).
`define TIDELINK_PHY_V2
// Note: the FC-emit / router-grant obs (obs_fcemit_*_o Wlink ports + Region F
// slots 3-4) is now UNCONDITIONAL in the shared sources — no per-file define
// needed (a flist/global define never reaches the packaged-IP OOC synth).
`include "axi_chiplet_controller.sv"
