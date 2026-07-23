# Freeze Waiver — F14-B (data-mode wedge, no in-field recovery)

**Status:** proposed waiver for RTL freeze `integ/freeze-2026-07-21`. Requires David's sign-off.
**Gate artifact:** `xfail_f14b_datamode_wedge` — the one XFAIL in the otherwise-green gate (33 PASS + 1 XFAIL).

## The finding

A transient **data-mode** disturbance of two classes leaves the link wedged such that the
standard software re-bring-up (`to_data_mode` + CR/CRACK exchange) cannot clear it — only a
**full power-on reset of BOTH dies** recovers:

- `S1_s2m_data_flip` — an all-lane data-word flip during data mode → `WEDGES(unwedged only by full POR of BOTH dies)`
- `S1_s2m_clock_kill` — a link-clock dropout during data mode → `WEDGES(unwedged only by full POR of BOTH dies)`
- `S0_passthrough` (control) — a benign passthrough → `RECOVERS` (this clause is the instrument-sanity check; without it a broken injector would wedge for a trivial reason and the sentinel would report a comfortable XFAIL for the wrong cause).

**Architectural cause:** the SYNC beacon is off in data mode, so a framing slip has no re-anchor,
and `to_data_mode` never re-arms the deskew/calibrator. Evidence: [ERROR_INJECTION_FINDINGS.md](ERROR_INJECTION_FINDINGS.md),
sentinel contract in the Makefile above `sim_gate_xfail_f14b`.

## Why this is waivable for freeze

1. **Sim-only, and the disturbance class is severe/synthetic.** F14-B injects an all-lane
   simultaneous data flip or a hard link-clock kill *during live data mode*. On real KR260
   hardware the link delivers **12/12 byte-exact, in-order** with no such wedge observed in normal
   operation ([project_kr260_first_data_crossing_2026_07_22]).
2. **Recovery paths DO exist, just not fully in-field-automatic:**
   - `SWI_FORCE_RECAL` (B1) is proven to work **bilaterally on silicon** (cal_state 4→7→2;
     re-converges) — it recovers eye-calibration disturbances.
   - A **both-die POR** deterministically recovers every case. On KR260 this is a scripted
     power-cycle; there is no bench trip.
3. **Liveness is monitorable.** The only trustworthy liveness signal is a **tagged data canary**
   (every status register reads identical healthy-vs-wedged — "fcsm is not liveness," confirmed on
   silicon). A canary detects the wedge so the POR recovery can be triggered.
4. **Scope.** TideLink v1 is an honest functional prototype / first-silicon vehicle. A both-die-POR
   recovery for a severe transient fault is acceptable at this maturity; a self-healing path is an
   enhancement, not a correctness blocker for the gated datapath.

## Conditions of the waiver

- The wedge is **detectable** (tagged-data canary) and the **recovery is documented** (both-die POR;
  `SWI_FORCE_RECAL` for eye-cal disturbances). Both are in the KR260 runbook.
- The sentinel **stays in the gate**: `xfail_f14b_datamode_wedge` remains, asserting the exact
  signature. If a recovery path later lands, the `WEDGES` clauses stop matching → **XCHG** → the gate
  fails until the sentinel is promoted to a positive asserting regression. The waiver cannot rot
  silently.

## Post-freeze enhancement path (not blocking)

- A **retrain-lite** recovery: re-arm the deskew/calibrator on `to_data_mode` without a full POR.
- Keep a **periodic SYNC re-anchor** available in data mode (couples to the EPOCH/SYNC_REANCHOR work).
- When either lands, promote `xfail_f14b_datamode_wedge` to `sim_gate_f14b_recovers` (positive).

## Sign-off

- [ ] David — accept the waiver as stated for freeze `integ/freeze-2026-07-21`.
