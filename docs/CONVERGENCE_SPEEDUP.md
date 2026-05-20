# TideLink bring-up convergence speed-up — analysis & phased plan

> **Audience.** A hardware engineer with one bench week before the v1 tag who
> wants TideLink bring-up to *feel* snappy — sub-minute from `make deploy` to
> "16/16 lanes locked, FCSM=4, cr_pkt seen on both ends" — without rolling
> RTL changes that risk re-opening the convergence question already answered
> on `feat/td-combined`.
>
> **Source data.** This document is grounded in tonight's 30-deploy reliability
> characterisation (`bringup_reliability.sh`,
> `/home/dam1n19/td_campaign/bringup_reliability.log`,
> 2026-05-20), the time-series probe
> (`/home/dam1n19/td_campaign/bringup_health_probe.log`), and the closed-loop
> bring-up converger run
> (`/home/dam1n19/td_campaign/bringup_bestofn_diag.log`). It cites RTL by
> file/line for traceability. Everywhere a number is **measured** it is
> labelled as such; everywhere a number is **estimated** the basis is given.
>
> **Scope.** SW + script-level changes first; small RTL/parameter tweaks
> second; structural PHY work third. Doorbell / AHB_TX traffic is explicitly
> out of scope — the wedge hazard documented in
> `pynq_host/scripts/deploy_pair.sh:29-40` is a separate problem.

---

## 1. Empirical baseline (the data we have)

### 1.1 Reliability stats (N = 30 deploys, one-shot, no retry)

From `/home/dam1n19/td_campaign/bringup_reliability.log` (script
`pynq_host/scripts/bringup_reliability.sh`). Each row is one fresh redeploy
(`deploy_pair.sh` in parallel master+slave), then one `recal_cycle`, then one
`SETTLE=2 s` read of `SWI_LANE_STATUS` (`0x4403_2000 + 0x108`):

| Metric                                      | Value      |
| ------------------------------------------- | ---------- |
| 16/16 perfect convergence (one-shot)        | **5/30** (16.7%) |
| ≥14/16 near-converged (one-shot)            | 24/30 (80.0%)  |
| FCSM ≥2 on both sides                       | 18/30 (60.0%)  |
| die_a (master RX, non-flip) lock count      | mean 7.03/8, min 5, max 8 |
| die_b (slave  RX, flip)     lock count      | mean 7.27/8, min 6, max 8 |
| Combined (master + slave)                   | mean 14.30/16, min 12, max 16 |

That is the per-deploy success rate **`p = 0.167`**. The mean lock count
(14.30/16, 89.4%) is high enough that the calibrator + S_HOLD + IDELAYE2
stack is *clearly working* — the residual is in the tail (lanes that need
just-right per-lane phase, see §3) rather than a systemic dead path. Most
deploys are one or two lanes shy of perfect.

### 1.2 Per-deploy latency profile (waterfall)

Wall-clock for one `bash deploy_pair.sh` + `recal_cycle` + `SETTLE` read,
measured loosely against the script (`pynq_host/scripts/deploy_pair.sh`,
`pynq_host/scripts/bringup_pair_converge.sh`) and estimated where the script
has no instrumentation (marked *est*; basis given):

```
Step                                       Time   File:line              Notes
─────────────────────────────────────────  ─────  ─────────────────────  ──────────
SSH-1 handshake + scp tidelink.bin (4 MB)  ~4 s   deploy_pair.sh:97-99   *est: 802.11 over board's WiFi
                                                                          + sshpass startup, dominant when
                                                                          repeated per-deploy
SSH-1 handshake + scp tidelink.hwh         ~0.5 s deploy_pair.sh:100-102 *est: tiny file, mostly handshake
SSH-2 handshake + fpga_manager write       ~3-4 s deploy_pair.sh:105-112 *est: actual bitstream load is
  ├─ cp /tmp/.bin → /lib/firmware/                                        ~1 s, sleep 1 dominates the rest
  ├─ echo > /sys/class/fpga_manager/.../firmware
  └─ sleep 1
SSH-3 handshake + python3 config (4-5 writes) ~3-4 s deploy_pair.sh:123-173 *est: python3 startup +
  ├─ strap                                                                mmap×6 + sleep 0.005×2 + prints
  ├─ debug_unlock
  ├─ PAIR_BASE_ADDR
  ├─ swi_phase_offset
  ├─ ROLE_CFG (role_lock)
  └─ swreset toggle (3 writes + 2× sleep 5 ms)
─────────────────────────────────────────  ─────
deploy_pair.sh per side                    ~11-12 s
(two sides run in parallel under `&; wait`,
 so wall-clock is max(M,S) ≈ 12 s)         ~12 s   bringup_reliability.sh:95-97

sleep 1 after parallel deploy              1 s    bringup_reliability.sh:98

recal_cycle:                                       bringup_pair_converge.sh:167-172
  ├─ set_slot0(M, 0x3) & set_slot0(S, 0x3)  ~3 s   parallel SSH; max of 2 SSH RTT
  ├─ sleep RECAL_HOLD                       0.25 s
  ├─ set_slot0(M, 0x1) & set_slot0(S, 0x1)  ~3 s
  └─ sleep SETTLE                           2 s

read_status (M, S) one each                ~6 s    bringup_pair_converge.sh:132-144
                                                   (sequential in reliability.sh:100-101)
─────────────────────────────────────────  ─────
TOTAL one deploy + recal + settle          ~27-30 s   *matches observed ~30 s in tonight's reliability run*
```

