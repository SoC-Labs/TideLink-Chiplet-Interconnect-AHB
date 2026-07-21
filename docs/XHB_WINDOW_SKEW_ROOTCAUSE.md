# XHB peer-window round-trip fails under EPOCH_PROFILE=silicon — root cause

**Author:** lane X-A (weekend continuation, 2026-07-17)
**Bench:** `cocotb/tidelink_top_pair_v2`, `test_v2_xhb_window` (VCS, `TIDELINK_PHY_V2=1`)
**Status of the fix below:** PROPOSAL — **NOT APPLIED**. No shared RTL, deps, or bench
files were modified. Instrumentation lives only in `cocotb/xhb_window_skew_debug/`.

---

## TL;DR

The failure is **not** a datapath-logic, credit, or framing bug, and it is **not** specific
to the XHB round-trip. It is a **missing/unarmed whole-word cross-lane corrector on the
receive datapath**:

- The V2 build compiles `src/rtl/local_overrides/WavD2DGpio_v2.v`, which **hard-selects**
  `SYNC_REANCHOR_EN(1'b1)` / `EPOCH_ANCHOR_EN(1'b0)` (lines **790 / 827**). There is **no
  `` `ifdef TIDELINK_EPOCH_ANCHOR `` selector** in the V2 override, so the Makefile
  `EPOCH_ANCHOR=1` knob is a **dead no-op** for V2 (proven below).
- The only corrector that *is* built (`SYNC_REANCHOR`) arms **only** when the SYNC beacon
  floods the RX in data mode. The peer-window/data bring-up
  (`pair_v2_common.do_to_data_mode`) writes `R8_SLOT0 = 0` → **beacon OFF** → SYNC_REANCHOR
  **never arms**. Runtime confirms: `epoch_anchored_o = 0`, `epoch_span_o = 0`.
- Therefore **any** real cross-lane whole-word skew on a receive direction **shears every
  word that crosses it**. `EPOCH_PROFILE=silicon` skews **only** the S→M direction, so the
  M→S (forward) path is clean and the S→M (return) path is corrupt.
- `test_v2_xhb_window` is the **first flow whose success requires the skewed S→M
  direction** — its write-completion **B-response** travels S→M. The write **request** and
  its data travel M→S (clean) and land byte-exact; only the B-response is lost, so
  `ahb_sub` never completes → timeout at **1,337,080 ns**.

**Stimulus verdict:** **FAIR in magnitude and config-faithful**, but its **premise is a
model**. The skew (S→M lane words `[3,7,5,4,6,3,7,5]`, spread 4, max 7) sits well inside the
deskew FIFO capacity (`DEPTH_LOG=5` ⇒ 32 deep, `EPOCH_OFF_MAX=24`) and the "no armed
corrector" config is the documented "as-built silicon bit-for-bit" build — so the test does
**not** unfairly disable a corrector the silicon has. What is *modelled* (not freshly
measured) is that **real silicon exhibits whole-word (16-bit-multiple) cross-lane epoch
skew**. Per MEMORY that premise is contested (real skew may be sub-word / untrained-lane;
"25 MHz byte-exact both dirs", "lane-7 skew refuted"). **If the premise holds, the round
trip WILL hang on hardware; Monday must measure the return-direction skew before treating
this as a live blocker.**

---

## 1. Reproduction (both directions archived)

| Run | Command | Result |
|---|---|---|
| PASS | `make MODULE=test_v2_xhb_window EPOCH_PROFILE=zero` | 4/4 byte-exact round-trips |
| FAIL | `make MODULE=test_v2_xhb_window EPOCH_PROFILE=silicon` | `TimeoutError: ahb_sub WRITE 0x40000000 did not complete` @ 1,337,080 ns |

Both runs print the **same** elaboration banner:

```
[tb_top] EPOCH_ANCHOR_EN: master=1 slave=1 (deskew: m=0 s=0)
```

Note the split: the `WlinkGPIOPHY` parameter reads **1**, but the **deskew instance reads
0** — the anchor the tb *thinks* it enabled is not in the datapath. That is the first thread.

Bring-up is healthy in **both** runs (identical up to the write):
`cal_done=1`, `fcsm=4`, `cr=1 crack=1` on both dies. The link "comes up clean"; the data
return path does not.

---

## 2. Instrument verification (house rule: verify the instrument first)

### 2a. The `EPOCH_ANCHOR=1` knob does nothing on V2 (stale Makefile/RTL comment)

- The V2 flist (`flists/tidelink_fpga_v2.flist:165`) compiles
  `src/rtl/local_overrides/WavD2DGpio_v2.v` — **not** `deps/tidelink-phy/rtl/wav/WavD2DGpio.v`.
- The **deps** file has the selector (`deps/.../WavD2DGpio.v:730-736`,
  `` `ifdef TIDELINK_EPOCH_ANCHOR → TL_EPOCH_ANCHOR_EN=1'b1 ``). The **V2 override does not**:
  it hard-codes `.EPOCH_ANCHOR_EN(1'b0)` (`WavD2DGpio_v2.v:827`). Its own comment at line
  826 ("EPOCH path stays available via the param") is **untrue for V2** — the identical
  untruth the deps file explicitly *fixed* (deps `:699-701`) was never ported here.
