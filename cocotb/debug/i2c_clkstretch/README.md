# cocotb/i2c_clkstretch — SHORTCOMINGS-14a repro + fix

Wires the **real** `i2c_master_axil` and `i2c_slave_axil_master` cores
together over a modelled open-drain (wired-AND) I2C bus — the same bus
model as `uvm/tidelink_top_system/tb/top.sv` — with a latency-injecting
AXIL target behind the slave bridge. This isolates the SHORTCOMINGS-14a
multi-byte I2C wedge from the full chiplet system.

The slave bridge issues one AXIL word write per 16 I2C data bytes (or at
STOP) and parks until the slow AXIL `B`. While parked it back-pressures
the I2C slave core, which holds SCL low to **clock-stretch**. The TB's
`+SCL_STRETCH_PASS` plusarg mirrors the `axi_chiplet_controller.sv` I2C
pin mux (`assign i2c_scl_t = role_is_master ? mst_scl_t : <here>;`):

| plusarg | slave SCL on bus | meaning |
|---------|------------------|---------|
| `SCL_STRETCH_PASS=0` | forced `1'b1`  | the OLD buggy mux — stretch discarded |
| `SCL_STRETCH_PASS=1` | `slv_scl_t`    | the FIX — slave open-drain SCL passed through |

The test pushes a 22-byte I2C write (2 addr + 20 data) so a word write
fires *mid-transaction* and the slave must stretch while the prior word's
slow APB is pending — the same shape as the autoneg `MASK_RES_TX`.

This harness models the mux internally, so it proves the root cause and
the fix mechanism independent of (and prior to) the one-line RTL change
to `axi_chiplet_controller.sv`. The RTL change itself (Fix A) is what
makes the *real* slave-role wrapper behave like `SCL_STRETCH_PASS=1`.

## Run

```
make                                                # default = fixed mux, must PASS
make repro     # SCL_STRETCH_PASS=0, sim_build_repro # negative control: must show the wedge
make fix       # SCL_STRETCH_PASS=1, sim_build_fix   # positive: validates the fix
```

cocotb sim does not auto-rebuild on submodule edits — `rm -rf
sim_build*` before a re-run if RTL changed.

Expected:

- `SCL_STRETCH_PASS=0`: `REPRO CONFIRMED` — the buggy mux fails to
  complete the >16-byte write cleanly (the negative control asserts it
  must **not** look clean).
- `SCL_STRETCH_PASS=1`: `FIX VALIDATED` — no wedge, no NACK, slave did
  clock-stretch, ≥2 clean AXIL writes, first/last words exact.

The verdict keys off the slave-side AXIL ground truth
(`slv_first_wdata` / `slv_last_wdata` / `slv_wr_count`), set by the real
bridge, so it is independent of the cocotb I2C driver.
