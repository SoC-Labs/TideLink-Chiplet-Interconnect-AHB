# Deploy Handoff — P15/P16 I²C Bring-up (next bench session)

Branch: **`feat/i2c-autonomous-lock-integ`** @ **3de5ebe** (pushed).
Submodule pin: **34126b6** (unchanged from previous session).

Source of the repin: `staging/i2c_train/HW_VALIDATION_RESULTS.md` §6-8
(why W9/V7 was abandoned, why P15/P16 was chosen).

---

## 0. Before you sit at the bench

Confirm the farm builds finished cleanly:

```bash
ls -lh /tmp/i2c_wt/imp/fpga/output/pynq-z2-pair-all/tidelink.{bit,ltx}
ls -lh /tmp/i2c_wt/imp/fpga/output/pynq-z2-pair-flip-all/tidelink.{bit,ltx}
# Both .bit files should be ~4 MB and timestamped 2026-05-20 (or later).
# The .ltx files are the ila_i2c probe files — keep them with the bits.
```

If either is missing, check the per-target farm log:
```
/tmp/i2c_wt/imp/fpga/run/farm/pynq-z2-pair-all@local.<timestamp>.log
/tmp/i2c_wt/imp/fpga/run/farm/pynq-z2-pair-flip-all@srv04936.<timestamp>.log
```

## 1. Physical setup (5 minutes)

1. **Verify NO Arduino shield card is plugged into either board.**
   The Arduino dedicated I²C bus (P15/P16) is now driven by the FPGA —
   any shield on either board will contend.
2. **Verify the J13 ribbon is still attached** (we did not change ribbon
   pinning; lanes 0-7 + clocks still ride J13 exactly as before).
3. **3-wire Dupont harness between the two boards' Arduino shield
   headers:**

   | Wire | Board A (z2_02) Arduino pin | Board B (z2_03) Arduino pin |
   |---|---|---|
   | 1 | **SDA** | **SDA** |
   | 2 | **SCL** | **SCL** |
   | 3 | **GND** | **GND** |

   SDA/SCL are labelled on the silkscreen at the dedicated I²C position
   (between the digital and power headers — same place a stock Arduino
   Uno has them). Use the GND immediately next to that header.

   - Keep leads short (~10 cm or less).
   - Twist SDA with GND, SCL with GND (optional but cheap).
   - On-board pull-ups: 1.5 kΩ on each board, ≈750 Ω in parallel —
     fine for I²C up to 400 kHz.

## 2. Deploy from mapstone (no JTAG needed)

```bash
# From your workstation (the user's laptop / srv03335):
ssh mapstone-dev.ecs.soton.ac.uk

# On mapstone-dev:
#   First acquire the lease — REQUIRED before deploy. See
#   memory note "Lease must be GRANTED before deploy"
#   (~/.claude/projects/.../feedback_lease_grant_before_deploy.md):
#   the show output must say "granted", not just "free"; release
#   first if it's stuck.
/opt/fpgahub/bin/fpgahub pair lease acquire bridge1
/opt/fpgahub/bin/fpgahub pair lease show    bridge1   # must show: granted
```

Stage the new bitstreams onto mapstone (replaces the old W9/V7 ones
sitting there from the previous session):

```bash
# From the build host (e.g. srv03335 where /tmp/i2c_wt lives):
rsync -a \
  /tmp/i2c_wt/imp/fpga/output/pynq-z2-pair-all/tidelink.{bit,ltx} \
  mapstone-dev.ecs.soton.ac.uk:tidelink_hwval/

rsync -a \
  /tmp/i2c_wt/imp/fpga/output/pynq-z2-pair-flip-all/tidelink.{bit,ltx} \
  mapstone-dev.ecs.soton.ac.uk:tidelink_hwval/tidelink-flip.bit
# ^ note the rename: deploy_pair.sh expects tidelink.bit (master) and
#   tidelink-flip.bit (slave) in ~/tidelink_hwval/
```

Adjust paths if the build is on a different host. The previous session
used:
- `srv03335:/tmp/i2c_wt/imp/fpga/output/pynq-z2-pair-all/tidelink.bit` → master (z2_02)
- `srv04936:~/.cache/tidelink-farm/pynq-z2-pair-flip-all/imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit` → slave (z2_03)
  (or it's rsync'd back to local `/tmp/i2c_wt/imp/fpga/output/pynq-z2-pair-flip-all/` by farm_build.sh — check there first)

Deploy:

```bash
# On mapstone-dev:
bash ~/tidelink_hwval/deploy_pair.sh
# (Or whatever the wrapper is called in your tree — the previous
# session's deploy_pair.sh handled fpga_manager on both boards via SSH.)
```

