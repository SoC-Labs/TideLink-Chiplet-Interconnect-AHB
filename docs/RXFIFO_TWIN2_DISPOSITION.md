# RX-FIFO TWIN 2 — Disposition (verification-plan gap F10)

**Status:** root cause verified against current RTL, reproduced in sim (A/B with teeth),
intent answered with evidence, turnkey fix written as a proposal patch. **Not applied,
not committed** — shared RTL untouched.

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
- `tidelink_fifo.sv` (the RX FIFO): instantiate `tidelink_fifo_mem` with
  `.ENABLE_AHB_WRITE(0)` — the one intent-bearing line that turns AHB writes to the RX
  window into a no-op in silicon. Read path, FC commit path, IRQ, and the sticky `underrun`
  reporter are all untouched.

Only the read-only **RX** instance is tied off; the TX datapath and the unit TB (which
instantiates `fifo_mem` directly, default `1`) keep their AHB-write behaviour. The patch
applies cleanly (`git apply --check` clean, 3 hunks).

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

The **only** difference between the two runs is which RTL the flist picks (shared files are
never modified); `tb_top` instantiates with `ENABLE_AHB_WRITE(0)` — ignored (VCS `AOUP`
warning) on unfixed RTL, honoured on the patched copy. Each config uses its own
`sim_build_<cfg>` to defeat the stale-`simv` trap.

```
$ make ab      # (source ./set_env.sh; TIDELINK_PHY_V2=1)
A: UNFIXED RTL   ->  1/3 passed, 2 failed  ->  CORRECT (bug reproduced)
B: PATCHED RTL   ->  3/3 passed, 0 failed  ->  CORRECT (fix holds)
```

Unfixed failure signatures (the exact derived blast radius):
- `test_01`: *"an AHB write to the RX window BURNED credit (4096 -> 4094)"* + `write_ptr 0 -> 8`.
- `test_02`: *"the genuine FC packet's header was committed at SRAM byte 0x0008, not 0 —
  mis-framed"*.

**To run:** `cd cocotb/fifo_rx_twin2 && make ab` (or `make unfixed` / `make patched`).

## 6. Rollout to `sim_gate` (when the fix lands)

Add a suite alongside `sim_gate_fifo`, pinned to the **patched** config so the shared RTL
change is enshrined:
```make
sim_gate_fifo_twin2:
	$(call sim_gate_run,fifo_rx_twin2,\
	  rm -rf cocotb/fifo_rx_twin2/sim_build_patched && \
	  $(MAKE) -C cocotb/fifo_rx_twin2 FIFO_SRC=patched sim)
```
Once the patch is applied to the shared files, also switch the bench's default flist to the
shared tree (or keep the patched copies as the frozen A/B reference). Run the full 42-test
`cocotb/tidelink_fifo` bench post-apply to confirm the `ENABLE_AHB_WRITE=1` default leaves it
green (algebraically guaranteed; verify anyway per the sim-gate-before-deploy rule).

---

## Tapeout recommendation

**Apply the fix before tapeout.** RX-FIFO TWIN 2 is a real, live, unguarded silicon defect
in the same class as the phantom pop that already reached hardware: an AHB write to the
CPU-read-only RX aperture walks the FC-shared `write_ptr` and burns credit, so a stray or
bulk "clear the window" access mis-frames the *next genuinely received packet* and slowly
desyncs credit from the peer. Evidence is unambiguous that no software legitimately writes
the RX aperture (every driver only reads it; committed data arrives via the FC port), so the
correct fix is to reject AHB writes to the RX FIFO — a three-hunk, default-preserving change
(`ENABLE_AHB_WRITE`, default 1, tied 0 at the one RX instance) that changes no other path and
leaves the existing test suite behaviour byte-identical. It is proven to have teeth (unfixed
1/3, patched 3/3) with the exact `+8 byte / −2 credit` silicon signature. Low risk, high
value; ship it with the gate suite wired into `sim_gate`.
