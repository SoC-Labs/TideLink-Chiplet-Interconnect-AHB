// V2 build shim: per-file define + include of the shared source.
// Per-file defines survive IP packaging where fileset/global mechanisms do
// not (3 failed attempts logged on feat/phy-v2-integration, 2026-06-11).
`define TIDELINK_PHY_V2
// I1 FC-emit / router-grant observability (2026-07-30). Per-file define so it
// survives Vivado IP packaging (a flist +define+ is dropped — see banner).
// Must match v2_Wlink.v: gates the obs_fcemit_*_o Wlink ports + Region F slots
// 3-4. Drop BOTH to build a winscan-only image.
`define TIDELINK_FCEMIT_OBS
`include "axi_chiplet_controller.sv"
