# PHC Phase-1 — Raw Observation Pass (2026-05-24)

Exhaustive observation of the deployed bitstreams on bridge1 — **no fixes,
no hypotheses**, just everything we could read out of master+slave.

Operator: dam1n19 / Claude observation agent.  
Lease tokens (all on bridge1): `3rVibzErnIC6JAekBmR6fg` → `y4aWFPna7CwjW_XQqkDL6Q`
(repeated re-acquires due to srv03335 30-second-cadence per-board lease grabs
from a concurrent dam1n19 client — see *Coordination notes* below).

## Scope deltas from the original plan

Three deviations from the original three-bitstream sweep, each forced by a
hard environmental constraint discovered during the run:

1. **Build #11 (`feat/phc-rx-counters`) and Build #12 (`feat/mark-debug-clean`
   = current main) bitstreams not on disk**. None of the user-provided md5
   prefixes (`1feb923…`, `758b67e…`, `27d4b52…`, `1dff208…`) match any
   bitstream found anywhere under `/home/dam1n19/`, `/tmp/`, or remote
   `srv03335`, `srv04936`. Only Build #13 (`feat/phc-slave-rx-fix`, commit
   `167923a`, manifest sha256 `9c7eadcfcd89…` / `865a0f66b1f7…`) was found
   already staged on mapstone-dev `/tmp/tidelink_deploy/`. A farm rebuild of
   #12-from-current-main is feasible at ~35 min/target × 2 targets but did
   not fit in the 2-hour budget alongside the slave-recovery hazard below.
2. **Region 8 (`0x44038xxx`, phy-align observability) is unmapped on this
   build's AXI decode** — every read SIGBUSes (signal 7) on both master and
   slave. This is data in itself.
3. **The Region-8 SIGBUS storm on the FIRST (unscoped) sweep wedged the
   slave's PS** to the point that it became unreachable over SSH and could
   not be recovered via `fpgahub pair down/up` (USB cycle did not power-cycle
   the boards). All scheduled post-test sweep / B1 / reset experiment data
   for Build #13 are therefore **missing**. A second, region-8-free
   "focused" sweep (after the wedge) returned `master OK, slave No route to
   host`.

## Coordination notes

bridge1 has a concurrent dam1n19 client on `srv03335` that re-grabs the
per-board lease (pynq_z2_02_pl + pynq_z2_03_pl) on a 30-second cadence with
sub-second hold time. Audit log shows the pattern
`lease.acquired (srv03335, dam1n19) → lease.released (srv03335)` every
~31 s for the duration of this session. This blocks `fpgahub pair up`
because by the time the pair-level lease is granted, the per-board lease
is owned by srv03335. **Recovery from the slave wedge will require either**
silencing that srv03335 client OR a physical power cycle by the operator.

---

## Build #13 — `feat/phc-slave-rx-fix` `167923a`

```
sha256(tidelink.bin)      = 9c7eadcfcd89900c5a38a9ea9efdf6eb007bafdec934e00a09a5391e66e79ef2
sha256(tidelink-flip.bin) = 865a0f66b1f77545036e7dddaf220fb1ee99cd8c66e645157609e2e29287ca45
label                     = build13-167923a
manifest expected_lock_min= 14
deployed via              = mapstone-dev:/tmp/tidelink_deploy/  (provenance OK)
deploy timestamp          = 2026-05-24T00:10:30Z (master+slave)
```

### B0 converge result

**PASS — full 16/16 bidirectional link at iteration 1.**

```
==============================================================
 TideLink coordinated closed-loop bring-up  Sun May 24 00:11:45 BST 2026
  NORMAL (die_a->192.168.4.101, die_b->192.168.6.101)
  die_a=MASTER_IP(192.168.4.101) (non-flip, RX-clk Y7-MRCC)  phase mp=0
  die_b=SLAVE_IP(192.168.6.101) (flip,     RX-clk Y9-SRCC)  phase sp=0
  MAX_RETRIES=10 SETTLE=2s BESTOF=3
==============================================================
 PROVENANCE — bitstreams about to be deployed (from /tmp/tidelink_deploy):
  tidelink.bin:      sha256 9c7eadcfcd89…  label=build13-167923a  commit=167923a  expect_lock>=14
  tidelink-flip.bin: sha256 865a0f66b1f7…  label=build13-167923a  commit=167923a  expect_lock>=14
==============================================================
IT   | die_a@101 lk/ft cal# fs cr     | die_b@101 lk/ft cal# fs cr     | tot/16
1    | 0xff/0x00 8 1 fs1 cr0          | 0xff/0x00 8 1 fs2 cr1          | 16
==============================================================
RESULT: CONVERGED — full 16/16 bidirectional link at iteration 1
  die_a@192.168.4.101[0xff 0x00 1 8 1 0]  die_b@192.168.6.101[0xff 0x00 1 8 2 1]
  (Doorbell / AHB_TX end-to-end is a SEPARATE step — wedge hazard.)
```

