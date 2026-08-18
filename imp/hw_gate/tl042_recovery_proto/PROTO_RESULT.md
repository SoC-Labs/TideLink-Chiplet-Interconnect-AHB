# TL-042 Option-1 recovery — cocotb PROTOTYPE result

**Scratch prototype for handoff. NOT a landing. Do not commit.**

Reproduces the XHB500 AW-not-accepted write-wedge
(`docs/DIAGNOSE_XHB500_RAW_HREADYOUT_LOW.md`) on the tidelink `u_xhb_sub` bridge
and validates the Option-1 synthetic-accept + synth-B-drain recovery, in an
isolated copy of `tidelink_top.sv`.

## Isolation proof (zero mutation of the shared tree)

`tidelink/src/rtl/tidelink_top.sv` md5:
- **start:** `3eb9f53d3207edb48acd59fd3b5b490a`
- **end:**   `3eb9f53d3207edb48acd59fd3b5b490a`  (unchanged)

Nothing under `tidelink/src/rtl/` or `tidelink/cocotb/` was edited. The build
compiles a LOCAL copy of `tidelink_top.sv` via a shim (`shim_fix.sv` /
`shim_orig.sv`) that `` `include ``s the copy by absolute path; the base flist's
`v2_tidelink_top.sv` line is sed-swapped for the shim at build time. Read-only
vendor IP under `/research/AAA/**` was never written.

## Files (all in this dir)

| file | role |
|---|---|
| `tidelink_top_orig.sv` | verbatim HEAD copy (control / unpatched) |
| `tidelink_top.sv` | Option-1 patched copy |
| `tl042_recovery.patch` | unified diff orig → patched (8 hunks) |
| `shim_orig.sv` / `shim_fix.sv` | build shims (`` `define TIDELINK_PHY_V2`` + include the copy) |
| `tb_top.sv` | copy of the recovery-suite two-die tb + a guarded wedge injector (`` `ifdef TB042_WEDGE_HOOK``) |
| `test_tl042_awwedge.py` | control + fix + edge-case cocotb tests |
| `test_tl042_diag.py` | cycle-by-cycle bridge-internal probe (used to find the mechanism) |
| `Makefile` | `make control` / `make fix` / `make all` |
| `control_clean.log`, `fix_clean.log` | clean captured logs (post Makefile fix) |
| `diag3.log` | cycle-by-cycle bridge-internal probe trace |
| `_snapshot_dam1n19_*/` | backup copy of the deliverables |

(The `*_clean.log` files are the authoritative runs, produced after the Makefile
default-goal recursion described under *Harness notes* was fixed.)

Reproduce: `source tidelink/set_env.sh` then `make control` and `make fix`
(each `rm -rf`s its sim_build first — stale-build trap). Stall timeout shortened
to `2^10` via `+define+TIDELINK_SUB_STALL_TIMEOUT_LOG2=10` so the wedge trips in
a sim-able window.

## The patch (Option 1, with the bench-driven refinement)

Hooks are exactly those the diagnosis named. New wrapper nets:
`s_axi_awready_brg` / `s_axi_wready_brg` (fed to the bridge `.awready`/`.wready`
instead of the raw downstream nets), `s_axi_awvalid_dn` / `s_axi_wvalid_dn` (fed
to the Wlink target instead of the raw bridge valids), `synth_aw_accept` /
`synth_w_accept`, and a `rec_active` recovery latch.

```
assign synth_aw_accept   = rec_active & s_axi_awvalid;      // held for WHOLE recovery
assign synth_w_accept    = rec_active & s_axi_wvalid;
assign s_axi_awready_brg = synth_aw_accept | (s_axi_awready & ~rec_active);
assign s_axi_wready_brg  = synth_w_accept  | (s_axi_wready  & ~rec_active);
assign s_axi_awvalid_dn  = s_axi_awvalid & ~rec_active;     // downstream fully masked
assign s_axi_wvalid_dn   = s_axi_wvalid  & ~rec_active;
rec_arm  = sub_stall_expired & s_axi_awvalid & ~s_axi_awready
         & (sub_wr_os_ctr==0) & ~synth_b_pending & ~rec_active;
rec_done = rec_active & ~s_axi_awvalid & (sub_wr_os_ctr==0)
         & xhb_sub_hreadyout_raw & ~synth_b_pending;
