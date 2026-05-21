# AUTOCAL_ENABLE Parameter Trace — tidelink_top → u_calibrator

Worktree: `/home/dam1n19/td_idelay_wt`
Parent commit: `40ca58c` (bisect: restore src/rtl + fpga/vivado_ip + flists to morning 8bc6051 state)
Submodule: `deps/axi-chiplet-controller @ a55d346` (feat/i2c-autonomous-lock)
Date: 2026-05-21

## TL;DR

**AUTOCAL_ENABLE reaches `u_calibrator` as `1` on the FPGA build.** No fix required.

The hard-coded `1'b1` is applied at the `axi_chiplet_controller` instantiation in
`tidelink_top.sv:1365` (a *parameter override at the instance*, not a parameter
forwarding from a higher level). It therefore short-circuits the FPGA wrapper
chain — the value reaches the calibrator regardless of whether the wrapper /
IP / BD expose the parameter.

## Parameter chain (4 levels)

| Level | File:line | What happens |
|-------|-----------|--------------|
| 0. BD instance | `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl:287` | `create_bd_cell ... tidelink_vivado_wrapper:1.0 tidelink_0` — **no** `AUTOCAL_ENABLE` set_property (the IP component doesn't expose it). |
| 1. IP / wrapper | `fpga/vivado_ip/tidelink_vivado_wrapper.v:42-53` | Declares `SYS_*`, `RAM_*`, `FC_DATA_W`, `NUM_PHY_LANES`, `TIDELINK_PAIR_BASE`, `PHC_LOCK_GATE_EN`. **No** `AUTOCAL_ENABLE` parameter — neither declared nor passed to `tidelink_top`. |
| 2. tidelink_top | `src/rtl/tidelink_top.sv:1364-1366` | `axi_chiplet_controller #(.AUTOCAL_ENABLE(1'b1)) u_chiplet_controller (...)` — **hard-coded 1 at the instance**, not a parameter forwarding. This is the binding site. |
| 3. axi_chiplet_controller | `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:29` | `parameter AUTOCAL_ENABLE = 1'b0` — default 0 is overridden to 1 by level-2. |
| 4. autocal_enable_w | `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:1036-1037` | `wire autocal_enable_w = AUTOCAL_ENABLE \| autocal_force_enable_q;` → `calibrator_role_locked = role_locked & autocal_enable_w;` → fed to `u_calibrator.role_locked` (line 1042). With `AUTOCAL_ENABLE=1`, `autocal_enable_w` is constant `1`, so `calibrator_role_locked == role_locked`. |

## Why the missing wrapper/IP/BD propagation does not break it

A `defparam`-style instance override (`#(.AUTOCAL_ENABLE(1'b1))`) is evaluated
**at elaboration of the parent** (`tidelink_top`). It only requires that the
*child* module (`axi_chiplet_controller`) declare the parameter — which it
does. The wrapper above `tidelink_top` does **not** need to know about
`AUTOCAL_ENABLE` for the override to take effect; it just needs to elaborate
`tidelink_top` normally, which it does.

This is unlike the `#(.AUTOCAL_ENABLE(SOMETHING))` *forwarding* pattern, which
would require every level above to declare and pass the parameter.

## Synthesis-log confirmation

`imp/fpga/project/pynq-z2-pair-all/tidelink_project.runs/tidelink_design_tidelink_0_0_synth_1/runme.log`:

- `INFO: [Synth 8-6157] synthesizing module 'axi_chiplet_controller' [...axi_chiplet_controller.sv:22]` — elaborated.
- `INFO: [Synth 8-6157] synthesizing module 'tidelink_phy_align_calibrator' [...tidelink_phy_align_calibrator.sv:99]` — calibrator was instantiated (not optimized away as dead code, which would happen if `calibrator_role_locked` were a constant 0 and the whole sub-tree got swept).
- `INFO: [Synth 8-3333] propagating constant 0 across sequential element (u_calibrator/swreset_q_reg)` — this is the **swreset** input (tied to `1'b0` at `axi_chiplet_controller.sv:1047`), **not** `role_locked`. The fact that only `swreset_q_reg` is constant-propagated (not the entire calibrator state) is positive evidence that `role_locked` is *not* a synthesis-time constant 0 — i.e. `autocal_enable_w` is 1, not 0.

No `[Synth 8-3917]` "removed sequential element" warnings for `u_calibrator/cur_state_reg` either — the FSM survived.

## grep audit

```
$ grep -rn AUTOCAL_ENABLE fpga/ src/rtl/ deps/axi-chiplet-controller/logical/
deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:29:    parameter AUTOCAL_ENABLE = 1'b0
deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:1024:    // Calibrator role_locked trigger: gated by AUTOCAL_ENABLE (parameter,
deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:1036:    wire autocal_enable_w        = AUTOCAL_ENABLE | autocal_force_enable_q;
src/rtl/tidelink_top.sv:1365:        .AUTOCAL_ENABLE(1'b1)
```

Two sites, exactly as the brief describes. No surprise overrides in the FPGA tree.

## Verdict

`AUTOCAL_ENABLE` reaches `u_calibrator` as **`1`** on the synthesized FPGA build for `pynq-z2-pair-all` (and by extension all pair variants, since they all instantiate `tidelink_vivado_wrapper:1.0` the same way). The calibrator FSM runs immediately after `role_locked` rises.

## Recommended fix

**None required for FPGA bring-up.** The parameter does reach the calibrator.

### Optional hardening (post-bring-up, not for this branch)

If a future scenario needs to *disable* autocal on FPGA without an RTL change
(e.g. to A/B-test the calibrator against pure SW bit-slip), one of:

1. **Wrapper / IP exposure** — add `parameter AUTOCAL_ENABLE = 1'b1` to
   `tidelink_vivado_wrapper.v` (default 1 to preserve current behaviour),
   pass it into `tidelink_top` (which would also need to gain the param and
   forward it to `u_chiplet_controller` instead of hard-coding `1'b1`),
   then re-package the IP so the BD can `set_property CONFIG.AUTOCAL_ENABLE`.
   ~3 levels of plumbing — defer until needed.

2. **SW APB-writable register** — wire `autocal_force_enable_q` to a new bit
   in the APB control register, so SW can flip it at runtime. Lower-overhead
   than (1) but requires a register map change.

Neither is needed right now — the calibrator is already enabled, which is
the intended bring-up state.
