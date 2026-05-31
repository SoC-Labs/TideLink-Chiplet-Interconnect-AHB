# Autoneg HW failure diagnosis — v3 build → ST_ERROR on both dies

**Branch:** `feat/td-autonomy` (worktree `/home/dam1n19/SoCLabs/td-bisect/td-autonomy/`)
**Date:** 2026-05-30
**HEAD probed:** `deae762`  (build v3 deployed at `8296697` per parent brief)
**Verdict:** **(d) Bitstream-level integration gap — I²C SCL/SDA are NOT wired to any FPGA pin on this branch's PYNQ-Z2 pair targets. NOT an autoneg-RTL bug.**

## TL;DR

The autoneg FSM is doing exactly what its design requires when the I²C bus is electrically inert: both dies wait for backoff, both attempt to claim the bus over I²C, neither sees any peer traffic, both eventually time out (`nego_timeout_reg = 131_082_000` cycles ≈ 2.6 s @ 50 MHz), and both fall back to `nego_role = nego_fallback = master` with `nego_force_lock=1`. Result: both dies sit in `ST_ERROR` with `ROLE_CFG=0x02` (lock=1, cfg=master).

The fault is NOT in the RTL. It is that the v3 bitstream **has no `i2c_scl_i` / `i2c_sda_i` net connected** — the `tidelink_0/i2c_scl_i`, `tidelink_0/i2c_sda_i` block-design pins are unconnected, which Vivado synthesises as a logic-0 input. The autoneg I²C master is therefore driving onto a bus whose input side is permanently held low; START is never generated as an externally observable edge, `sda_start_seen` stays 0, no I²C transaction ever completes, and the timeout path fires.

**RTL fix is NOT required.** The recovery is at the FPGA-target integration layer (XDC + BD).

## Probe data (verbatim)

### die_a / z2_02 @ 192.168.4.101 (post-deploy +1 min)

```
---- Region 4 (chiplet controller @0x44032080..0x4403209C) ----
  0x080 ROLE_CFG           = 0x00000002  lock=1 cfg=0
  0x084 I2C_SLV_STS        = 0x00000002  addressed=0 slv_busy=0 role_locked=1 role_effective=0
  0x088 I2C_SLV_ADDR       = 0x0000007e  (0x7e)
  0x08C I2C_PRESCALE       = 0x0000007d  (125)
  0x090 NEGO_CFG           = 0x00000061  en=1 start=0 pri_sel=0 fallback=0 force_lock=1 mask_hs_auto=1
  0x094 NEGO_STATUS        = 0x00000027  state=7 (ST_ERROR) done=0 error=1 won=0 lost=0 sda_start=0 mask_mm=0
  0x098 NEGO_PRIORITY      = 0x0000ffff
  0x09C NEGO_TIMEOUT       = 0x07d02710  (131082000)
---- Region 8 (chiplet controller @0x440320A0..0x440320BC) ----
  0x440320a0..0x440320bc = 0x00000000 (all eight registers; training never entered)
```

(2-second NEGO_STATUS trace shows no change: terminal ST_ERROR.)

### die_b / z2_03 @ 192.168.6.101 (identical)

```
ROLE_CFG=0x02   NEGO_CFG=0x61   NEGO_STATUS=0x027   NEGO_PRIORITY=0xFFFF
NEGO_TIMEOUT=0x07d02710  Region 8 all zero.
```

### Decode of NEGO_STATUS layout (from axi_chiplet_controller.sv:705)

```
{22'd0, mask_mm[9], sda_start[8], lost[7], won[6], error[5], done[4], state[3:0]}
```

0x027 = state=7 (ST_ERROR), done=0, error=1, won=0, lost=0, sda_start=0, mask_mm=0.

This is the **timeout-fallback** path (autoneg FSM line 569-586): when timeout_ctr_r reaches 0 in any non-terminal state, `nego_error_nxt=1`, `nego_role_nxt = nego_fallback`, `nego_set_role_cfg=1`, `state_nxt = ST_ERROR`. `nego_done_nxt` is NOT set by this path (intentional — done is reserved for the won/lost paths).

`nego_fallback = NEGO_CFG_RESET[4] = 0` (master) and `nego_force_lock = NEGO_CFG_RESET[5] = 1`, which exactly produces the observed `ROLE_CFG=0x02` (lock=1, cfg=master) on both dies. `sda_start_seen=0` confirms neither die ever observed an externally driven START on the I²C bus.