Note master `fs1 cr0` vs slave `fs2 cr1` (`fs`=lane-spread, `cr`=cross-rate).
Different but both within the 16/16 pass threshold.

### Pre-B1 (= post-B0) APB sweep

**280 addresses attempted across both sides; SIGBUS regions excluded below.**
Raw per-side files: `docs/_obs_raw/b13_pre_master_uniq.txt`,
`docs/_obs_raw/b13_pre_slave_uniq.txt`.

#### Region 0 (`0x4403_0000 - 0x4403_002C`) — all zeros, both sides

12 addresses, all `0x00000000` master + slave.

#### Region 1 (`0x4403_1000 - 0x4403_10FC`) — config block, both sides identical

| Off  | Master         | Slave          | Notes                              |
|------|----------------|----------------|------------------------------------|
| 0x00 | `0x0b0a0908`   | `0x0b0a0908`   | looks like a build/ID stamp        |
| 0x04 | `0x00000080`   | `0x00000080`   |                                    |
| 0x08 | `0x00000001`   | `0x00000001`   |                                    |
| 0x0C | `0x00000000`   | `0x00000000`   |                                    |
| 0x10 | `0x00020601`   | `0x00020601`   |                                    |
| 0x14 | `0x00000708`   | `0x00000708`   | `=1800`                            |
| 0x18..0xFC | all 0    | all 0          | block unused on both sides         |

#### Region 2 (`0x4403_2000 - 0x4403_20FC`) — link / PTP / RX_DIAG

| Off  | Master         | Slave          | Notes                              |
|------|----------------|----------------|------------------------------------|
| 0x00 | `0x44032000`   | `0x44032000`   | self-address loopback / device ID  |
| 0x04 | `0x00000014`   | `0x00000014`   | `=20`                              |
| 0x08 | `0x00000000`   | `0x00000000`   |                                    |
| 0x0C | `0x00001000`   | `0x00001000`   | (focused-sweep showed `0x1002` on master at 23:22 — bit1 likely transient; see *Note A* below) |
| 0x10 | `0x00000000`   | `0x00000000`   |                                    |
| 0x14 | `0x544c0100`   | `0x544c0100`   | ASCII `"TL\x01\x00"` magic         |
| 0x18 | `0x00000000`   | `0x00000000`   |                                    |
| 0x2C | SIG7 (master)  | SIG7 (slave)   | unmapped on both sides             |
| 0x30 | `0x00000001`   | `0x00000001`   | PTP-related, identical             |
| 0x34 | `0x00000000`   | `0x00000000`   | PTP_CTRL (post-B0, pre-B1: off)    |
| 0x40 | `0x00000000`   | `0x00000000`   | HW_SYNC_CTRL                       |
| 0x44 | `0x3b9ac9ff`   | `0x3b9ac9ff`   | `=999_999_999` HW_SYNC_INTERVAL default |
| 0x48 | `0x00000000`   | `0x00000000`   | HW_SYNC_STATUS                     |
| 0x4C | `0x00000000`   | `0x00000000`   | SERVO_CTRL                         |
| 0x50 | `0x0000b333`   | `0x0000b333`   | **identical, non-zero**            |
| 0x54 | `0x00004ccc`   | `0x00004ccc`   | **identical, =19660**              |
| 0x58 | `0x000003e8`   | `0x000003e8`   | **identical, =1000**               |
| 0x5C | `0x00000000`   | `0x00000000`   |                                    |
| 0x70 | `0x0000b333`   | `0x0000b333`   | **identical duplicate of 0x50**    |
| 0x74 | `0x00004ccc`   | `0x00004ccc`   | **identical duplicate of 0x54**    |
| 0x78 | `0x000003e8`   | `0x000003e8`   | **identical duplicate of 0x58**    |
| 0x7C | `0x00000000`   | `0x00000000`   |                                    |
| 0x80 | `0x00000002`   | `0x00000003`   | **DIFFERS — ROLE_CFG (master=0x2, slave=0x3)** |
| 0x84 | `0x00000002`   | `0x00000003`   | **DIFFERS — duplicate of ROLE_CFG**|
| 0x88 | `0x0000007e`   | `0x0000007e`   |                                    |
| 0x8C | `0x00000001`   | `0x00000001`   |                                    |
| 0x94 | `0x00000006`   | `0x00000006`   |                                    |
| 0x98 | `0x0000ffff`   | `0x0000ffff`   |                                    |
| 0x9C | `0x07d02710`   | `0x07d02710`   | `=131_082_000`                     |
| 0xCC | `0x00002000`   | `0x00002000`   |                                    |
| 0xD8 | `0x00070000`   | `0x00070000`   |                                    |
| 0xDC | `0x50460100`   | `0x50460100`   | ASCII `"PF\x01\x00"` magic         |