## 3. Smoke test (~30 s)

Wlink probe — exactly as before, sanity-checks that the bitstream came
up and the W-link is alive:

```bash
ssh mapstone-dev.ecs.soton.ac.uk 'bash ~/tidelink_hwval/wlink_probe.sh'
# Expect: idx0 = 0x55115500 on both boards (lane-7 guard).
```

## 4. I²C bring-up test (~10 s)

The headless fast-poll probe is unchanged — it just hits MMIO and
doesn't know what pins the BD is wired to:

```bash
ssh mapstone-dev.ecs.soton.ac.uk 'bash ~/tidelink_hwval/run_i2c_test_fast.sh'
```

### Pass criteria

Look for the **STICKY** lines at the end of each board's section:

| Boards | Bus state |
|---|---|
| Both boards: `EVER i2c_busy=1` | ✅ Bus alive — pull-ups work, ribbon-equivalent (Arduino jumpers) carries |
| Both: `EVER i2c_addr=1` | ✅ Slave decoded master's address |
| Both: `EVER nego_done=1` | ✅ MASK handshake completed in at least one direction |
| Either: `ROLE_STATUS[1] locked=1` | ✅ Role-lock asserted (look for `[locked=1 ...]` in the t=… line) |

If you see `EVER i2c_busy=1 EVER i2c_addr=1 EVER nego_done=1` on both
boards: **done** — autonomous lock works. Run the full turnkey:

```bash
ssh mapstone-dev.ecs.soton.ac.uk 'bash ~/tidelink_hwval/bringup_autocal_i2c.sh'
```

### Diagnostic ladder if it doesn't pass

| Symptom | Most likely cause | Action |
|---|---|---|
| `EVER i2c_busy=0` on **both** boards | Harness wire missing / bad Dupont seat | Re-seat all 3 wires; confirm GND continuity with multimeter |
| `EVER i2c_busy=0` on **both**, harness verified good | Arduino shield card on one of the boards (contending) | Remove shield(s) |
| Master `i2c_busy=1`, slave `i2c_busy=0` | Harness wire broken on slave side | Replace SDA or SCL jumper |
| Both `i2c_busy=1`, neither `i2c_addr=1` | Addressing/protocol — NEGO_PRIORITY misprogrammed, or I²C too fast | Verify probe set master priority=1, slave=0xFFFF; raise `I2C_PRESCALE` (ctrl_reg #3) from 128 → 200 |
| `i2c_addr=1` but `nego_done=0` | MASK retries exhausted (8-cycle bounded) | Look at `mismatch=1` in STICKY — non-zero implies real peer-mask divergence; re-check master/slave bypass settings |
| Truly inert (re-tried, nothing helps) | Real BD wiring or RTL defect | Bench JTAG ILA capture with staged `tidelink{,-flip}.ltx` — playbook in HW_VALIDATION_RESULTS.md §4 |

`run_i2c_test_fast.sh` already programs `I2C_PRESCALE=200` (≈250 kHz)
and `NEGO_CFG=0x61` — no need to override anything for the first run.

## 5. After the session

```bash
# Release the lease (frees the bench for colleagues):
ssh mapstone-dev.ecs.soton.ac.uk '/opt/fpgahub/bin/fpgahub pair lease release bridge1'
```

If P15/P16 passes: bump `MERGE_HANDOFF.md` to "ready for merge into
`feat/fpga-flow`", and update memory note
`project_tidelink_i2c_autonomy.md` with the durable HW-pass result.

If P15/P16 also fails inert: the next escalation is bench JTAG capture
(don't repin again until ILA proves where the channel breaks).

## 6. What's deployed

- Bitstream master (z2_02): `pynq-z2-pair-all/tidelink.bit`
  - I²C SDA on P16, SCL on P15
  - BD Edit 1 (IOBUF top ports) + `ila_i2c` cell (6× probes, .ltx
    matching this bit)
  - Lanes 0-7 + clocks on the same J13 ribbon pins as before
- Bitstream slave (z2_03): `pynq-z2-pair-flip-all/tidelink.bit`
  - Symmetric I²C (P16=SDA, P15=SCL); TX/RX flipped on the lanes
- `pynq_host/scripts/{nego_probe_fast.py,run_i2c_test_fast.sh,
  bringup_autocal_i2c.sh,wlink_probe.sh,deploy_pair.sh}` already
  staged on mapstone:~/tidelink_hwval/ from the previous session —
  pin-agnostic, no update needed.
