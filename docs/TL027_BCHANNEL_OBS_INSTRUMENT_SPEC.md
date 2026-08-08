# TL-027 instrument-first — B-channel (0x82) a2l observation taps: ready-to-execute spec

**Status:** SPEC-READY, David-gated (netlist-affecting + register-map contract change + requires rebuild).
**Purpose:** give silicon a discriminator for the RANK-1 peer-write data-drop wedge by exposing the
**B (write-response, data_id 0x82)** app-to-link replay node's raw pointers + false-FULL terms — the
same six read-only taps `_13` already exposes for the TideLink sideband node, but on the AXI **write
path** (which `_13`'s 0xA1 sideband obs does NOT observe).

Why this is gated, not autonomously committed:
- **Netlist-affecting** → invalidates HW-proven bitstream `9cca6fe`; needs a rebuild to be usable.
- **Confirmatory only** → the rank-1 wedge's DOMINANT cause is physical marginal-eye (see
  `project_rank1_peerwrite_datadrop_2026_08_06`); this instrument localizes, it does not cure.
- **Touches the register-map contract** → a new Region-10 APB slot that `tl39.py` / GUI / host tooling
  must learn. That coordination is David's call.

Do the contested CDC self-heal port (the TL-027 *fix*) only AFTER this instrument confirms the write-path
false-FULL on silicon — per the ratified "instrument-first before betting the wedge cure on it".

---

## The node: `WlinkGenericFCReplayV2_5` is the B (0x82) a2l node

Instantiation chain (all under `deps/axi-chiplet-controller/logical/wlink/`):
- `AXI4ToWlink.v:605` — `WlinkGenericFCSM_2 wlink_axibFC` (the "b" write-response FCSM).
- `WlinkGenericFCSM_2.v:505` — `WlinkGenericFCReplayV2_5 a2l_fc_replay`.
- `WlinkGenericFCSM_2.v:629` — `swi_data_id_1 <= 8'h82` (confirms channel = B).
- FIFO-memory cross-check (`flists/tidelink_top_full_asic_v2.flist:299-312`): `..._bFC_a2l_14x8`
  (B = `_5`, 14-wide/depth-8) vs `..._awFC_a2l_101x8` (AW = `_1`, 101-wide). Disambiguates _1 vs _5.

Full channel map: AW=`_1`(0x80) · W=`_3`(0x81) · **B=`_5`(0x82)** · AR=`_7`(0x83) · R=`_9`(0x84).

## The template: `_13`'s obs endpoint = APB RO `0x4403_2158` (Region 10, slot 6)

Six taps, leaf `src/rtl/local_overrides/WlinkGenericFCReplayV2_13.v:179-185`:
`obs_a2l_wptr⇐fifo_io_wbin_ptr`, `obs_a2l_synced_ack⇐a2l_link_addr_app_clk`, `obs_a2l_full⇐a2l_full`,
`obs_enable_app_clk_demet⇐enable_app_clk_demet_io_out`, `obs_a2l_rreset⇐link_reset`,
`obs_a2l_rptr⇐fifo_io_rbin_ptr`. Threaded up through:
`FCSM_6.v` (:300-313,:424-430,:1018-1024,:1075-1081) → `TideLinkToWlink.v` (:69-77,:100-106,:201-207,:229-235)
→ `Wlink.v` (:299-307,:450-456,:1147-1153,:1958-1964) → `axi_chiplet_controller.sv` (raw :1043-1054,
2-flop CDC to apb_clk :1818-1832/:1926-1932/:2014-2026, packed into read word :2550-2558 at
`ctrl_reg_addr[2:0]==3'h6`). 0x2158 bitmap: `[0]app_ready [1]link_empty [6:2]wptr [11:7]synced_ack
[12]full [13]enable_demet [18:14]rptr [19]rreset [23:20]spare [31:24]=0xA2 marker`.

## Files to change (mirror the chain on the AXI-B branch)

| # | file | action |
|---|------|--------|
| a | `src/rtl/local_overrides/WlinkGenericFCReplayV2_5.v` (NEW) | verbatim copy of `deps/.../WlinkGenericFCReplayV2_5.v` + the 6 obs ports. **Widths NARROWER: `[3:0]` not `[4:0]`** (depth-8 FIFO; `_5.v` taps: `fifo_io_wbin_ptr[3:0]`, `a2l_link_addr_app_clk[3:0]`, `a2l_full` bit[3]/[2:0], `enable_app_clk_demet_io_out`, `link_reset`, `fifo_io_rbin_ptr[3:0]`). Copy pristine `_5`, **not** `_13` (do not drag in `_13`'s Bug-A ACK-gate). |
| b | `src/rtl/local_overrides/WlinkGenericFCSM_2.v` (NEW) | mirror FCSM_6 obs edits at the analogous lines; B replay instance is `a2l_fc_replay` (`FCSM_2.v:505`). |
| c | `src/rtl/local_overrides/AXI4ToWlink.v` (NEW — **no precedent override**) | add module out ports + wires + assigns; tap the `wlink_axibFC` instance (`AXI4ToWlink.v:605`); leave the other 4 FCSMs untouched. |
| d | `src/rtl/local_overrides/Wlink.v` (override exists) | add a parallel `obs_a2l_b_*_o` set fed from the `axi2wl` instance (`Wlink.v:1722`), mirroring the existing `tl2wl` plumbing. |
| e | `src/rtl/local_overrides/axi_chiplet_controller.sv` (override exists) | B raw wires + 2-flop sync regs + `u_wlink` connections + **a NEW Region-10 decode arm** in the read mux (`:2494-2571`; addr math `:604-628`) — slots 6 (0x2158) and 7 (0x215C) are taken and 0x2158 is fully packed, so allocate a free slot (marker byte `0x82`). |
| f | flists — repoint B-branch modules deps→override, per flist | `tidelink_fpga_v2.flist` (`_5`@:272, FCSM_2 already override@:294, AXI4ToWlink@:126); `tidelink_top_full_asic_v2.flist` (`_5`@:273, FCSM_2@:286, AXI4ToWlink@:127); + the non-v2 flists if targeted (`tidelink_fpga.flist` :203/:211/:97, `tidelink_top_full_asic.flist` :147/:159/:76). |
| g | `cocotb/tidelink_a2l_replay_cdc/` | extend to exercise `_5` (4-bit/8) obs taps; assert data path bit-identical with taps present (inert-instrument proof). |
| h | host tooling (`pynq_host/.../tl39.py`, GUI reg map) | teach the new slot address + bitmap AFTER David ratifies it. |

## Verification (before any HW)
1. `rm -rf sim_build*`; elaborate every touched flist (V2 fpga + asic).
2. Cocotb A/B: identical AW/W/B/R traffic **with vs without** the obs override — assert byte-exact data,
   FCSM path unchanged, and the new APB slot reads the expected marker + live pointers. Proves the
   instrument is functionally inert (read-only fan-out).
3. `make sim_gate` green (no regression from the register-map add).

## Asymmetries that bite (do not copy `_13` verbatim)
- `_5` pointers are **4-bit**, `_13` are 5-bit → every downstream width shrinks (wptr/rptr 4-bit fields).
- `AXI4ToWlink.v` has **no existing override** — this branch carries one extra brand-new hierarchy override.
- `_5` FIFO is `WavFIFO_8` / `AddrSync` base (vs `_13`'s `WavFIFO_20` / `AddrSync_18`); `app_data[13:0]`.
