# RX-FIFO TWIN 2 — Disposition (verification-plan gap F10)

**Status (2026-07-19): CLOSED IN RTL.** Fix applied to the shared RTL, **tied off at
the silicon RX-FIFO instance**, and gated by `fifo_rx_twin2` in `SIM_GATE_ALL_SUITES`.
Root cause verified, reproduced in sim (A/B with teeth, negative control still
failing), intent answered with evidence.

> ✅ **F10 is closed in the RTL.** `src/rtl/tidelink_top.sv` instantiates the RX FIFO
> with `.ENABLE_AHB_WRITE (0)`, so an AHB write to the read-only RX aperture can no
> longer arm the packet-length latch or walk the FC-shared `write_ptr`. This is the
> **only** tie required — see §4.2 for why the other two candidate sites must *not*
> be tied. Remaining work is silicon/FPGA confirmation, not RTL.

- Defect class: same family as the shipped read-side phantom pop (`f9b94b7`,
  `project_rxfifo_empty_read_phantom_pop_2026_07_14`). This is its **write-side twin**.
- Owner artifacts: `cocotb/fifo_rx_twin2/` (bench), `docs/proposals/twin2_fix.patch`
  (the applied patch, kept for provenance), this document.
- Verified on `integ/consolidation-2026-07`, `2026-07-18`, VCS 2022.06, `TIDELINK_PHY_V2=1`;
  re-verified after application on `2026-07-19`.

- Defect class: same family as the shipped read-side phantom pop (`f9b94b7`,
  `project_rxfifo_empty_read_phantom_pop_2026_07_14`). This is its **write-side twin**.
- Owner artifacts: `cocotb/fifo_rx_twin2/` (bench), `docs/proposals/twin2_fix.patch`
  (proposal), this document.
- Verified on `integ/consolidation-2026-07`, `2026-07-18`, VCS 2022.06, `TIDELINK_PHY_V2=1`.

---

## 1. Root cause — verified against CURRENT RTL

`src/rtl/fifo/tidelink_fifo_ctrl.sv` (line numbers current as of this disposition):

- **The unguarded write-side length-latch arm — line 189:**
  ```systemverilog
  capture_write_length_nxt = valid_ahb_access && (haddr == RAM_ADDR_W'(1'd0)) && hwrite;
  ```
  ANY AHB write to offset 0 arms the packet-length latch. The next cycle
  (`capture_write_length_r`, line 201) captures `packet_word_length = clamp_length(hwdata)`
  and asserts `packet_active`. The **sibling read-side arm** (lines 206–207) received the
  `&& !rx_fifo_empty` phantom-pop guard on 2026-07-14; **the write arm got no equivalent
  guard.**

- **Completion fires on the paired write — line 109:**
  ```systemverilog
  wire ahb_write_complete = ahb_valid_transfer && (haddr == write_target_addr_r) && hwrite;
  ```
  With `packet_active_r` now set and `write_target_addr_r = (len+1)<<2`, a write to that
  offset fires `write_complete`, which walks `write_ptr` (line 122) and consumes credit
  (lines 272–273).

- **Why it is worse than the read-side twin — line 149:**
  ```systemverilog
  assign fc_translated_addr = fc_wr_addr + write_ptr_r;
  ```
  `write_ptr_r` is **shared with the FC committer** (the real silicon receive path). The
  read-side phantom pop only corrupted the *read* pointer; this corrupts the pointer the
  **hardware receiver writes through**.

**Trigger (minimal):** a driver "clears" or probes the read-only RX window by writing
zeros to offsets 0 then 4 — the write-side analogue of the phantom-pop drain sweep. Cycle
trace (empty FIFO, `write_ptr=0`, `credit=MAX=4096`):