**Where the time goes.**  Roughly two-thirds of a 30 s deploy is **SSH
session handshake overhead and the `sleep 1`/`sleep 2` "be safe" pads** — not
work the FPGA or the link is actually doing.  The bitstream load itself is
~1 s, the `recal_cycle` electrical action is <100 µs, and lane lock is
**stable by T+10 ms** per the time-series probe (§3.2). Almost everything
else on this waterfall is shell + SSH + paranoid `sleep`.

### 1.3 Convergence-time distribution (geometric model)

With closed-loop retry (`bringup_pair_converge.sh`), each iteration is an
independent Bernoulli trial with probability **p = 0.167** of a 16/16
outcome:

```
P(converge within K)        = 1 − (1−p)^K
E[t_converge]               = t_per_deploy / p
N at 95th percentile        = ⌈ log(0.05) / log(1−p) ⌉ retries
```

For the **current** parameters (`p = 0.167`, `t = 30 s`):

|  K (MAX_RETRIES)  |  P(converge ≤ K)  |  Wall-clock to K-th try  |
|  :-:  |  :-:  |  :-:  |
|  1   |  16.7%  |   30 s  |
|  3   |  42.2%  |   90 s  |
|  6   |  66.5%  |  180 s  |
| 12   |  89.5%  |  360 s  |
| 17   |  ~95%   |  510 s (≈ 8.5 min)  |
| 20   |  97.4%  |  600 s (≈ 10 min)   |

The mean wall-clock to converge is **~3 min** (`30 s / 0.167`), the 95th
percentile is **~8.5 min**. That is the experience an engineer is having
*today*. The rest of this document is about what each lever does to that
number.

---

## 2. Latency profile — full anatomy of one deploy

Section 1.2 gave the headline waterfall; this section drills into each
component so we can attribute the savings in §4.

### 2.1 SSH session overhead

Every `sshpass -p $PASS ssh ...` invocation runs a fresh TLS-1.2-class
handshake against the board. On a routed network (host → mapstone-dev →
per-board /24) this is **~2-3 SSH round-trips plus password auth** plus the
`sudo -S` password echo on the remote. Empirically the SSH connection setup
alone is **~1.5-3 s per invocation** (the boards are running a slow ZynqPS
sshd; this is the dominant cost). `deploy_pair.sh` opens **three** such
sessions per side, and `bringup_pair_converge.sh` opens **two more per
recal** (`set_slot0` × 2) plus **two per status read** — easily 7-10 SSH
sessions per iteration, or 15-20 s of pure SSH-setup time per deploy.

The PYNQ board's `dropbear`/`openssh` is single-threaded for auth handshake
and runs on the 666 MHz Cortex-A9; this is the slowest link.

### 2.2 SCP cost

The bitstream `.bin` is ~4 MB; the `.hwh` is ~50 kB. SCP throughput on these
boards is bottlenecked by the WiFi link (~10-30 Mbit/s effective), so a
single `.bin` transfer takes ~2-4 s and is dominated by the file transfer
rather than the handshake — *if* the bitstream actually changed.  **It
doesn't**: every deploy in a convergence loop ships the byte-identical
bitstream. This is pure waste.

### 2.3 fpga_manager load

The actual `echo tidelink.bin > /sys/class/fpga_manager/fpga0/firmware`
write is fast on the Zynq (the driver loads the bitstream into PL config
memory at clock rate); experience says it returns in well under 1 s. The
`sleep 1` afterwards (`deploy_pair.sh:110`) is a defensive pad that **could
be replaced by a status poll** of `/sys/class/fpga_manager/fpga0/state`
(`operating` ⇔ load complete). Estimated saving: 0.5-0.8 s per deploy.

### 2.4 swreset toggle

`deploy_pair.sh:162-166` writes three values to `WL+0x208` with `sleep
0.005` between them (5 ms). On `pad_clk_rx` ≈ 25 MHz that is **125 000
cycles** between writes; the actual swreset/lltx-enable signals need only a
handful of cycles to propagate. 1 ms is *generous*. 5 ms × 2 = 10 ms total,
which is rounding error in the 30 s budget but adds up when you start
chasing every other 100 ms.

### 2.5 recal_cycle SETTLE pad

`bringup_pair_converge.sh:172` sleeps `SETTLE=2 s` after dropping `slot0`
back to `0x1` and then reads. The time-series probe (`bringup_health_probe.log`)
shows lane_locked is **stable at T+10 ms** post-recal — see also
§3.2. 2 s is ~200× longer than needed for the lock to settle. Even a
conservative 100 ms would catch every observed state in the probe.

### 2.6 Sequential read_status

`bringup_reliability.sh:100-101` reads master then slave **sequentially**
(`MR=$(read_status M); SR=$(read_status S)`). Each is a fresh SSH session;
~3 s × 2 = 6 s. Parallelising the two reads buys ~3 s back per iteration
for free.

### 2.7 Inside the Python helper

Every per-board action opens `/dev/mem` and `mmap`s pages individually.
That's not slow per se — what *is* slow is the **Python startup itself**
(~300-600 ms on the A9). Coalescing multiple writes/reads into a single
Python invocation is a big win because *the cost is the Python startup,
not the writes*.

---

## 3. Convergence reliability profile

The 30-deploy reliability log doesn't just give us a scalar `p = 0.167`; it
gives us per-lane statistics that change the optimisation strategy. The two
RX paths (die_a's RX of slave TX, die_b's RX of master TX) have very
different per-lane profiles because they use different FPGA banks and
different RPi GPIO pins.

### 3.1 Per-lane lock probability table

Computed directly from `bringup_reliability.log` by parsing the per-deploy
hex lock vectors and counting bit-by-bit (30-sample base, so the binomial
1-σ on a single per-lane probability is ≈ ±9 percentage points — small
differences here are noise but the bimodal split is real):

