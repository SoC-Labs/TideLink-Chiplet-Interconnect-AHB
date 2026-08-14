# TL-035 A/B — predictions recorded BEFORE the run (2026-08-13)

Written before any board operation, so the result cannot be rationalised after
the fact. This campaign has produced three confident-but-unsupported readings in
a row (dead ECCCNT counter; ILA wired to the sideband node; Region F all-clean
misread as exoneration), and every one of them was rescued by checking the
instrument rather than the DUT. Pre-registration is the cheapest guard against a
fourth.

## Arms

| Arm | Build | Source | die_a md5 | die_b md5 |
|---|---|---|---|---|
| A — baseline | `a2lonly-28409f5` (2026-08-09) | `5d58c2a3`, clean manifest | `9eadebb8…` | `13573e46…` |
| B — TL-035 fixed | `.tl033` (2026-08-11) | `d317c98…-dirty` | `8947a50d…` | `5979d88c…` |

Arm A provably LACKS the fix (`git show 5d58c2a3:…/WlinkGenericFCSM_4.v` still has
`& ~socl_l7_real_crc_seen`, no `TL033_LEGACY_WDOG` guard). Arm B provably HAS it,
verified in the packaged IP the build consumed, with the legacy define set nowhere.

## Prediction 1 (peer, "Dual-chiplet KR260 implementation assessment")

**Not a null — an arm-to-arm conversion.** Compare die_b's *channel signature* per arm:

- **Arm A (no fix):** die_b shows `aw`/`w` wedge_sticky set — write stuck on die_b's
  slave side, AW-node FCSM stuck in recovery. That is the state-7 class, so TL-035
  should bite.
- **Arm B (fixed):** die_b shows a COMPLETED B, die_a clean — the write recovered
  and completed, but its B was lost on the return path.

If the arms differ this way, TL-035 is **not** null: it converted the failure from
"write never completes (state-7 stuck)" to "completes but B lost on return" — the
necessary-not-sufficient pattern this campaign keeps hitting (cf. TL-032).
Peer stated they would bet on this over a clean null.

## Prediction 2 — what a genuine null would mean

If BOTH arms show identical die_b-completed + die_a-clean, that is still two results,
not zero: a B lost specifically *after* an AW-recovery episode is most likely
recovery-INDUCED (the AXIREC mechanism — I5 fires, response abandoned post-recovery),
not an independent return-path fault. synth-B (`dcf0fce`) is already in both builds
and would be evidently insufficient for the AW-recovery-triggered B. So a null
convicts TL-035 **and** names the next locus: extend synth-B / I5 coverage to the
AW-recovery case.

## Prediction 3 — my own, on the instrument (step 6c)

The liveness check is binary and I am NOT predicting which way it goes:

- **stall bits move under load** → front-end is sampling → a later all-clean wedge
  word is trustworthy and means a genuine never-driven B.
- **stall bits never move** → sampler is dead → every all-clean Region F read is
  meaningless **including TL-009's `0xad800000`**, which is retroactively VOIDED
  rather than merely softened, and an AXI-node ILA becomes unavoidable.

I record explicitly that I consider the second branch live. TL-009's ground truth
("Region F reads HEALTHY ⇒ NOT an FC-node wedge") is an unsound inference either
way, because `wedge_sticky` and `stall_live` both require `valid & ~ready` and
`resp_err` latches only on a completed handshake — so a never-driven B
(`b_valid = 0` forever) is invisible to this word **by construction**.

## Attribution controls

