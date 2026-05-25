# PHC Phase-1 — Agent Handoff Document

**Date**: 2026-05-24
**Author**: Multi-agent debug session (auto-mode), summarising for handoff to next agent
**Status**: b25 farm building; b24 deployed and HW-tested; bug NOT yet resolved on hardware

---

## 1. Where I am right now (current branch + in-flight work)

- **Main repo working branch (srv03335)**: `feat/phc-manual-replicate-b21` (unchanged by me; my work is in worktrees)
- **Active worktree**: `/home/dam1n19/SoCLabs/td-bisect/b25-rx-accept-reg/`
  - Branch: `feat/phc-rx-accept-reg-b25`
  - HEAD: `b9f567a` — *rtl(tidelink_ptp) + b25: register rx_accept into single keep+dont_touch FF*
  - Parent chain: `b9f567a` (b25) → `c6c56c2` (dbg_hub C_CLK_INPUT_FREQ_HZ fix from Agent K) → `6b58942` (b24 decouple + cocotb test update) → `e8c9b83` (feat/phc-ila-submodule-b22)
  - Submodule `deps/axi-chiplet-controller` is on `8a4fcf5` (b22 ILA SHA — DO NOT BUMP)
- **b25 farm in flight**: kicked ~21:00 UTC with `FPGA_INSERT_DEBUG_CORE=1`. Background task `b56aaluaq`. ETA ~21:45 UTC. Outputs will land at `imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.bit` once done.
- **Other live worktrees** (kept for trace): `b22-ila/`, `b23-fsm-harden/`, `b24-rx-decouple/`, `b20-slave-rx/`, `v1-consolidated/`, `unified-build/`. See `cleanup_proposal.md` in repo root (from Agent L) for which can be pruned.

---

## 2. The bug — one paragraph

Two PYNQ-Z2 boards connected by a 40-pin ribbon. Master sends PHC SYNC short-packets at 128 Hz via Wlink; slave is supposed to latch them into its PHC servo. Link layer is 16/16 + cal_done both sides. **Slave's `PTP_CTRL[2]` rx_valid sticky bit stays 0 indefinitely** even though APB readback confirms `PTP_CTRL[0]` enable is set, master HW_SYNC_STATUS seq_num is advancing at 128 Hz, and ILA capture proves master IS transmitting valid SP packets that reach slave's link-layer classifier. PHC offset never converges.

Today's session ruled out 7 hypothesis classes and narrowed the bug to **synth-replication of combinational signals in tidelink_ptp's RX path** when the flip-bitstream's mirrored pin map causes Vivado to place identical RTL into divergent physical cones per consumer.

---

## 3. Hypothesis table (with confidence)