```
`sub_aw_accept` now keys on `s_axi_awready_brg`, so a synthetic accept increments
`sub_wr_os_ctr` and hands the write to the existing synth-B drain, which is
broadened to fire while `rec_active & sub_wr_os_ctr!=0`.

### KEY finding (why the naive Option-1 fails, and what a real fix must do)

The diagnosis' Option-1 sketch (a **one-shot** synthetic AW/W accept, `awready`
pulsed for a single beat) **does NOT recover** — proven in this bench. Root
cause, from the cycle-by-cycle probe (`test_tl042_diag.py`): the tidelink wrapper
holds its own address pipe (`pipe_valid_r`/`pipe_hsel_r`) so `xhb_sub_hsel` stays
**HIGH** for the entire wedge. The instant the single synthetic accept drains the
XHB500 stage-1 reverse slice, the bridge **re-latches the same held address**
(`buffer_full` goes 0→1 again — a phantom second AW), `raw` pulses high for
exactly **one** cycle, then the pipe clears, `hsel` drops, and the phantom AW is
left stuck (downstream still masked) → `raw` back to 0 forever. So a working
Option-1 must **hold the synthetic accept across the whole flush**, accepting
every re-presented AW/W beat until the bridge presents no more `awvalid` and its
slice is empty — which is what the patched RTL does.

## Control (unpatched copy) — reproduces the wedge

`make control` → `test_control_write_wedges_no_recovery` **PASS**:
```
[ctrl] after 3072 cyc: ahb_sub_hreadyout=0 raw=0 rose_at=None
       stall_ctr_max=1024 sub_wr_os_ctr=0 synth_b_pending=0
[ctrl] PASS: write WEDGED — hreadyout stuck 0 past the 2^10 timeout, no recovery
```
An outbound bufferable write is presented on `m_ahb_sub_*`; the downstream
`s_axi_awready`/`wready` are forced LOW (the wedge). The stall timer ramps to the
full `2^10` timeout and `ahb_sub_hreadyout` / `xhb_sub_hreadyout_raw` stay 0 with
no recovery — exactly the silicon hang. (`sub_wr_os_ctr` stays 0, confirming the
existing synth-B backstop is structurally blind, as the diagnosis states.)

## Fix (patched copy) — recovers

`make fix` → `test_fix_write_recovers` **PASS**:
```
[fix] recovered=True rose_at=966 hreadyout=1 raw=1 hresp=0
      synth_aw_fired=True@963 synth_b_fired=True rec_active_seen=True
      stall_ctr_max=1024 os_ctr_max=2
[fix] PASS: AW-not-accepted wedge RECOVERED via synthetic AW/W accept + synth-B
      drain; legal AHB termination (hresp=OKAY) at cyc 966
```
Cycle-accurate sequence (from the probe), recovery firing ~cyc 963 (well past the
`2^10` timeout — non-vacuous):

| cyc | synthAW | awready_brg | addr_readyout | os | synthB | raw | ahb_sub_hreadyout |
|----|----|----|----|----|----|----|----|
| 963 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | first synthetic AW accept; pipe still holds hsel |
| 964 | 1 | 1 | 1 | 1 | 0 | 1 | 0 | AW#1 drained, W accepted, raw pulses |
| 965 | 0 | 0 | 1 | 2 | 1 | 1 | 0 | phantom AW#2 accepted+counted, pipe clears, hsel drops |
| 966 | 0 | 0 | 1 | 1 | 1 | 1 | **1** | **RECOVERED** — legal AHB OKAY termination to the PS |

**AHB termination: OKAY** (`hresp=0`), matching the existing synth-B's OKAY
rationale (the write is treated as landed-but-response-lost, not SLVERR, to avoid
the PS write-retry loop the diagnosis notes).

## Edge case — mid-recovery link revival must not double-accept

`make fix` → `test_fix_double_accept_masked`: the test wedges, then the instant
`rec_active` asserts it drives the downstream `s_axi_awready`/`wready` HIGH
("link revives") and asserts, every cycle, that the Wlink-facing
`s_axi_awvalid_dn & s_axi_awready` (and the W equivalent) never coincide.

`test_fix_double_accept_masked` **PASS**:
```
[edge] link 'revived' (downstream ready driven HIGH) at cyc 963
[edge] revived=True rose_at=965 synth_b=True downstream_double_AW_cycles=0
       downstream_double_W_cycles=0 os_ctr_max=2
[edge] PASS: mid-recovery link revival did NOT double-accept — Wlink-facing
       valids stayed masked (dbl_aw=0 dbl_w=0), internal flush os_ctr_max=2,
       recovery completed at c=965