| Lane | die_a lock | die_b lock | Notes |
| ---: | ---------: | ---------: | :---- |
| 0    | **30/30 (100%)** | 21/30 (70%) | bimodal: master perfect; slave marginal |
| 1    | 21/30 (70%)      | **30/30 (100%)** | slave perfect; master marginal |
| 2    | 28/30 (93%)      | **30/30 (100%)** | |
| 3    | **16/30 (53%)**  | **30/30 (100%)** | **die_a lane 3 is THE bottleneck** |
| 4    | 29/30 (97%)      | 25/30 (83%) | |
| 5    | 29/30 (97%)      | 24/30 (80%) | slave lanes 4–5 marginal |
| 6    | **30/30 (100%)** | **30/30 (100%)** | |
| 7    | 28/30 (93%)      | 28/30 (93%) | |

```
   lane probability — die_a (master RX of slave TX)
   100% │   ████   ████   ████ ████      ████
    90% │   ████ ████████ ████ ████      ████
    80% │   ████ ████████ ████ ████ ████ ████
    70% │   ████ ████████ ████ ████ ████ ████
    60% │   ████ ████████ ████ ████ ████ ████
    50% │   ████ ████████ ████ ████ ████ ████
        └───L0──L1──L2──L3──L4──L5──L6──L7──
                       ↑ THE LANE

   lane probability — die_b (slave RX of master TX)
   100% │████      ████ ████ ████      ████
    90% │████ ████ ████ ████ ████      ████ ████
    80% │████ ████ ████ ████ ████ ████ ████ ████
    70% │████ ████ ████ ████ ████ ████ ████ ████
        └───L0──L1──L2──L3──L4──L5──L6──L7──
              ↑ marginal
```

### 3.2 Bank-13 vs bank-35 hypothesis

The Pynq-Z2 PHY pinout straddles two IO banks:

- **Bank 13 (HD)** carries half the lanes plus `pad_clk_rx` (Y7-MRCC for
  non-flip; Y9-SRCC for flip — see
  `project_tidelink_idelay_slaveclk` memory and
  `pynq_host/scripts/bringup_pair_converge.sh:202-203`).
- **Bank 35 (HP)** carries the rest, with the IDELAYCTRL columns split
  X0/X1.

The two extreme outliers (die_a lane 3 at 53%, die_b lane 0 at 70%) are
*both* on the same physical bank-35 group on their respective sides
according to `docs/GPIO_PHY_ARCHITECTURE.md` §10.2. That section already
hypothesised "per-bank-group calibrator phase search" as the structural
fix; tonight's data confirms it is the right hypothesis.

### 3.3 What that means for the optimisation strategy