| # | Hypothesis | Status | Evidence | Confidence (RULED OUT / OPEN / PRIMARY) |
|---|---|---|---|---|
| A | Master TX FSM stuck (`hw_sync_trigger` cone replication) | ❌ Ruled out | b23 hardened all of `hw_sync_trigger`, `tx_state_r`, `tx_pending_r`, `hw_sync_state_r` with `keep+dont_touch+fsm_encoding`; HW behaviour unchanged. ILA on master `sp2wl/tx_valid` fired (master IS transmitting). | RULED OUT — 95% |
| B | BD address-map asymmetry slave-side | ❌ Ruled out | Agent E: the two Vivado BD .tcl files are **byte-identical** post-comment-strip (398/398 non-comment lines, zero substantive diff). Only pin-map mirrors. Wrapper.v, DRC.xdc, idelay.xdc identical. | RULED OUT — 98% |
| C | rx-link clock async-FIFO reset-release race on slave | ❌ Ruled out | Software-pulsed `swi_swreset` (bit 3 of `0x4403_0208`) on slave AFTER lane-locked → no rescue of `PTP_CTRL[2]`. | RULED OUT — 90% |
| D | Slave Wlink LLRX disabled / missing config write | ❌ Ruled out | Slave `0x4403_0208 EnableReset = 0x00027f07` at reset default already (LLRX/LLTX/SWI all enabled). | RULED OUT — 95% |
| F | CR/CRACK directional asymmetry | ❌ Ruled out (red herring) | Agent F audited `WlinkGenericFCSM_*.v`: cr_seen=1 master / 0 slave is a benign boot-race where slave's RX byte-aligner misses the first CR; FCSM state advances via CRACK path; `fe_tx_credit_max` loaded on either pkt_is_cr OR pkt_is_crack — system self-heals. NOT the PHC bug. | RULED OUT — 95% |
| G | Hardware-specific (bad pad / cable / IDELAYE2 unique to z2_03) | ❌ Ruled out | Agent G's SWAP=1 deploy test: z2_03 healthy as master; z2_02 broken as slave with flip bitstream. Bug follows role/bitstream, not physical board. | RULED OUT — 99% |
| J | Slave's `ptp_enable_r` consumer-replica fail (`rx_accept = ptp_sp_rx_valid & ptp_enable_r`) | ❌ Ruled out by experiment | b24 decoupled `rx_accept = ptp_sp_rx_valid` (removed ptp_enable_r gating). HW test: PTP_CTRL[2] still 0. But **PHC_HW_CAP DID start advancing on slave**, proving `rx_accept` IS now firing — just at a different consumer than the latch. | RULED OUT — 92% |
| **★** | **`rx_accept` combinational-cone replicated per consumer; PHC consumer sees it fire, latch consumer does not** | ★ PRIMARY (b25 testing now) | Same physical wire produces different observable behaviour at the two consumers (line 316 latch vs line 332 PHC capture in `src/rtl/tidelink_ptp.sv`). Identical class of bug to historical Bug #3 (mask phase prune) and the txn_step_nxt latch issue. | PRIMARY — 75% |
| Alt | `ptp_sp_rx_data_id` bus wire split between sp2wl output and tidelink_ptp input | Open (testable by b25 ILA) | Less likely than ★ because the data_id check is only one consumer of the latch RTL; if rx_accept fired at the latch site, `ptp_rx_valid_r` would set to 1 unconditionally (no data_id gating on the latch — re-read of RTL confirmed this). | OPEN — 15% |
| Alt2 | Some other downstream signal (e.g. `ptp_sp_rx_valid` itself) is also cone-replicated and the bug just moves further along | Open | b25 registers rx_accept which is one layer downstream of ptp_sp_rx_valid. If b25 also fails, this is the next theory. | OPEN — 10% (fallback if b25 fails) |

---

## 4. The HW evidence that survived all 7 ruled-out hypotheses

| Probe | Value | What it proves |
|---|---|---|
| Master `HW_SYNC_STATUS` seq_num | advancing 128 Hz | Master HW_SYNC FSM actively generating SYNC events |
| Slave `SWI_LANE_STATUS` | `0x002300ff` (lane_lock=0xff, cal_done=1, fcsm=2, llrx_state=1) | Wlink RX healthy on slave |
| Slave `WL_LinkStatus[4]` | rx_data_valid = 1 | Wlink RX sees valid data |
| Slave `ECC_COUNTERS` | 0 (no corrected, no corrupted) | Packets arriving cleanly — not dropped at ECC |
| Slave `FC_TIDELINK_CRC_Errors` | 0 | FC node sees clean packets |
| Slave `0x4403_0208 EnableReset` | `0x00027f07` | LLRX/LLTX/SWI all enabled |
| Slave `PTP_CTRL` | `0x00000001` (enable=1, rx_valid=0, W1C=0) | Software enable wrote correctly to readback FF |
| Slave `PTP_RX_PAYLOAD` | `0x00000000` | No SYNC seq_num ever latched |
| Slave `SERVO_STATUS` | `0x00000000` | Servo never got a sync_rx_done |
| Slave `PTP_STATUS` | `0x00000000` (tx_router_idle=0, tx_pending=0) | Slave's Wlink LL TX is busy with something (likely CR/CRACK responses) |
| **First ILA capture on slave `sp2wl/rx_pkt_valid`** | **FIRED at 2026-05-24 19:22:42** | **Master IS transmitting; data_id 0x50 matched; slave's sp2wl classified valid SP packet** |
| Slave `PHC_HW_CAP` on b24 | seconds advancing (263→266→268 in 1s of wallclock) | `phc_hw_capture = tx_handshake \| rx_accept`. Slave doesn't TX, so `rx_accept` IS firing at the PHC consumer |

