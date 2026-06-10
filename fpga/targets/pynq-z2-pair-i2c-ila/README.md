# pynq-z2-pair-i2c-ila

I²C-instrumented PYNQ-Z2 pair target — master die clone of `pynq-z2-pair-all`
with an inserted ILA debug core targeting the chiplet autoneg / I²C-master
path.

Investigates Bug N7/N8: on silicon the master FSM reaches ST_NEGO_CLAIM →
ST_NEGO_POLL → ST_ERROR on autoneg timeout, but `obs_i2c_mst_status.busy_int`
never rises during the 8 s probe window. This target adds a ~28-probe
ILA to the master die so the FSM ↔ AXIL ↔ i2c_master ↔ I²C-bus chain can be
correlated cycle-by-cycle on hardware.

## Probes (via `(* mark_debug = "true" *)`)

| Group | Signal | Width | Source file |
| ----- | ------ | ----- | ----------- |
| AXIL→core cmd shadow | `cmd_address_reg` | 7 | `src/rtl/local_overrides/i2c_master_axil.v` |
| | `cmd_start_reg` | 1 | |
| | `cmd_write_reg` | 1 | |
| | `cmd_stop_reg` | 1 | |
| | `cmd_valid_reg` | 1 | |
| | `prescale_reg` | 16 | |
| FIFO output | `cmd_valid_int` | 1 | |
| | `cmd_ready_int` | 1 | |
| i2c_master core FSM | `state_reg` | 5 | `src/rtl/local_overrides/i2c_master.v` |
| | `phy_state_reg` | 5 | |
| | `bus_active_reg` | 1 | |
| | `s_axis_cmd_ready_reg` | 1 | |
| | `start_bit` | 1 | |
| | `stop_bit` | 1 | |
| Autoneg ↔ I²C bus arb | `nego_state_w` | 4 | `src/rtl/local_overrides/axi_chiplet_controller.sv` |
| | `nego_driving` | 1 | |
| | `fsm_axil_awvalid` | 1 | |
| | `fsm_axil_awaddr` | 8 | |
| | `fsm_axil_wdata` | 32 | |
| | `mst_axil_bvalid` | 1 | |
| | `mst_axil_arready` | 1 | |
| | `mst_axil_rvalid` | 1 | |
| | `mst_axil_rdata` | 32 | |
| Autoneg AXL sub-FSM | `axl_state_r` | 3 | `src/rtl/local_overrides/tidelink_autoneg.sv` |
| | `txn_step_r` | 3 | |
| | `axl_done_r` | 1 | |
| Top-wrapper I²C bus | `i2c_scl_i_int` | 1 | `tidelink_design_wrapper.v` |
| | `i2c_scl_o_int` | 1 | |
| | `i2c_scl_t_int` | 1 | |
| | `i2c_sda_i_int` | 1 | |
| | `i2c_sda_o_int` | 1 | |
| | `i2c_sda_t_int` | 1 | |

Total: ~28 probes, ~99 bits. `C_DATA_DEPTH = 4096` (inherited from
`fpga/insert_debug_core.tcl`). At hclk = 50 MHz that's ~82 µs of capture per
arm — short for the 8 s autoneg timeout, so trigger position must be set
right at the entry edge.

## Recommended trigger (set at HW Manager / cap-script time)

Trigger on `nego_state_w` rising-edge to 4'd3 (ST_NEGO_CLAIM).
Suggested window-position 25 % (1024 pre, 3072 post) so the captured window
straddles the ST_NEGO_WAIT → ST_NEGO_CLAIM boundary.

## Build

```
cd /home/dam1n19/SoCLabs/td-bisect/td-autonomy
source ./set_env.sh
FPGA_INSERT_DEBUG_CORE=1 make -C fpga build_design TARGET=pynq-z2-pair-i2c-ila
```

The master-die clone is `pynq-z2-pair-i2c-ila`; the slave die can stay on
`pynq-z2-pair-flip-all` (it's in BYPASS / ERROR — only master needs the ILA).

## Notes

The `mark_debug` attributes in `local_overrides/` are inert for all other
targets unless `FPGA_INSERT_DEBUG_CORE=1` is exported — only this i2c-ila
target sets that env at build time. The base of this target is a literal
clone of `pynq-z2-pair-all/` (same XDC, same BD TCL); the ILA is purely
additive via `mark_debug` + post-synth `insert_debug_core.tcl`.