- Pre-inject Region F snapshot on both dies, timestamped, so post-inject stickies
  are attributable to the inject and not to a stale pre-inject beat (peer point 3:
  confirm the completed B is the POST-replay write's B).
- die_b is read FIRST post-inject, since die_b survives die_a's wedge — this makes
  the lost-completion conclusion independent of die_a's sampler being alive.
- md5 pinned per die per arm; the harness ABORTS on mismatch. The rig was found
  running an unlabelled ILA build with a foreign `.hwh`, so provenance is not assumable.

## Face-mapping caveat — deliberately NOT asserted

`axi_tgt_0_*` = local AXI master's view, `axi_ini_0_*` = remote AXI slave's view
(`axi_chiplet_controller.sv:3061/3069`). On the **-flip** build I have NOT verified
which face carries die_b's slave-generated B. Raw words will be reported with my
decode and this caveat; the mapping is to be settled jointly before either party
publishes a directional claim.

---

# Round 2 — predictions added AFTER the n=1 A/B, BEFORE the repeats and the ILA

The n=1 A/B produced: baseline die_b `0xad800000` (all clean), fixed die_b
`0xad408020` (`ini_aw` wedge+stall), both arms wedging die_a. Nothing below is
established; these are the falsifiable claims that the repeats and the AW-node
ILA are being run to test.

## Prediction 4 (peer) — the fixed-arm blocker is DOWNSTREAM of the AW node

Verified port facts that motivate it: `axi_ini_0_aw_valid` is `output` and
`axi_ini_0_aw_ready` is `input` (`axi_chiplet_controller.sv:314/315`), and
`axi_ini_0_aw_{valid,ready}` wire to `m_axi_aw{valid,ready}`
(`tidelink_top.sv:2903/2904`). So the fixed-arm signature (valid=1, ready=0) is a
downstream stall: die_b's AW node RECOVERED and RE-ISSUED, and something one hop
down refuses it.

**Peer's prediction, verbatim:** in the FIXED arm at the wedge the ILA shows
`axiaw` FCSM RECOVERED (not state-7) + `m_axi_awvalid=1` + `m_axi_awready=0`,
with the blocker downstream (a prior outstanding txn on die_b's m_axi as the lead
sub-cause). If `axiaw` is instead stuck in state-7 in the fixed arm, the
downstream reframing is WRONG and the "stuck at the node" reading stands.
**NO-FIX arm:** `axiaw` stuck in state-7, `m_axi_awvalid=0` (never re-issued),
which is the all-clean word.

Consequence already accepted: candidate (ii) "AW credit-starve" is OUT for the
fixed arm, because credit-starvation suppresses VALID and we observe valid=1.
Live candidates are all READY-side.

## Prediction 5 (mine) — the refusing agent is XHB500, not generic fabric

`tidelink_top.sv:2902` labels that port block "AXI initiator (to XHB500 AXI->AHB
bridge)", and `m_axi_awready` is consumed at `:2557` by the XHB500 instance. The
bridge's write path carries exactly the machinery the downstream account needs:
`hazard_list.sv HAZARD_LIST_SIZE=4` ("up to FOUR writes deep on s_axi", :1515),
`sub_wr_os_ctr` (:1526), `synth_b_pending` (:1530), `sub_axi_outstanding` (:1573).

This is the same mechanism TL-003 (Fix K — hazard-list never freed the EWR write)
and TL-005 (synth-B drains `sub_wr_os_ctr` so the bridge re-idles) already
address. Both are `hw_proven` on exactly ONE inject class,
`errinject --node B --inj-byte 0`. An AW-node inject reaches the same bridge
through a different door.

**Prediction:** if the ILA shows `axiaw` RECOVERED + `m_axi_awvalid=1` +
`m_axi_awready=0`, then at the wedge `sub_wr_os_ctr != 0` and/or a stale
hazard-list entry is present.
**Falsifier:** if `awready` is low with an EMPTY hazard list and zero outstanding
writes, the blocker is beyond XHB500 and this refinement is wrong.

## Prediction 6 (mine) — the repeats

No prediction offered on the outcome. The falsifier is mechanical and stated in
`repeat_ab.sh`: baseline must reliably read `0xad800000` and the fixed arm must
reliably read `0xad408020`. If baseline EVER reads `0xad408020`, or the fixed arm
EVER reads `0xad800000`, the "conversion" is draw-noise and evaporates. Arms are
alternated (B,A,B,A,...) so rig drift is shared rather than confounded.

## Control that both future ILA builds must carry