- **Proven, not assumed:** a **clean** rebuild (`rm -rf sim_build_silicon_anchor`) with
  `EPOCH_ANCHOR=1` — `+define+TIDELINK_EPOCH_ANCHOR` **confirmed present in the VCS compile
  line** — still prints `deskew: m=0 s=0` and still fails identically at 1,337,080 ns.
  ⇒ The decisive "does the EPOCH anchor rescue it?" experiment is **inconclusive by
  construction**: the anchor cannot be built into V2 at all. (Instrument trap; consistent
  with the campaign's 15 prior instrument failures — the Makefile's `EPOCH_ANCHOR` doc block,
  lines 96-111, is stale for the V2 flist.)

### 2b. The built corrector (SYNC_REANCHOR) never arms in this flow

`WavD2DGpio_v2.v:790` builds `SYNC_REANCHOR_EN=1`, but re-anchor arms only off a SYNC beacon
in the RX stream. `pair_v2_common.do_to_data_mode()` writes `R8_SLOT0 = 0`
(`R8_SLOT0_OFF`) ⇒ `swi_sync_insert_en = 0` ⇒ **no beacon** ⇒ re-anchor never arms.
Runtime probe on the master RX deskew (S→M consumer):
`epoch_anchored_o = 0`, `epoch_span_o = 0`. **No whole-word corrector is active.**

---

## 3. Forward/return split — the smoking gun

Instrumented probe (`cocotb/xhb_window_skew_debug/instr_xhb.py`, reusing the built
`sim_build_silicon` binary): issue the peer-window write, do **not** block on completion,
and watch the slave BRAM terminus + the master `hreadyout`:

```
[instr] master deskew epoch_anchored_o = 0
[instr] master deskew epoch_span_o = 0
[instr] FORWARD WRITE LANDED in slave BRAM[0]=0xcafef00d at +128 cyc
[instr] RESULT slaveBRAM[0]=0xcafef00d forward_landed=YES@+128
        (over 60000 cyc after write; completion handshake back over S->M)
```

- **Write REQUEST + data (M→S, clean): DELIVERED byte-exact** — `slaveBRAM[0]=0xCAFEF00D`
  128 cycles after issue. The slave XHB500 → `ahb_mng` → BRAM path is fine.
- **B-RESPONSE (S→M, skewed, uncorrected): LOST** — `hreadyout` stays low; the master XHB500
  `slv` never gets its `b` completion; `ahb_sub` times out.

### 3b. The shear is general, not XHB-specific

`test_v2_pair_data` under `EPOCH_PROFILE=silicon` (same binary) isolates it to *direction*:

```
[m2s] m->s: rx=[0x00240000, 0x0, 0xda7a0000, 0xcafebabe]   PASS   (M->S clean)
[s2m] s->m: rx=[0x00000001, 0x0, 0x0, 0x0]                 FAIL   (S->M sheared)
TESTS=3 PASS=2 FAIL=1
```

