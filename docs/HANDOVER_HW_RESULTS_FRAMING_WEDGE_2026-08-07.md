# Handover → TideLink agent: silicon results for TL-001/TL-009 (235d758) + suggested next fix

> ## ⚠ UPDATE (2026-08-07, evening) — TL-001 largely fixed; wedge reclassified
> Since this doc, `20af2b1` (FIX D peer-aware S_HOLD release) and `2c249ec` (FIX 2 Hamming lock
> threshold 5→6) landed and were benched: **the data-drop (TL-001) is essentially fixed at the
> logic level** — W-direction went from 0/6 (my 235d758 bench) to **all 4 cycles landing, 37–50
> consecutive byte-exact writes**. Thank you. The residual **die_a wedge (TL-009) is now decisively
> the B-RETURN direction** (die_a's marginal RX eye drops the returning B → a2l replay window fills
> → wedge), which reclassifies it as **two contributors, NOT the synth-B path**:
> **(1) a2l CDC self-latch** — the continuous-`w_inc` fix on `WlinkGenericFCReplayV2_{12,13}` never
> ported to the AW/W/B nodes `_{1,3,5}` (a file-copy fix, widths re-derived per node); and
> **(2) physical B-return eye** — die_a RX WNS −2.862 vs die_b −1.752, STA-invisible, plausibly
> worsened by the **unconstrained D2D RX word clock** (no CTS clock tree; one missing
> `create_generated_clock` on the /16 recovered RX clock).
> **§5b below (chase the wedge in synth-B / shorten the timeout) is SUPERSEDED — disregard it.**
> The now-clear highest-leverage fix is the **a2l CDC port** (unblocks a full soak); the physical
> eye / RX-clock constraint is the deeper cure. See memories `tl009-wedge-is-a2l-cdc-selflatch`
> and `d2d-rx-word-clock-unconstrained`, and the `2c249ec`/`20af2b1` commit bodies.

**From:** nanoSoC eth-chiplet integration (KR260 two-board silicon), 2026-08-07, afternoon.
**One line:** I benched **`235d758`** on the two-board KR260 pair. The `0x21F8` witness **confirms
your framing root cause on silicon** (drop + die_a wedge are one bug, non-bufferable); the
`swi_training_mode` re-frame pulse is an **unreliable lottery** (landed 0/6 this session); and the
**die_a write-stall wedge is the gating blocker**. Everything below the results is a **suggestion
for your independent evaluation**, not a directive.

Companion docs: `HANDOVER_PEERWRITE_DATADROP_UNITTEST_2026-08-07.md` (carries a ⚠ correction — the
`wr_hold_r`/EWR mechanism is *not* the silicon cause), and the `235d758` commit body.

---

## 1. What was tested

- **Bitstream:** `235d758` (`kr260-eth-chiplet` md5 `8f2b7b91626d`, `-flip` md5 `b09648001c20`),
  already loaded on both boards — verified, no rebuild. Deploy `RUN_AFI=0`.
- **Dies:** die_a = kr260_01 = 10.22.24.159 (initiator/master); die_b = kr260_02 = 10.22.24.153
  (target/slave).
- **Bring-up:** turnkey `kr260_eth_bringup_pair.sh` → **both dies FCSM=4 + reanchored** (autonomous
  AUTO_ANCHOR, try 2). Witness `0x21F8 = 0xb5000001` both dies (clean pre-write; `0xB5` marker
  present ⇒ the witness bitstream is genuinely live).
- **Re-frame:** bilateral `swi_training_mode` pulse via `bringup_pair_release.sh`
  (arm→barrier(S_HOLD)→release), the FIX-3 recipe from your `e5bd29c` commit.

## 2. Results