## Failure point — bitstream level, not RTL

### Searched: i2c_scl_i / i2c_sda_i wiring across `fpga/targets/`

```
$ grep -rn "i2c_scl_i\|i2c_sda_i" fpga/targets/  | grep -v mps3
(no output — only the mps3 target wires these signals)
```

The PYNQ-Z2 pair targets `pynq-z2-pair-all` and `pynq-z2-pair-flip-all` (and every flip / ila / slow / mmcmbypass variant for the pair) leave `tidelink_0/i2c_scl_i` and `tidelink_0/i2c_sda_i` **unconnected in the block design**. The `tidelink_design_wrapper.v` for these targets has no `i2c_scl` / `i2c_sda` ports and the wrapper comment-block at lines 23-24 explicitly states:

> // - I2C sideband: scl_i/sda_i pulled high (open-drain idle state)

— but this is a description of intended behaviour, **not** an instantiated tie-off in the BD. There is no `xlconstant` cell driving these pins to 1, and no `assign … = 1'b1;` in the wrapper. Vivado synthesises an unconnected BD input port as a default-0 net (confirmed by the `tidelink.hwh` content — both ports listed with no child SIGNAL/CONNECTION elements). The BD tcl file itself even calls this out at lines 408-411:

> // Until the I2C jumpers are in place, the link will hang waiting for the handshake.
> // Use apb_debug_unlock_i (existing strap) for emergency local bring-up that doesn't require peer coordination.

### Why `feat/i2c-autonomous-lock-integ` worked but `feat/td-autonomy` does not

The previous validation work referenced in memory `project_tidelink_i2c_autonomy.md` (autoneg PASS on silicon at `feat/i2c-autonomous-lock-integ @ a657306`) was done on a branch that contained commits **`7a1a2b3`** ("xdc: fix build-safe guard … make i2c pins unconditional") and **`3de5ebe`** ("xdc: repin i2c off-ribbon to Arduino dedicated I2C (P15/P16)"). Those two commits add:

- A BD-side edit that exposes `i2c_scl_io` and `i2c_sda_io` as external ports on `pynq-z2-pair-all` and `pynq-z2-pair-flip-all`.
- XDC PACKAGE_PIN constraints on P15 (SCL) and P16 (SDA), which are the Arduino dedicated I²C pads with on-board pull-up resistors fitted on the PYNQ-Z2 PCB.

Neither `7a1a2b3` nor `3de5ebe` is in `feat/td-autonomy`'s commit ancestry:

```
$ git log --oneline feat/td-autonomy -- "fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc"
affc4f8  fpga(pynq-z2-pair-all): split DRC waivers into separate xdc + cleanup
5cbbc0f  fpga(pair-all): mirror PHC IP + PMOD-B trigger onto -all variant
5d34baf  fpga: lane-7 remap B19/F20 -> spare W9/V7 (v4 diag confirmed pin-bad)
794313e  STEP 1: trunk §9 base — autocal calibrator @ interim 0x4403_1000
30dc14c  fpga: extra pynq-z2 target variants + ribbon-wiring update
```

The lane-7 remap (`5d34baf`) repurposed W9/V7 — which were the ORIGINAL I²C pins on `feat/i2c-autonomous-lock-integ` — for `pad_tx[7]/pad_rx[7]`. The follow-up to move I²C to P15/P16 (`3de5ebe`) never made it onto `feat/td-autonomy`. **This is a branch-merge gap.**

## Proposed remediation

Three options, in increasing effort and decreasing risk:

### Option 1 — `apb_debug_unlock_i` poke (script-side, no rebuild, BUT does not save autoneg)

Re-add the `apb_debug_unlock_i` GPIO=1 write to `deploy_pair.sh` (the Phase 4 deletion). This forces `mask_hs_gate_open=1` regardless of mask-handshake status. **However** the autoneg FSM has already terminated at ST_ERROR by the time the script gets to issue the write; ST_ERROR is a terminal state in the FSM with no exit transition (axi_chiplet_controller / tidelink_autoneg.sv:1164-1166). So this alone does NOT recover the link — `role_lock` would still need the legacy ROLE_CFG W1S path. Net effect: this regresses Phase 3+4 autonomy.