```
Zero downstream AW/W accepts across the whole window despite the link being
driven ready mid-recovery, and recovery still completed.


The mask is structural: `s_axi_*valid_dn = s_axi_*valid & ~rec_active`, so the
downstream valid is 0 for the entire recovery regardless of when the link
revives — the same AW/W can never be accepted by both the synthetic path and the
real downstream. NOTE `sub_wr_os_ctr` reaches **2** during recovery; that is the
wrapper-pipe re-latch (one extra AW beat), both beats synthetically accepted and
both masked from the downstream — it is *not* a downstream double-accept.

## Harness notes (bugs found & fixed in the bench itself)

- **Makefile default-goal recursion (FIXED).** cocotb's `Makefile.sim` sets
  `all: sim` as the default goal. My first-cut Makefile also defined
  `all: control fix`, which *merges* into cocotb's target → `all: sim control fix`.
  Because the `control`/`fix` recipes invoke `$(MAKE) … TESTCASE=…` with no
  explicit target, each no-target sub-make ran `all` = `sim` (the intended test,
  once — so the per-test results below are valid) **plus** `control`+`fix`, which
  recursed and spawned a growing chain of redundant `test_control` sims that
  polluted the logs and burned licenses until killed. Fixed by renaming the
  aggregate target to **`both`** so it no longer clobbers cocotb's `all`. Clean
  re-runs (`control_clean.log`, `fix_clean.log`) confirm a single, terminating
  process tree. If you see redundant runs, check for an `all:` collision first —
  this is NOT a concurrent session (I initially misread it as one).
- **Every invocation recompiles.** `flist_deps.mk` makes `simv` depend on all
  flist source files; several `src/rtl/local_overrides/*` files carry mtimes
  newer than any build here, so the staleness guard rebuilds each run (~4–5 min).
  Correct, just slow. The Makefile regenerates the shim-swapped flist only when
  its content changes (mtime-stable), so that is not an additional trigger.

## What is still uncertain / not covered

1. **W-beat / B-beat sequencing for bursts.** Validated only for a **single-beat
   word write** (`hsize=2`, `hburst=0`). The flush accepts every presented W beat
   until the bridge stops, but a multi-beat AXI burst (wlast timing, N synth-B)
   was not exercised. The diagnosis explicitly flagged this as bench-only —
   still open for bursts.
2. **synth-B drain vs. `bready` timing / hazard-list leak.** `raw` recovers as
   soon as the AWs are flushed and the slice empties (the EWR posted-write fast
   path), *before* the synth-B necessarily frees both XHB500 hazard entries. The
   PS-facing `hreadyout` completes regardless, but whether every hazard entry is
   freed (so a *subsequent* write is clean) was not proven — a phantom-AW leak in
   the depth-4 hazard list is possible and needs a back-to-back-write test.
3. **`rec_active` clean release.** `rec_done` requires `sub_wr_os_ctr==0`; if the
   synth-B cannot drain `os` to 0 (the item above), `rec_active` stays asserted
   and the downstream stays masked. The single-write master still completes, but
   a stuck `rec_active` would wedge *future* real traffic — must be made
   self-releasing (e.g. also release on `~awvalid & raw` after a bound).
4. **Real downstream `awready` is forced, never organically stuck.** The wedge is
   injected by a tb `force`; the recovery was not tested against a genuinely
   wedged Wlink target, and the "revival" is a forced level, not real link
   traffic. Interaction with a reviving FCSM/credit flow is unproven.
5. **Non-bufferable write path** (`hprot[2]=0`, non-EWR) not run; there the
   bridge waits for B before `raw` rises, so the synth-B is load-bearing for
   `hreadyout` — a different timing than the bufferable case shown here.
6. **Two-die harness, single die exercised.** Only the master die's sub-bridge is
   driven; no cross-die/PTP/TideChart interaction.

## Verdict

**Option 1 recovers the wedge in sim — the mechanism is sound — but it is NOT yet
ready to graduate to a real TL-042 patch. It needs more work.**

- The control reproduces the hang and the fix demonstrably clears it with a legal
  AHB OKAY termination, and the double-accept mask holds. That validates the
  *approach*.
- **The load-bearing correction for the owner:** a one-shot synthetic accept (as
  the diagnosis sketched) is insufficient — the wrapper's own held `hsel` re-latches
  the address, so the accept must be held across the full flush. This is the
  single most important finding to carry forward.
- Before landing, the owner must close items 1–3 above (burst beat-count, hazard
  drain / `os` leak, self-releasing `rec_active`), and re-validate against a
  genuinely (not forced) wedged link and the non-bufferable path. The synth-B
  clear was simplified in this prototype (`clear when os==0`) and diverges from
  the shipped F-1/F-2 `os<=1 & bready` semantics — that must be reconciled so the
  existing accepted-write-stuck backstop is not regressed.

Confidence the *approach* is correct: **high**. Confidence the *current RTL* is
land-ready: **low** — it is a proof-of-mechanism, not a finished fix.