| cycle | stimulus | effect |
|------|----------|--------|
| T0/T1 | AHB write `0` → offset 0 | `capture_write_length` → `packet_word_length=0`, `packet_active=1`, `write_target=4` |
| T2 | AHB write → offset 4 | `haddr==write_target` → `write_complete` → `write_ptr += (0+2)<<2 = 8`, `credit -= 2` |

## 2. Blast radius (re-derived + measured)

For a clear-write that latches length `L`, one completion does `write_ptr += (L+2)<<2` and
`credit -= (L+2)`. A zero-length clear-write pair therefore leaves **`write_ptr = 8`,
`credit = 4094`** for a packet that was never received. Downstream:

1. **Mis-framed receive.** The next genuine FC-committed packet writes its header at
   `fc_translated_addr = 0 + write_ptr_r = 8` → SRAM word 2 instead of word 0. The reader,
   addressing from `read_ptr = 0`, reads two stale words then the header — the packet comes
   back shifted (identical silicon signature to the read-side twin, but caused on the write
   side).
2. **Credit desync.** The local credit counter is now 2 below the peer's view for phantom
   traffic — a slow, cumulative leak of advertised buffer space on every stray write.

**Measured** (unfixed RTL, `cocotb/fifo_rx_twin2`): after the clear-write pair, a genuine
6-word-payload FC packet's header landed at **SRAM byte `0x0008`, not `0x0000`**; final
`write_ptr` and `credit` carried the extra `+8 / −2` offset. Exactly as derived.

## 3. Intent question — is AHB-write-to-RX supported anywhere? **NO.**

Grep evidence (`fpga/`, `src/sw/`, `scripts/`):

- **No runtime write ever targets the RX aperture.** Searching for a `wr`/`devmem`/poke to
  `0x84010000` / `0xA4010000` / `0x44010000` / `RXFIFO_BASE` / `GP1_RX` returns **nothing**.
- **Every access to the RX aperture is a READ.** `fpga/hw_regression/td_v2_hwlib.sh`:
  `GP1_RX=0x84010000  # GP1 RX DATA aperture — the REAL committed A->B data`, accessed only
  via `gp1_rx(){ b rd ... }` / `gp1_rx_d(){ "$1" rd ... }`. The hwlib header states plainly:
  *"txburst → read GP1 RX data aperture 0x84010000 for the byte-exact payload."*
- **CPU writes go to a different aperture.** `GP1_TX=0x84000000  # GP1 TX DATA aperture
  (txburst target)`. TX is a separate datapath, not this FIFO's AHB write.
- **RTL confirms the role.** `tidelink_top.sv:1391` labels the instance *"TideLink RX FIFO"*
  with the AHB slave *"FC adapter RX writes + CPU reads"* — i.e. received data is committed
  through the **FC direct-write port (`fc_wr_*`)**, and the CPU only **reads** the window.
- The **only** thing that AHB-writes to this block is the unit testbench
  (`cocotb/tidelink_fifo`), which reuses the AHB-write path as a test-injection shortcut
  because its `tb_top` ties the FC port off — which is exactly why sim was blind to the
  defect (the path is only ever exercised *positively*).

**Conclusion:** AHB-write-to-RX is not a supported silicon operation. Fix intent =
**reject / ignore AHB writes to the RX FIFO** (make them a no-op) while preserving the
legacy AHB-inject path for the unit TB.

## 4. Fix (proposal — `docs/proposals/twin2_fix.patch`)

Per the root-cause memory's recommendation, a parameter — **not** a new predicate (no
RTL-observable predicate distinguishes a legitimate TB inject from an illegitimate silicon
write; the distinction is *which port* and *which build*):

- `tidelink_fifo_ctrl.sv`: add `parameter ENABLE_AHB_WRITE = 1`; gate **both** the
  write-length arm (line 189) and `ahb_write_complete` (line 109) on `(ENABLE_AHB_WRITE != 0)`.
  With the default `1` the guards constant-fold away → **behaviour byte-identical to today**,
  so the existing 42-test `cocotb/tidelink_fifo` bench is unaffected.