**Not recommended for v3 validation.** It defeats the whole point of v3 (which is to demonstrate autoneg → lock → train without SW writes).

### Option 2 — Cherry-pick BD-Edit-1 + XDC fixes (FPGA target fix, requires rebuild)

This is the **right fix**. Pull THREE commits onto `feat/td-autonomy`:

```
git cherry-pick a1acd8b   # bd: BD Edit 1 — expose I2C as IOBUF'd top ports
git cherry-pick 7a1a2b3   # xdc: drop Tcl `if` guard (broken in XDC dialect)
git cherry-pick 3de5ebe   # xdc: repin i2c -> P15/P16 (Arduino pads, on-PCB pull-ups)
```

These edits add:
- `i2c_scl_io` / `i2c_sda_io` external ports to the block design (touches `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl` and the `-flip-all` mirror; `a1acd8b`).
- `tidelink_design_wrapper.v` `inout` ports + IOBUF tie-off pair to drive `i2c_scl_i`/`i2c_scl_o`/`i2c_scl_t` and same for SDA (`a1acd8b`).
- `pynq_z2_tidelink.xdc` PACKAGE_PIN constraints (`3de5ebe`):
  - `set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports i2c_scl_io]`
  - `set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports i2c_sda_io]`
  - PULLUP omitted because TUL's on-PCB pull-up resistors dominate.

Plus the physical operator step: a 3-wire Dupont harness between the two boards' Arduino shield headers (SDA↔SDA on P16, SCL↔SCL on P15, GND↔GND). Both boards must run with the Arduino shield card UN-populated (would contend with the bus). The memory entry `project_tidelink_i2c_autonomy.md` confirms this works on silicon when wired up.

**Effort:** ~2 h to apply the three cherry-picks, resolve any conflicts (the diffs look mostly additive over the lane-7-remap context already on `feat/td-autonomy` — `3de5ebe`'s commit message even calls out that the P15/P16 choice was made *because* it doesn't collide with lane-7 W9/V7), validate the BD, and run synthesis + place + route. **Requires a fresh bitstream build.** Build v4 already running at `deae762` needs to be killed and restarted at the post-cherry-pick HEAD.

### Option 3 — Re-introduce static SW init in deploy_pair.sh (regresses Phases 3-5)

Restore the pre-Phase-3 deploy_pair.sh that wrote ROLE_CFG W1S + apb_debug_unlock=1 + Wlink 0x208 swreset + PAIR_BASE_ADDR. This brings the link up but does NOT exercise the autoneg path on hardware — same RTL works, but you cannot claim autonomy until the I²C wiring is restored.

Useful only as an **interim bring-up** to unblock other downstream work (PHC, etc) while the proper Option-2 build is being prepared.

## Recommendation

**Kill build v4.** Apply Option 2 (cherry-pick `7a1a2b3` + `3de5ebe`) on `feat/td-autonomy`, then start v5 build. While that builds, optionally deploy v3 with the Option-3 legacy script so downstream agents stay unblocked.

Sim (cocotb tidelink_top_pair) has no I²C-wiring gap (the testbench in tb_top.sv:205-209 already does the open-drain wire-AND between the two dies), which is exactly why test_10 reaches `train_ok=1` while the HW deploy times out.

## Files / commits referenced

- Probe data: `/tmp/probe_autoneg_full.py` (staged on z2_02 and z2_03 at `/tmp/probe_autoneg_full.py`)
- Autoneg FSM source: `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv` lines 569-586 (timeout fallback), 580 (`nego_role_nxt = nego_fallback`), 1164-1166 (`ST_ERROR` is terminal).
- BD tcl with i2c-tied-off note: `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl` lines 87-89, 408-411.
- Wrapper without i2c ports: `fpga/targets/pynq-z2-pair-all/tidelink_design_wrapper.v` lines 23-24 (descriptive only — no actual tie-off in this file).
- Missing commits on this branch: `a1acd8b` (BD Edit 1 — IOBUF tie + external ports), `7a1a2b3` (XDC `if`-guard fix), `3de5ebe` (repin i2c → P15/P16). All three reachable on `feat/i2c-autonomous-lock-integ` ancestry.
- HW lease state: `bridge1` held by mapstone-dev (parent session).
