# TL-021 first-silicon debuggability obs — implementation-ready spec (David-gated)

**Status:** SPEC-READY, David-gated (netlist-affecting, touches the HW-proven read-mux decode + adds a swi bit → David signs to land + rebuild).
**Why spec not autonomous-commit:** sub-item (1) is NOT the "one-liner" the registry implied — it's a coordinated **4-site** change on the critical `axi_chiplet_controller.sv` read-mux, because Regions D/F *fold* onto the `ctrl_reg_addr[4:3]==2'b00` bank and are disambiguated by 1-bit flags the I2C sideband path never drives. A naive hit-widen makes D/F reads collide with Region C. Getting the fold/flag logic subtly wrong regresses existing external-APB obs reads on the tapeout controller.

All three sub-items directly serve TL-009 first-silicon bring-up (the obs that cracked TL-009 is unreadable via the on-silicon I2C sideband). Each is APB-read sim-provable before David lands it.

## The region map (resolved — the registry's "D/F" naming is correct)

Read mux `axi_chiplet_controller.sv:1156-1164`: `ctrl_reg_addr[4:3]` has only 4 slots; slot `2'b00` is a **shared bank of four logical regions (9/10/D/F)** picked by 1-bit flags `apb_ctrl_reg_rf/_rd/_r10` (ports :242/:247/:254), driven ONLY by the external path in `tidelink_apb_regs.sv:633-635`. Address model: `apb_region = paddr[8:5]`.

| Region | paddr[8:5] | [4:3] path | select flag | SoC bytes | contents |
|---|---|---|---|---|---|
| 4 | 0100 | 2'b01 direct | — | 0x2080–9C | ROLE/I2C/NEGO cfg |
| 8 | 1000 | 2'b10 direct | — | 0x2100–1C | SWI training/lane-status |
| C | 1100 | 2'b11 direct | — | 0x2180–9C | autoneg N7/N8 obs |
| 9 | 1001 | 2'b00 folded | (all flags 0) | 0x2120–3C | SYNC-obs |
| 10 | 1010 | 2'b00 folded | apb_ctrl_reg_r10 | 0x2144–5C | eye/per-lane |
| **D** | 1101 | 2'b00 folded | apb_ctrl_reg_rd | **0x21A0–BC** | **RX-framer sticky + winscan** (:2692-2729) |
| **F** | 1111 | 2'b00 folded | apb_ctrl_reg_rf | **0x21E0–FC** | **AXI-node/winscan/leak obs** (:3028-3038) |

- RX-framer stickies = **Region D**: 0x21A0/A4/A8 = `sync_obs_rxcap0_1`/`rxcap1_1`/`fcsmcap_1` (:2692-2695), slot [2:0]=0/1/2.
- Wedge witness = **Region F** 0x21F8 = `xhb_sub_obs_word_i` slot [2:0]=6 (:3036), **V2-only** (`ifdef TIDELINK_PHY_V2`).

## Sub-item (1) — reach D/F from the I2C sideband (4-site change)

The slv path builds `slv_ctrl_reg_addr = {slv_apb_paddr[8:7], slv_apb_paddr[4:2]}` (:608) → `[4:3]=paddr[8:7]`. Regions D and F both have paddr[8:7]=11 → both select `regionC_rdata`. And the `2'b00` bank needs the rf/rd flags the slv path never drives. So:

1. `:595-599` — add hit terms:
   ```
   wire slv_apb_ctrl_regionD = (slv_apb_paddr[8:5] == 4'b1101);
   wire slv_apb_ctrl_regionF = (slv_apb_paddr[8:5] == 4'b1111);
   wire slv_apb_ctrl_hit = slv_apb_psel &&
     (slv_apb_ctrl_region4||slv_apb_ctrl_region8||slv_apb_ctrl_regionC
      ||slv_apb_ctrl_regionD||slv_apb_ctrl_regionF);
   ```
2. `:608` — fold D/F onto the 2'b00 bank (mirror tidelink_apb_regs.sv:646-648):
   ```
   wire slv_bank00 = slv_apb_ctrl_regionD || slv_apb_ctrl_regionF;
   wire [4:0] slv_ctrl_reg_addr = slv_bank00 ? {2'b00, slv_apb_paddr[4:2]}
                                             : {slv_apb_paddr[8:7], slv_apb_paddr[4:2]};
   ```
3. new slv-side flags OR-merged with the external ports:
   ```
   wire ctrl_reg_rd_eff = apb_ctrl_reg_rd || (slv_apb_ctrl_hit && slv_apb_ctrl_regionD);
   wire ctrl_reg_rf_eff = apb_ctrl_reg_rf || (slv_apb_ctrl_hit && slv_apb_ctrl_regionF);
   ```