- `tidelink_fifo_mem.sv`: add the param and forward it to `u_fifo_ctrl`.
- `tidelink_fifo.sv` (the RX FIFO): ~~instantiate `tidelink_fifo_mem` with
  `.ENABLE_AHB_WRITE(0)`~~ — **AMENDED ON APPLICATION, see §4.1.** It now declares
  `parameter ENABLE_AHB_WRITE = 1` and *forwards* it to `u_fifo_mem`. Read path, FC
  commit path, IRQ, and the sticky `underrun` reporter are all untouched.

The patch applied cleanly as written (`git apply` clean, 3 hunks) — but the third hunk
had to be amended after measurement; see below.

### 4.1 Amendment made when the patch was applied (2026-07-19)

The patch's premise for hunk 3 was that `tidelink_fifo` **is** "the one RX instance", so
hardcoding `.ENABLE_AHB_WRITE (0)` inside it was safe. **That premise was wrong, and was
caught by measurement, not review.**

`tidelink_fifo` is a *reusable wrapper*, not an instance. It has three RTL users
(`tidelink_top.sv:1417`, `tidelink_fifo_ahb.sv:148`, `tidelink.sv:96` — all RX, so the
*intent* was right) **and five testbench users** that instantiate it directly and
legitimately inject packets through the AHB slave: `cocotb/tidelink`, `cocotb/tidelink_ahb`,
`cocotb/tidelink_top`, `cocotb/tidelink_py_pair`, `cocotb/tidelink_system`.

Hardcoding `0` there therefore broke the AHB-inject path those benches depend on —
**measured: `cocotb/tidelink` went 25/25 → 10/25 (15 failures)**, verified as a true
regression by re-running the same bench against the pre-fix RTL (25/25). None of those
benches are in `SIM_GATE_ALL_SUITES`, so **the gate would not have caught this**.

The applied form keeps the patch's stated contract — *default 1 = byte-identical to today,
the integrator ties 0* — and simply moves the tie to where an actual instance exists:

> **DONE 2026-07-19 — see §4.2.** The tie landed at `src/rtl/tidelink_top.sv` only.

### 4.2 Where the tie-off actually belongs (measured, 2026-07-19)

There are **three** `tidelink_fifo` instantiation sites. Only one of them may be tied,
and the reason is the same in all three cases: **is the FC direct-write port wired?**
An RX FIFO with AHB writes disabled must still be fillable by the FC committer;
disabling both leaves a FIFO that nothing can write.

| Site | FC port wired? | In silicon path? | Action | Why |
|---|---|---|---|---|
| `src/rtl/tidelink_top.sv:1417` | **Yes** — real `fc_wr_*` from the FC adapter | **Yes** — the shipping RX datapath | **`.ENABLE_AHB_WRITE (0)`** | This is the defect's home. Closing it here closes F10. |
| `src/rtl/fifo/tidelink_fifo_ahb.sv:148` | **No** — `fc_wr_valid/write` hardwired `1'b0` | **No** — instantiated nowhere in `src/` | forwarded param, default **1** | Tying it 0 makes the FIFO **unfillable by any means** (measured: 4 of 14 `*_via_ahb` tests fail with no alternative path). And it buys zero silicon safety, since nothing instantiates it. |
| `src/rtl/tidelink.sv:96` (legacy) | **No** — `fc_wr_*` hardwired `1'b0` | **No** — only in `tidelink_ahb.flist` | untouched, inherits default **1** | Same as above; explicitly a legacy wrapper ("live builds use `tidelink_top.sv`"). |

**Correction to the §4.1 warning.** That warning said the tie-off would break "the five
benches" and demanded they be migrated to the FC port. That was over-broad — it described
the *hardcode-inside-`tidelink_fifo`* blast radius, which is not the blast radius of tying
at the integration points. Measured after the tie landed:

- The four benches that instantiate `tidelink_fifo` **directly** (`cocotb/tidelink`,
  `tidelink_top`, `tidelink_py_pair`, `tidelink_system`) keep the default `1` and are
  **untouched**. `cocotb/tidelink` = **25/25 with the tie-off in place**.
- `cocotb/tidelink_ahb` goes through `tidelink_fifo_ahb`, which is **not** tied → **14/14**.
- The 15 benches that reach the FIFO through `tidelink_top` **are** affected — and all pass,
  because they deliver data over the link through the FC port, which is exactly the path the
  fix preserves.

**No testbench migration was required.** The tie was placed where the FC port is genuinely
wired, so nothing lost its only fill path.

*Note:* the `overrun` sticky-flag's AHB-write term is intentionally left ungated — a stray
write to a full RX window may still raise the diagnostic `overrun` flag, which is harmless
(sticky, software-visible, no pointer/credit effect).

## 5. Reproduction + A/B result (the gate test)

Bench `cocotb/fifo_rx_twin2/` — mirrors the phantom-pop `test_41`/`test_42` template but
**exposes the FC direct-write port** so the genuine packet is committed through the real
silicon path, independent of the defective AHB write path. Checks are **whitebox on
`write_ptr` / `credit_count`** (immune to the SRAM X-init blindness that hid the phantom pop).

- `test_00_fc_commit_baseline` — genuine FC packet lands at base 0, credit correct.
  **PASS on both** configs (the instrument works).
- `test_01_ahb_clear_write_is_noop` — an AHB clear-write must not move `write_ptr` or burn
  credit (X-immune whitebox; primary check).
- `test_02_genuine_fc_packet_survives_ahb_clear` — end-to-end: stray AHB clear-write, THEN
  a genuine FC packet, which must land byte-exact at base 0.

The **only** difference between the two runs is which RTL the flist picks; `tb_top`
instantiates with `ENABLE_AHB_WRITE(0)` — honoured by the real fixed RTL, and ignored
(VCS `AOUP` warning) by the pre-fix copies. Each config uses its own `sim_build_<cfg>` to
defeat the stale-`simv` trap.

**A/B polarity flipped when the fix landed (2026-07-19).** Before, `unfixed` meant the
shared RTL (then buggy) and `patched` meant local `*.PATCHED.sv` copies. Now the shared RTL
is fixed, so the roles reverse:

- `FIFO_SRC=tree` (**the default, and what the gate runs**) → the real `src/rtl/fifo/*.sv`.
- `FIFO_SRC=unfixed` → frozen `*.UNFIXED.sv` copies of the pre-fix RTL, kept locally as the
  **negative control**. They are deliberately frozen and will drift; their only job is to
  embody pre-fix write-arm behaviour, which is historical.

The `*.PATCHED.sv` copies were **deleted** — with the fix in the tree, a gate that compiled a
private copy of it would prove nothing about what ships.

```
$ make ab      # (source ./set_env.sh; TIDELINK_PHY_V2=1)     [re-run 2026-07-19]
A: UNFIXED (frozen pre-fix copies)  ->  1/3 passed, 2 failed  ->  CORRECT (bug reproduced)
B: TREE (real shared src/rtl)       ->  3/3 passed, 0 failed  ->  CORRECT (fix holds in tree)
```

The negative control **must keep failing**. If `unfixed` ever passes, the test has gone
blind and the aggregate's green on this suite is worthless.

Unfixed failure signatures (the exact derived blast radius):
- `test_01`: *"an AHB write to the RX window BURNED credit (4096 -> 4094)"* + `write_ptr 0 -> 8`.
- `test_02`: *"the genuine FC packet's header was committed at SRAM byte 0x0008, not 0 —
  mis-framed"*.

**To run:** `cd cocotb/fifo_rx_twin2 && make ab` (or `make unfixed` / `make tree`).

## 6. Rollout to `sim_gate` — **DONE (2026-07-19)**

