# Build #10 (AUTOCAL=0) — HW NEGATIVE

**Date:** 2026-06-01 08:48 BST
**Branch:** `fix/build10-autocal0` @ `ee2602e` (reverted to AUTOCAL=1 in `d783db2`)
**Builds:** master `e19eaa1e…`, slave `b5b62649…`
**Build wall:** 46m local + ~24m srv04936 parallel
**Hypothesis tested:** `AUTOCAL_ENABLE(1'b0)` per memory `★★★ AUTOCAL=0 HW workaround 2026-05-27` would "unblock the FPGA link bilaterally" by disabling the runtime calibrator.
**Result:** FALSIFIED. AUTOCAL=0 breaks PHY convergence in current RTL stack.

## HW evidence

`bringup_pair_converge` ran 10 retries, never converged:
```
IT 1..10: die_a@101 0x00/0x00 (master DEAD), die_b@101 0xff/0x00 (slave alive but cal_done=0)
RESULT: NOT CONVERGED, best 8/16 at iter 1
```

After doorbell rings (with broken PHY):
- master REG_STATUS=0x00000001 (returner_busy=1, wedged)
- slave REG_STATUS=0x00000001 (returner_busy=1, wedged)
- DB_RESP=0 both sides

## Why the memory entry was misleading

The historical AUTOCAL=0 hack was committed at `f2ab31c` (`ila-iter: force AUTOCAL_ENABLE=1'b0 (S_PROBE workaround empirically broken on HW)`, 2026-05-29). That commit also confirms the exact symptom we're chasing:

> "Symptoms with AUTOCAL=1 + S_PROBE:
> - Lane lock 16/16 + cr_pkt_seen=1 bilaterally
> - **AHB doorbell M->S non-deterministic (works once then 0)**
> - PTP HW_SYNC slave never receives master's SYNC packets
> - NORMAL bitstream-to-board mapping never converges"

These symptoms EXACTLY match Build #9 HW behaviour. So the "M→S asymmetric corruption" is the known long-standing bug; it has been documented before; **neither AUTOCAL=0 nor S_PROBE successfully fix it on silicon**.

The AUTOCAL=0 hack apparently worked in the older `feat/td-autonomy` / `feat/td-i2c-...` context (older RTL stack, prior to the autonomy + L11 + L9 additions). With current stack, AUTOCAL=0 alone is insufficient — PHY convergence requires the calibrator to actually run.

## Implications

The remaining options to clear the HW doorbell wedge:

1. **Deeper ILA capture** — instrument the slave RX framer with `mark_debug` on `pkt_is_data_pkt`, `valid_rx_pkt_crc_err`, `auto_rx_in_word_count`, `send_nack_req`, `auto_rx_in_sop`, `auto_rx_in_data[63:0]` and capture the wedge in HW. The probe agent identified these signals in `cocotb/tidelink_top_pair/test_bugc_link_layer_probe.py` for sim; same probes in HW would localise the actual signal.

2. **Bisect the regression** — find the commit between v1.0-rc1 (14.40/16 historical) and current HEAD where doorbell delivery broke. ~30 commits in scope. Each bisect step ~50min build + 30min HW.

3. **Submodule synth — try a different `feat/calibrator-bug-fix` branch tip** — there may be a later S_PROBE iteration that addresses the May-29 HW finding.

4. **Lower-level scope: oscilloscope on RPi GPIO ribbon during 100-doorbell M→S** — confirm whether the master's TX stops, the slave's RX corrupts, or the ribbon is dropping bits.

## What stays in branch

- L11 (Bug A wedge-break watchdog) — sim+HW PASS, no SSH disconnect
- L9 + L9b (Bug A correctness in sim) — sim 3/3 PASS, harmless in HW
- Bug B RTL fix — sim 7/7 PASS, not exercised on HW yet
- AUTOCAL=0 → REVERTED back to AUTOCAL=1 (commit `d783db2` on `fix/build10-autocal0`)

`fix/build9-unified` remains the best-state branch (PHY converges, link layer wedges).
`fix/build10-autocal0` is preserved as a "tested negative" record for AUTOCAL=0 hypothesis.
