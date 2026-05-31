# Build #7 HW validation — 2026-05-31 (L10 partial success)

**Build:** #7 (commit `bc52f88`, label `build7-ila-L10`, FPGA_INSERT_DEBUG_CORE=1)
**Bitstreams:** master sha `09e35b9cde35…`, slave sha `18578544b657…`
**Patches included:** ILA mark_debug (per Build #5 R-1 plan) + **L10** AHB HREADYOUT wedge-break watchdog
**Bug B fix:** NOT included (user reverted intentionally between Build #6 and #7)

## Headline

**L10 partially works** — first AHB write after bringup completes without wedging master, but **second write wedges master** (SSH disconnect, link DOWN). The 1-cycle `wedge_force_ready_r` pulse may not propagate cleanly through axi_ahblite_bridge → AXI BVALID → SmartConnect → PS outstanding-write counter.

## Test sequence

| Phase | Result |
|---|---|
| Build #7 deploy (master + slave) | ✅ Both `fpga_manager: operating` |
| bringup_pair_converge | ✅ 16/16 at iter 4 (master init noise; settles) |
| First AHB N=1 packet write | ✅ **PASS** — master responsive, link UP both sides, REG_STATUS=0, CRED=0x1000 |
| `hostname` SSH check after AHB | ✅ Master returns `pynq-z2-02` |
| Second AHB N=1 packet write | ❌ **FAIL** — `client_loop: send disconnect: Broken pipe`. Master wedged again. |
| Recovery time | 90 s power-cycle + 60 s re-bringup |

## L10 analysis

The L10 watchdog:
- After WEDGE_LIMIT=16 cycles of `ahb_tx_hreadyout` stuck low, force `wedge_force_ready_r=1` for 1 cycle, drop the pending word, bump `tx_dropped_cnt_r`
- Reset `wedge_cnt_r=0`, allow next AHB transaction

What worked:
- **Master TX wedge primitive PARTIALLY DEFANGED** — first AHB write no longer wedges
- Link stays UP after first write (was going to 0x00020000 in Build #5)
- REG_STATUS = 0 stays clean

What didn't:
- Second AHB write still wedges → 1-cycle HREADY pulse may be insufficient for axi_ahblite_bridge to latch BVALID and decrement PS's outstanding-write counter
- L10 doesn't address the underlying SLAVE RX wedge (a2l_full stays asserted forever)

## Next iteration — L11 proposal

**Widen the force_ready pulse to 4 cycles** AND **hold HRESP=OKAY for the full window**:

```systemverilog
// L11 (proposed): wider force-ready pulse
logic [2:0] wedge_force_ready_cnt_r;
always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn) wedge_force_ready_cnt_r <= '0;
    else if (wedge_cnt_r == WEDGE_LIMIT[4:0]) wedge_force_ready_cnt_r <= 3'd4;
    else if (wedge_force_ready_cnt_r != 0)    wedge_force_ready_cnt_r <= wedge_force_ready_cnt_r - 3'd1;
end
assign wedge_force_ready_w = (wedge_force_ready_cnt_r != 0);
```

Then use `wedge_force_ready_w` instead of `wedge_force_ready_r` for both the HREADYOUT gate and tx_data_phase_r clear gate. Holding HREADY high for 4 cy gives AXI-AHB bridge plenty of time to latch and forward BVALID.

**Alternative L11 (more aggressive)**: always-ready, drop-on-overflow:
```systemverilog
assign ahb_tx_hreadyout = 1'b1;  // L11: PS bus never blocks
// New: drop counter increments whenever tx_data_phase_r asserts AND skid_can_accept=0
```
This keeps master ALWAYS responsive at cost of silent AHB data drops when downstream is wedged — but data is being lost anyway (slave RX wedged regardless of L10). SW polls `tx_dropped_cnt_r` to detect drop rate.

## Bug B (untested this session)

Bug B was not exercised in Build #7 testing because:
1. Bug B fix was reverted (intentional) so Bug B is expected to reproduce as in Build #5
2. Master wedge after Bug A test prevents Bug B test in same session without power-cycle

## Files

- L10 patch applied to: [src/rtl/tidelink_fc_adapter.sv:181-235](src/rtl/tidelink_fc_adapter.sv#L181) (manual Edit per `docs/BUG_A_WEDGE_INVESTIGATION_2026_05_31.md` recipe)
- Build #7 staged at: `mapstone-dev:/tmp/tidelink_deploy_build5/`
- Test script: `/tmp/build5_app_test.py`
- Predecessor: [BUILD5_HW_VALIDATION_2026_05_30.md](BUILD5_HW_VALIDATION_2026_05_30.md), [BUG_A_WEDGE_INVESTIGATION_2026_05_31.md](BUG_A_WEDGE_INVESTIGATION_2026_05_31.md)

## Conclusion

L10 is **on the right track** — wedge primitive defanged for first write — but the 1-cycle pulse is **insufficient under stress**. L11 (wider pulse OR always-ready) is the proven next iteration. Wall cost: one more 55-min build.