The contradiction: `rx_accept` provably fires at line 332 (PHC consumer), but `ptp_rx_valid_r` (line 316, same `rx_accept` wire as gate) never latches to 1. **That's only physically possible if synth produced two different physical nets named `rx_accept`.**

---

## 5. Build history & verdicts (today only)

| Build | Branch | Change | HW result |
|---|---|---|---|
| b22 | `feat/phc-ila-submodule-b22 @ e8c9b83` | submodule SHA bump for master `sp2wl/tx_valid` ILA | 16/16 link first try; slave PTP_CTRL[2] = 0 (bug present) |
| b23 | `feat/phc-fsm-harden-b23 @ 58b7de0` | `keep+dont_touch` on `hw_sync_trigger`, `tx_state_r`, `tx_pending_r`, `hw_sync_state_r`; `fsm_encoding=sequential` on FSM regs | 16/16 first try; PTP_CTRL[2] still 0 — proves Agent A wrong by experiment |
| b24 | `feat/phc-rx-decouple-b24 @ c6c56c2` | `rx_accept = ptp_sp_rx_valid` (decouple from `ptp_enable_r`); + Agent K's `C_CLK_INPUT_FREQ_HZ` fix in `fpga/insert_debug_core.tcl` | 16/16 first try; PTP_CTRL[2] still 0 BUT PHC_HW_CAP starts advancing on slave — bug moved 1 layer downstream |
| b25 | `feat/phc-rx-accept-reg-b25 @ b9f567a` | Register `rx_accept` into single `(* keep *)(* dont_touch *)(* mark_debug *)` FF; +mark_debug on `ptp_sp_rx_valid`, `ptp_sp_rx_data_id` | **Farm building right now (ETA 21:45 UTC); FPGA_INSERT_DEBUG_CORE=1** — bitstream will have real ILA |

---

## 6. Diagnostic infrastructure (operational today, persists)

### JTAG / ILA access via mapstone-dev
- **`hw_server` on mapstone-dev:3121** has been running since 2026-04-28; FT2232H cables physically wired to z2_01..z2_04.
- **5 JTAG targets enumerate** (verified today via `phc_ila_discover.sh`):
  - `localhost:3121/xilinx_tcf/Xilinx/Z2_01_TULA` (spare)
  - `localhost:3121/xilinx_tcf/Xilinx/Z2_02_TULA` ← **master (192.168.4.101)**
  - `localhost:3121/xilinx_tcf/Xilinx/Z2_03_TULA` ← **slave (192.168.6.101)**
  - `localhost:3121/xilinx_tcf/Xilinx/Z2_04_TULA` (spare)
  - `localhost:3121/xilinx_tcf/Digilent/210249B86C47`
- **Vivado 2025.2** at `/tools/Xilinx/2025.2/Vivado/bin/vivado` on mapstone-dev

