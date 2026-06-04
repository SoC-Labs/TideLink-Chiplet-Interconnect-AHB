# Bug A — FCSM state-4 gate decisive ILA evidence (2026-06-03)

## Build #20 ILA capture: master, post-bringup, post-AHB-write

After 20 builds, finally got direct ILA visibility into the FCSM 4→5
transition gate signals. The breakthrough was discovering that
`SKIP_PACKAGE_IP=1` was using a stale IP source cache at
`imp/fpga/tidelink_ip/src/` — refreshing it manually plus copying into
`imp/fpga/project/.../ipshared/40ad/src/` got the new probes into the
.ltx (73 probes vs the prior 68).

## Decisive probe values (all stable for 4096 captured cycles)

| Probe (path under `u_tidelink_top/`) | Value | Width |
|---|---|---|
| `u_chiplet_controller/u_wlink/tl2wl_io_obs_fcsm_state` | **4 (LINK_IDLE)** | [2:0] |
| `obs_a2l_replay_link_valid_w` | **0** | 1 |
| `obs_fe_rx_is_full_w` | **0** | 1 |
| `obs_fe_rx_credit_max_w` | **0x1f (31)** | [7:0] |
| `tl_fc_a2l_valid` | 0 | 1 |
| `tl_fc_a2l_ready` | 1 | 1 |
| `u_chiplet_controller/sync_obs_a2l_replay_v_1` (apb_clk) | 0 | 1 |
| `u_chiplet_controller/sync_obs_fe_rx_full_1` (apb_clk) | 0 | 1 |
| `u_chiplet_controller/sync_obs_fe_rx_cred_1` (apb_clk) | 0x1f | [7:0] |

## What this proves

The state-4 → state-5 transition gate in `WlinkGenericFCSM_6.v:519`:
```verilog
wire [2:0] _GEN_60 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? 3'h5 : state;
```

- `~fe_rx_is_full = 1` ✅ — slave's RX side has buffer space
- `fe_rx_credit_max = 0x1f (31)` ✅ — slave's CR/CRACK credit info captured cleanly
- `a2l_fc_replay_link_valid = 0` ❌ — **THE BLOCKER**

So the FCSM is permanently stuck because the **app→link FIFO has no
valid data on its link side**.

## The deeper question

`a2l_fc_replay_link_valid` is the link-clock-domain read side of an
async FIFO that takes `io_app_a2l_valid` pulses (the master fc_adapter's
`tl_fc_a2l_valid`) on its write side.

For the FIFO link side to have data, the write side must have pushed
something. The write enable is gated by `io_app_enable` = `swi_enable`
(set to 1 at POR via Wlink.v:2229). So the FIFO is enabled.

In Build #20, `tl_fc_a2l_valid = 0` constantly — master fc_adapter
isn't producing valid. But this is the OPPOSITE of Build #15 where
`tl_fc_a2l_valid = 1` (skid loaded, but `tl_fc_a2l_ready = 0`). So
Bug A presents differently across builds:
- Build #15: master skid LOADED, wlink TX refusing
- Build #20: master skid EMPTY (likely caused by my observability
  changes affecting timing/routing of the master AHB path)

The probe evidence from Build #20 is still valid for diagnosis: even
if Build #20's master TX path is broken, the FCSM state and FIFO link
side are diagnosed cleanly.

## Hypothesis for the fix

Two candidates (need disambiguation with more ILA):

**(A) async FIFO CDC bug.** The `a2l_fc_replay` FIFO's app→link CDC
might be losing valid pulses. The data write completes on app clock
but the link-side read pointer doesn't advance, leaving link.valid = 0
forever. Fix would be in the FIFO implementation — likely
`wlink_WavFIFOMem.v` / `wlink_WavFIFOPtrLogic.v`.

**(B) swi_enable transient drop.** If `swi_enable` momentarily drops
during bringup (e.g., via bringup_pair_converge.sh's slot0=0x3 recal
poke), the FIFO write side gets disabled. Subsequent writes are
ignored. The FIFO link side stays empty. Fix: lockout writes to
`swi_enable` during normal operation OR re-enable post-bringup.

To distinguish: add ILA on `swi_enable` (single bit at
`Wlink.v` top level — easy hook) and `a2l_fc_replay_app_valid` (already
in scope but not at top).

## Observability infrastructure changes (Build #17–#20)

5 files changed to thread observation ports up from
`WlinkGenericFCSM_6.v` to `tidelink_top.sv`:
- `src/rtl/local_overrides/WlinkGenericFCSM_6.v`: added 3 output ports
- `src/rtl/local_overrides/TideLinkToWlink.v` (new local override):
  added pass-through ports
- `src/rtl/local_overrides/Wlink.v`: added module-level ports +
  internal wires + tl2wl instance wiring + output assigns
- `src/rtl/local_overrides/axi_chiplet_controller.sv`: added 3
  outputs + sync CDC flops with `(* mark_debug, dont_touch *)`
- `src/rtl/tidelink_top.sv`: added wires with
  `(* mark_debug, dont_touch, keep *)` + instance wiring

Also `flist/tidelink_fpga.flist`: replaced deps TideLinkToWlink.v
entry with local_overrides version.

**Critical**: the observation chain works ONLY if
`imp/fpga/tidelink_ip/src/` mirrors the edited sources. After source
edits, run package_ip OR manually copy:
```
for f in src/rtl/local_overrides/{axi_chiplet_controller.sv,Wlink.v,WlinkGenericFCSM_6.v,TideLinkToWlink.v} src/rtl/tidelink_top.sv; do
  cp $f imp/fpga/tidelink_ip/src/$(basename $f)
  cp $f imp/fpga/project/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_project.gen/sources_1/bd/tidelink_design/ipshared/40ad/src/$(basename $f)
done
```

## Build #20 bit SHAs

- master `.bit`: see `imp/fpga/output/pynq-z2-pair-mmcmbypass-oddr-all/tidelink.bit` (Jun 3 02:17)
- slave `.bit`: see `imp/fpga/output/pynq-z2-pair-mmcmbypass-oddr-flip-all/tidelink.bit` (see Build #20 watcher log)
- master `.bin`: master deploy SHA `4f18a3503a30…`
- slave `.bin`: slave deploy SHA `59d4cb366305…`
- master `.ltx`: 73 probes (vs prior 68), uuid `8c7a4108cecd5b94…`

## Next step

Hypothesis (A) test: ILA on `a2l_fc_replay_app_valid` (Wlink-internal
write side of the FIFO). If we see write side firing but link side
not, the FIFO CDC is broken. If write side never fires, fc_adapter
isn't pushing.

Hypothesis (B) test: ILA on `swi_enable`. If it drops mid-bringup,
that's the bug.

Both probes are easier to add (single-bit, mark_debug at Wlink.v scope,
no CDC needed since they're already in app/apb domain).

But first — the master TX path regression caused by Build #20's
observability needs to be understood. Master fc_adapter `tl_fc_a2l_valid`
should fire when PYNQ does AHB writes. In Build #20 it doesn't.
Either:
- L11 watchdog is dropping everything
- The added obs ports caused worse P&R, breaking AHB timing
- PYNQ AHB writes aren't actually reaching fc_adapter

Recommend: revert tidelink_top.sv observability wires (back to clean
state); keep the Wlink-internal observation pass-throughs (they
don't drive functional logic). Then debug master TX in isolation.
