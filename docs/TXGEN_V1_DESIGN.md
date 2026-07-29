# v1 PL-side TX traffic generator — design

**Status (2026-07-24):** design agreed; **`src/rtl/tidelink_tx_gen.sv` written and elaborating
clean** (VCS `+lint=all`, standalone). `TXGEN_PRESENT` / `TXGEN_CREDIT_GATE_DIS` parameters
added to `tidelink_top.sv`; full-design elaboration re-verified green
(`flists/tidelink_fpga_v2.flist`, 78 modules, rc=0).
**WIRED on branch `feat/txgen-v1-integration`** (not merged to main): 2:1 TX mux + Region-E
shim in `tidelink_top.sv`, `pair_credit_count` / `hw_credit_consume_*` through
`tidelink_apb_regs.sv` → `tidelink_fifo.sv` (as a 3-way net-delta combine), and the module
added to all 5 flists carrying `tidelink_fc_adapter.sv`. Verified:
- full-design elaboration **rc=0, 79 modules** (V2 flist);
- **`TXGEN_PRESENT=0` ⇒ 78 modules** — the block and its mux are genuinely gone, so the
  tapeout netlist is unchanged (test a3);
- **`test_v2_pair_data` 3/3 PASS** with the generator present-but-disarmed — the
  proven-datapath regression is unaffected (test a2).

**Still outstanding before this is usable:** the §4 unit env (`cocotb/tidelink_txgen/`, tests
a1/b1/c1), the pair saturation/credit tests (b2/b3/b4/c2) and the **mandatory negative control
c3**, the RDL/header regen, `sim_gate` wiring, and `package_ip` (Tier-0.a IP-MATCH will
hard-fail until it re-runs — that is the gate working as designed).
**Why it exists:** on FPGA the measured per-word cost is ~96 PL cycles of PS→PL store round
trip while the link needs ~16 ⇒ **the link is ~83% idle**. Every throughput improvement we
want to benchmark (FC batching, deeper skid, address suppression) is therefore **invisible to
a PS-driven workload** — the bottleneck is the Zynq bridge, not the link. The generator is
not "one optimisation among several": it is **the instrument that makes every later
version-over-version comparison measurable**. See `docs/HANDOVER_LINK_GUI_Z2_2026_07_24.md`
§10a for the metric consequences.

---

## 1. Placement — generator masters the EXISTING AHB TX port

`tidelink_tx_gen.sv` sits inside `tidelink_top.sv` and drives a **2:1 mux** between the
top-level `ahb_tx_*` inputs (`tidelink_top.sv:238-247`) and the `u_fc_adapter` instance
(`:1580-1589`).

**Rejected — injecting FC words inside `tidelink_fc_adapter` (past the AHB layer).** That
bypasses precisely the logic under measurement and the logic that has produced every silicon
TX bug on this campaign: the held-NONSEQ one-shot lock (`tidelink_fc_adapter.sv:200-244`, the
×5 duplicate-FC-word defect), the Bug-A honest-back-pressure completion rule (`:326-346`), the
`TX_STALL_TIMEOUT` ERROR backstop (`:311-346`), and the arbiter interaction with the
returner's sideband credit packets (`:433-546`). A number produced past those is one no real
master could ever reproduce.

**Rejected — AXI DMA / datamover in the BD.** Costs new BD cells, an AXI master port, a new
aperture (on KR260 that means editing `addrmap.tcl` and re-satisfying its 5-part self-check),
a DDR buffer and a host driver — **per target, across two board families** — and the transfers
would *still* be filtered through `axi_ahblite_bridge:3.0`, whose held-NONSEQ behaviour is the
documented source of the ×5 bug. That benchmarks the Xilinx bridge.

**The chosen shape needs no new top-level ports**, therefore:
`fpga/vivado_ip/tidelink_vivado_wrapper.v`, `fpga/filelist.tcl`,
`fpga/targets/*/tidelink_design.tcl` and `kr260-pair-onchip/addrmap.tcl` are **all unchanged**.
Control rides the already-mapped APB aperture. Build-system delta = one line per flist.

