# Handover → TideLink agent: port the a2l CDC self-heal to the AW/W/B replay nodes (TL-009 wedge)

**From:** nanoSoC eth-chiplet integration (KR260 two-board silicon), 2026-08-07 evening.
**One line:** The die_a wedge (TL-009) is your **a2l ACK-ptr CDC self-latch** — the fix you already
shipped on `WlinkGenericFCReplayV2_{12,13}` (continuous `w_inc` + ACK window-guard) was **never
ported to the AW/W/B data-plane replay nodes `_{1,3,5}`**, which is what both the FPGA V2 and the
ASIC V2 flists actually compile. Porting it is a **file-copy fix with per-node width re-derivation**.
This is the highest-leverage next step: it makes a lost-B **survivable** (no permanent self-latch),
which unblocks a real soak.

> **This is a SUGGESTION for your independent evaluation** — you root-caused this bug and own these
> nodes. In particular the width/bound re-derivation (§3) and whether all three channels need it
> (§5) are your call. I've made the mechanical part exact so you can accept/reject quickly.

Context: the data-drop (TL-001) is now essentially fixed by FIX D (`20af2b1`) + FIX 2 (`2c249ec`)
— W-direction crosses 37–50 consecutive byte-exact on silicon. The wedge is the **only** remaining
blocker, and it's the **B-return** direction. See `HANDOVER_HW_RESULTS_FRAMING_WEDGE_2026-08-07.md`
(⚠ its §5b synth-B idea is superseded by this doc) and memories `tl009-wedge-is-a2l-cdc-selflatch`,
`peerwrite-drop-is-phy-framing`.

---

## 1. The bug (verbatim from your own `_13` fix)

`src/rtl/local_overrides/WlinkGenericFCReplayV2_13.v:207-224`:

> Was edge-triggered (`w_inc = a2l_link_addr != a2l_link_addr_in`): a single ACK change pushes ONE
> transfer, then `w_inc` deasserts. On silicon (die_a async clock ratio) the WavMultibitSync mailbox
> occasionally delivers a **TORN value (0x1f)** into the app-side synced ACK → false `a2l_full` →
> `app_ready=0` → TX stalls → `a2l_link_addr` freezes → **NO further edge** → the torn value is
> **NEVER overwritten** → **PERMANENT self-latch** = the reproducible A→B cap at ~6 words. FIX: drive
> `w_inc` CONTINUOUSLY (=1) … P(permanent latch)=0.

**Why this is the die_a wedge, on my silicon:** witness `0x21F8 = 0xb5000521` decodes to
`sub_wr_os_ctr=0`, `hreadyout_raw=1`, HWM=1 — the **near-side XHB500 bridge fully recovered**, so the
stuck resource is **upstream in the replay window**, exactly where this self-latch lives. The
~1–4-to-~17-write wedge I measured is the "~6 words" cap. The `2c249ec`/`20af2b1` commit bodies
independently localise the residual to the **B-return** direction (die_a's marginal RX drops the
returning B; after ~(a2l window depth) losses the far-gated replay window fills → wedge).
`bit4=0` (non-bufferable) rules out the XHB500 EWR/hazard-list path, so `wr_hold_r`/Fix K are inert
here — do **not** chase it in the bridge.

## 2. What's fixed vs not (verified 2026-08-07)

