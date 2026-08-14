# N1 independent verdict — this session (dam)  — LOCKED 2026-08-14

Independent attempt under the two-session no-mid-flight-exchange protocol. This is my judgment layer
over the directed-sim evidence in this directory (`EVIDENCE.txt`, the four `*.log` files) produced by my
own test `cocotb/tidelink_axi_datanode_recovery/test_n1_readbackstop_suppress.py`. I have NOT read the peer's
`imp/hw_gate/n1_repro/` construction or verdict.

## VERDICT: N1 is a REAL RTL masking defect (reproduced cycle-exact), CONDITIONAL, with reachability OPEN.

### CONFIRMED (measured, matches the RTL)
For a coincident stuck read + **≥2** stuck writes, at shared-timer expiry T:
- write fires `synth_b_pending` (`:1865`), which **masks both** read-ERROR cycles at `:1898/:1906`
  (`err1@T+1`, `err2@T+2`) because synth-B drains one write/cycle (`:1870` needs `ctr<=1` to clear) so it
  stays asserted ≥2 cycles;
- `sub_rd_os_r` is cleared unconditionally (`:1675`); the re-fire sites are `if (sub_rd_os_r)` (`:1645/:1674`)
  so the read ERROR can **never re-fire**;
- result: **zero `HRESP=ERROR` at the port**, read abandoned → a real AHB master on that read would hang.
Cycle-by-cycle trace is in `EVIDENCE.txt` and matches my own static RTL reading exactly.

### CONDITIONAL / more cautious than the raw sim (my judgment)
1. **`ctr==1` self-heals ONLY because `bready=1`.** With `bready=1` synth-B drains in one cycle, the mask
   lifts at T+2, `err2` delivers `HRESP=ERROR`. But that self-heal **depends on prompt synthetic-B
   acceptance**; a **B-backpressured** path could hold `synth_b_pending` up and mask both cycles even at
   `ctr==1`. The sim tested only `bready=1` — I do NOT call `ctr==1` universally safe.
2. **Reachability is OPEN, not closed.** The sim found **no real-traffic path** to
   `sub_rd_os_r=1 ∧ sub_wr_os_ctr>=2` from the `ahb_sub` port (XHB500 serialises a read behind outstanding
   writes; the coincident state was reachable only by `Force(s_axi_arvalid)` at the internal bus). That is
   strong but it is **absence-of-evidence from one port / one scenario, not a proof no path exists** — a
   different master, a different ordering, or a non-`ahb_sub` reader is untested. Severity turns on this and
   it is unresolved.

### RECOMMENDATION
- **Fix regardless — it is cheap and it closes a latent hang.** The read backstop must not be gated by
  `~synth_b_pending` at `:1898/:1906`, and/or the shared timer/predicate (`:1573`) should be split so a
  write backstop cannot swallow the read's escape. This is the same class as TL-042 (a recovery bit that is
  also a mask term for another mechanism).
- **ASIC weight is high.** On the ASIC the FCSM recovery is stripped from the flist, so the `tidelink_top`
  backstops are the ONLY recovery — a masking bug that disables the read escape is exactly the thing with no
  fallback there. That raises the value of the cheap fix even while reachability is unproven.
- **Resolve reachability separately** to fix severity: is there ANY path (any master/port/ordering) to a
  read outstanding alongside ≥2 outstanding writes? Not from `ahb_sub` in my test — but that is not "never".

### Status of claims
CONFIRMED-by-measurement: the masking + no-re-fire chain for ctr≥2. INFERRED (not directly timed): that a
real AHB master would hang (could not attach a real master to the masked read given the Force-only construction).
OPEN: reachability, and the `bready`-starved `ctr==1` extension. Fix recommendation stands on the confirmed
defect alone, independent of reachability.