Pair any die_a or die_b ILA arm with a NO-CORE control build of identical source,
read via OBS_AXI. ILA insertion has itself caused this wedge class on this design
(`WlinkGenericFCSM_6.v:129-138`, build #4, 5/5 deploys wedged at state 7). The
08-12 transport capture was die_a-core / die_b-no-core — an uncontrolled
asymmetry its author has since acknowledged. If the no-core control ALSO shows
`ini_aw`, the debug core did not create it.

## Correction to Prediction 5 — the id-mismatch sub-cause is REFUTED

An earlier form of this hypothesis (peer's candidate B) held that a hazard entry
could go unfreed because its stored id differed from `sub_wr_awid_r`, so neither
the real B nor synth-B's B would match it. **That cannot happen on this bridge.**

`tidelink_top.sv:1880` states it and the RTL confirms it: *"This bridge ties
awid = hmaster = 12'd0 … so EVERY hazard entry carries id 0 and the peer must
return bid 0."* Verified at `:2474` (`.hmaster (12'd0)`) and `:1864`
(`sub_wr_awid_r <= s_axi_awid`, that same constant). There is exactly one id in
the system, and Fix K exists to make the match unconditional — *"the hazard match
is GUARANTEED and the entry drains regardless of what the link did to the bid
bits."* An id-aware drain would be a no-op.

**What replaces it is stronger, and is documented in the same comment block** as
the mechanism behind the on-silicon N-write soak hard-wedge:

> *"the write is never freed, and after a few writes the same-address `hazard`
> stall (hazard_list.sv:139) — or a full 4-deep list — stops the bridge => die_a
> PS SmartConnect saturates … The B handshake still COMPLETES (b_done pulses), so
> the I5 outstanding-timeout keeps resetting and **synth-B NEVER arms =>
> unrecoverable**."*

So synth-B fails to rescue this door not through an id mismatch but because
`b_done` keeps pulsing on other traffic, continually resetting the I5 timer so
the backstop never arms.

**Revised candidates for the fixed-arm `awready` stall:**
- **(A) same-address hazard stall** (`hazard_list.sv:139`) from one unfreed entry — leading
- **(C) 4-deep list full** — needs four unfreed entries; unlikely from one inject, cheap to rule out by occupancy
- ~~(B) id mismatch~~ — refuted; constant AWID by construction

**Revised prediction:** at the wedge a hazard entry is occupied and unfreed with
the SAME ADDRESS as the re-issued AW; the list need not be full; `b_done` pulses
and the I5 timer repeatedly resets so `synth_b_pending` never asserts.
**Falsifier:** list empty / occupancy zero while `awready` is low ⇒ the blocker is
beyond XHB500 and this refinement is wrong.

**Probe list revised:** drop the id probes (constant). Probe hazard-list
occupancy / `list_pointer`, per-entry ADDRESS, the re-issued AW's `awaddr`,
`b_done` pulses, the I5 outstanding-timer, and `synth_b_pending`.

**Fix location is a hard constraint, not a preference.** XHB500 lives under
`/research/AAA/ip_library/…/xhb500` — lab-wide shared vendor IP that must not be
modified. Any fix belongs in the `tidelink_top` wrapper beside synth-B, or as a
documented local override copied into the project tree.

---

# RESULT: Prediction 6 FIRED — the conversion is RETRACTED

First baseline repeat tripped the falsifier:

    iter  arm       die_b_pre   die_b_post   die_a    rc
    1     tl035     0xad800000  0xad408020   WEDGED   1
    1     baseline  0xad800000  0xad408020   WEDGED   1   <-- ini_aw on the NO-FIX arm

That run md5-verified die_a `9eadebb8` / die_b `13573e46` = `a2lonly-28409f5`, the
arm proven to lack the fix. **The die_b signature is NONDETERMINISTIC** — the same
build yields all-clean on one draw and `ini_aw` on another. The original Arm A
all-clean was a draw, not a property of the baseline.

**Withdrawn:** the "TL-035 converts the failure signature" reading, and the causal
story beneath it ("unfixed ⇒ watchdog disarmed ⇒ recovery never completes ⇒ the
write never reaches die_b's AXI"). Prediction 4's NO-FIX branch goes with it.

**Survives:** die_a wedges on one AW byte-0 inject in BOTH arms (deterministic,
3/3). TL-035 is present + structurally verified and does not prevent it. The
`ini_aw` stall state is real and reached by BOTH builds. "Lost write response on
the return path" stays refuted (b clean, resp_err=0, both arms). Region F sampler
is alive. The rig delivers byte-exact on both builds.

**TL-035's honest status is now weaker than necessary-not-sufficient: NO
DEMONSTRATED EFFECT on this failure, in either direction.** Keep it on hygiene
grounds (it fixes a real permanent-disarm defect and is sim-clean); do not sign it
off as the wedge fix; do not revert it.

# CORRECTION: Predictions 4 and 5 were aimed at the WRONG BRIDGE

There are two XHB500 instances, and the machinery is split across them:

| instance | line | type | comment | carries |
|---|---|---|---|---|
| `u_xhb_sub` | :2474 | `xhb500_ahb_to_axi_bridge_chiplet_slv` (AHB→AXI) | :573 "ahb_sub → XHB500 AHB→AXI → chiplet controller **s_axi**" | hazard list (:1515), `.hmaster(12'd0)`, `sub_wr_os_ctr`, `sub_aw_accept = s_axi_awvalid & s_axi_awready` (:1570), synth-B, Fix K (:1895) |
| `u_xhb_mng` | :2556 | `xhb500_axi_to_ahb_bridge_chiplet_mst` (AXI→AHB) | :619 "chiplet controller **m_axi** → XHB500 AXI→AHB → ahb_mng" | `.awvalid(m_axi_awvalid)`, `.awready(m_axi_awready)` |

The observed stall is `m_axi_awvalid=1 / m_axi_awready=0` ⇒ **`u_xhb_mng`**. Every
hazard-list / `sub_wr_os_ctr` / synth-B / Fix K argument belongs to `u_xhb_sub` —
a different instance, opposite direction of travel.

**Therefore withdrawn:** "this maps onto TL-003/TL-005". Fix K and synth-B act on
the outbound path (this die's PS writes toward the link); the stall is on the
inbound path (remote writes going out to die_b's local AHB). Candidates (A)
same-address hazard and (C) list-full are `hazard_list` properties and cannot
explain an `m_axi_awready` stall.

**What survives:** the AXI firewall/timeout item (TL-037) is strengthened, not
weakened — synth-B watches `u_xhb_sub`'s counters and by construction cannot
observe an `m_axi_awready` stall on `u_xhb_mng` at all. It is the only backstop
that can see this class.

**Not yet traced, deliberately not guessed:** what holds `u_xhb_mng`'s `awready`
low — the AHB side not returning `hready` from die_b's fabric, the bridge FSM
stuck mid-burst after the recovery episode, or a prior incoming beat never
completing on AHB. The probe list must be re-based onto `u_xhb_mng` + `ahb_mng`
`hready` before a build is spent.

# OWNERSHIP FORK — one signal decides whether this is TideLink's bug at all

`u_xhb_mng`'s AHB-side `hready` is `.hready(ahb_mng_hready)` (`:2618`), and
`ahb_mng_hready` is an **input port** of `tidelink_top` (`:313`) — i.e. it comes
from outside, across the TideLink ↔ die_b-SoC integration boundary. Verified both
lines directly.

So reading that one signal at the wedge forks ownership:

| observation | meaning | owner |
|---|---|---|
| `ahb_mng_hready` **LOW** | `u_xhb_mng` is faithfully back-pressuring a downstream that never completes. The blocker is die_b's SoC AHB fabric/memory (nanosoc / eth-subsystem) — outside TideLink and outside XHB500. | different subsystem, likely different repo |
| `ahb_mng_hready` **HIGH** while `m_axi_awready` **LOW** | `u_xhb_mng`'s own AXI→AHB FSM is stuck. Vendor XHB500 (read-only tree) ⇒ wrapper-side workaround. | TideLink wrapper |

**Resolve this before spending an ILA build** — it is cheap and it may take the
defect off TideLink's plate entirely. The AHB `haddr` also names *which* die_b
slave is stalling.

**Probe list re-based** (hazard-list / `sub_wr_os_ctr` dropped — wrong bridge):
`u_xhb_mng` FSM state, `m_axi` aw/w/b valid+ready, and
`ahb_mng_{hready,htrans,haddr,hburst}`. `ahb_mng_hready` is the first-order
discriminator.

**Memory readback re-interpreted, and it gets cleaner:** a `u_xhb_mng` stall is
*before* the AHB write reaches die_b memory, so on an `ini_aw` run the data should
be ABSENT from die_b memory. On an all-clean run: present ⇒ H2 (completed, B lost
on return); absent ⇒ H1 (failed upstream).

**Nondeterminism now has a natural explanation:** whether `u_xhb_mng` refuses the
re-issued AW depends on whether a prior inbound beat is still draining on die_b's
AHB when the recovered AW lands — a timing race, and therefore run-to-run
variable. That is consistent with the observed signature scatter.

## Running signature tally (see hw_gate/repeats/SIGNATURES.tsv for the live table)

Original A/B: tl035 `ini_aw`, baseline all-clean.
Repeats so far: r1 tl035 `ini_aw`, r1 baseline `ini_aw`, r2 tl035 `ini_aw`.
So `ini_aw` is the common draw in BOTH arms and the single baseline all-clean now
looks like the outlier — which is exactly why the conversion did not survive.

---

# RESULT: H2 CONFIRMED on the all-clean draw (r3 tl035)

The rare all-clean draw arrived with a VALID inject (`errinject_rc=1`), and the
memory readback fired:

    die_b post 0x21E0 = 0xad800000   (ALL-CLEAN)   die_a WEDGED
    pre  VERIFY 16/16 byte-exact
    post VERIFY 12/16 byte-exact  firstbad=idx0 got0xb0008000 exp0xa5a50000
    LOCALMEM CHANGED at idx [0,1,2,3]
       idx0 0xa5a50000 -> 0xb0008000
       idx1 0xa5a50001 -> 0xb0008001
       idx2 0xa5a50002 -> 0xb0008002
       idx3 0xa5a50003 -> 0xb0008003
    idx4..15 UNCHANGED

**The value identifies the writer, so there is no confound with the liveness
soak.** `cov_errinject_sweep.py:266` computes
`base = (0xB0000000 | (data_id << 8) | (byte << 4) | bit)`; for AW (`0x80`),
byte 0, bit 0 that is exactly `0xB0008000`. And the sweep header states "exactly
ONE outgoing packet (the first after arming) is corrupted" — so resume word 0
**is** the injected beat.

⇒ **The injected, CRC-corrupted write's data LANDED byte-exact in die_b memory**,
along with the next three. Then nothing, and die_a wedged.

- die_b received, accepted and completed the injected write — the AW recovered,
  the data crossed, the write retired into die_b's memory.
- die_b's Region F is legitimately all-clean because die_b never stalled.
- die_a wedged anyway, waiting on completions that never returned.
- The 4-then-stop pattern fits outstanding-write exhaustion: die_a issues a few
  writes concurrently, all land, the Bs do not return, die_a blocks when its
  outstanding limit fills.

**Lost-B-on-the-return-path is RESURRECTED for the all-clean subset.** It stays
refuted for the `ini_aw` subset — a different draw, a different mechanism.

## The picture is three-way

| case | die_b signature | mechanism |
|---|---|---|
| injected, `ini_aw` draw (4/6 valid) | `0xad408020` | die_b INBOUND `u_xhb_mng` refuses the re-issued AW; the write never lands |
| injected, all-clean draw (1/6 valid) | `0xad800000` | die_b COMPLETES the write; the **B is lost on the return**; die_a starves |
| spontaneous, no inject | `0xad800000`, `wedge=False` | die_a OUTBOUND `u_xhb_sub` soak-wedge; die_b's taps are structurally blind to it |

The nondeterminism now has mechanism-level meaning rather than being noise:
whether die_b's inbound bridge accepts the recovered AW decides which of the
first two you get.

**Caveats held:** n=1 for the all-clean draw. Only 4 of 32 stream words landed, so
"die_b completed the write" is established for those four, not for the stream.
And WHY the B was lost is not shown — only that the data arrived and the
completion did not.

**Instrument split that follows:** die_b ILA for the inbound case; die_a JTAG ILA
(`u_xhb_sub` hazard occupancy / `sub_wr_os_ctr` / `synth_b_pending`) for the
outbound soak. On a spontaneous 6b failure the informative immediate capture is
**die_a's** state, not die_b's `0x21E0`.
