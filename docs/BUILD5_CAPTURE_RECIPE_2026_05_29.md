# Build #5 capture recipe — 2026-05-29

Authoritative operator recipe for deploying Build #5 onto the z2_02/z2_03 pair
and pulling the Bug A + Bug B ILA captures. Pairs with the ready-to-run
wrapper at `pynq_host/scripts/build5_capture.sh`. Designed for autonomous
(operator-offline) execution — the script will refuse to do anything
destructive without an explicit override.

> **Scope** — read-only capture. No RTL changes. No writes to
> `/research/AAA/ip_library/**`. Vivado 2025.2 + hw_server on mapstone-dev.

## 1. What Build #5 changes vs Build #4

Build #5 adds six new `mark_debug` probes inside `src/rtl/tidelink_ptp.sv` to
close the visibility gap on Bug B (HW_SYNC FSM wedge):

| Probe              | Width | Source line                | Purpose                                             |
|--------------------|------:|----------------------------|-----------------------------------------------------|
| `tx_state_r`       |   2   | `tidelink_ptp.sv:183`      | TX-side state held while HW_SYNC is supposed to fire |
| `hw_sync_interval_r`|  30  | `tidelink_ptp.sv:367`      | Programmed interval (1 ms = 0x100000 @ 50 MHz)      |
| `target_seconds_r` |  48   | `tidelink_ptp.sv:383`      | HW_SYNC FSM next-fire target                        |
| `target_ns_r`      |  30   | `tidelink_ptp.sv:384`      | HW_SYNC FSM next-fire target (sub-second)           |
| `hw_sync_state_r`  |   2   | `tidelink_ptp.sv:395`      | **Bug B trigger** — IDLE/ARM/FIRE/DONE              |
| `phc_time_reached` |   1   | `tidelink_ptp.sv:406`      | Combinational; should pulse when PHC ≥ target       |

Removed: the `pair_credit_counter` `mark_debug` attribute (suspected R-1
regression source).

Bug A probes (added earlier — already present from `ebbde0e`): `tl_fc_a2l_*`,
`tl_fc_l2a_*`, `fc_rx_fifo_*`, `rx_state_r`, `rx_pkt_type`, `tx_router_idle`,
`ptp_sp_*` (see `docs/archive/ILA_PLACEMENT_AUDIT_2026_05_29.md` §3).

## 2. Probe name mapping for the .tcl

`phc_ila_capture.tcl` looks up probes by **glob pattern** against the names
loaded from the .ltx — so it works without hard-coding `u_dbg_int/probe_NN`
indices. The glob patterns used by `build5_capture.sh`:

| Capture pass        | Pattern glob (passed via `-p`)   | Trigger                    |
|---------------------|----------------------------------|----------------------------|
| Bug A — master TX   | `*tl_fc_a2l_valid*`              | rising edge (1'bR)         |
| Bug A — slave RX    | `*tl_fc_l2a_valid*`              | rising edge (1'bR)         |
| Bug B — master      | `*hw_sync_state_r*`              | value match `2'h2` (FIRE)  |

The multi-bit value match is driven via the new `TIDELINK_TRIGGER_VALUE` env
var — the .tcl auto-discovers the probe width and emits
`set_property TRIGGER_COMPARE_VALUE eq<W>'h<V>`.

No existing probe names referenced in the .tcl were removed in Build #5. The
old fallback chain (`*slave_ll_rx_valid_sop*` etc.) still resolves in the
auto-discover path for legacy callers.

## 3. Pre-deploy check

```bash
# Confirm lease GRANTED — not "queued"!
ssh mapstone-dev /opt/fpgahub/bin/fpgahub pair status bridge1
# expected: state=granted user=<you> ttl=...

# Confirm both boards are reachable
ping -c 1 192.168.4.101 && ping -c 1 192.168.6.101
```

If lease is queued, abort — per `feedback_lease_grant_before_deploy.md`,
`pkill -9` the whole deploy tree and retry. The wrapper script enforces
`granted` and aborts on `queued`.

## 4. Deploy step

```bash
# On mapstone-dev:
cd ~/SoCLabs/tidelink
./pynq_host/scripts/build5_capture.sh
# OR run manually:
./pynq_host/scripts/deploy_pair.sh 192.168.4.101 z2_master die_a /tmp/tidelink_deploy --manifest <build5_manifest.json>
./pynq_host/scripts/deploy_pair.sh 192.168.6.101 z2_slave  die_b /tmp/tidelink_deploy --manifest-flip <build5_flip_manifest.json>
```

Expected output (per board):

```
==== z2_master @ 192.168.4.101 — role=die_a strap=0 ctrl=0x2 bitstream=tidelink.bin ====
  provenance OK: tidelink.bin sha256 abc123def456… matches manifest (label=build5)
  fpga_manager: operating
  PHY_CTRL       = 0x00000000 (swi_phase_offset=0)
  PAIR_BASE_ADDR = 0x44032000
  ROLE_CFG       = 0x02 (lock=1, cfg=0)
==== z2_master done (sha256=abc123def456… label=build5) ====
```

`fpga_manager: operating` is the load-of-record. If that line is missing,
the deploy will retry up to `MAX_LOAD_ATTEMPTS` (default 2) and then exit 3.

## 5. Live-state check (BEFORE triggering anything)

Read `0x44032108` (SWI_LANE_STATUS slot 2) on each board. The wrapper
decodes it to:

| Bit-field        | Decode                                            |
|------------------|---------------------------------------------------|
| `[7:0]`          | `lane_locked` mask — expect `0xFF`                |
| `[16]`           | `cal_done` — expect `1`                           |
| `[20:17]`        | FCSM state — **Build #5 success = master != 7**   |
| `[22:21]`        | LL_RX state — `2` = error                         |
| `[23]`           | `cr_pkt_seen_rx` sticky                           |
| `[24]`           | `crack_pkt_seen_rx` sticky                        |
| `[29]`           | `llrx_valid`                                      |

Also runs `wlink_probe.sh` on both boards for the full FC region snapshot —
checks PAIR_BASE_ADDR, CURRENT_CREDITS, DOORBELL_RESP_ACC, RELEASED_ACC,
ECC counters.

**Hard stop signal**: master FCSM == 7 means Build #5 has NOT cleared the
Build #4 regression — capture continues regardless because the ILA data is
still diagnostic, but the report is flagged FAIL.

## 6. Bug A capture sequence

Goal: prove (or refute) that the master is asserting `tl_fc_a2l_valid` and
that the slave is seeing the matched `tl_fc_l2a_valid` after the master
sends 100 doorbells + 10 AHB packets.

1. Arm master ILA (z2_02) — `phc_ila_capture.sh -b master -p '*tl_fc_a2l_valid*'`
2. Arm slave ILA (z2_03) — `phc_ila_capture.sh -b slave -p '*tl_fc_l2a_valid*'`
3. Wait 3 s for both to enter ARM state.
4. SW perturbation (master only): 100× doorbell W1C @ 0x44032014, then
   10× AHB packet writes @ 0x44000000 (HAZARD: only if master FCSM != 7).
5. Both captures upload after the 30 s timeout (or earlier if triggered).
6. Artefacts → `imp/fpga/output/build5_captures/<ts>/bug_a/`.

Expected on Build #5 SUCCESS:
- Master capture shows `tl_fc_a2l_valid` rising 100+ times.
- Slave capture shows matched `tl_fc_l2a_valid` rises (delay ≈ FC pipeline).
- `fc_rx_fifo_valid` and `fc_rx_fifo_ready` should both pulse.

Expected on Build #5 FAILURE:
- Master `tl_fc_a2l_valid` rises but slave `tl_fc_l2a_valid` never does
  (mid-FCSM drop) — Bug A confirmed in middleware.

## 7. Bug B capture sequence

Goal: confirm `hw_sync_state_r` never reaches HW_SYNC_FIRE (2'b10) despite
HW_SYNC_INTERVAL being programmed sensibly — i.e. the FSM is wedged in ARM
or back in IDLE.

1. Arm master ILA on `*hw_sync_state_r*` with `TIDELINK_TRIGGER_VALUE=0x2`
   (FIRE state). Timeout 60 s.
2. SW perturbation (master only): write
   `HW_SYNC_INTERVAL = 0x100000` (1 ms @ 50 MHz) at `0x44032044`, then
   `HW_SYNC_CTRL = 0x05` (force_en | enable) at `0x44032040`.
3. **Expected**: trigger NEVER fires; .tcl times out at 60 s and uploads
   the partial buffer (showing `hw_sync_state_r` stuck at IDLE or ARM).
4. Captured `hw_sync_interval_r` should read `0x100000`; `target_ns_r`
   should be set to `phc_ns + 0x100000` but `phc_time_reached` either
   never pulses OR pulses without driving the state machine forward.
5. Artefact → `imp/fpga/output/build5_captures/<ts>/bug_b/`.

If trigger DOES fire (`hw_sync_state_r == 2`) — that disproves the Bug B
hypothesis and the captured buffer shows what cycle FIRE was reached.

## 8. Vivado 2025.2 gotchas honoured

All from `reference_insert_debug_core.md` §4–§6 — applied in
`pynq_host/scripts/phc_ila_capture.tcl`:

1. **`CONTROL.MAX_DATA_DEPTH` removed in 2025.2** — script no longer reads
   it. `CONTROL.DATA_DEPTH` is no longer written either (IP-creation only).
2. **`CONTROL.CAPTURE_MODE` read-only in 2025.2** — script no longer
   writes it. Trigger conditions only (no capture conditions).
3. **`wait_on_hw_ila` corrupted-waveform bug** — script polls
   `STATUS.HW_ILA` directly until non-RUNNING with a 200 ms sleep loop.
4. **`upload_hw_ila_data` may flake once** — wrapped in `catch` with one
   retry after `refresh_hw_device`.

The only writable runtime property left is `CONTROL.TRIGGER_POSITION`, which
remains harmless on 2025.2.

## 9. Artefact layout

```
imp/fpga/output/build5_captures/<ts>/
├── run.log
├── bug_a/
│   ├── phc_ila_master_<ts>.{ila,csv,vcd,log}
│   └── phc_ila_slave_<ts>.{ila,csv,vcd,log}
└── bug_b/
    └── phc_ila_master_<ts>.{ila,csv,vcd,log}

docs/BUILD5_CAPTURE_REPORT_<ts>.md   # written by build5_capture.sh
```

## 10. Manual override hooks

| Env / flag                     | Purpose                                              |
|--------------------------------|------------------------------------------------------|
| `--no-lease`                   | Skip lease acquire (must already be granted)         |
| `--release-lease`              | Release at end (default: keep — autonomous-friendly) |
| `--skip-deploy`                | Re-run captures against a previously-deployed pair   |
| `--skip-bug-a` / `--skip-bug-b`| Run only one trigger pass                            |
| `--bug-a-timeout <s>`          | Override 30 s default                                |
| `--bug-b-timeout <s>`          | Override 60 s default                                |
| `TIDELINK_LTX_PAIR_ALL`        | Path to pair-all .ltx on mapstone-dev                |
| `TIDELINK_LTX_PAIR_FLIP_ALL`   | Path to pair-flip-all .ltx                           |
| `TIDELINK_BOARD_PASS`          | PYNQ board password (default `xilinx`)               |
| `TIDELINK_TRIGGER_VALUE`       | Multi-bit trigger compare value (e.g. `0x2`)         |

## 11. Readiness verdict

The script is gated on Build #5 outputs being present at
`imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.{bin,hwh}` and the
matched `.ltx` files at `~/td_milestone_stage/build5/`. **Do NOT execute
until Build #5 finishes** — the deploy step `cp -v` on the absent .bin will
fail loud.

Related: `reference_phc_ila_capture.md`, `reference_insert_debug_core.md`,
`feedback_lease_grant_before_deploy.md`, `feedback_no_tmp_worktrees.md`,
`docs/archive/ILA_PLACEMENT_AUDIT_2026_05_29.md`.