### Ownership rules (safety-critical)
- `gen_owns` may only **assert** when the external port is idle. `ahb_tx_hsel` is tied `1'b1`
  at the IP boundary (`tidelink_vivado_wrapper.v:577`), so **HSEL cannot be the idle
  indicator** — `htrans[1]` is the only usable one.
- Once a packet starts, `gen_owns` holds to packet completion; an external beat arriving
  mid-packet gets a **two-cycle AHB ERROR**, never a silent OKAY drop (that was the L11
  watchdog's sin, `tidelink_fc_adapter.sv:271-290`).
- `hready` into the adapter: `gen_owns ? fc_adapter_hreadyout : ahb_tx_hready`. An identity on
  both FPGA targets (the wrapper loops it, `:507/583/586`) but stated explicitly so ASIC /
  nanoSoC integrations that do not loop back still work.
- Address/data come from flops; only beat-advance is combinational off `hreadyout` ⇒ no new
  long path, no comb loop.

### Inertness (TWIN-2 precedent, plus a structural guarantee)
TWIN-2's discipline is a build param AND-ed with a POR-disarmed runtime arm plus a sticky
fault for disarmed attempts (`tidelink_fifo_ctrl.sv:160,512`; `tidelink_apb_regs.sv:226,242`).
Mirror it, and add what TWIN-2 lacks:
1. `parameter bit TXGEN_PRESENT = 1'b1`; under `generate if (!TXGEN_PRESENT)` the module **and
   the mux** are absent ⇒ the ASIC netlist is provably identical (flists set 0).
2. `TXGEN_CTRL[0] EN`, POR 0. `gen_owns = txgen_en_r & txgen_running_r`, both reset 0 ⇒ with
   EN=0 the mux select is a constant-0 net and synthesis constant-folds the mux away.
3. `EN` survives STOP/CLR — only POR or an explicit `EN=0` clears it (the lesson of
   `tidelink_apb_regs.sv:237-243`, where FLUSH must not disturb the arm).
4. `STATUS.EXT_ABORT` sticky when an external beat is refused — make the silent no-op visible.

---

## 2. Register interface — APB **Region E** (`paddr[8:5] == 4'b1110`), offsets 0x1C0-0x1DC

SoC addresses `<apb_base>+0x21C0..0x21DC` (Z2 `0x4403_21C0`, KR260 die_a `0x8403_21C0`).

**Region E and F are unclaimed** — verified independently: they appear in no read mux
(`tidelink_apb_regs.sv:580-682`), no `ctrl_reg_write` (`:543-548`), are excluded from perf by
the `<= 4'b0111` bound (`:560-561`), absent from `pslverr` (`:692-733`), and there is no
`[8:5]` compare for them in `tidelink_top.sv` or `local_overrides/axi_chiplet_controller.sv`.

Implemented as a **shim slave decoded in `tidelink_top.sv`** (pattern of `eye_shim_sel:925`,
`gpio_phy_apb_sel:1098`) and folded into the `tl_apb_prdata/pready/pslverr` mux
(`:1237-1255`, **both `ifdef` arms**) — so `tidelink_apb_regs.sv`, which ~40 suites regress
against, gains no new register state.

🔒 **Qualify Region-E WRITES with `!fc_cfg_apb_active`** (`tidelink_top.sv:863`). The FC RX
config path shares this APB bus and carries a **peer-supplied** 12-bit offset
(`tidelink_fc_adapter.sv:698`), so a mis-set `PAIR_BASE` or a hostile/faulty peer could
otherwise reach Region E. **A remote die must never be able to arm our traffic generator.**
One wire.

| Off | Name | Acc | Fields |
|---|---|---|---|
| 0x1C0 | `TXGEN_CTRL` | RW | `[0]`EN (POR 0, survives STOP/CLR) `[1]`START(W1P) `[2]`STOP(W1P) `[3]`FOREVER `[4]`CLR(W1P, must not disturb EN) |
| 0x1C4 | `TXGEN_PKT` | RW | `[11:0]`PKT_LEN N (HW-clamped to `MAX_PACKET_LEN`, `tidelink_fifo_ctrl.sv:242`) `[27:16]`DEST_OFF |
| 0x1C8 | `TXGEN_GAP` | RW | `[15:0]`IPG_CYCLES `[31:16]`CREDIT_MARGIN |
| 0x1CC | `TXGEN_BUDGET` | RW | total FIFO words when `FOREVER=0` |
| 0x1D0 | `TXGEN_STATUS` | RO | `[0]`RUNNING `[1]`DONE `[2]`STALL_CREDIT `[3]`STALL_AHB `[4]`ERR_AHB(sticky) `[5]`EXT_ABORT(sticky) `[6]`CREDIT_GATE_ACTIVE |
| 0x1D4 | `TXGEN_WORDS` | RO | FIFO words accepted (`hreadyout`-qualified), saturating |
| 0x1D8 | `TXGEN_STALL` | RO | saturating stalled cycles — the "is the link the bottleneck?" number |
| 0x1DC | `TXGEN_ID` | RO | `0x5447_0100` — presence probe (cf. `PERF_ID`, `tidelink_perf.sv:516`) |

Packet count = `TXGEN_WORDS/(N+2)`; no separate counter needed.

**Emitted packet format** (must match peer framing): word0 `{PKT_LEN[11:0], 20'h0}` — the
length lives in `[31:20]` (`tidelink_fifo_mem.sv:169`, `tidelink_fifo_ctrl.sv:298`); word1
`DEST_OFF`; then N payload words carrying `{seq[15:0], idx[15:0]}` so a 2-word shift (the
phantom-pop signature, `tidelink_fifo_ctrl.sv:324-339`) is caught. Addresses restart per
packet; consecutive beats always differ, which clears `tx_xfer_lock` via the diff-addr term
(`tidelink_fc_adapter.sv:240`) — the lock only collapses *same*-address held NONSEQ, which the
generator never emits. Test `IPG=0` anyway.

---

## 3. Credit safety — gate on `pair_credit_counter`, reserve-then-send

**The RX FIFO write side has NO backpressure**: `fc_wr_ready = 1'b1`
(`tidelink_fifo_mem.sv:92`) and a zero-credit write is **silently dropped** with only a sticky
overrun (`tidelink_fifo_ctrl.sv:482-501`). A hardware generator without a hardware credit gate
would destroy data at line rate. **The gate is mandatory, not optional.**

Gate signal: **`pair_credit_counter`** (`tidelink_apb_regs.sv:372`) — our local view of the
**peer's** free RX credit, maintained in hardware (incremented by the peer's returner via the
SIDEBAND FC word → our `fc_rx_cfg` APB master → `pair_counter_increment`, `:375`).

