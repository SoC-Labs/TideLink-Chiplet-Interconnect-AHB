# Build #5 capture report — 20260530_004715

**Status**: FAILED
**Out dir**: /home/dam1n19/SoCLabs/tidelink/imp/fpga/output/build5_captures/20260530_004715
**Run log**: /home/dam1n19/SoCLabs/tidelink/imp/fpga/output/build5_captures/20260530_004715/run.log

## Inputs
- Master IP: 192.168.4.101
- Slave IP:  192.168.6.101
- Artefacts staging: /tmp/tidelink_deploy
- pair-all .ltx:      /home/dam1n19/td_milestone_stage/build5/tidelink.ltx
- pair-flip-all .ltx: /home/dam1n19/td_milestone_stage/build5/tidelink-flip.ltx

## Pre-trigger live-state check
unchecked

## Bug A capture (tl_fc_a2l_valid rising)
- master capture: not run
- slave  capture: not run

## Bug B capture (hw_sync_state_r == HW_SYNC_FIRE)
- master capture: not run
- expected: TIMEOUT (Bug B = trigger never fires)

## New mark_debug probes (Build #5)
- tx_state_r           (2 bits)
- hw_sync_interval_r   (30 bits)
- target_seconds_r     (48 bits)
- target_ns_r          (30 bits)
- hw_sync_state_r      (2 bits)  <-- Bug B trigger probe
- phc_time_reached     (1 bit)

Removed: pair_credit_counter mark_debug.

## Artefacts on disk
```
total 4
drwxr-xr-x. 2 dam1n19 fp   29 May 30 00:47 .
drwxr-xr-x. 3 dam1n19 fp   37 May 30 00:47 ..
-rw-r--r--. 1 dam1n19 fp 2826 May 30 00:47 run.log
```

See docs/BUILD5_CAPTURE_RECIPE_2026_05_29.md for the design rationale.
