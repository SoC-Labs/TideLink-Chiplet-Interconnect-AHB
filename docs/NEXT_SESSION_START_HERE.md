# Next session — start here

**Last updated:** 2026-05-25
**Purpose:** Fresh context entry-point for the next session. Replaces the noisy mid-session handoff docs. Read this *first*; the linked docs go deep on each topic.

---

## Where the project is

TideLink is a chiplet interconnect IP. It boots, lanes lock 16/16, but the FC layer (doorbell + AHB-TX) and PHC Phase-1 (slave HW_SYNC RX) are broken on the FPGA-pair proxy (bridge1).

After yesterday's diagnostic session, the **single most likely root cause for BOTH bugs** is **training-mode-stuck**: the autoneg FSM's mask phase is being skipped due to synth-pruning of `nego_cfg_reg[6]` (mask_hs_auto_en), so `swi_training_mode_r` never auto-clears, so the Wlink keeps transmitting training patterns instead of real packets — explaining doorbells stuck in TX FIFO, slave llrx/valid constant 0, PHC RX silent, all at once.

## Read these, in this order

1. [ASIC_SIGNOFF_PLAN.md](ASIC_SIGNOFF_PLAN.md) — **the whole plan**. 20 gates organised into 5 tiers + 5 phases. The strategic picture.
2. [PHC_PHASE1_HANDOFF.md](PHC_PHASE1_HANDOFF.md) — the diagnostic trail. Sections §10b and §10c contain the most recent and most decisive findings.
3. [TIDELINK_TOMORROW_SESSION_HANDOFF.md](TIDELINK_TOMORROW_SESSION_HANDOFF.md) — an alternative interpretation of the same evidence pointing at `WavD2DGpioTx.v:43-45` per-lane mux flip mid-word. Worth cross-checking — may be the actual root cause OR a related symptom.
4. [SIGN_OFF_STATUS.md](SIGN_OFF_STATUS.md) — snapshot of where individual gates stood as of 2026-05-23. Use as a starting reference; supersede with current state.

## Step 1 — Check the b26 farm

Yesterday's session kicked b26 farm (~00:16 UTC). Worktree: `/home/dam1n19/SoCLabs/td-bisect/b26-trainmode-fix/`. Branch `feat/phc-trainmode-fix-b26`, parent commit `0d41f67`, submodule commit `dbe9ac8`.

The RTL change: `(* keep *) (* dont_touch *) (* mark_debug *)` on:
- `axi_chiplet_controller.sv:309` — `nego_cfg_reg` (NEGO_CFG[6:0]; bit[6]=mask_hs_auto_en)
- `axi_chiplet_controller.sv:549` — `swi_training_mode_r`
- `tidelink_autoneg.sv:305` — `state_r` (+ fsm_encoding=sequential)
- `tidelink_autoneg.sv:336` — `axl_state_r` (+ fsm_encoding=sequential)
- `tidelink_autoneg.sv:337` — `txn_step_r`

Check completion:
```bash
ls -la /home/dam1n19/SoCLabs/td-bisect/b26-trainmode-fix/imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.bit
tail -10 /home/dam1n19/SoCLabs/td-bisect/b26-trainmode-fix/imp/fpga/run/farm/b26-launch.log
```

## Step 2 — Deploy + test b26

If b26 farm passed:
```bash
cd /home/dam1n19/SoCLabs/td-bisect/b26-trainmode-fix
SHA=$(git rev-parse --short HEAD)
# bit2bin + manifests
for T in pynq-z2-pair-all pynq-z2-pair-flip-all; do
    python3 fpga/scripts/bit2bin.py imp/fpga/output/$T/tidelink.bit imp/fpga/output/$T/tidelink.bin
done
bash pynq_host/scripts/make_bitstream_manifest.sh imp/fpga/output/pynq-z2-pair-all/tidelink.bin --label "b26-trainmode-fix" --commit "$SHA" --target pynq-z2-pair --lock-min 16
bash pynq_host/scripts/make_bitstream_manifest.sh imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin --label "b26-trainmode-fix" --commit "$SHA" --target pynq-z2-pair-flip --lock-min 16

# Stage to mapstone-dev (cat-over-ssh, see PHC_PHASE1_HANDOFF.md §6 for the pattern)
# ... stage all 8 files: .bin, .hwh, .manifest.json, .ltx per side ...

# Reacquire lease + deploy
fpgahub pair lease acquire bridge1 --ttl 3600
ssh mapstone-dev "bash --noprofile --norc -c 'cd /home/david/SoCLabs/tidelink && pynq_host/scripts/bringup_pair_converge.sh'"
```

Then the **two-pronged validation** that determines whether b26 is the fix:

### Test A — doorbell (FC layer)

```bash
ssh mapstone-dev "bash --noprofile --norc -c 'cd /home/david/SoCLabs/tidelink && source pynq_host/scripts/_ptp_common.sh
# Clear accumulators
remote_r 192.168.4.101 0x44032024 >/dev/null
# Write doorbell on master
remote_w 192.168.4.101 0x44032014 0x1
sleep 0.5
M_DR=$(remote_r 192.168.4.101 0x44032024)
printf \"master DOORBELL_RSP_ACC = 0x%08x\\n\" \"$M_DR\"'"
```