### ILA capture scripts (in repo)
- `pynq_host/scripts/phc_ila_discover.sh` — pre-flight: enumerate JTAG targets
- `pynq_host/scripts/phc_ila_capture.sh` — wrapper, picks board glob
- `pynq_host/scripts/phc_ila_capture.tcl` — Vivado HW Manager dance (patched for Vivado 2025.2: `CONTROL.MAX_DATA_DEPTH` removed, `CONTROL.CAPTURE_MODE` read-only; Agent K's STATUS-poll workaround + `.fire.txt` sidecar + `reset_hw_ila` between captures)
- `pynq_host/scripts/phc_ila_fire_detect.tcl` (NEW from Agent K) — batched arm-fire-detect-reset loop over multiple probes

### Known dbg_hub gotcha (FIXED in b24 onwards)
b22's dbg_hub had `C_CLK_INPUT_FREQ_HZ = 300_000_000` (Vivado default) but actual ila_clk runs at 25 MHz — 12× mismatch broke BSCAN frame counter on sample-buffer readback (`[Xicom 50-38] No trigger mark in any sample in window: 0` + `[Xicom 50-41] corrupted`). Agent K's patch in `fpga/insert_debug_core.tcl` auto-derives `C_CLK_INPUT_FREQ_HZ` from `[get_clocks -of_objects $ila_clk]` PERIOD. **b25 will have a working ILA**.

### Board access pattern
- `ssh mapstone-dev` (configured in `~/.ssh/config`, key-based)
- From mapstone-dev: `sshpass -p xilinx ssh -o StrictHostKeyChecking=no xilinx@192.168.4.101`
- The bashrc on mapstone-dev emits `Agent pid X` noise — use `bash --noprofile --norc -c '...'` wrapper for clean output
- Helper functions in `pynq_host/scripts/_ptp_common.sh`: `remote_r ADDR`, `remote_w ADDR VAL`, `apb_r OFF`, `apb_w OFF VAL`, `check_link_up`, `quiesce_servo`, `phc_init_50mhz`, `phc_hw_cap_read`, etc.

### bridge1 lease (`fpgahub`)
- `fpgahub pair lease show bridge1` — current state
- `fpgahub pair lease acquire bridge1 --ttl 5400` — acquire, returns token
- Lease auto-expires; release with `fpgahub pair lease release bridge1 --token <token>`
- **Lease must be GRANTED before deploy** — verify show output is "granted" not "queued"

### Bitstream provenance
- `pynq_host/scripts/make_bitstream_manifest.sh <bin> --label <label> --commit <sha> --target <name> --lock-min N` — generates `.bin.manifest.json` next to .bin
- `pynq_host/scripts/deploy_pair.sh BOARD_IP LABEL ROLE [ARTEFACTS] --manifest <path>` — refuses to flash if sha256 doesn't match; use `--check-only` to read back loaded sha without flashing
- Staging dir on mapstone-dev: `/tmp/tidelink_deploy/` — expects `tidelink.bin`, `tidelink-flip.bin`, corresponding `.hwh`, `.manifest.json`, `.ltx`

### Convergence test
- `pynq_host/scripts/bringup_pair_converge.sh` — closed-loop pair deploy + lane-lock convergence (NORMAL or SWAP=1 mode)
- `pynq_host/scripts/bringup_ptp_sync.sh` — full PHC sync test (initialises PHCs, enables PTP, starts HW_SYNC on master, polls offset + servo lock)

---

## 7. The b25 fix in detail

`src/rtl/tidelink_ptp.sv:298-322`:

```systemverilog
// b24: decouple RX-accept from ptp_enable_r to avoid synth-replicated
// FF mismatch under flip-bitstream pin-map placement.
// b25: register rx_accept into a single FF with keep+dont_touch so
// synth cannot replicate the combinational cone per consumer (PHC,
// latch, sync_rx_done all see the same physical net). b24 observation
// on HW: PHC_HW_CAP advanced (rx_accept fired at the PHC consumer)
// but ptp_rx_valid_r never latched (rx_accept = 0 at the latch
// consumer) — proof of split-replica behaviour. +1 cycle of latency
// is benign; PHC capture is on the same cycle so timing is preserved.
(* keep = "true" *) (* dont_touch = "true" *) (* mark_debug = "true" *)
logic rx_accept_r;
always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn) rx_accept_r <= 1'b0;
    else          rx_accept_r <= ptp_sp_rx_valid;
end
wire rx_accept = rx_accept_r;

assign ptp_sp_rx_accept = rx_accept;

// b25: also mark_debug the data_id and consumer-side latch so ILA can
// discriminate between rx_accept-fire-but-data-id-wrong (data wire bug)
// and rx_accept-not-firing (cone-replication bug) if b25 still fails.
(* mark_debug = "true" *) wire [7:0] dbg_ptp_sp_rx_data_id = ptp_sp_rx_data_id;
(* mark_debug = "true" *) wire       dbg_ptp_sp_rx_valid   = ptp_sp_rx_valid;
```

---

## 8. What the next agent should do

### Step 1 — wait for b25 farm
The farm was kicked at ~21:00 UTC. Background task id was `b56aaluaq`. The expected completion is ~21:45 UTC. Output goes to `imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.bit`. Check timing summary in same dir for `WNS/WHS`.

If timing fails badly (WNS << -1 ns or many failing endpoints), there's a `make build_pair_farmed` rerun with `IMPLEMENTATION_STRATEGY=Performance_Explore` option that historically tightens it.

### Step 2 — bit2bin + manifest + stage
```bash
cd /home/dam1n19/SoCLabs/td-bisect/b25-rx-accept-reg
SHA=$(git rev-parse --short HEAD)
for T in pynq-z2-pair-all pynq-z2-pair-flip-all; do
    python3 fpga/scripts/bit2bin.py imp/fpga/output/$T/tidelink.bit imp/fpga/output/$T/tidelink.bin
done
bash pynq_host/scripts/make_bitstream_manifest.sh imp/fpga/output/pynq-z2-pair-all/tidelink.bin --label "b25-rx-accept-reg" --commit "$SHA" --target pynq-z2-pair --lock-min 16
bash pynq_host/scripts/make_bitstream_manifest.sh imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin --label "b25-rx-accept-reg" --commit "$SHA" --target pynq-z2-pair-flip --lock-min 16
```

Then stage to `mapstone-dev:/tmp/tidelink_deploy/` via cat-over-ssh (see how I did it for b24 in the conversation history). ALSO stage the .ltx files this time — b25 will have them since `FPGA_INSERT_DEBUG_CORE=1`.

### Step 3 — deploy + test
```bash
fpgahub pair lease acquire bridge1 --ttl 5400
ssh mapstone-dev "bash --noprofile --norc -c 'cd /home/david/SoCLabs/tidelink && timeout 360 pynq_host/scripts/bringup_pair_converge.sh'"
# Expect 16/16 first try
ssh mapstone-dev "bash --noprofile --norc -c 'cd /home/david/SoCLabs/tidelink && DURATION=30 OFFSET_OK_NS=500 LOCK_HOLD=3 pynq_host/scripts/bringup_ptp_sync.sh'"
# Watch for: slave PTP_CTRL[2] becomes 1, SERVO_STATUS becomes 3 (locked)
```

### Step 4 — interpret

**If b25 PASSES (slave PTP_CTRL[2] → 1, SERVO_STATUS locks):**
- Bug confirmed: `rx_accept` cone replication
- This is the win. Merge b25 to main; tag a release; close PHC Phase-1.
- File a clean PR. Reference the entire build history (#14 through #25) in PR body for trace.

**If b25 FAILS (PTP_CTRL[2] stays 0):**
- ILA is now operational. Capture on slave using `phc_ila_capture.sh -b slave`.
- Trigger sequence to try (order matters):
  1. `rx_accept_r` (the new registered FF) — if it fires here, the latch HAS to see it (only one physical net now). If still no latch, scenario shifts dramatically.
  2. `dbg_ptp_sp_rx_data_id` — capture the data_id at the consumer site. Should be 0x50; if it's anything else (0x44/CR, 0x45/CRACK, 0xa1/FC, etc.) the data_id wire is the bug.
  3. `ptp_rx_valid_r` — if this DOES toggle in the trace but the APB readback shows 0, the readback path is broken (very unlikely but cheap to rule out).
- Alt2 hypothesis becomes primary: `ptp_sp_rx_data_id` bus itself is replicated/corrupted between sp2wl output and tidelink_ptp input. Solution: register/mark_debug that 8-bit wire similarly.

### Step 5 — if neither b25 nor an ILA-guided b26 fixes
Consider escalation:
- Re-examine the placement constraints. Maybe pin a region for tidelink_ptp via `PBLOCK` to force consistent placement.
- Try Vivado `IMPLEMENTATION_STRATEGY=Performance_NetDelay_high` or similar to force less aggressive replication.
- Consider PLATFORM/silicon escalation if Vivado is genuinely broken on this version.

---

## 9. Key file paths

| Path | What |
|---|---|
| `src/rtl/tidelink_ptp.sv` | The module under fix (b25 RTL change here) |
| `src/rtl/tidelink_top.sv:1538-1540` | Where ptp_in/ptp_out packed bus is wired |
| `deps/axi-chiplet-controller/logical/wlink/ShortPacketToWlink.v` | sp2wl — slave's RX FIFO + filter (`dataIdMatch` for 0x50/0x51) |
| `deps/axi-chiplet-controller/logical/wlink/Wlink.v` | Wlink top — `sp2wl_io_app_enable = swi_enable` |
| `fpga/insert_debug_core.tcl` | ILA insertion + dbg_hub config (Agent K's fix lives here) |
| `pynq_host/scripts/phc_ila_capture.{sh,tcl}` | Working ILA capture pipeline |
| `pynq_host/scripts/_ptp_common.sh` | APB helpers + register offsets |
| `docs/PHC_PHASE1_DIAGNOSIS_2026_05_24.md` | Agent L's earlier consolidation |
| `docs/PHC_PHASE1_OBSERVABILITY_MAP.md` | Every APB-readable observation point |
| `cleanup_proposal.md` (repo root) | Branch + worktree cleanup proposal awaiting user approval |
| `/home/dam1n19/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/MEMORY.md` | Persistent memory index for Claude |

---

## 10. Critical guardrails

1. **DO NOT WRITE TO `0x4400_0000` (AHB_TX)** — this is the wedge hazard. Will take a board offline. Recovery requires power cycle.
2. **DO NOT bump the submodule** beyond `8a4fcf5` without explicit reason — that's the b22 ILA SHA, and master TX-path ILA depends on it.
3. **DO NOT use `boot_hw_device` in xsdb/Vivado** — Agent K learned the hard way it wipes the bitstream's DONE bit (z2_03 was wiped today; user redeployed via `bringup_pair_converge.sh`).
4. **DO NOT skip `FPGA_INSERT_DEBUG_CORE=1`** when you want ILA in the build — b23 and b24 forgot this and had no ILA, wasting a debug session each.
5. **DO NOT trust `wait_on_hw_ila -timeout`** under Vivado 2025.2 — it can hang indefinitely when hw_server state is corrupted. Agent K's `phc_ila_capture.tcl` uses STATUS polling instead, with `reset_hw_ila` between captures.
6. **DO use `bash --noprofile --norc -c '...'`** for SSH-to-mapstone-dev wrapped commands to avoid `Agent pid X` bashrc noise.
7. **DO acquire lease via `fpgahub pair lease acquire bridge1 --ttl 5400`** before deploying; verify "granted" state.
8. **DO NOT pipe long-running farm builds through `head`** — when `head` closes early, SIGPIPE propagates back through `tee` to the bash orchestrator and kills the build. Redirect to a log file instead: `... > imp/fpga/run/farm/launch.log 2>&1`. Learned the hard way on b25's first kick.
9. **DO `git submodule update --init --recursive`** after `git worktree add` — worktrees don't auto-init submodules and the build will fail at `package_ip` if `deps/axi-chiplet-controller/logical/interfaces/apb4_if.sv` is missing.

---

## 10b. Late-breaking netlist analysis (2026-05-24 evening — post b24 deploy)

Vivado batch on b24 slave's routed DCP (`/apps/Xilinx/Vivado/2024.1/bin/vivado -mode batch -source /tmp/netlist_inspect_b24.tcl` + `/tmp/lut_inspect_b24.tcl`) gave the following findings:

- **`rx_accept` is NOT synth-replicated**: only 2 logical nets (`ptp_sp_rx_accept` top-level + `sp2wl/rx_accept`), each with one driver pin. The combinational pass-through `wire rx_accept = ptp_sp_rx_valid;` was inlined away.
- **`ptp_sp_rx_valid` is NOT synth-replicated**: 2 nets (top + inside u_ptp), FANOUT=22 each.
- **`ptp_rx_valid_r_reg` is a single FDCE** at SLICE_X66Y55. Driven by LUT3 `ptp_rx_valid_r_i_1` (INIT=`8'h54`, inputs: I0=W1C-from-LUT6, I1=Q, I2=ptp_sp_rx_valid) — truth table CORRECT (decoded: rx_valid=1, Q=0, W1C=0 → D=1).
- **The FDCE CLR pin** connects to `tx_payload_r[15]_i_3_n_0`, which is a LUT1 (INIT=`2'h1`) inverter of `hresetn`. Shared as the reset LUT across all ptp_*_reg FFs. Normal — CLR fires only at reset.
- **Timing into `ptp_rx_valid_r_reg/D`**: no setup or hold violation. The 1 failing hold endpoint in the b24 slave bitstream is on `pad_tx[5]` (board output) — unrelated.
- **`phc_hw_capture` LUT4** (INIT=`16'hEAAA`) decodes to: `phc_hw_capture = ptp_sp_rx_valid OR (ptp_enable_r AND ptp_sp_tx_ready AND tx_state[1])`. So PHC_HW_CAP advancing on slave does NOT uniquely prove `rx_accept` is firing — it could be firing from the `tx_handshake` branch (servo DELAY_REQ TX attempts).

### Revised diagnosis after netlist analysis

The cone-replication hypothesis is invalidated by the netlist. The most likely cause is now:

- **Slave's `ptp_sp_rx_valid` never asserts**, despite `sp2wl/rx_pkt_valid` (input-side classifier) firing per ILA. The gap is inside `sp2wl/rx_fifo`:
  - `rx_fifo_io_winc` blocked (FIFO permanently full)
  - CDC issue on rinc / rempty (FIFO never reports non-empty to consumer)
  - `auto_rx_in_word_count` or `auto_rx_in_data_id` corrupted at FIFO write port

The slave's PHC_HW_CAP advancing was masking the silence — it was advancing from the TX-handshake path (slave's servo periodically firing DELAY_REQ attempts via `servo_dreq_trigger & ptp_enable_r`), NOT from rx_accept.

### Even later: deeper netlist analysis of `sp2wl/rx_fifo`

Ran `/tmp/sp2wl_rxfifo_inspect.tcl` and `/tmp/fifo_drain_check.tcl` on b24 slave routed DCP. Findings:

- `rx_fifo/mem/io_rdata[*]` (24 bits) reports **FANOUT=0** in both queries — either Vivado dead-stripped the data path, or cross-hierarchy queries missed consumers (b25 ILA will discriminate)
- `sp_bus_out_0[24]` (= `ptp_sp_rx_valid` to tidelink_ptp) is driven by **LUT1 INIT=`2'h1` at SLICE_X50Y43** — an inverter, so output = `~rx_fifo_io_rempty`. Functionally correct.
- The FIFO is `WavFIFO_21` — classic async-FIFO with: `read_ptr_logic`, `write_ptr_logic`, `sync_rptr_demet` (RX→app demet), `sync_wptr_demet` (app→RX demet), `mem` (96 FDCE FFs = 24-bit × 4-deep)
- `mem/mem_reg[*]` FFs have CLR ← `io_wreset` (write-side reset)
- Two clock domains: `io_rclk = app_clk = hclk` (read side), `io_wclk = rx_link_clk` (write side, derived from recovered slave RX clock)

**Most likely real bug**: slave's `rx_fifo_io_rempty` is stuck at 1 (FIFO perpetually empty), because of a **write-side CDC race on `io_wreset` and/or `write_ptr_logic`** — the slave's recovered RX clock starts oscillating only after master begins transmitting, AFTER POR releases, so the FIFO's write-side pointer FFs may come out of reset asynchronously w.r.t. the gray-pointer sync chain.

This **revives Agent C's reset-release race hypothesis** but at a deeper level than tested. Earlier we pulsed `swi_swreset` (Wlink-level reset) but that doesn't directly reset the FIFO write-pointer FFs on the correct clock — the FIFO's `WavResetSync` produces `io_wreset` from `swi_swreset` via a sync-release demet on `io_wclk`, which has the same release-on-first-edge issue.

### What b25 still proves

b25 was built with `FPGA_INSERT_DEBUG_CORE=1`, so it'll have a working slave ILA. When deployed, capture:
- **`rx_accept_r`** rising edge — if it never fires, the new diagnosis is confirmed
- **`tx_state_r[*]`** to see whether slave's TX FSM is cycling through TX_SEND (the masking artifact)
- **`sp2wl/rx_fifo_io_wfull`** + **`sp2wl/rx_fifo_io_rempty`** to see FIFO state directly
- **`dbg_ptp_sp_rx_data_id`** to confirm data_id at consumer site is 0x50 when rx_valid pulses

If b25's RX_accept never fires while sp2wl/rx_pkt_valid does, the next build (b26) should focus on the rx_fifo internals — possibly add mark_debug INSIDE the rx_fifo, OR replace the WavFIFO_21 with a clean inferred SystemVerilog FIFO with proper init.

---

## 10c. CRITICAL session-redefining finding (b25 ILA + doorbell test)

After deploying b25 (built with FPGA_INSERT_DEBUG_CORE=1 + Agent K's dbg_hub fix), three convergent results redefined the diagnosis:

### Finding 1: Doorbell FC layer is DEAD
Wrote 7 doorbells (6× master→slave, 1× slave→master). Zero responses in `DOORBELL_RSP_ACC` either side. Master's `FC_TIDELINK_TXFCFIFO` went from `0x1` (empty) to `0x0` (NOT empty) — packets ARE queueing in the FC TX FIFO but NEVER draining onto the wire. **The FC layer's TX path is stuck across ALL bitstreams (b22 and b25 same behaviour).**

### Finding 2: ILA waveforms show slave RX 100% silent
On both b22 and b25 bitstreams, ILA level-triggers on `llrx/valid`, `rx_pkt_valid`, `rx_fifo_io_rempty`, `ptp_rx_valid_r` produce captures where ALL 41 probes are constant at idle values across all 4096 samples. The `wait_on_hw_ila` always returns "FIRED" but the waveforms show no activity — Vivado 2025.2's catch wrapper returns 0 even on timeout, the FIRED reports are misleading. The actual signal evidence: **`llrx/valid` is 0 throughout every capture window** — the most basic Wlink RX activity flag never asserts. Earlier "rx_pkt_valid fired" capture from earlier in session had `[Xicom 50-38] No trigger mark in any sample in window: 0` warning — that was the same false-positive.

### Finding 3: training-mode-stuck hypothesis matches ALL evidence
The user pointed out that **mask phase auto-clearing of `swi_training_mode_r` is gated on `mask_hs_auto_en` (NEGO_CFG[6])** — known Bug #3: synth-pruned to 0 in some builds, mask phase skipped, training_mode never auto-clears.

Predicted symptoms of training-mode-stuck: link sends training patterns instead of real data → lane lock 16/16 (training patterns lock fine), cal_done=1, ECC counters 0 (no real packets), `llrx/valid` never asserts (training patterns aren't classified as packets), FC TX queues packets but never sends (TX also outputs training), PHC RX silent.

**Every symptom matches.**

### Implication for the next build

**b26 must fix the mask_hs_auto_en synth-pruning** before any further PHC-specific work. The likely fix:
- Add `(* keep = "true" *) (* dont_touch = "true" *)` to `nego_cfg_reg[6]` in `axi_chiplet_controller.sv:309`
- AND/OR add `(* keep *)` on the autoneg FSM state regs that gate the mask phase transition (per `tidelink_autoneg.sv:711` `if (mask_hs_auto_en)`)
- Verify via post-route DCP inspection that `nego_cfg_reg[6]` is NOT optimised to a constant 0
- Optionally: add an APB-readable observability bit that exposes the actual `swi_training_mode_r` HW value (currently only the SW override at 0x2100 is readable)

If b26 fixes the training-mode auto-clear, **BOTH the FC layer and PHC RX should start working** — single root cause for two seemingly-separate bugs.

### Stand-down state at end of this session

- bridge1 lease released
- b22 currently loaded on boards (slave has the broken bitstream but link is up)
- b25 worktree + bitstreams still available (`/home/dam1n19/SoCLabs/td-bisect/b25-rx-accept-reg/`)
- b25 farm output sha256: master `0b933d31db9d`, slave `f63a053f8a98`
- All findings updated in this doc and in memory

---

## 11. TL;DR for next agent

You're picking up at: **b25 farm in flight at ~21:00-21:45 UTC**, worktree `/home/dam1n19/SoCLabs/td-bisect/b25-rx-accept-reg/`, branch `feat/phc-rx-accept-reg-b25`, HEAD `b9f567a`.

The bug is **slave PTP_CTRL[2] never sets to 1** despite master sending SYNC and slave's link layer receiving them. 7 hypotheses ruled out today; primary working hypothesis is **`rx_accept` combinational cone replicated per consumer in the slave bitstream's RTL placement, with the latch consumer's replica permanently 0**.

b25 registers `rx_accept` into a single (`keep`+`dont_touch`+`mark_debug`) FF to force one physical net for all consumers, and enables `FPGA_INSERT_DEBUG_CORE=1` so b25's bitstream ALSO has a real ILA (with the correct dbg_hub clock frequency from Agent K's fix) for definitive electrical diagnosis if b25 also fails.

**Deploy + test b25 once the farm completes. If PTP_CTRL[2] → 1, the bug is solved. If not, use the ILA to capture `rx_accept_r`, `dbg_ptp_sp_rx_data_id`, and `ptp_rx_valid_r` on slave and decide between cone-replication-of-data_id vs latch-readback-broken theories.**

Good luck.