> **Note A** — `0x4403200C` read `0x00001002` on the very first focused sweep
> at 23:22:39Z (master only — was line `0x4403200c 4098 0x00001002`) but
> `0x00001000` in the larger pre-sweep dump captured immediately before.
> Both sweeps occurred post-B0 with no intervening writes from this agent.
> One-bit transient flip (bit 1) at the only millisecond-scale gap.

#### Region 8 (`0x4403_8xxx`) — UNMAPPED, both sides SIGBUS

Every address 0x44038000–0x440380FC tried returned SIGBUS (signal 7) on
master AND on slave for Build #13. The phy-align observability region the
plan refers to is not present in this AXI map. (Reading these addresses
from `/dev/mem` via a fork-per-page helper still wedged the slave's PS
on the second pass — see *Operational hazards* at the bottom.)

#### PHC (`0x4405_0000 - 0x4405_00FC`) — counter idle, both sides identical

| Off  | Master         | Slave          | Notes                              |
|------|----------------|----------------|------------------------------------|
| 0x00 | `0x00000000`   | `0x00000000`   | PHC_CTRL                           |
| 0x04 | `0x00000000`   | `0x00000000`   | PHC_STATUS                         |
| 0x08 | `0x00000004`   | `0x00000004`   | **identical, NS_INCR=4 default**   |
| 0x0C–0xA0 | all 0     | all 0          |                                    |
| 0xA4 | `0x3b9ac9ff`   | `0x3b9ac9ff`   | `=999_999_999` (SERVO default)     |
| 0xA8 | `0x00000000`   | `0x00000000`   | SERVO_STATUS                       |
| 0xAC–0xFC | all 0     | all 0          |                                    |

#### ahb_fifo (`0x4401_0000 - 0x4401_001C`) — all zeros, both sides

8 addresses, all `0x00000000`.

#### ahb_sub (`0x4000_0000 - 0x4000_000C`) — all zeros (master), slave not captured (truncation)

### Master vs slave register diff (Build #13, post-B0, pre-B1)

Across the **211 register addresses commonly readable on both sides**
(SIGBUS and side-truncation excluded), only **TWO** values differ:

```
0x44032080  master=0x00000002  slave=0x00000003
0x44032084  master=0x00000002  slave=0x00000003
```

Both are ROLE_CFG / its read-back duplicate. The bottom bit reflects the
strap/role configuration (master=non-flip ROLE_CFG=0x2, slave=flip
ROLE_CFG=0x3). **Every other readable address is byte-identical between
master and slave on Build #13, post-B0.**

### B1 (`bringup_ptp_sync.sh`) — NOT RUN

Slave wedged before B1 step could execute. See *Operational hazards*.

### Post-B1 sweep — NOT RUN
### Reset experiment — NOT RUN
### Strobe-and-read of sticky-error registers — NOT RUN

---

## Build #12 (current main, `feat/mark-debug-clean` MERGED) — NOT RUN

Bitstreams matching the user-supplied md5 prefixes `758b67e9` / `1dff208a`
were not present on any local disk searched (`/home/dam1n19`, `/tmp`,
`srv03335`, `srv04936`). Rebuild from current `main` HEAD (`c858881`) on
the farm would take ~35 min/target; combined with the slave-wedge recovery
hazard the elapsed time would have run past the 2-hour budget. No data
collected.

---

## Build #11 (`feat/phc-rx-counters`) — NOT RUN