Rejected alternatives: `current_credit_count` is our **local** FIFO's free space (wrong
buffer); the Wlink `fe_rx_is_full`/`fe_rx_credit_max` protect the 16-deep a2l replay FIFO
(the *wire*), which the generator already honours for free via
`tl_fc_a2l_ready → skid_can_accept → hreadyout`, but which does **not** protect the peer's
16 KB RX SRAM.

```
start_ok = txgen_en_r && txgen_running_r && !packet_in_flight
        && pair_credit_counter_en
        && (pair_credit_count >= (PKT_LEN + 2) + CREDIT_MARGIN)
```

- **Reserve `(PKT_LEN+2)` at packet START**, not on completion — the adapter takes 1 word/hclk,
  so a completion-time consume lets the next packet arm against credit already spoken for.
- **Packets are atomic once started.** Never abandon mid-packet: a truncated packet leaves the
  peer's `packet_active_r`/`write_target_addr_r` armed (`tidelink_fifo_ctrl.sv:146-164`), the
  state that mints credit above MAX on a later drain (`:390-425`,
  guarded by `test_v2_truncated_pkt_credit`). Reserve-up-front makes this unreachable.
- On `ERR_AHB` mid-packet (the stall-timeout abort) latch sticky, **stop, do not auto-restart**
  — the peer is mid-packet and software must FLUSH.