| Node | Channel (a2l data-plane) | ptr width | depth | flist source | `w_inc` |
|---|---|---|---|---|---|
| `_12`, `_13` | (already-fixed siblings) | 5-bit `[4:0]` | 16 | **local_overrides** | `1'b1` ✅ |
| **`_1`** | AW/W/B | **4-bit `[3:0]`** | **8** | **deps/** (unfixed) | edge ❌ |
| **`_3`** | AW/W/B | **6-bit `[5:0]`** | **32** | **deps/** (unfixed) | edge ❌ |
| **`_5`** | AW/W/B | **4-bit `[3:0]`** | **8** | **deps/** (unfixed) | edge ❌ |

All three unfixed nodes have byte-identical shape (`deps/axi-chiplet-controller/logical/wlink/…`):
- `:56` `wire [W:0] a2l_link_addr_in = link_ack_update ? link_ack_addr : a2l_link_addr;` (no guard)
- `:116` `assign link_addr_to_app_clk_w_inc = a2l_link_addr != a2l_link_addr_in;`  ← the bug
- `:117` `assign link_addr_to_app_clk_w_addr = link_ack_update ? link_ack_addr : a2l_link_addr;`
- `:122-124` `a2l_link_addr <= 'h0; … else if (link_ack_update) a2l_link_addr <= link_ack_addr;`

## 3. The port (per node — mechanical, widths re-derived)

Create `src/rtl/local_overrides/WlinkGenericFCReplayV2_{1,3,5}.v` as copies of the deps files, and
apply the three edits below. **`W` = MSB index, `D` = FIFO depth** — per node: `_1`,`_5` → `W=3, D=8`;
`_3` → `W=5, D=32`. (Sanity: `D == 1<<W`, and it equals `a2l_full`'s addr-bit count = depth.)

**(a) Replace the `a2l_link_addr_in` line (`:56`) with the window-guard block** (ported from `_13:132-139`):
```verilog
// a2l ACK-ptr window guard (ported from _13, DAM 2026-07-07). Reject any ACK whose
// addr is outside the outstanding, sent-but-not-yet-acked window [a2l_link_addr, rbin_ptr]
// (lap-aware) or beyond FIFO depth. All operands are LINK-domain -> no new CDC path.
wire [W:0] a2l_ack_off_req = link_ack_addr    - a2l_link_addr; // requested advance (mod 2^(W+1))
wire [W:0] a2l_ack_off_max = fifo_io_rbin_ptr - a2l_link_addr; // outstanding window
wire       a2l_ack_valid   = link_ack_update
                           & (a2l_ack_off_req <= a2l_ack_off_max)
                           & (a2l_ack_off_max <= (W+1)'(D));   // depth clamp: _1/_5 4'h8 ; _3 6'h20
wire [W:0] a2l_link_addr_in = a2l_ack_valid ? link_ack_addr : a2l_link_addr;
```
Concretely the clamp literal is `4'h8` for `_1`/`_5` and `6'h20` for `_3`.

**(b) Continuous `w_inc` (`:116`)** — the actual self-heal:
```verilog
assign link_addr_to_app_clk_w_inc  = 1'b1;               // continuous resend (was: != edge)
```
**(c) Feed the guarded value + gate the latch on the guard (`:117`, `:123`):**
```verilog
assign link_addr_to_app_clk_w_addr = a2l_link_addr_in;   // was: link_ack_update ? link_ack_addr : …
// … in the always block:
end else if (a2l_ack_valid) begin                        // was: else if (link_ack_update)
  a2l_link_addr <= link_ack_addr;
```
This is exactly `_13`'s shape (`:224-225`, `:251`), only the widths/clamp differ.

## 4. Flist repoint (make the build compile the overrides)

Both flists currently pull `_1/_3/_5` from `deps/` and `_12/_13` from `local_overrides/`. Repoint
`_1/_3/_5` to `local_overrides/` (mirror the `_12/_13` lines):

- `flists/tidelink_fpga.flist`: line **190** (`_1`), **201** (`_3`), **203** (`_5`)
  `deps/axi-chiplet-controller/logical/wlink/…` → `src/rtl/local_overrides/…`
- `flists/tidelink_top_full_asic_v2.flist`: line **246** (`_1`), **257** (`_3`), **259** (`_5`)
  → `src/rtl/local_overrides/…` (the `_12/_13` overrides sit at 249/253; all three confirmed).

Grep both flists after editing: every `WlinkGenericFCReplayV2_{1,3,5,12,13}` line must resolve under
`src/rtl/local_overrides/`, and nothing under `deps/…` for those five. (The `imp/fpga/…ipshared/…`
and `imp/fpga/eth_chiplet_ip/src/…` copies are Vivado-packaged snapshots — the IP will need
re-packaging so the override reaches the FPGA build, same as any RTL edit.)

## 5. How to unit-test it (harness already exists)

`cocotb/tidelink_a2l_replay_cdc/` already A/B-tests this exact fix on `_13`:
`Makefile` picks `LOCAL_DUT = local_overrides/…_13.v` vs `DEPS_DUT = deps/…_13.v` (`USE_DEPS=1`),
`TOPLEVEL=tb_top`, `MODULE=test_a2l_replay_cdc`. Suggested:
1. **Reproduce-first:** run against a `deps` (unfixed) node and force the torn-ACK (`0x1f`) mailbox
   value — confirm the permanent self-latch (TX caps at ~depth words). Then run against the ported
   `local_overrides` node — confirm self-heal within ~1 mailbox round-trip.
2. **Per-width:** parametrise `tb_top`/`dut_src.f` for the `_1`/`_5` (4-bit/8) and `_3` (6-bit/32)
   geometries so the depth clamp is exercised at each width (a wrong clamp only bites at the lap
   boundary — the idle single-clock sim won't catch it, per your `_13` note "silicon is the verifier").
3. **Guard regression:** an in-window ACK must still advance exactly as before; an out-of-window /
   >depth ACK must be dropped (the Bug-A guard).

## 6. Scope / caveats (your call)

- **This makes a lost-B *survivable*, it does not stop the losses.** The B losses are caused by
  die_a's marginal physical RX eye (WNS −2.862, STA-invisible) — plausibly worsened by the
  **unconstrained D2D RX word clock** (no CTS tree; memory `d2d-rx-word-clock-unconstrained`). So
  expect this port to convert "wedge after ~6 writes" into "runs a long soak with occasional
  self-healed B-hiccups," not "zero hiccups." That's the win we need to *measure* the framing.
- **Which channels?** Memory says AW/W/B = `_{1,3,5}`; the wedge is B-return, but porting all three
  is low-risk and avoids mis-identifying the channel. Confirm the `_1/_3/_5`→channel mapping if you
  want to port only the B node.
- **ASIC vs FPGA divergence** (memory `asic-netlist-diverges-from-fpga-proven`): the ASIC V2 flist is
  a separate compile — repoint it too, and re-derive the clamp against whatever depths the ASIC build
  parametrises (verify they match the FPGA `_1/_3/_5` widths above; don't assume).

## 7. What I'll do on the eth-chiplet side
- Re-package the FPGA IP + rebuild once the override lands, then **bench the soak** (deploy `RUN_AFI=0`,
  bring-up, `swi`/turnkey, then a multi-write soak) — the success criterion is **die_a no longer
  wedges** (a lost-B self-heals) so we can finally characterise the framing land-rate POR-free.
- Read `0x21F8` across the soak to confirm `stall_stuck`/`wr_stuck` stop latching.

**Ask:** the §3 port on `_{1,3,5}` + §4 repoint, and your read on §6 (widths, which channels). One
change; it turns the wedge from fatal into self-healing and unblocks everything downstream.

## 8. Provenance
- Fix reference: `src/rtl/local_overrides/WlinkGenericFCReplayV2_13.v:132-139` (guard), `:224-225`
  (continuous `w_inc` + guarded `w_addr`), `:251` (gated latch). Sibling proof `WlinkGenericFCSM_6.v:1081`.
- Unfixed: `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_{1,3,5}.v:56,116,117,122-124`.
- Flists: `tidelink_fpga.flist` (190/201/203), `tidelink_top_full_asic_v2.flist` (246/257/259).
- Test: `cocotb/tidelink_a2l_replay_cdc/`. Silicon: `HANDOVER_HW_RESULTS_FRAMING_WEDGE_2026-08-07.md`.
