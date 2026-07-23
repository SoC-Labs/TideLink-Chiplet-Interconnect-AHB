# deskew_handoff_lottery — cross-lane word-skew robustness harness

> ## ⚠️ PREMISE REFUTED — this bench does NOT reproduce a real KR260 delivery bug
>
> This directory was built to reproduce a hardware-reported "intermittent
> delivery" bug on the KR260 pair (2026-07-22): *first packet crosses byte-exact,
> subsequent packets read all-zero; which direction delivers is a lottery.*
>
> **That report was a receiver-side MEASUREMENT ARTIFACT, not a link bug.** The
> TideLink RX FIFO is a **streaming** FIFO — successive packets queue at
> **advancing 16-byte offsets**. The hardware receiver read a **fixed** offset
> (`0x8`) and therefore only ever saw **packet 0**; every later packet looked
> "undelivered." Reading at the correct **strided** offsets shows **12/12
> distinct tags delivered byte-exact, in order, with correct complements.**
>
> **There is no framer-lock lottery. The cross-lane word deskew is correct and
> delivery is reliable on the KR260.** Do not read this bench as evidence of a
> field delivery bug — there is none.
>
> **What this directory still is:** a general **cross-lane whole-word skew
> robustness harness** for the V2 deskew. It exercises the training→data handoff
> anchor under *deliberately injected, synthetic* whole-word skew and is
> parametric on the fix knobs (`EPOCH_ANCHOR_EN`, `LANE_MASK`) so Phase-3 can
> characterise the deskew's correction envelope. The "lottery / intermittent"
> labels in the code and transcript below predate the refutation and refer to
> behaviour under **injected synthetic skew**, not any real-ribbon behaviour.
>
> **The lesson worth keeping:** this harness's *own* read path already does the
> right thing — `_send_one` drains each packet with a per-packet **strided**
> sweep (offsets `0x00..0x0C`, whose final read fires `read_complete` and pops
> the packet). That is exactly the protocol the hardware receiver failed to use.
> A sim built on the correct read protocol would never have shown the artifact;
> the artifact lived entirely in the receiver software's fixed-offset read.

---

## What the harness is made of

Two cross-wired V2 (`TIDELINK_PHY_V2`) `tidelink_top` dies, joined by a
runtime-programmable per-lane whole-word skew injector, brought up to data mode
by the proven SW recipe, then driven with distinct-tagged packets that are
byte-exact-checked and drained per packet.

| file | role |
|------|------|
| `tb_top.sv` | two cross-wired V2 `tidelink_top` dies (copied from `cocotb/tidelink_top_pair_v2`, injector swapped) |
| `epoch_skew_rt.sv` | **runtime-programmable** per-lane whole-word skew injector (this bench's replacement for the sibling's compile-time `pad_skid`) |
| `pair_v2_common.py` | shared V2 harness: APB/AHB drivers, `run_bringup_full`, `make_packet` (copied verbatim from the sibling bench) |
| `test_deskew_handoff_lottery.py` | the tests |
| `Makefile` | flist + `flist_deps.mk` staleness guard + the fix knobs |
| `pad_skid.sv`, `eye_fault.sv` | copied in for parity; `pad_skid` is **not** instantiated here |

### The runtime injector

`epoch_skew_rt` delays each lane by a runtime-selectable **whole-word** (16
`pad_clk` cycle) amount. A word-multiple delay shifts a lane's content by an
integer number of 16-bit link words with **no** change to bit-alignment or clock
phase (the clock is forwarded unchanged) — so training / IDELAY / bit-slip still
lock (lanes read `0xFF`), while the assembled 128-bit word is sheared by the
cross-lane word offsets. cocotb sets the per-lane vector once per trial at reset
and holds it constant, so each trial's behaviour is deterministic; different
trials use different vectors (synthetic "ribbon realizations").

## Config knobs (parametric for Phase-3 characterisation)

| knob | default | effect |
|------|---------|--------|
| `EPOCH_ANCHOR=0\|1` | `0` | `1` → `+define+TB_TOP_EPOCH_ANCHOR_EN` → defparam `phy.EPOCH_ANCHOR_EN=1` on both dies → the training-exit EPOCH anchor; `SYNC_REANCHOR_EN` becomes its complement. |
| `LANE_MASK=0xNN` | `0xFF` | the test Force-drives `...phy.gpio.u_deskew.lane_mask` on both dies when `!= 0xFF` (e.g. `0xFE` to mask lane 0). At `0xFF` the RTL path is untouched. |
| `MODULE` | `test_deskew_handoff_lottery` | the test module |
| `DUMP=1` | off | enable the `waves.vcd` dump (multi-GB; off by default) |

## Tests

* `test_00_zero_skew_control` — zero skew → every packet, both directions, both
  positions, delivers byte-exact in both builds. (Harness soundness.)