Same reason; skipped per task instructions ("if you can't fit all three,
do #12 first then #13 then #11").

---

## Cross-bitstream comparison

Only one bitstream observed; cross-bitstream comparison **not possible**
this session. The only data point worth recording for the next session is
the per-side identity of all 211 commonly-readable addresses on Build #13,
which gives a precise byte-for-byte baseline that a re-observation of #11
and #12 (when rebuilt) can be diffed against.

---

## Operational hazards encountered (raw record)

1. **Region 8 read = AXI SIGBUS on both sides for this build family.**
   The `0x4403_8000` block is unmapped in the AXI decode of the deployed
   Build #13 bitstream. SIGBUS (signal 7) is the kernel's response on
   first access from `/dev/mem`. A fork-per-page helper survives this on
   master, but on the FIRST exhaustive sweep (sweep_apb_v4.sh with full
   region-8 enumeration on both sides) the slave's PS became permanently
   unreachable over SSH ("No route to host") immediately after its
   region-8 SIGBUS storm completed — master finished cleanly. The
   focused (12-address region-8) sweep run after the wedge also SIGBUS'd
   on master but **did not wedge master**. Pattern: full-region-8 brute
   sweep on slave appears to lock the slave's AXI / PS path.
2. **`fpgahub pair down/up` does NOT power-cycle the boards.** USB rebind
   only. After the slave wedge, pair down (ok) + pair up returned the
   per-board lease 409 from `srv03335` and never resurrected SSH. Slave
   stayed unreachable through the entire remainder of the session.
3. **Concurrent lease pressure from `srv03335` (same user)**. A second
   dam1n19 client on srv03335 re-grabs the pynq_z2_02_pl and pynq_z2_03_pl
   per-board lease every ~30 s, briefly holding sub-second then releasing.
   Pattern in `fpgahub board lease-history pynq_z2_02_pl`:
   ```
   23:29:28 lease.acquired srv03335 dam1n19
   23:29:28 lease.released srv03335
   23:29:59 lease.acquired srv03335 dam1n19
   23:30:00 lease.acquired srv03335 dam1n19
   23:30:00 lease.released srv03335
   ...
   ```
   Every attempt at `fpgahub pair up` lost the race. Identity of the
   srv03335 caller is unknown — `pgrep -af fpgahub|td_|tidelink|vivado`
   on srv03335 returned nothing.
4. **`bin/cat | ssh` corruption from `Agent pid …`** noise. The remote
   shell rc on mapstone-dev (a non-Claude account) starts `ssh-agent` and
   emits `Agent pid NNNNNNN\n` to stdout on every login, which corrupts
   any binary `cat | ssh` pipe and any `tar c | ssh tar x` pipe. Workaround
   used: `ssh … | { read first; cat; } > local_file` strips the first line.
   This isn't a TideLink issue but worth recording — every cross-host
   binary transfer in this session had to be cleansed.

---

## Files dropped under `docs/_obs_raw/`

```
b13_pre_master.txt        master pre-B1 sweep (with SIGBUS-retry duplicates)
b13_pre_master_uniq.txt   master pre-B1 sweep, sorted+deduped (280 unique)
b13_pre_slave.txt         slave pre-B1 sweep (with SIGBUS-retry duplicates)
b13_pre_slave_uniq.txt    slave pre-B1 sweep, sorted+deduped (276 unique)
b13_pre_diff_full.txt     master/slave hex-value diff (71 lines incl SIGBUS-only-on-one-side)
b13_pre_diff_ms.txt       master/slave clean diff (2 lines = ROLE_CFG addresses only)
```

Each line in the per-side files is:
```
<addr_hex>  <decimal_value>  <hex_value>
```
or for unmapped regions:
```
<addr_hex>  SIG7
```

---

## Notes — things that stood out (raw, no hypothesis)

- The RX_DIAG-style counter values `0xb333 / 0x4ccc / 0x3e8` appear
  **twice** in region 2 at offsets `0x50–0x58` and `0x70–0x78`. The values
  are byte-identical on master and slave for Build #13. Build #11's
  report (PHC_PHASE1_HW_REPORT § "RX_DIAG counter read") had
  `master 0x4ccc / 0x3e8` and `slave 0x800000 / 0xf4240` — i.e. Build #13's
  slave RX_DIAG reads agree with **master's** Build #11 values, not slave's.
- `0x44032014 = 0x544c0100` (ASCII `"TL\x01\x00"`) and
  `0x440320DC = 0x50460100` (ASCII `"PF\x01\x00"`) look like magic / ID
  registers and are identical master/slave.
- The PHC default value at `0x4405_0008` is `4`, not `0` or `20` (the
  programmed-for-50MHz NS_INCR value `phc_init_50mhz` writes). Both sides
  identical.
- `0x440500a4 = 0x3b9ac9ff` (`= 999_999_999`) appears as a PHC default
  AND at region-2 `0x44032044` as the HW_SYNC_INTERVAL default — the same
  magic number used as the "no-sync" interval default.
- `0x40000000–0x4000000C` ahb_sub returns `0x00000000` on master.
- `0x44010000–0x4401001C` ahb_fifo returns `0x00000000` on both sides.
- The transient `0x4403200C` bit-1 flip between two sweeps with no
  intervening writes is the only spontaneous register change observed
  this session.