`fifo_rx_twin2` is in `SIM_GATE_ALL_SUITES` and the aggregate invokes
`sim_gate_fifo_twin2` immediately after `sim_gate_fifo`. The `FIFO_SRC=patched` pin is
**dropped** (it existed only to select the local patched copies), so the target now runs the
bench default — the real shared RTL:

```make
sim_gate_fifo_twin2:
	$(call sim_gate_run,fifo_rx_twin2,\
	  rm -rf cocotb/fifo_rx_twin2/sim_build_tree && \
	  $(MAKE) -C cocotb/fifo_rx_twin2 sim)
```

The negative control is **not** gated and never can be — it is expected to fail. Re-run
`make -C cocotb/fifo_rx_twin2 ab` by hand whenever the bench or the FIFO RTL changes.

### Post-apply verification actually run (2026-07-19)

| Check | Result |
|---|---|
| `make sim_gate_fifo_twin2` (the promoted suite, real RTL) | **PASS** 6 s, `TESTS=3 PASS=3 FAIL=0` |
| `make sim_gate_fifo` (`fifo_rx_phantom_pop`, sibling) | **PASS** 72 s, `TESTS=42 PASS=42 FAIL=0` |
| `make sim_gate_v2_data` (`v2_pair_data`, datapath) | **PASS** 14 s |
| `make sim_gate_asicelab` / `_v2` (param-list change → re-elaborate) | **PASS** 10 s / 11 s |
| `make -C cocotb/fifo_rx_twin2 ab` (negative control retains teeth) | unfixed **1/3 FAIL** (correct), tree **3/3 PASS** |
| `cocotb/tidelink` (25-test wrapper bench, the §4.1 regression check) | **25/25 PASS**, identical to the pre-fix baseline |

**Default-preservation evidence.** With `ENABLE_AHB_WRITE = 1` both guards are
`(1 != 0) && X`, which constant-folds to `X` — algebraically the pre-fix expressions.
Empirically: `cocotb/tidelink_fifo` (42 tests) instantiates `tidelink_fifo_mem` *directly,
without passing the parameter*, so it runs entirely on the default and **injects packets over
the AHB write path under test** — exactly the path that would break if the default were not
preserved. It is 42/42, unchanged. `cocotb/tidelink` (25 tests, via the wrapper) is likewise
25/25 against a measured pre-fix baseline of 25/25.

---

## Tapeout recommendation

**CLEARED FOR TAPEOUT 2026-07-19 (RTL).** The fix is applied, tied off at the shipping RX
FIFO (`tidelink_top.sv`), gated by `fifo_rx_twin2`, and shown not to regress anything
(42/42, 25/25, 14/14, full `sim_gate`). What remains is **on-silicon/FPGA confirmation**,
not RTL work — this defect has no observable-from-software signature until it mis-frames a
packet, so treat the gate as the primary evidence.

Historically, RX-FIFO TWIN 2 was a real, live, unguarded silicon defect
in the same class as the phantom pop that already reached hardware: an AHB write to the
CPU-read-only RX aperture walks the FC-shared `write_ptr` and burns credit, so a stray or
bulk "clear the window" access mis-frames the *next genuinely received packet* and slowly
desyncs credit from the peer. Evidence is unambiguous that no software legitimately writes
the RX aperture (every driver only reads it; committed data arrives via the FC port), so the
correct fix is to reject AHB writes to the RX FIFO — a default-preserving change
(`ENABLE_AHB_WRITE`, default 1, tied 0 at the **one** shipping RX instantiation) that changes
no other path and leaves existing test behaviour byte-identical (42/42, 25/25, 14/14
measured). It is proven to have teeth (unfixed 1/3, tree 3/3) with the exact
`+8 byte / −2 credit` signature. Low risk, high value — **and now landed**: the tie is in
`tidelink_top.sv` and the gate suite is wired into `sim_gate`. No bench migration was needed
(§4.2).