The S→M FC **packet** path is sheared identically. So the XHB window is not special — it is
merely the first success-critical consumer of the skewed return direction. (This is why the
blocking sim-gate runs pair_v2 only at `EPOCH_PROFILE=zero`, `Makefile:317-364`; the
silicon/staircase profiles live in the separate diagnostic `v2_gate` aggregate,
`Makefile:160`.)

---

## 4. Root cause (one statement, with file:line)

> Under `TIDELINK_PHY_V2`, the receive datapath has **no armed whole-word cross-lane
> corrector**: `src/rtl/local_overrides/WavD2DGpio_v2.v:827` hard-disables the EPOCH anchor
> (`EPOCH_ANCHOR_EN(1'b0)`, with no `TIDELINK_EPOCH_ANCHOR` selector — unlike deps
> `WavD2DGpio.v:730-736`), and the only built corrector `SYNC_REANCHOR_EN(1'b1)`
> (`:790`) never arms because bring-up leaves the SYNC beacon off
> (`cocotb/tidelink_top_pair_v2/pair_v2_common.py::do_to_data_mode`, `R8_SLOT0=0`).
> Consequently any whole-word cross-lane skew on a receive direction shears every word.
> `EPOCH_PROFILE=silicon` skews only S→M, so the XHB peer-window **B-response** (the sole
> success-critical traffic on the skewed direction) is corrupted and never decodes; the
> master XHB500 `slv` never completes and `ahb_sub` times out at 1,337,080 ns. The forward
> write data (M→S, clean) lands byte-exact, proving the datapath logic is correct.

**Hypotheses killed with evidence:**

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Datapath / XHB logic bug | ❌ killed | forward write lands byte-exact (`slaveBRAM=0xCAFEF00D`) |
| Credit / framing wedge | ❌ killed | M→S packets + XHB forward path deliver; only skewed dir fails |
| Write never reaches die_b | ❌ killed | slave BRAM written at +128 cyc |
| EPOCH anchor would rescue it (test misconfigured) | ⚠️ untestable on V2 | anchor not buildable in V2 override; clean `+define` no-op |
| No active whole-word corrector on the RX | ✅ **ROOT** | `epoch_anchored=0`, `span=0`; SYNC_REANCHOR unarmed (beacon off); S→M shears in *both* xhb and pair_data |

---

## 5. Proposed fixes (PROPOSAL — NOT APPLIED)

### Option A — RTL: restore EPOCH-anchor selectability in the V2 override (durable)

The EPOCH anchor is **training-exit-anchored** (`tidelink_lane_deskew_v2.sv` header): it
arms automatically at the peer's training→data edge and needs **no SYNC beacon** — exactly
the corrector this flow lacks. Port the selector the deps file already has. *In
`src/rtl/local_overrides/WavD2DGpio_v2.v`:*

```verilog
   // --- add above the tidelink_lane_deskew instantiation (~line 779) ---
`ifdef TIDELINK_EPOCH_ANCHOR
   localparam TL_EPOCH_ANCHOR_EN  = 1'b1;
   localparam TL_SYNC_REANCHOR_EN = 1'b0;   // mutually exclusive ($fatal if both)
`else
   localparam TL_EPOCH_ANCHOR_EN  = 1'b0;   // default: bit-identical to today
   localparam TL_SYNC_REANCHOR_EN = 1'b1;
`endif

   tidelink_lane_deskew #(