* `test_10..13_*` — one deterministic synthetic realization each. SHIPPING build
  (`EPOCH_ANCHOR=0`) → the injected skew exceeds the occupancy-only deskew's
  envelope and shears; FIX build (`EPOCH_ANCHOR=1`) → the training-exit anchor
  corrects it and every packet delivers.
* `test_99_lottery_summary` — re-runs all realizations and tabulates the
  outcomes (label retained from before the refutation).

### Rigor against false positives

Every "delivered" is a **distinct-payload byte-exact** check that also **drains**
the packet from the RX FIFO with the correct per-packet **strided** read
(offsets `0x00..0x0C`; the final read pops the packet). Distinct payloads per
(trial, direction, packet) are the tags, so a stale/mis-offset FIFO read cannot
produce a false PASS. `flist_deps.mk` `CUSTOM_COMPILE_DEPS` guards the stale-simv
trap; `SIM_BUILD` is keyed on `EPOCH_ANCHOR`. **After any RTL edit
(`tb_top.sv`, `epoch_skew_rt.sv`, or a flist source), `rm -rf sim_build_*`
before trusting a result.**

## Run

```sh
source ../../set_env.sh
export TIDELINK_PHY_V2=1
export EPOCH_PROFILE=zero        # skew is injected at RUNTIME, not via EPOCH_PROFILE

make EPOCH_ANCHOR=0              # occupancy-only deskew under injected skew
make EPOCH_ANCHOR=1             # training-exit EPOCH anchor
make lottery                    # both builds, one transcript
```

## Transcript (2026-07-22, VCS T-2022.06-SP2, ~2 min/build)

Both builds: **TESTS=6 PASS=6 FAIL=0.** These are the deskew's responses to
*deliberately injected synthetic* whole-word skew — a robustness/envelope
characterisation, **not** a reproduction of any field behaviour.

Injected realizations (per-lane whole-word delays, `m2s` = master→slave RX,
`s2m` = slave→master RX; R1 = the v37 silicon fingerprint on the master's RX):

```
R0_zero        m2s=[0,0,0,0,0,0,0,0]        s2m=[0,0,0,0,0,0,0,0]
R1_s2m_silicon m2s=[0,0,0,0,0,0,0,0]        s2m=[3,7,5,4,6,3,7,5]
R2_m2s_silicon m2s=[3,7,5,4,6,3,7,5]        s2m=[0,0,0,0,0,0,0,0]
R3_s2m_lane0   m2s=[0,0,0,0,0,0,0,0]        s2m=[7,0,0,0,0,0,0,0]
R4_both_skew   m2s=[2,5,1,6,3,7,4,2]        s2m=[3,7,5,4,6,3,7,5]
```

SHIPPING build — `[tb_top] EPOCH_ANCHOR_EN: master=0 slave=0 (deskew: m=0 s=0)`
— outcome per (packet A, packet B):

```
R0_zero        m2s(A,B)=(True, True)  s2m(A,B)=(True, True)    ALL-DELIVER (control)
R1_s2m_silicon m2s(A,B)=(True, True)  s2m(A,B)=(False, False)  s2m sheared
R2_m2s_silicon m2s(A,B)=(False,False) s2m(A,B)=(False, False)  both (FC couples dirs)
R3_s2m_lane0   m2s(A,B)=(True, True)  s2m(A,B)=(True,  False)  s2m A ok, B sheared
R4_both_skew   m2s(A,B)=(False,False) s2m(A,B)=(False, False)  both sheared
```

FIX build — `[tb_top] EPOCH_ANCHOR_EN: master=1 slave=1 (deskew: m=1 s=1)` —
every realization ALL-DELIVER `m2s(True,True) s2m(True,True)`.

Read as robustness: under *injected* whole-word skew the occupancy-only shipping
deskew has a limited envelope; the training-exit EPOCH anchor extends it so all
tested realizations correct. This says nothing about the KR260 field case, where
the real ribbon skew was already corrected and delivery was reliable (the
"failure" was the fixed-offset read).

## Fidelity — what this harness does and does not represent

**Does:** exercise the V2 deskew's training→data handoff anchor under a clean,
deterministic, whole-word (integer-UI) cross-lane skew model, and show that the
`EPOCH_ANCHOR_EN` and `LANE_MASK` knobs change the correction envelope — a useful
parametric robustness gate.

**Does NOT:**
* reproduce a real KR260 delivery bug — **there is none**; the field report was a
  fixed-read-offset artifact (correct strided reads deliver 12/12 byte-exact);
* model the analog fractional-UI drift of a physical ribbon (this is integer-UI,
  static per trial);
* represent the real KR260 ribbon's per-lane skew (never measured numerically) —
  the vectors here are plausible synthetic realizations, and R2/R4/R3's shears
  under `EPOCH_ANCHOR=0` are responses to skew heavier/different than whatever the
  real ribbon presented, which the shipping deskew evidently handled.
