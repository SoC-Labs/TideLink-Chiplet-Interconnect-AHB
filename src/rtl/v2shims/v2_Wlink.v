// V2 build shim: per-file define + include of the shared source.
// Per-file defines survive IP packaging where fileset/global mechanisms do
// not (3 failed attempts logged on feat/phy-v2-integration, 2026-06-11).
`define TIDELINK_PHY_V2
// I1 FC-emit / router-grant observability (2026-07-30). Per-file define so it
// survives Vivado IP packaging (a flist +define+ is dropped — see banner).
// Drop this line to build a winscan-only, zero-TX-router-footprint image.
`include "Wlink.v"