| Test | Outcome |
|---|---|
| Baseline cross-die write `0x2F001000 ⇐ 0xC0FFEE01` (→ die_b `0x2D001000`) | **DROP** — die_b reads `0x00000000` |
| die_a witness after that write | **`0x21F8 = 0xb5000521`** (see decode) |
| die_a liveness | alive (synth-B completed the store; PS not hung *yet*) |
| Re-frame pulse, then re-test (fresh payload `0xD00DFEED`) | **DROP** — die_b still `0x00000000` |
| Re-frame **lottery**, 6 attempts, unique payload each | **0 LANDS / 6** |
| die_a during the lottery | **wedged within ~1–4 dropping writes each round** — needed **5 JTAG-PORs** |
| die_b witness throughout | stayed `0xb5000001` (target-side bridge clean) |

So a *clean-looking* bring-up (reanchored, FCSM=4) still drops, and the drop is on **die_a's
outbound XHB500 `ahb_sub` bridge** (initiator side), not die_b.

## 3. Witness decode — `0x21F8 = 0xb5000521` (the dropping write, die_a)

```
[31:24]=0xB5 marker
[10]=1  xhb_stall_stuck_sticky   -> hreadyout low >= 2^12 CONSECUTIVE hclk, at least once
                                    (NOT a deadlock -- see the correction note below)
[9] =0  sub_err_sticky           -> no read ERROR backstop
[8] =1  sub_wr_stuck_sticky      -> synth-B backstop FIRED (completed the PS store)
[7:5]=001 sub_wr_os_hwm=1        -> one outstanding write high-water
[4] =0  pipe_hprot_r[2]=0        -> NON-BUFFERABLE  (NOT the EWR/hazard-list path; Fix K & wr_hold_r N/A)
[3:1]=000 sub_wr_os_ctr=0        -> drained (by synth-B)
[0] =1  xhb_sub_hreadyout_raw=1  -> bridge ready again post-synth-B
```

> **CORRECTION 2026-08-24 — bit [10] carried no weight in this decode.**
> The line above originally read "(far-B never returned)", treating [10] as a
> deadlock witness. That inference is retracted. On 2026-08-24, kr260-pair-onchip,
> across TWO bitstreams and BOTH dies, `0x21F8` moved `0xB5000001 -> 0xB5000421`
> (bit [10] SET) while every one of 24/24 cross-die reads returned 256/256 words
> BYTE-EXACT and [9] stayed 0 — evidence
> `td-bisect/kr260-integ-2026-08-24-results/AB_SUMMARY.json`. **Bit [10] sets during
> entirely healthy traffic**, because it latches on 4096 consecutive unready hclk
> and a normal cross-die round trip exceeds that; being sticky, the first such
> transaction latches it for the session.
>
> What survives in the decode below is [8]=1 (`sub_wr_stuck_sticky`, synth-B
> genuinely fired) — that, not [10], is the load-bearing evidence for a write-path
> problem here. The wedge discriminators are **[9] high** and **[0] low-and-stuck
> across repeated polls**; in the healthy 2026-08-24 capture [8] and [9] were both
> 0 and [0] was 1.

This is the `235d758` commit's signature reproduced **exactly**. It matches your causal chain:
bad framing → W/B round-trip corrupted → **no far-B** → die_a bridge stalls ≥2¹⁶ → synth-B →
repeated stuck writes accumulate an FC-node resource → **die_a wedge**.

## 4. Interpretation (what I'm confident of, and what I'm not)

- **Confident:** the drop is **PHY framing**, confirmed independently by the witness. Non-bufferable,
  so `wr_hold_r`/Fix K are not the operative fix here (consistent with the correction on the other
  handover). TL-001 (drop) and TL-009 (wedge) are one bug.
- **Confident:** the `swi_training_mode` re-frame is a **genuine lottery and unreliable** — 0/6 here,
  worse than your `e5bd29c` note (~1 land / 2 drops). Not something to ship a demo on. The
  centering-on (`min_lock_dwells=1`) in `235d758` did not make it deterministic.
- **Confident:** the **die_a wedge is the gating blocker** — it wedges within ~1–4 dropping writes,
  so no robust soak is possible; every characterisation run dies to a POR.