-      .LANES(8), .WIDTH(16), .DEPTH_LOG(5), .SYNC_REANCHOR_EN(1'b1),
+      .LANES(8), .WIDTH(16), .DEPTH_LOG(5), .SYNC_REANCHOR_EN(TL_SYNC_REANCHOR_EN),
       ...
-      .EPOCH_ANCHOR_EN(1'b0)
+      .EPOCH_ANCHOR_EN(TL_EPOCH_ANCHOR_EN)
   ) u_deskew ( ...
```

Default (no define) is **bit-identical** to today. `EPOCH_ANCHOR=1` then genuinely builds the
anchor. **Caveat (do not flip the default on sim evidence alone):** MEMORY + deps
`WavD2DGpio.v:723-728` record the EPOCH anchor losing the deskew unit test and showing an
unstable silicon span (0..12); it must be **A/B'd on hardware** against SYNC_REANCHOR before
becoming the default. This change only makes it *selectable*, matching what deps already
offers.

### Option B — arm the built corrector (weaker, likely insufficient)

Keep SYNC_REANCHOR but assert the SYNC beacon (non-zero `R8_SLOT0` / `swi_sync_insert_en`)
before peer-window traffic so re-anchor can engage on the return direction. **Not
recommended as primary:** deps `WavD2DGpio.v:718-721` and MEMORY both report that "forcing
the beacon on does not make it arm" and that SYNC_REANCHOR silicon arming is an open problem
(`tol5 sync_seen_vec=0x00`). List it only as an experiment.

### Option C — bench-gate + hardware readiness gate (the Monday-safe one)

Independent of which corrector ships, **gate on the RETURN direction before trusting the
transparent window**:

1. **Canary round-trip:** after bring-up, do one `ahb_sub` write **+ read-back** to a scratch
   peer address with a **bounded SW timeout**. If it does not complete OK, the return path is
   uncorrected — **do not** route real data through the transparent window; fall back to
   one-way push channels (which use only the clean forward direction — see §6).
2. **Corrector-engaged check:** read the PHY EPOCH/re-anchor status on the RX that carries the
   return direction (`epoch_anchored` / `epoch_span`, or the SYNC-reanchor `reanchored` obs)
   and require it engaged before enabling the window.

---

## 6. What Monday's hardware session must do differently

1. **The peer-window / AXI-FC round-trip is return-path-critical.** A healthy link
   (`cal=1`, `cr/crack` latched, `link_active`) is **necessary but not sufficient** — those
   indicators all use the clean/control path and **say nothing about whole-word coherence on
   the data return direction**. Do not infer "window works" from "link up".
2. **Run a bounded canary round-trip first** (Option C.1) before any real transparent-window
   traffic. On ZynqMP an undecoded/never-completing `ahb_sub` beat can wedge the PS. There
   *is* an RTL backstop — `tidelink_top.sv:1280-1357`, `SUB_STALL_TIMEOUT_LOG2` default **16**
   (~2^16 hclk) → the beat completes with **HRESP=ERROR** rather than hanging forever — but at
   slow silicon hclk that is a long stall and the write still **fails**. Give the canary a SW
   timeout **shorter** than 2^16 hclk and treat a non-OK result as "return path uncorrected".
3. **One-way push still works.** The forward (M→S) direction delivered byte-exact even with
   the return direction fully sheared. The **ethernet M0 frame relay is one-way** and should
   survive return-direction skew; the **transparent window / any read-back / any credited
   response is not** and is the real exposure. Prioritise accordingly for the demo.
4. **Measure the return-direction skew before believing this is a live blocker.** The whole
   failure hinges on the *premise* that silicon has whole-word (16-bit-multiple) cross-lane
   epoch skew. Capture the per-lane post-deskew alignment on the return direction (raw slice,
   not the saturating livematch — see MEMORY instrument traps). If the real skew is sub-word,
   the deskew's occupancy/bit-align handles it and the round-trip is fine; if it is
   whole-word, arm a corrector (Option A build, or Option C gate) **before** the demo.

---

## Appendix — artifacts

- Logs: `run_zero.log` (PASS), `run_silicon.log` (FAIL), `run_silicon_anchor_clean.log`
  (clean `+define+TIDELINK_EPOCH_ANCHOR`, still fails, deskew=0), `run_instr.log`
  (forward-lands/return-lost), `run_pairdata_sil.log` (S→M shear, 2/3) — in the session
  scratchpad.
- Instrumented test: `cocotb/xhb_window_skew_debug/instr_xhb.py` (read-only DUT peeks; reuses
  the built `sim_build_silicon` binary via `SIM_BUILD=sim_build_silicon`).
- Key source anchors: `WavD2DGpio_v2.v:790,827` · deps `WavD2DGpio.v:730-736` ·
  `pair_v2_common.py::do_to_data_mode` · `tidelink_top.sv:1280-1357` (stall backstop) ·
  `Makefile:96-111,160,317-364`.