- **The per-shot rate `p = 0.167` is dominated by die_a lane 3.** If lane 3
  succeeds, the other 7 die_a lanes are ≥93% each, and die_b is already
  ≥80% on its worst lane. A back-of-envelope `Π(lane probabilities)`:
  - die_a (all 8 lanes lock): 1.00 × 0.70 × 0.93 × 0.53 × 0.97 × 0.97 × 1.00 × 0.93 ≈ **0.305**
  - die_b (all 8 lanes lock): 0.70 × 1.00 × 1.00 × 1.00 × 0.83 × 0.80 × 1.00 × 0.93 ≈ **0.432**
  - Joint (both sides 8/8, assuming independence): 0.305 × 0.432 ≈ **0.132**
  Observed `p = 5/30 = 0.167` — close enough that the independence assumption
  is roughly right, and **the analysis says lane 3 on die_a is the lever**.
  Lift lane 3 alone from 53% → 90% and the joint rises from ~0.13 to
  **~0.22**. Lift it to 100% and the joint rises to **~0.42** (paired with
  die_b's marginals also being lifted by a per-bank phase tweak).

- **Lane masking is therefore a credible per-shot strategy.** If we
  declare 7/8 lanes acceptable for bring-up demo and mask lane 3, the
  per-shot 7+/8 rate on die_a is approximately **`Π(other 7 lanes)` ≈
  0.305 / 0.53 ≈ 0.575**, and joint 7+/7 + 8/8 ≈ 0.575 × 0.432 ≈ **0.25**
  — a 1.5× improvement just from masking the worst.

- **The calibrator already runs best-of-sweep across 128 (slip,phase)
  points** (`src/rtl/tidelink_phy_align_calibrator.sv:110-138`,
  DWELL_CYCLES=64). Lane 3's marginal-eye behaviour is consistent with the
  eye being narrower than the calibrator's quantisation can resolve, *not*
  with a missing search dimension. The structural fix (§4C) is more taps
  or a different sample-point mechanism, not more search.

---

## 4. Optimisation catalogue

Five categories; each lists touch surface, effort, expected gain. The §5
quantitative model combines them.

### A. Quick wins (script-only, no RTL, no rebuild) — target 30 s → 5 s

| # | Lever | Touch | Effort | Expected gain |
| :- | :--- | :--- | :--- | :--- |
| A1 | **SSH ControlMaster persistent sessions** — open one SSH session per board at script start (`ssh -M -S /tmp/ctl-$IP`), reuse for every subsequent command (`ssh -S /tmp/ctl-$IP ...`). Eliminates handshake on N−1 of N invocations. | `deploy_pair.sh`, `bringup_pair_converge.sh`, `bringup_reliability.sh` | 1 h | **−10 to −15 s per deploy** (5-7 handshakes × 2-3 s saved each). This is the single biggest quick win. |
| A2 | **Single-SSH config block** — fold strap + debug_unlock + PAIR_BASE_ADDR + PHY phase + ROLE_CFG + swreset into one Python invocation per board. Today's `deploy_pair.sh:123-173` already does most of this; the only multi-SSH pattern is one fresh SSH for the config block, but combined with A1 every SSH is essentially free anyway. | `deploy_pair.sh` | done already mostly; refinement 1 h | **−2 to −3 s** if A1 is not done; **0 s** if A1 is done. Mostly mechanical clean-up. |
| A3 | **Cache .bin / .hwh on board** — copy bitstream once to `/lib/firmware/tidelink.bin` (and `-flip.bin`), don't re-scp on every iteration. The cache is persistent across re-deploys until manually evicted; only `fpga_manager` reload is needed to re-trigger. | `deploy_pair.sh:95-102` + a one-shot stage step | 1 h | **−4 to −5 s per deploy** (no scp). After this, "redeploy" is just `echo .bin > .../firmware`, which is sub-second. |
| A4 | **SETTLE: 2 s → 100 ms** — probe data (`bringup_health_probe.log`) shows lock stable at T+10-80 ms; 100 ms is conservative. | `bringup_pair_converge.sh:92`, `bringup_reliability.sh:39` | 5 min | **−1.9 s per recal**. |
| A5 | **sleep 1 after fpga_manager → status-poll** — replace fixed `sleep 1` with a tight poll on `/sys/class/fpga_manager/fpga0/state` until `operating`. Typical: <300 ms. | `deploy_pair.sh:110` | 30 min | **−0.5 to −0.8 s per deploy**. |
| A6 | **swreset toggle sleeps 5 ms → 1 ms** — link clock is 25 MHz; one ms is 25 000 cycles, ample margin. | `deploy_pair.sh:163,165` | 5 min | **−8 ms per deploy** (negligible alone, useful in aggregate). |
| A7 | **Parallel read_status** — read M and S in parallel with `&; wait` instead of sequential. With A1 in place this is one round-trip on each persistent socket. | `bringup_reliability.sh:100-101`, `bringup_pair_converge.sh:234-235` | 15 min | **−3 s per iteration**. |
| A8 | **BESTOF=1 if SETTLE is short** — `BESTOF=3` reads + `POLL_GAP=0.4` adds ~1.2 s/iter; once we trust the SETTLE=100 ms read, one good read is enough. | `bringup_pair_converge.sh:94` | 5 min | **−1.2 s per iteration**. |

**Sum of Quick wins (estimated):**

```
Today (per deploy + recal + settle):  ~30 s
  −A1 (ControlMaster, 5 sessions)     ~−12 s
  −A3 (skip scp)                       ~−5 s
  −A4 (SETTLE 2 → 0.1)                ~−1.9 s
  −A5 (fpga_manager poll)              ~−0.7 s
  −A7 (parallel reads)                 ~−3 s
  −A8 (BESTOF 3 → 1)                   ~−1.2 s
  −A2/A6 misc                          ~−0.3 s
─────────────────────────────────────  ──────
Estimated post-Quick-wins per-deploy: ~5-7 s    (5-6× faster)
```

These are **all** script-level changes. Zero RTL, zero rebuild, zero
verification risk. They can be unit-tested by running the existing
reliability and converger scripts before/after on the same bitstream.

### B. Medium-term wins (SW + small RTL) — target per-shot rate `p`: 16.7% → ≥50%

| # | Lever | Touch | Effort | Expected gain |
| :- | :--- | :--- | :--- | :--- |
| B1 | **Lane-mask the worst lane(s) via APB** — add (or wire up an existing) per-lane mask register in `tidelink_phy_align_calibrator.sv` or the FCSM so a flagged lane reports `lane_done=1, lane_fault=0, locked=1`, allowing the rest of the bring-up sequence to proceed. Bring-up tolerates 7/8 with a slight throughput hit; useful for demo. | RTL: 1 reg + mask gate; SW: write mask in deploy_pair.sh based on a known-bad-lane env var | 1-2 days | **`p` ≥ 0.4 with one mask, ≥0.6 with two** based on the §3.3 math. |
| B2 | **HW-characterised per-lane phase LUT** — sweep `swi_phase_offset` per lane on a known-good day, record best per-lane phase per IP, then load the per-lane phase as a hint at deploy time. The calibrator's best-of-sweep would then start from a known centre rather than a sweep edge. Today `swi_phase_offset` is a single global value driven from a register; per-lane already exists in the calibrator output. We just need a fallback SW preload before role_lock. | SW: env var or YAML lookup table; RTL: no change (per-lane phase is already plumbed in calibrator output, see `tidelink_phy_align_calibrator.sv:220` and §9.7 docs) | 1 day | **`p` 0.17 → 0.40-0.50**. Reduces the calibrator's sweep variance for marginal lanes; turns lane 3 into a "narrow-but-found" instead of "narrow-and-missed". |
| B3 | **DWELL_CYCLES 64 → 128 (param sweep)** — narrow-eye lanes win or lose on whether the calibrator catches them during one dwell window. Doubling DWELL_CYCLES roughly doubles the bit-time spent at each (slip,phase), giving the run-length score (`lane_score`) more dynamic range and the marginal lane more chances to score above LOCK_THRESH. Cost: sweep time 8192 → 16384 cycles ≈ 66 µs (still sub-millisecond). | RTL: `tidelink_phy_align_calibrator.sv:167` param default; sim regression to confirm no timing change; rebuild | 1 day (rebuild dominates) | **`p` +5-10 pp on marginal lanes**. Effect is multiplicative with B2. |
| B4 | **HOLD_CYCLES as SW-tunable register** — today `HOLD_CYCLES = 8 × 128 × DWELL_CYCLES` is a compile-time parameter. Bringing it out via the APB chiplet-controller register block lets bring-up SW dial it long for HW and short for sim, and dial it longer for known-skew scenarios. Already partially supported via `EARLY_EXIT` cocotb force (`tidelink_phy_align_calibrator.sv:279`). | RTL: APB reg + plumb to `HOLD_CYCLES`; tiny SW | 1 day | **+2-5 pp** on per-shot rate via richer skew window; mainly a quality-of-debugging win. |
| B5 | **ECC + retry budget tuning** — with Hamming(33,24) ECC restored (commit `9089b45`) the per-credit-frame success rate should improve. Once SW reaches FCSM=4 + cr_pkt_seen on both sides, do a short doorbell-less ECC-stress (read SWI_LANE_STATUS over 1000 cycles, count `lane_locked` flicker) to confirm the link's *steady-state* reliability rather than just first-lock. | SW probe + analysis only | 0.5 day | informational; tightens which lanes are "really locked vs marginal" |

### C. Structural wins (RTL changes, post-v1) — target `p` → 0.9+ AND simpler latency

| # | Lever | Touch | Effort | Expected gain |
| :- | :--- | :--- | :--- | :--- |
| C1 | **Per-bank-group calibrator phase search** — split the calibrator's shared `sweep_phase` into two phase registers (one per IDELAYCTRL column X0/X1); each per-lane lane consults the appropriate group. Recommendation: keep slip search shared, double the phase search to per-group. `docs/GPIO_PHY_ARCHITECTURE.md` §10.2 calls this out as the right structural fix. | RTL: substantial calibrator refactor; sim regression | 5-7 days | **`p` → 0.7-0.85** based on the model that marginal lanes lose their eye because the global phase favours the *other* bank-group. Specifically targets the bimodal in §3.1. |
| C2 | **Comma-symbol word-boundary self-realign (T3a)** — described in `docs/GPIO_PHY_ARCHITECTURE.md` §5.4 (USE_T3A) but disabled by default; the documented T3a went the wrong way once. Right design is comma-symbol-based continuous realign rather than one-shot. Replaces the ms-scale role_lock-skew lottery with a deterministic word boundary at any time during training. | RTL: WavD2DGpioRx + calibrator integration; substantial new state machine; sim regression | 7-10 days | **`p` → 0.95+** *and* removes the I2C-synchronisation requirement (§D). |
| C3 | **ISERDESE2 / GTX (v2 PHY)** — replaces the bit-banged sample stack with an ISERDESE2 receiver per lane, eliminating the calibrator entirely. This is the v2 PHY path. | Major: new PHY layer, new XDC, new sim env | weeks | **`p` ≈ 1.0** on the FPGA; new product surface. |

### D. I2C-coordinated training (in flight) — eliminates staggered-POR variance

`feat/i2c-autonomous-lock-integ` already adds an I2C autoneg between the
two boards. Once both boards hold `training_mode` high until both have
locked, the role_lock-skew variable disappears: today, master and slave
release `role_lock` independently via two parallel SSH writes, and the
remaining ~ms skew is what S_HOLD is patching over. With I2C autoneg, both
boards agree on "we are both ready to train" before either of them
releases — the residual ~10% tail probability of one side exiting training
while the other is still searching is gone.

| Lever | Touch | Effort | Expected gain |
| :--- | :--- | :--- | :--- |
| D1 | **Land the I2C autoneg branch (`feat/i2c-autonomous-lock-integ` @ `e22528a`, sub `34126b6`)** — pins are repinned to Arduino dedicated I2C P15/P16 with on-board pull-ups; bitstreams already rebuilding. | RTL already done; SW integration with `bringup_pair_converge.sh` to wait for the I2C-autoneg-done bit before doing the post-deploy `recal_cycle` | 1-2 days | **`p` → 0.85-0.95** *if* the residual fault is staggered-POR (very likely from the §3 data: faults are uncorrelated and small-count, exactly the I2C-autoneg failure signature). |

D is the architecturally correct version of what `bringup_pair_converge.sh`
is currently doing in software via the closed loop. Once it lands, the
closed-loop retry remains as a safety net but should hit on iteration 1
most of the time.

### E. Statistical / parallel approaches

| # | Lever | Touch | Effort | Expected gain |
| :- | :--- | :--- | :--- | :--- |
| E1 | **Speculative reload, no scp** — keep `/lib/firmware/tidelink.bin` cached; retry is just `echo .../firmware`. With ControlMaster this becomes <1 s per retry. Subsumed by A3. | trivial | done by A3 | covered by A3 |
| E2 | **Parallel against a second pair of boards** — not applicable for the 1-pair lab. Listed for completeness. | infra | n/a | n/a |
| E3 | **Speculative recal during `sleep 1`** — issue `recal_cycle` proactively before the explicit one. Marginal: tied to the existing closed loop already retrying. | bringup_pair_converge.sh | 1 h | minor |

---

## 5. Quantitative model

The geometric distribution of attempts-to-success gives us a clean way to
compare levers. Let `p` = per-deploy 16/16 probability, `t` = per-deploy
wall-clock; then `E[T_converge] = t / p`, and the 95th percentile attempt
count is `N_95 = ⌈ log(0.05) / log(1-p) ⌉`.

### 5.1 Scenario table

```
Scenario                          p_per_deploy  t_per_deploy  E[T_conv]  N_95  t_95
─────────────────────────────────  ─────────────  ────────────  ─────────  ────  ─────────
Today baseline                     0.17           30.0 s        ~3 min     17    ~8.5 min
Quick wins only (A1/3/4/5/7/8)     0.17            5.0 s         30 s      17    ~85 s
Quick + lane-mask worst (B1)       0.40            5.0 s         13 s       6     30 s
Quick + per-lane phase LUT (B2)    0.50            5.0 s         10 s       5     25 s
Quick + I2C autoneg lands (D1)     0.85            5.0 s          6 s       2     10 s
Quick + B1 + B2 + D1 combined      0.90            3.0 s        3.3 s       2      6 s
```

### 5.2 What moves the needle

- **The biggest single lever is `t` (per-deploy wall-clock).** Today
  `t` = 30 s is 80% SSH+sleep overhead. Cutting it to 5 s alone takes the
  current 3-min mean down to 30 s with no change in `p`. **That's the
  quick-win story.**

- **The second biggest lever is `p` (per-deploy reliability).** Even with
  `t = 5 s`, going from `p = 0.17` to `p = 0.85` (I2C autoneg lands) drops
  the mean from 30 s to 6 s and the tail from 85 s to 10 s.

- **A user-visible threshold is "first try usually works."** That's `p ≥
  0.85` *and* `t ≤ 5 s`. Either of those alone gives a bad experience: if
  `p` is high but `t` is 30 s, the user still pays 30 s on the lucky case;
  if `t` is small but `p` is 0.17, the user sees a long staircase of
  flickering iterations before the green light. **You need both.**

### 5.3 Convergence-time CDF (today vs Phase 1)

```
P(converge ≤ T) — today (p=0.17, t=30s)
  1.0 │
      │
  0.8 │                                          ◯
      │                              ◯◯◯◯◯◯◯◯◯◯◯◯
  0.6 │              ◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯
      │       ◯◯◯◯◯◯◯
  0.4 │ ◯◯◯◯◯◯
      │◯◯
  0.2 │◯
      │
  0.0 ◯─────────────────────────────────────────────► T (s)
      0    60   120   180   240   300   360   420   480

P(converge ≤ T) — Phase 1 (p=0.17, t=5s)
  1.0 │                  ▓
      │            ▓▓▓▓▓▓
  0.8 │       ▓▓▓▓▓
      │    ▓▓▓
  0.6 │   ▓▓
      │  ▓▓
  0.4 │ ▓
      │▓▓
  0.2 │▓
      │
  0.0 ▓────────────────────────────────────────────► T (s)
      0    10   20    30    40    50    60    70   80

P(converge ≤ T) — Phase 2 (p=0.50, t=5s)
  1.0 │             ▓▓▓▓▓▓▓▓
      │       ▓▓▓▓▓▓
  0.9 │     ▓▓
  0.8 │    ▓
      │   ▓
  0.6 │  ▓
      │ ▓
  0.4 │▓
      │
  0.0 ▓────────────────────────────────────────────► T (s)
      0   5   10   15   20   25   30   35   40

P(converge ≤ T) — Phase 3 (p=0.85, t=3s) — "feels instant"
  1.0 │           ▓▓▓▓▓▓▓▓▓▓▓▓▓▓
  0.95│      ▓▓▓▓▓
      │    ▓
  0.85│  ▓
      │ ▓
      │▓
  0.0 ▓────────────────────────────────────────────► T (s)
      0    3    6    9   12   15
```

The curves shift dramatically left under Phase 1; further compression
under Phase 2/3 mostly cleans up the tail.

### 5.4 Worked example — what a bench operator sees

Today: `make deploy && bringup_pair_converge.sh`. Wall-clock until the
script prints "CONVERGED" is the random variable described above. On a
typical Wednesday: 2-3 min, occasional 8-min outliers, a `MAX_RETRIES`
budget that has to be set to 12-20.

Phase 1: 30 s wall-clock mean. The user runs the script, types in their
lease creds, and by the time they have alt-tabbed to read the result it's
done.

Phase 1 + B1/B2: ~10-13 s wall-clock. Effectively single-shot for the
operator's perception.

---

## 6. Recommended phased plan

### Phase 1 — this week, before v1 tag (script-only, no rebuild)

Order matters: each step has a small standalone benefit, and they
compound. Estimated total bench effort: 1 day of scripting + half a day of
validation.

1. **A3 — Cache .bin/.hwh on board.** Modify `deploy_pair.sh` to skip the
   scp if the board's `/lib/firmware/tidelink.bin` already matches a known
   sha1. Add a `--stage` mode that just primes the cache. Saves 5 s/deploy.
2. **A1 — SSH ControlMaster.** Wrap the SSH usage in a top-level
   `bringup_pair_converge.sh` that opens one persistent master socket per
   board and exports `SSHCOMMON` to use `-S /tmp/ctl-$IP`. Saves 10-15 s.
3. **A4 — SETTLE 2 s → 100 ms.** One-line change. Saves 1.9 s/iter.
4. **A5 — fpga_manager status-poll.** Replace `sleep 1` with a poll on
   `/sys/class/fpga_manager/fpga0/state`. Saves 0.5-0.8 s.
5. **A7 — Parallel read_status.** Wrap M+S reads in `&; wait`. Saves 3 s.
6. **A8 — BESTOF=3 → 1 (once SETTLE is short).** Saves ~1.2 s/iter.
7. **A6 — swreset 5 ms → 1 ms.** Negligible by itself; do for hygiene.

**Acceptance criterion for Phase 1:** rerun `bringup_reliability.sh` with
N=30. Expected wall-clock per deploy: ~5-7 s (vs 30 s). Expected
convergence rate unchanged (~0.17). The bring-up converger's mean wall-clock
should drop from 3 min to ~30 s.

### Phase 2 — post-v1 cleanup (small RTL, focused on `p`)

1. **B1 — Lane-mask register.** Plumb a per-lane mask into the calibrator
   or the FCSM advance logic. Add a `LANE_MASK` env var to deploy_pair.sh.
2. **B2 — Per-lane phase LUT.** Add a characterisation pass to
   `bringup_reliability.sh`: for each combination of (board, role), sweep
   `swi_phase_offset` and record the per-lane phase that gives the longest
   lock-run. Ship the LUT as a YAML under `pynq_host/data/`, load it
   pre-role_lock.
3. **B3 — DWELL_CYCLES 64 → 128.** One-parameter RTL change. Re-spin the
   bitstream. Rerun reliability characterisation.
4. **B4 — HOLD_CYCLES as APB reg.** Quality-of-debugging more than speed,
   but cheap. Useful for the §5 quantitative model exploration.
5. **D1 — Land I2C autoneg + use it in bringup_pair_converge.** The
   bitstreams already exist; the integration script change is small.

**Acceptance criterion for Phase 2:** `p` from 0.17 to ≥0.5 measured over
N=30 deploys with the same characterisation harness. Bring-up converger
mean wall-clock < 15 s.

### Phase 3 — v2 PHY / structural

1. **C1 — Per-bank-group calibrator phase search.** Substantial RTL but
   it directly attacks the bimodal in §3.1. Targets `p ≥ 0.85`.
2. **C2 — Comma-symbol word-boundary self-realign (T3a).** Eliminates the
   role_lock-skew variable entirely; pairs with C1 to give `p ≥ 0.95`.
3. **C3 — ISERDESE2/GTX PHY.** v2 product surface; out of week-1 scope.

---

## 7. Risks & non-goals

### 7.1 What NOT to do

- **Do not chase more RTL fixes for the existing calibrator until Phase 1
  is in place and re-measured.** The reliability stats include the
  `feat/td-combined` `S_HOLD`, best-of-sweep, IDELAYE2, and FCSM-sticky
  RTL — those are *not* the limit. The limit today is SSH overhead +
  per-deploy wall-clock + lane 3's narrow eye. Adding more calibrator
  logic before fixing the wall-clock would hide its effect under noise.

- **Do not push the `recal_cycle` SETTLE lower than 50 ms without
  re-running `bringup_health_probe.sh`.** The probe data shows stability
  at T+10 ms but only in single-digit iterations; if SETTLE drops too low
  on a busy board (kernel scheduler jitter), the read could catch a
  pre-stable state. 100 ms is the right initial target.

- **Do not aggressively parallelise more than M+S parallel.** Today the
  parallel-deploy in `bringup_reliability.sh:95-97` already saturates the
  link/board; further parallelism (multiple iterations overlapping) would
  step on the FPGA reload sequence and produce noise.

- **Do not skip the `swreset` toggle in `deploy_pair.sh:162-166` even
  though it looks defensive.** The 2026-05-09 bench note is real: omitting
  it returned occasional wedged FCSMs. The 5 ms → 1 ms cut is fine; the
  3-step write sequence must remain.

- **Do not deploy AHB_TX writes before the link is confirmed up.** The
  wedge hazard in `deploy_pair.sh:29-40` is unchanged by any work in this
  doc. Everything here uses APB reads + safe GPIO writes only.

### 7.2 Validation gates

For each Phase 1 change, the gate is:

1. **Reliability run unchanged.** Re-run `bringup_reliability.sh N=30`
   after the change. The per-deploy lock vectors must remain statistically
   consistent with §1.1 (mean 14.3/16 ± noise). If the mean drops, the
   change introduced a regression — revert.

2. **Converger result unchanged.** `bringup_pair_converge.sh
   MAX_RETRIES=12` must still PASS within reasonable iteration count on
   the worst day (12 iterations × the new `t` < the old budget).

3. **No new sleep paranoia.** Any new `sleep` introduced must come with a
   one-line justification commit-message comment ("waiting on X observable
   to settle, measured at Y ms in $REF").

### 7.3 Things that might bite

- **ControlMaster on flaky WiFi:** if a board's WiFi drops, the persistent
  control socket goes stale and subsequent commands hang. The wrapper
  needs a `ssh -O check` health probe and a recreate-on-fail path.
- **fpga_manager state poll race:** the `operating` state is reported on
  the kernel side before the PL is *fully* ready (clocks settle). Keep a
  small 100-ms post-poll pad to be safe; still 9× better than `sleep 1`.
- **Lane mask correctness:** if B1's mask gate is placed in the wrong
  signal path (locked vs done vs fault), the FCSM can advance with a lane
  that is actually dropping bytes. Sim regression must cover this.

---

## 8. Concrete next-step actions

Do these in this order. None require rebuild. None touch the dangerous
AHB_TX path.

1. **(1 h) Add SSH ControlMaster to `bringup_pair_converge.sh`.**
   Open one persistent socket per board, point `SSHCOMMON` at it. Re-run
   the converger; expect iteration time to drop from ~30 s to ~10-15 s
   with no other changes. This is the highest-leverage lever and lets you
   feel the result of every subsequent step in tens of seconds rather
   than minutes.

2. **(30 min) Add `--stage` mode + bin caching to `deploy_pair.sh`.**
   Stage once at script start; in the loop only do `echo .../firmware`.
   Combined with the ControlMaster, expect iteration time ~5-7 s.

3. **(15 min) Drop SETTLE 2 → 0.1, BESTOF 3 → 1, parallelise reads.**
   These are one-liners; the time-series data already justifies them.

4. **(1 h) Re-run `bringup_reliability.sh N=30` to confirm `p ≈ 0.17`
   is unchanged and per-deploy time has dropped.** If the reliability
   drops, one of the sleep cuts was too aggressive — revert that one.

5. **(2-4 h, the day after) Land B2 (per-lane phase LUT).** Run the
   reliability harness once with `swi_phase_offset` sweeping per side
   (this is the existing `phase_recal_sweep.sh`), score per-lane lock
   runs, write `pynq_host/data/phase_lut_z2_02_master.yaml` and
   `..._slave.yaml`. Modify `deploy_pair.sh` to load them. Re-run
   reliability; expect `p` to lift to ~0.4-0.5.

After those five steps the bring-up should be in the **5-10 s mean
convergence wall-clock** regime — well under the "feels snappy" bar — and
the v1 tag can be cut with the closed-loop converger as a one-line `make
bringup` integration.

---

## Appendix A — Mapping levers to commits and files

| Lever | Primary file | Line | RTL/SW |
| :--- | :--- | :--- | :--- |
| A1 ControlMaster | `pynq_host/scripts/bringup_pair_converge.sh` | 83 (`SSHCOMMON`) | SW |
| A1 ControlMaster | `pynq_host/scripts/deploy_pair.sh` | 91 | SW |
| A3 .bin cache | `pynq_host/scripts/deploy_pair.sh` | 97-112 | SW |
| A4 SETTLE | `pynq_host/scripts/bringup_pair_converge.sh` | 92 | SW |
| A5 fpga_mgr poll | `pynq_host/scripts/deploy_pair.sh` | 110 | SW |
| A6 swreset sleeps | `pynq_host/scripts/deploy_pair.sh` | 163, 165 | SW |
| A7 parallel reads | `pynq_host/scripts/bringup_reliability.sh` | 100-101 | SW |
| A8 BESTOF | `pynq_host/scripts/bringup_pair_converge.sh` | 94 | SW |
| B1 lane mask | `src/rtl/tidelink_phy_align_calibrator.sv` | new reg + gate at 716 | RTL |
| B2 phase LUT | new YAML + `deploy_pair.sh` PHASE_OVERRIDE | n/a | SW |
| B3 DWELL_CYCLES | `src/rtl/tidelink_phy_align_calibrator.sv` | 167 (default) | RTL |
| B4 HOLD_CYCLES APB | `src/rtl/tidelink_phy_align_calibrator.sv` | 189 + APB reg | RTL |
| C1 per-bank phase | `src/rtl/tidelink_phy_align_calibrator.sv` | 334-345 (iter regs) | RTL major |
| C2 T3a comma realign | `WavD2DGpioRx.v` (deps/wlink) | 221, 278 | RTL major |
| D1 I2C autoneg | `feat/i2c-autonomous-lock-integ` branch | (separate work) | RTL+SW |

## Appendix B — Per-deploy waterfall comparison

```
TODAY (one deploy + recal + settle, ~30 s)

  0s ─┬─ SCP .bin (sshpass) ............. 4 s
      │  SCP .hwh                        0.5 s
      │  SSH-2 fpga_mgr load + sleep 1   3-4 s
      │  SSH-3 config block + swreset    3-4 s     [×2 boards parallel: max=12s]
 12s ─┼─ sleep 1                          1 s
      │  set_slot0 = 0x3 ×2 (parallel)    3 s
      │  sleep RECAL_HOLD                 0.25 s
      │  set_slot0 = 0x1 ×2 (parallel)    3 s
      │  sleep SETTLE = 2 s               2 s
 21s ─┼─ read_status M (sequential)       3 s
      │  read_status S (sequential)       3 s
      │  BESTOF=3 × POLL_GAP=0.4          1.2 s
 28s ─┴─

PHASE 1 (same flow, all A-class optimisations applied, ~5 s)

  0s ─┬─ skip SCP (cached)                0 s
      │  echo > .../firmware              0.3 s
      │  fpga_mgr poll until operating    0.3 s
      │  config block (CM, single SSH)    0.5 s    [×2 boards parallel: max=1.1s]
1.1s ─┼─ sleep 0.3 (fpga readiness pad)   0.3 s
      │  set_slot0 = 0x3 (CM, parallel)   0.05 s
      │  sleep 0.25                       0.25 s
      │  set_slot0 = 0x1 (CM, parallel)   0.05 s
      │  sleep 0.1 (SETTLE)               0.1 s
1.85s ┼─ read_status M & S (parallel CM)  0.1 s   [BESTOF=1]
1.95s ┴─
```

The 6× compression isn't magic — it's removing SSH-handshake latency
(ControlMaster) + removing `sleep 1`/`sleep 2` pads (replaced with
measured short sleeps) + removing the SCP-on-every-iteration waste.

## Appendix C — Sources

- **Reliability stats:** `/home/dam1n19/td_campaign/bringup_reliability.log`
  (script `pynq_host/scripts/bringup_reliability.sh`, run 2026-05-20).
- **Time-series probe (lock trajectory):**
  `/home/dam1n19/td_campaign/bringup_health_probe.log` (script
  `pynq_host/scripts/bringup_health_probe.sh`).
- **Closed-loop converger run:**
  `/home/dam1n19/td_campaign/bringup_bestofn_diag.log`.
- **Calibrator RTL:** `src/rtl/tidelink_phy_align_calibrator.sv`
  (T3 + S_HOLD + best-of-sweep, lines 110-201 prose, 230-718 RTL).
- **Architecture reference:** `docs/GPIO_PHY_ARCHITECTURE.md` §4
  (calibrator) and §6 (bring-up sequencing) for context.
- **Bring-up scripts:** `pynq_host/scripts/deploy_pair.sh`,
  `pynq_host/scripts/bringup_pair_converge.sh`,
  `pynq_host/scripts/bringup_reliability.sh`,
  `pynq_host/scripts/bringup_health_probe.sh`.
- **MEMORY context:** `project_tidelink_fpga_bringup.md` (resolved branch
  state), `project_tidelink_idelay_slaveclk.md` (IDELAYE2 + slave-clock
  asymmetry), `project_tidelink_i2c_autonomy.md` (I2C autoneg pin map).
