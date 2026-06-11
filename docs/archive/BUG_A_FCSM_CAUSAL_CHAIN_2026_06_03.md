# Bug A — Full causal chain (2026-06-03, Build #22)

After 22 builds, ILA evidence from Build #22 (with continuous-AHB-write
load and dont_touch removed) finally exposes the **causal chain** for
Bug A:

## Decisive Build #22 ILA values

| Probe | Value | Notes |
|---|---|---|
| `fcsm_state` | 4 (LINK_IDLE) | Stuck, all 4096 captured cycles |
| `obs_a2l_replay_app_valid_w` | 0 | FC adapter idle (already pushed) |
| `obs_a2l_replay_link_valid_w` | **1** | **FIFO link side HAS valid data** |
| `obs_fe_rx_is_full_w` | **1** | **Slave RX appears full from master's view** |
| `obs_fe_rx_credit_max_w` | 0x1f (31) | Credit info captured from slave |
| `tl_fc_a2l_valid` | 0 | Skid empty (drained earlier) |
| `tl_fc_a2l_ready` | 1 | Wlink TX ready |

State 4→5 gate at `WlinkGenericFCSM_6.v:519`:
```verilog
_GEN_60 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? 3'h5 : state;
```
`link_valid=1`, `~is_full=0`, gate = `1 & 0 = 0` → state stays at 4.

## The chicken-and-egg

1. **POR**: `fe_rx_is_full=0`, `link_valid=0`, FCSM=4, both pointers = 0.
2. **Master pushes** the first FC word from fc_adapter via the skid.
   `link_valid=1`. FCSM transitions 4 → 5 (LINK_DATA).
3. **Master TX** drives the word out on the GPIO PHY (8 lanes, 16-bit
   word, ODDR-launched).
4. **Slave PHY lanes lock** correctly (calibrator converges 16/16,
   `SWI_LANE_STATUS = 0x018900ff`).
5. **But slave's LL_RX `llrx/valid` is 0** throughout (per Build #15
   slave ILA capture) — the bytestream from master is **NOT decoded
   into a valid packet** at the link-layer framer.
6. **Slave never consumes** any data words. The slave never sends a
   credit-return packet back to master.
7. **Master's `ne_rx_ptr`** advances on every state-4→5 transition
   (per `_GEN_59` at line 518). Master keeps pushing packets while
   it has credits.
8. **`fe_rx_ptr` stays at 0** because no credit-return packets arrive
   from slave. After ~31 pushes (`fe_rx_credit_max = 0x1f = 31`),
   `ne_rx_ptr` catches `fe_rx_ptr` modulo the credit window.
9. **`fe_rx_is_full = 1`** triggered by gray-code pointer compare.
   FCSM 4→5 gate is now permanently closed. Master can never push
   another packet.
10. **Slave RX FIFO contents stay 0**. `PKT_COMMITTED` never asserts.
    Bug A's surface symptoms.

## What's really broken

The PHY→link-layer byte-alignment / SOP-hunt logic on the slave side.
- Calibrator gives 16/16 per-lane bit lock ✅
- WavD2DGpio mux selects live data on word boundary (WORD_ALIGN_MUX=1) ✅
- BUT slave's `WlinkRxLinkLayer.llrx` framer doesn't re-hunt for SOP
  correctly after the training→data mux flip, so the first data
  packet's SOP marker is missed
- Once SOP is missed, the framer never resynchronizes
- All subsequent words look like garbage to the framer

This matches the 2026-05-24/25 documented bug (memory entry
`project_tidelink_interface_fcsm_bug_2026_05_24`). The supposed fix
landed (`WORD_ALIGN_MUX=1` in `WavD2DGpioTx.v`) but is partial — it
solves byte-alignment at the TX side but doesn't fix the slave's
LL_RX SOP-hunt after the training-data transition.

## Wrong fixes tried (now retrospectively explainable)

- **L7/L8/L9/F-1** (NACK class): the slave isn't even decoding packets,
  so it never generates NACKs to begin with. These were chasing a
  symptom that doesn't manifest.
- **L11** (master TX watchdog): masks the wedge from blocking PYNQ,
  but doesn't address the slave-RX upstream root cause.
- **L13/L13v2** (hwdata sampling): the payload IS formed correctly at
  master TX (Build #15 ILA confirmed `tx_fc_word = 0x0004_cafe_000f`).
  Wrong layer.

## Next-step fix candidates

1. **Slave LL_RX hunt-for-SOP fix**: ensure that after a training-mode
   transition (mux flip from training pattern to live data), the slave's
   framer resets its SOP search state and waits for the next valid SOP.
   Source: `src/rtl/local_overrides/WlinkRxLinkLayer.v` (already a
   local override from prior tdif-08 fix).

2. **Per-lane re-sync**: instead of word-boundary mux flip, force a
   training→data transition that includes an explicit SOP frame so the
   slave's framer doesn't have to guess.

3. **SW workaround**: after slave deploys + lanes lock, send a "wake
   SOP" sequence from master to bootstrap the slave's framer. Could
   be done via a special bringup script.

## Files changed for observability (Build #17–#22)

- `src/rtl/local_overrides/WlinkGenericFCSM_6.v` — 4 new io_obs ports
  (a2l_replay_link_valid, fe_rx_credit_max, fe_rx_is_full, app_valid)
- `src/rtl/local_overrides/TideLinkToWlink.v` — new local override
  with port pass-through
- `src/rtl/local_overrides/Wlink.v` — 4 obs_*_o ports + wires + tl2wl
  instance wiring + assigns
- `src/rtl/local_overrides/axi_chiplet_controller.sv` — 4 outputs +
  CDC sync flops with mark_debug (no dont_touch needed)
- `src/rtl/tidelink_top.sv` — 4 wires with mark_debug + instance
  wiring
- `flist/tidelink_fpga.flist` — TideLinkToWlink entry → local_overrides

**Critical gotcha**: when using `SKIP_PACKAGE_IP=1`, after editing
`src/rtl/local_overrides/*.sv`, must manually copy them into both:
- `imp/fpga/tidelink_ip/src/`
- `imp/fpga/project/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_project.gen/sources_1/bd/tidelink_design/ipshared/40ad/src/`

Otherwise IP synth uses the stale cached version and edits do nothing.

## Bit SHAs

- Build #22 master `.bit`: see `imp/fpga/output/...mmcmbypass-oddr-all/tidelink.bit` (Jun 3 04:08)
- Build #22 master `.bin`: `dff9d5b864ca…` (matches Build #21 — dont_touch was redundant)
- Build #22 slave `.bin`: `b3d4d453a609…`

## ILA artifacts (mapstone-dev)

- Build #22 master ILA CSV: `/tmp/buga_ila_b22/master/phc_ila_master_*.csv`
- Build #21 master ILA CSV: `/tmp/buga_ila_b21/master/phc_ila_master_20260603_032348.csv`
- Build #20 master ILA CSV: `/tmp/buga_ila_b20/master/phc_ila_master_20260603_022033.csv`
