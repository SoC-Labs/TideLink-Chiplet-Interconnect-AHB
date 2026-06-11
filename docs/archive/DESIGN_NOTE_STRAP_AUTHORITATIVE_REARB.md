# Design note — strap-authoritative role assignment under boot skew

**Status: DESIGN ONLY (2026-06-11). Not implemented; not required by the I2
contract.** Captured while closing the I2 gate (test_24) and the V4
zero-poke first-silicon run, both of which exhibit the behaviour.

## The behaviour

Under asymmetric POR/boot (any skew from ~100 µs to seconds), the **late die
wins arbitration and becomes master**, regardless of strap priority. Seen
deterministically in sim (test_24, all 3 skew points) and on silicon (V4
zero-poke, 2026-06-11).

## Why — traced mechanism (not the obvious one)

The early die does NOT fallback-park: the global `nego_timeout` is ~2.6 s,
so at realistic deploy skews it is still actively cycling
WAIT→CLAIM→NACK-retry when the peer boots. It loses because of *phase*, not
*exhaustion*: the late die walks straight through its short ST_NEGO_WAIT
backoff to CLAIM, while the early die is at a random point of a NACK-retry
backoff. First claim on the wire wins; the early die's `sda_start_detect`
fires and it takes the early-exit → ST_NEGO_DONE-lost. Strap priority only
decides when both dies enter ST_NEGO_WAIT together (the symmetric-POR case,
test_22).

## Why the "easy" fixes don't work

1. **Re-arbitrate after lock** — violates the role-lock invariant
   (`role_locked` is sticky until poresetn BY DESIGN; `wlink_por_reset =
   ~poresetn | ~role_locked` — unlocking tears the link down). Rejected.
2. **Don't lock on solo exhaustion** — misdiagnosis; the early die never
   reaches a fallback/exhaustion site at deploy-scale skews (see above).
3. **Shorten the early die's retry backoff** — narrows but cannot close the
   race window; whoever claims first still wins.

## Viable designs (pick when the feature is actually needed)

**A. Priority-carrying CLAIM + yield (protocol change, preferred).** The
CLAIM transaction carries the claimer's 16-bit priority byte(s). A die that
receives a peer CLAIM while its own priority is *better* responds with a
YIELD-NACK instead of ACK; the claimer backs off to ST_NEGO_WAIT and the
yielding die claims. Bounded by a yield-count cap to preserve liveness.
Touches: `tidelink_autoneg.sv` CLAIM/POLL arms + the I2C slave-side
responder + `docs/i2c_train/I2C_TRAIN_PROTOCOL.md`. Backward-compatible if
gated on a NEGO_CFG bit (needs `nego_cfg_reg` widened 7→8 bits; APB slot 4
has headroom).

**B. SW role-swap epilogue (no RTL).** Post-link-up, software reads both
dies' roles; if swapped vs strap intent, cycle poresetn on both (or use the
peer aperture once trusted) and rely on near-simultaneous restart →
symmetric arbitration → strap decides. Zero RTL risk; costs one extra
bring-up cycle when a swap is detected; not available in a zero-poke flow.

**C. Defer (current position).** All TideLink machinery is role-symmetric
(addressing via PAIR_BASE, FC nodes, PTP). Nothing currently depends on
which physical die is master. Revisit only if a consumer (e.g. fixed
PTP grandmaster placement, asymmetric board capabilities) makes physical
role placement matter.