- Software must stop writing `PAIR_CREDIT_CONSUME` (0x02C) while armed — hardware owns the
  decrement. The `always_ff` at `:378-401` becomes a 3-way combine so a peer credit-return
  landing on the same cycle as a generator consume cannot be lost.
- `parameter bit TXGEN_CREDIT_GATE_DIS` — **sim-only, never in a shipping flist** — exists so
  a negative control can prove the peer *does* overrun without the gate.

---

## 4. Verification

Primary env `cocotb/tidelink_top_pair_v2` (two full tops, real link, real returner credit
loop). New sibling unit env `cocotb/tidelink_txgen/`. **Do not** extend
`cocotb/tidelink_fc_adapter` (its tests are silicon-bug regressions that must stay
bit-stable), and **do not** use `cocotb/tidelink_ahb` (that is the RX/FIFO env — no adapter,
no TX aperture; wrong instrument).

- **(a) Inert when disarmed** — a1 unit: 10k randomised external beats, assert `gen_owns==0`
  and every adapter TX net bit-equal to the external net cycle-by-cycle; START-without-EN is a
  no-op. **a2 pair: `test_v2_pair_data` + `test_v2_pair_sustained` unchanged** (the
  proven-datapath regressions). a3: `TXGEN_PRESENT=0` elab arms.
- **(b) Saturates when armed** — b1 unit: 1 word/hclk sustained with `IPG=0`; then randomly
  gapped `tl_fc_a2l_ready` with **zero words lost or duplicated** (direct oracle for the ×5
  class). b2 pair: words/cycle vs the PS-style `ahb_tx_write_packet` path, plus `a2l_wptr`
  advancing **1:1** with `TXGEN_WORDS`. b3: byte-exact drain — saturation without
  byte-exactness is worthless. **b4: under saturation the returner's SIDEBAND credit packets
  must still get through** (peer `released_credits_acc` keeps advancing) — TX saturation
  starving the sideband would deadlock the credit loop, and this is the first stimulus that
  ever stresses that direction.
- **(c) Never overruns** — c1 unit: at most `floor(credit/(N+2))` packets then STALL_CREDIT,
  never a partial packet. c2 pair: never drain the peer, run to starvation, assert peer
  `overrun_r == 0` and credit neither underflowed nor exceeded MAX; **then drain and assert
  the generator resumes by itself**. **c3 NEGATIVE CONTROL (mandatory): rebuild with
  `TXGEN_CREDIT_GATE_DIS=1`, assert the peer's overrun sticky DOES set** — without it, c2's
  green could just mean the generator never sent enough (repo precedent:
  `sim_gate_v2_oddlane_negctl`).

## 5. Gate impact
Tier-0.a IP-MATCH **will hard-fail until `package_ip` is re-run** — that is the gate working
as designed (the stale/silent-V1 class); sequence RTL → `package_ip` → `farm_gate` → build,
never a skip. Target **zero** new `sv_anti_pattern_lint` findings. `xdc_lint` unchanged (same
`hclk` domain, no new I/O). Watch post-route WNS on the `ahb_tx` group on the first build —
`TXGEN_PRESENT=0` gives a clean A/B if a regression appears.

## 6. Hardware bring-up order (for the campaign runbook)
1. `TXGEN_ID` == `0x5447_0100` else the bitstream predates the generator.
2. `TXGEN_STATUS[6]` == 1 (credit gate compiled in) — else refuse to run.
3. Link up; `PAIR_CREDIT_COUNTER` (+0x2028) non-zero. POR is 0, so the generator is
   **fail-closed**: it simply never starts until credit exists.
4. Program PKT/GAP/BUDGET; stop writing `PAIR_CREDIT_CONSUME`.
5. `TXGEN_CTRL = EN|START[|FOREVER]`.
6. Sample `TXGEN_WORDS`/`TXGEN_STALL` over a wall-clock window — `STALL/elapsed` answers "is
   the link the bottleneck?".
7. Cross-check peer `STATUS[1]` overrun == 0 and `CREDIT_COUNT` draining.