PASS = `DOORBELL_RSP_ACC` non-zero. FAIL = stays 0.

### Test B — PHC sync (PHC Phase-1)

```bash
ssh mapstone-dev "bash --noprofile --norc -c 'cd /home/david/SoCLabs/tidelink && DURATION=30 OFFSET_OK_NS=500 LOCK_HOLD=3 pynq_host/scripts/bringup_ptp_sync.sh'"
```

PASS = "RESULT: PASS" with sustained `|offset| < 500 ns` for ≥ 3 consecutive samples. FAIL = `slave PTP_CTRL = 0x00000001` (rx_valid stays 0).

### Outcome matrix

| Doorbell | PHC | Interpretation |
|---|---|---|
| PASS | PASS | **Training-mode-stuck was the root cause. Single fix, both bugs gone. Ship.** |
| PASS | FAIL | FC layer fixed but PHC has an independent bug. Investigate PHC-specific RX path; b27 candidate. |
| FAIL | PASS | (Highly unlikely.) PHC RX works via sp2wl bypass; FC layer has independent bug. Investigate FC. |
| FAIL | FAIL | Training-mode-stuck wasn't it (or fix incomplete). Pivot to alternative diagnosis — see `TIDELINK_TOMORROW_SESSION_HANDOFF.md` for the WavD2DGpioTx mux-flip hypothesis. |

## Step 3 — If b26 works → enter the sign-off plan

[ASIC_SIGNOFF_PLAN.md](ASIC_SIGNOFF_PLAN.md) Phase 1 onwards. Approximate timeline:

| Phase | Wall time | Critical activity |
|---|---|---|
| 1 — Close out HW validation | ≈ 1 day | merge to main, soak, repeatability, stress |
| 2 — Close out CI gates | ≈ 2 days | CDC deltas, Verilator CI wire-up, repo cleanup |
| 3 — ASIC backend | ≈ 1-2 weeks | LEC, STA, physical, power, DFT (foundry queue) |
| 4 — Spec / docs sweep | ≈ 1 day | register map sync, errata, integration guide |
| 5 — Hand-off | ≈ 0.5 day | tag, archive, package |

The critical-path bottleneck after the bug fix is Phase 3 (foundry tool queues, not human time).

## Step 4 — If b26 does NOT work

Don't keep building blind. Sequence:

1. **Re-read [TIDELINK_TOMORROW_SESSION_HANDOFF.md](TIDELINK_TOMORROW_SESSION_HANDOFF.md)** — the WavD2DGpioTx.v:43-45 per-lane mux flip mid-word hypothesis is the strongest alternative. There may already be a tdif-02 farm build with a candidate fix.
2. **ILA on the master TX side** — b26 should have an ILA inserted (FPGA_INSERT_DEBUG_CORE=1 was set). Trigger on master `sp2wl/tx_valid` rising. If never fires → master genuinely silent (training-mode confirmed) → b26's keep+dont_touch didn't reach the right cell, try harder placement constraints. If fires → master IS transmitting → bug is in slave RX path; investigate `WavD2DGpioRx` recovery state machine.
3. **Vivado 2025.2 ILA reliability** — `wait_on_hw_ila` returns false-positive FIRED reports. Always verify by looking at the captured CSV waveform, not the "FIRED" log line. See `PHC_PHASE1_HANDOFF.md` §10c for the workaround.

## Operational notes (don't re-learn these)

- **Lease**: `fpgahub pair lease acquire bridge1 --ttl 3600` returns a token. `release` with that token. Verify "granted" not "queued" before deploying.
- **Topology**: srv03335 → mapstone-dev → board (192.168.4.101 master, 192.168.6.101 slave). bashrc on mapstone-dev emits `Agent pid X` noise; wrap commands in `bash --noprofile --norc -c '...'`.
- **DO NOT touch AHB_TX (0x4400_0000)** until the link AND FC layer are both verified working — wedge hazard, will take a board offline.
- **DO NOT `boot_hw_device`** in xsdb/Vivado — wipes the bitstream. Use `disconnect_hw_server` to unstick instead.
- **DO `git submodule update --init --recursive`** after `git worktree add` or builds fail at `package_ip`.
- **DO NOT pipe long-running farm to `head`** — SIGPIPE kills the orchestrator. Redirect to log file instead.
- **FPGA_INSERT_DEBUG_CORE=1** must be set as an env var when kicking the farm if you want ILA in the bitstream. b23 and b24 forgot this.

## What to leave alone

- The b22/b23/b24/b25 worktrees in `/home/dam1n19/SoCLabs/td-bisect/` — keep for trace until b26 (or successor) ships.
- The cleanup proposal in `cleanup_proposal.md` (repo root) — apply only after the bug is fixed; some "stale" branches contain load-bearing scripts.
- The patched `pynq_host/scripts/phc_ila_capture.tcl` — has Agent K's fixes for Vivado 2025.2 + the level-trigger prefix system (`L:` and `L0:`).
- Persistent memory at `/home/dam1n19/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/` — Agent M's consolidation is current; trust it.