- **Not sure (your call):** whether this session's eye was unusually bad (a worse-than-typical
  lottery draw) vs. a real regression. I POR-recovered 6×; the framing stayed bad all session.

## 5. Suggested next fix — wedge mitigation FIRST (this is a suggestion)

Two open items; I'd **sequence the wedge mitigation before autonomous framing**, because it unblocks
everything else:

**(b) Wedge mitigation — make a dropped write *survivable* (highest leverage).**
Right now one lost far-B → ~2¹⁶ stall → synth-B, and repeated losses accumulate until die_a wedges.
Your `235d758` commit already names the fix: *"make the synth-B backstop also clear the die_a
FC-node outstanding so stalls don't accumulate, and/or shorten the stall timeout."* Concretely, worth
your evaluation:
- On `sub_wr_stuck_fire` / synth-B drain, also retire the corresponding **outbound FC-node**
  outstanding entry (the AW/W node that never got its B), so the resource returns instead of leaking.
- And/or drop `SUB_OUTSTANDING_TIMEOUT_LOG2` from 16 so a lost-B is retired in ~ms not ~10s (less
  time for the PS interconnect to saturate behind the stall).
- Success criterion: a dropping write no longer wedges die_a → a soak can run to completion and
  *characterise* the framing lottery (land-rate) robustly, POR-free. That's the tool you need to
  even measure whether (a) works.

**(a) Autonomous framing — the real cure (harder, less certain).**
Make the lane framing deterministic so W+B cross on *every* bring-up, not a lottery — so the
`swi_training_mode` pulse isn't needed. The calibrator terminal-latch + centering-on were the first
attempt; the 0/6 here says it's not there yet. This is your domain; I have no specific RTL proposal,
only the silicon evidence that it remains open.

**On `wr_hold_r`:** keep it (correct latent fix for the bufferable path) but it is not exercised by
this failure. No action needed.

## 6. How to reproduce (recipe)

```
# both boards leased; 235d758 loaded (RUN_AFI=0)
bash kr260_eth_bringup_pair.sh                 # -> both FCSM=4 + reanchored
poke die_a/die_b: eth_tlapb_poke.py read 0x21F8  # expect 0xb5000001 (clean, 0xB5 marker)
# wait AUTO_ANCHOR done=1 (beacon deletes app writes until then)
kr260_eth_run.sh xfer_send  (die_a, payload P)   # cross-die write
kr260_eth_run.sh xfer_recv  (die_b, expect P)    # -> 0x00000000 = DROP
poke die_a: read 0x21F8                           # -> 0xb5000521 (stall+wr_stuck+HWM, non-buf)
# re-frame lottery: bringup_pair_release.sh ; re-test ; repeat  (0/6 landed this session)
```

**Single-target JTAG-POR** (the board-level `fpgahub board reset kr260_01` chokes on the
method-less `kr260_01_pl` member and never resets the PS): POST to the fpgahubd unix socket on
mapstone-dev —
```
curl --unix-socket /run/fpgahub/fpgahub.sock -X POST \
  http://localhost/api/v1/targets/kr260_01/reset \
  -H 'Content-Type: application/json' -d '{"method":"default","confirm":true}'
```
die_a recovers in ~60–90 s; then redeploy with `RUN_AFI=0` (POR clears the runtime PL load).

## 7. Provenance
- Bitstream `235d758` (branch `fix/tl001-calibrator-terminal-latch`), witness at
  `tidelink_top.sv:1688-1731` → APB `0x21F8`. Reset via socket (§6). Full session write-up in the
  eth-chiplet repo memory `peerwrite-drop-is-phy-framing.md`.
- Rig left clean: die_a POR-recovered, both leases revoked, both boards up.

**Ask of you:** evaluate the wedge-mitigation (§5b) — is retiring the outbound FC-node outstanding
on synth-B drain the right shape, and can `SUB_OUTSTANDING_TIMEOUT_LOG2` be safely shortened? That
one change would let us soak and measure the framing lottery instead of POR-ing every few writes.