4. `:1157-1159` — use the merged flags in the read mux (`apb_ctrl_reg_rd`→`ctrl_reg_rd_eff`, `_rf`→`ctrl_reg_rf_eff`).

RO regions → reads carry pwrite=0 so no `ctrl_reg_write` strobe (:601): additive to the read path only.

## Sub-item (2) — i2c_slv_reset debug-override (bit-identical when default-0)

`:3074` today: `wire i2c_slv_reset = ~hresetn | role_is_master;` (master holds its inbound I2C in reset by construction). New default-OFF bit in Region-4 `I2C_SLV_ADDR` (slot 3'h2, SoC 0x4403_2088; uses only [6:0], writable pre- AND post-role-lock at :919/:930):
1. declare `logic i2c_slv_dbg_force_reg;` (near :645); reset `<=1'b0` in POR block (:753).
2. decode bit[7] in BOTH write paths (:919 and :930): `3'h2: begin i2c_slv_addr_reg <= wdata[6:0]; i2c_slv_dbg_force_reg <= wdata[7]; end`
3. gate `:3074`: `wire i2c_slv_reset = ~hresetn | (role_is_master & ~i2c_slv_dbg_force_reg);`
4. (opt) read-back in region4_rdata slot 3'h2.

Bit-identical when the bit=0 (`role_is_master & ~0 == role_is_master`). Master writes 0x2088[7]=1 over its OWN local APB (not the I2C door that's in reset). Reviewer note: setting the bit also re-enables the slv_apb→ctrl_reg WRITE path on the master (the :590-593 assumption is intentionally relaxed under debug).

## Sub-item (3) — ext_stall_err_q → APB (one word, V2-only)

`ext_stall_err_q` (tidelink_top.sv:944-961, POR-cleared, not APB-mapped). It and `xhb_sub_obs_word` (then at tidelink_top.sv:1724, then with 13 spare bits [23:11]) are in the SAME module → no threading:

> ⚠ **The snippet below is the 2026-08 sketch and is now STALE.** `ext_stall_err_q` did land at `[11]`, but `[12]`/`[13]`/`[14]` have since been allocated to TL-042/TL-044 and the word is built at `:2178`. Decode against the table in "0x21F8 WITNESS WORD — CURRENT LAYOUT" below, not against this line.
```
// tidelink_top.sv:1724
wire [31:0] xhb_sub_obs_word = { 8'hB5, 12'h0, ext_stall_err_q /*[11]*/, xhb_stall_stuck_sticky /*[10]*/, ... };
```
Path: ext_stall_err_q → xhb_sub_obs_word[11] → `.xhb_sub_obs_word_i` (:3086) → regionF slot 3'h6 (:3036) → SoC 0x4403_21F8 bit[11]. V2-only (0x21F8 is `ifdef TIDELINK_PHY_V2`); for V1 visibility a different (controller-internal) slot + a new port would be needed — out of scope for a V2 first-silicon debug build.

## 0x21F8 WITNESS WORD — CURRENT LAYOUT (updated 2026-09-11, rev2/integration)

`xhb_sub_obs_word` has moved on since the sketch above: it is now built at
`src/rtl/tidelink_top.sv:2178`, the spare pool is `[23:15]`, and the word carries
the TL-042/TL-044 containment plane. This is the authoritative layout for
anything decoding SoC `0x4403_21F8` / `0x8403_21F8` / `0x4_2E03_21F8`:

| bits | signal | meaning |
|---|---|---|
| `[31:24]` | `8'hB5` | presence marker. Absent -> the plane is not in this bitstream; decode NOTHING and report could-not-evaluate. |
| `[23:15]` | spare `9'h0` | |
| `[14]` | `xhb_dead_perm_r` | **TL-044**: containment latched PERMANENTLY after `XHB_DEAD_RELAPSE_MAX` clear/re-arm cycles. The port will never re-arm. |
| `[13]` | `xhb_dead_r` | **TL-044**: XHB500 declared DEAD; the port is in BOUNDED-ERROR containment (live, not sticky). |
| `[12]` | `sub_wr_hol_stuck_sticky` | **TL-042**: head-of-line WRITE-age watchdog EXPIRED (the starvation-immune watchdog fired). |
| `[11]` | `ext_stall_err_q` | TL-021 bounded-ext-stall sticky (sub-item (3) above). |
| `[10]` | `xhb_stall_stuck_sticky` | bridge `hreadyout` stuck low >= 2^12 hclk == XHB500 hazard-list-full / deadlock witness. |
| `[9]` | `sub_err_sticky` | 2-cycle ERROR backstop fired (read). |
| `[8]` | `sub_wr_stuck_sticky` | synth-B backstop fired (write). |
| `[7:5]` | `sub_wr_os_hwm` | outstanding-write high-water mark. |
| `[4]` | `pipe_hprot_r[2]` | bufferable / EWR. |
| `[3:1]` | `sub_wr_os_ctr` | outstanding-write count (live). |
| `[0]` | `xhb_sub_hreadyout_raw` | live bridge-ready. |

**Bit-allocation note (2026-08-24, carried from the RTL).** TL-042 and TL-044 were
developed independently against the same spare pool and both originally claimed
`[12]`. Landing order on this branch gave TL-042 `[12]`; TL-044 shifted up to
`[13]`/`[14]`. Neither simulation suite reads the packed word — both probe the RTL
signals by name — so this is a SILICON/APB contract change only, and the host
decoders are the only thing that can get it wrong.

### Why `[12]`/`[13]`/`[14]` had to be decoded on the host

Until 2026-09-11 `grep -rl 'sub_wr_hol\|xhb_dead' pynq_host` returned **nothing**.
Two watchdogs and a permanent containment latch shipped with no host tool able to
report that they had fired. The consequence is not cosmetic: TL-044's premise is
an XHB500 port parked behind *healthy* FC nodes, so **Region F (`0x21E0`) reads
clean right through it** and `health_snapshot.py` printed `RESULT: HEALTHY
(exit 0)` for a die that was retiring every transfer with a bounded AHB ERROR.
`0x21F8` is the only place that state is visible.

### Host decoders (all marker-gated on `0xB5`)

| tool | what it does with the plane |
|---|---|
| `pynq_host/scripts/health_snapshot.py` | reads `0x21F8`, renders every field, and FAULTs (exit 1) on any of `[8]`..`[14]`. An absent marker is COULD-NOT-EVALUATE (exit 2), never HEALTHY; `--allow-missing-witness` is the explicit opt-out, mirroring `--allow-missing-regionf`. |
| `pynq_host/scripts/eth_sysval_board.py` | `obs` mode emits `ext_stall_err` / `wr_hol_stuck` / `xhb_dead` / `xhb_dead_perm`; absent marker -> `None`, never `0`. |
| `pynq_host/scripts/kr260_sysval.py` | `healthy()` requires the marker present and the containment triple all-zero; `witness_faults()` renders the reason in words. A *missing key* (board script older than this decode) is also not-healthy — T1_provenance is the test that names that cause. |
| `pynq_host/scripts/kr260_recover_gate.py` | `link_healthy()` and the wedge inducer both gate on the full set `stall_stuck / synth_b / wr_hol_stuck / xhb_dead / xhb_dead_perm`; an absent marker is not-healthy. |
| `pynq_host/scripts/kr260_reliability_sweep.py` | records all three in the JSONL/CSV artefacts (report-only). |
| `pynq_host/scripts/kr260_afi.sh` | prints the bits alongside the deploy-time marker canary (report-only). |

**Control:** `scripts/ci/tests/test_obs_witness_decode.py` — 50 checks over
synthetic register words: each bit at the position the RTL packs it, no bleed
between adjacent fields, the marker gate producing `None` rather than `0`, the
verdict FAULTing on a clean Region F with a containment bit set, and
`health_snapshot` / `kr260_sysval` agreeing on the same words. Runs in
`make selfcheck_gates`. Proven red two ways on 2026-09-11: transposing the
`[13]`/`[14]` expectation gives 4 failures, and mutating the production decode to
fail open on an absent marker gives 3.

## Sim-proof plan (before David lands)
- (1) cocotb APB-read: drive slv_apb_* at paddr 0x1A0 and 0x1F8; assert rdata = rxcap0 / xhb_sub_obs (not regionC). Negative: pre-edit the same reads return Region C. Model on `cocotb/tidelink_apb_regs/test_perf_region_decode.py`.
- (2) poke 0x2088[7]=1 (local APB), assert i2c_slv_reset deasserts while role_is_master=1; with bit=0 assert bit-exact function of role_is_master.
- (3) V2 build: force ext_stall_err_q=1 (drive tl_apb_pready stalled past EXT_STALL_LIMIT), APB-read 0x21F8[11]==1; POR → clears.

## Risk
All RO/additive except (2), which is bit-identical while its default-0 bit is clear. (1) touches the critical read-mux — the fold must force D/F to [4:3]=2'b00 (no write decode there for RO obs) so it can't accidentally write Region C's 2'b11 slot.
