# ILA Plan — Master RX / S→M ACK-Return Path Microscope

Status: READY-TO-BUILD design (no build, no deploy, no design-RTL change in this doc)
Author: instrumentation-design agent, 2026-06-05
Working dir: `/home/dam1n19/SoCLabs/tidelink`
Target under instrumentation: **`pynq-z2-pair-mmcmbypass-oddr-all`** (the MASTER bed, z2_02)
Companion: `docs/DEBUG_PLAN_CREDIT_RETURN_DATA_TRANSFER.md` (hypothesis H1)

> HARD RULE honoured: nothing under `/research/AAA/ip_library/**` or
> `/research/AAA/phys_ip_library/**` is touched. All RTL edits are confined to
> `src/rtl/local_overrides/**` + `deps/tidelink-gpio-phy/rtl/**` (project tree).

---

## 0. The bug, in one line

Link comes up bilaterally (cal_done=1, cr=1, crack=1, 8/8 lock) but sustained
traffic decays: the **master's RX chain stops decoding the slave's ACK packets**,
so `fe_rx_ptr` (credit return) freezes, `fe_rx_is_full` latches, the functional
credit ring fills, and both M→S delivery and the S→M return-link die. We want an
ILA that freezes the master RX chain **at the instant the ACKs stop framing**,
end-to-end from the deskew FIFO output through the RX framer, the packet decode,
the `ack_nack_fifo` CDC, and the `fe_rx_ptr` update.

---

## 1. Instrumentation method — decision + why it avoids the known blockers

### 1.1 The three candidate methods in this repo

| Method | Reaches internal Wlink/FCSM nets? | Status here |
|---|---|---|
| (A) BD-level `create_bd_cell -vlnv …:ila:6.2` wired in `tidelink_design.tcl` (as in `pynq-z2-pair-flip-ila/tidelink_design.tcl:324`) | **NO** — only top-level `tidelink_0` BD pins. The FCSM `obs_*` signals are consumed into the APB SWI_LANE_STATUS register **inside** the packaged IP (`tidelink_top.sv:2094`, `axi_chiplet_controller.sv:1781-1797`); they are **not** `tidelink_0` ports. | unusable for this bug |
| (B) `insert_debug_core.tcl` (FPGA_INSERT_DEBUG_CORE=1) — post-synth scan of `MARK_DEBUG==1` nets → builds `u_dbg_int` → writes `.ltx` (`fpga/build_design.tcl:287-308`, `fpga/insert_debug_core.tcl`) | **YES** — works on `-hierarchical` nets anywhere in the synth DCP | **chosen** |
| (C) Hand-written `create_debug_core` stanza baked into a `*_drc.xdc` | YES but **forbidden** — this is exactly what caused 6 build failures and was deleted (commit `9bcee8e`); `pynq_z2_tidelink_drc.xdc:18-30` now documents its removal | DO NOT reintroduce |

**Chosen method: (B) `insert_debug_core.tcl` + a SMALL, SCOPED set of `mark_debug`
attributes re-added ONLY to the override RTL files.**

### 1.2 Why mark_debug must be re-added, and how to do it without re-tripping the blockers

`insert_debug_core.tcl:24` selects nets via `get_nets -hierarchical -filter
{MARK_DEBUG == 1 && TYPE == SIGNAL}`. On 2026-06-03 all 65 live `mark_debug =
"true"` attrs were stripped from RTL (memory `reference_fpga_markdebug_dbghub_blocker`;
verified today: `grep -rn 'mark_debug = "true"' src/rtl/` returns **zero** live
hits, only `/* mark_debug-disabled */` comment forms). So today an
FPGA_INSERT_DEBUG_CORE=1 build finds 0 marked nets and silently builds NO core
(`insert_debug_core.tcl:27-30`). We must re-introduce a **surgical** mark set.

The two historical blockers and how this plan defeats each:

* **Blocker (a) — Chipscope 16-213 (constant-folded marked net → unconnected
  probe channel).** Root mechanism: `opt_design` runs AFTER
  `implement_debug_core` and constant-propagates a marked *single-use
  combinational* net to GND, disconnecting the probe pin
  (`reference_fpga_markdebug_dbghub_blocker`, `insert_debug_core.tcl:127-147`).
  **Defences, all already in the script + reinforced by our net choice:**
  - `insert_debug_core.tcl:142-147` pins every probed net `DONT_TOUCH true`
    before `implement_debug_core` (Xilinx-recommended guard for 16-213).
  - `insert_debug_core.tcl:168-181` skips any probe group whose net is genuinely
    dangling (no driver/pin/port), with a loud warning, instead of failing.
  - **Our net-selection rule (the real defence): mark only `reg` declarations
    and multi-fanout control nets — NEVER a one-shot combinational wire that
    opt_design can fold.** Every signal in Capture Config #1 §3 below is either a
    flip-flop output (`state`, `fe_rx_ptr`, `ne_rx_ptr`, `fe_rx_credit_max_txsync`,
    `send_ack_req`, `last_good_pkt_from_rx`, `byte_count`, deskew `out_data` /
    `primed`) or a multi-fanout decode net that already feeds the FCSM
    (`fe_rx_is_full`, `pkt_is_ack_pkt`, `isAckPacket`, …). Registers cannot be
    constant-folded; the high-fanout decodes survive because they drive the state
    machine. This is why the 2026-06-03 fold hit the *48-bit FC-word* path (a
    training-mode-bypass combinational mux) and NOT these registers.

* **Blocker (b) — the `create_debug_core` stanza in `*_drc.xdc`.** Already
  removed (`pynq_z2_tidelink_drc.xdc` is now 31 lines = combinatorial-loop waiver
  only). `insert_debug_core.tcl:224-227` writes the `.ltx` itself via
  `write_debug_probes`; it needs NO XDC stanza. **Do not run a Vivado
  `save_constraints` that re-bakes a stanza into the drc.xdc** (that is how it got
  there originally). The build flow's `save_constraints -force`
  (`insert_debug_core.tcl:195`) writes to the *timing* constraint set, not the
  drc.xdc, and is required by `implement_debug_core` — leave it.

* **Blocker (c) — insert_debug_core.tcl gotchas (`reference_insert_debug_core`).**
  All already fixed in the current script: bracketed-name handling
  (`:36-49` stores net *objects*), core named `u_dbg_int` not `u_ila_int`
  (`:86`), BD-top clock pick by fewest `/` (`:63-75`), and the Vivado-2025.2
  `C_CLK_INPUT_FREQ_HZ` auto-detect (`:106-125`) that prevents the dbg_hub
  waveform-corruption at readback. **Do not touch the script.** The
  `MAX_DATA_DEPTH`/`CAPTURE_MODE` 2025.2 read-only quirks are handled at IP
  creation: depth is fixed by `C_DATA_DEPTH 4096` (`:87`) at build time — we do
  NOT try to change it at capture time.

### 1.3 What we add (the only RTL deltas — proposed diffs, NOT applied)

A **single new override file is NOT needed**; we add `(* mark_debug = "true" *)`
attributes to declarations already in the override files. Because the FPGA IP is
packaged from `flist/tidelink_fpga.flist` (which already points at
`src/rtl/local_overrides/WlinkGenericFCSM_6.v`, `…/WlinkRxLinkLayer.v`,
`…/WavD2DGpio.v`, and `deps/tidelink-gpio-phy/rtl/tidelink_lane_deskew.sv`), the
marks land in the synth DCP for THIS target with no flist change.

> SCOPING NOTE: re-adding mark_debug affects ALL targets at synth time, but the
> NO-ILA targets are protected by `strip_mark_debug.tcl` (the
> `STEPS.OPT_DESIGN.TCL.PRE` hook set in `build_design.tcl:303-307` for the
> else-branch) which clears MARK_DEBUG before opt_design. So a no-ILA build of
> any target stays clean; only an FPGA_INSERT_DEBUG_CORE=1 build wires the core.
> **However**, because the 2026-06-03 incident proved the *auto*-debug path can
> still bite if a marked net folds, keep the mark set to the register/control
> nets in §3 and run the FIRST instrumented build on a farm node where a failure
> costs only one build (see §6 contingency).

The exact attribute insertions (diffs) are listed in **Appendix A**. They are
the minimal set that makes the §3 probe list reachable.

---

## 2. Clock-domain reality (drives the two-config split)

The master RX chain crosses three clock domains. The ILA samples on ONE clock
(`insert_debug_core.tcl:54` picks `clk_wiz_0/clk_out1` = hclk, 25 MHz on this
target). Signals from a faster/async domain are still captured but only
hclk-sampled snapshots — fine for *event localisation* (where does the ACK
die?), not for cycle-exact link-rate timing.

| Domain | Net / clock | Signals living here |
|---|---|---|
| **Recovered RX word clock** | `gpiorx_0_io_link_clk` (= forwarded `pad_clk_rx` / 16), `…/gpio/u_deskew` `out_clk` (`WavD2DGpio.v:364`) | deskew `out_data`/`all_ready`/`primed`/`lane_has_data`; RxLinkLayer `llrx` (`Wlink.v:1327`, clocked by `llrx_clock`) `state`/`byte_count`/`endOfPacket`/`valid` |
| **FC RX clock** `io_rx_clk` | drives the FCSM packet decode + `ack_nack_fifo` *write* (`WlinkGenericFCSM_6.v:856`) | `auto_rx_in_sop/valid/data_id`, `crc_corrupt`, `pkt_is_*`, `ack_nack_fifo_io_winc/io_wfull` |
| **FC TX clock** `io_tx_clk` | drives FCSM `state` + ring ptrs + `ack_nack_fifo` *read* (`:860`) | `state`, `fe_rx_ptr`, `ne_rx_ptr`, `fe_rx_credit_max_txsync`, `send_ack_req`, `last_good_pkt_from_rx`, `ack_nack_fifo_io_rinc/io_rempty/io_rdata`, `isAckPacket/isNotExpPacket`, `fe_rx_is_full` |

On this FPGA target `io_rx_clk`/`io_tx_clk` are both derived from the recovered
link clock region (the GPIO PHY runs the Wlink at link rate); hclk (clk_wiz
clk_out1) is the BD fabric clock the ILA samples. The deskew/framer nets are in
a *different* (recovered) domain than the hclk ILA clock — they are still
observable as hclk-sampled values, which is exactly what we want for "did the
framer's byte_count desync when ACKs stopped?". Cycle-exact deskew-bubble timing
would need the ILA clocked on `gpiorx_0_io_link_clk`; that is **Capture Config #2**.

**Because one 4096-deep ILA on one clock cannot cleanly serve both the recovered
RX-framer domain and the io_tx FCSM domain, this plan ships TWO capture configs.
Run Config #1 (FCSM/ACK-focused, hclk-sampled) FIRST** — it directly answers
"does the credit ring wedge because the ACK never decodes?" and triggers on the
wedge bit. Config #2 (deskew/framer-focused, recovered-clock-sampled) is the
follow-up that pins *where in the RX front-end* the ACK frame is corrupted.

---

## 3. Capture Config #1 — FCSM / ACK-decode microscope (RUN FIRST)

**ILA clock:** `clk_wiz_0/clk_out1` (hclk, auto-picked by
`insert_debug_core.tcl:65`). Depth 4096 (`:87`).

**Hierarchical instance path prefix** (verified from the instance chain
`tidelink_0` → `…/u_tidelink_top` → `u_chiplet_controller` → `u_wlink` →
`wlink_tidelinktl`; the BD packages `tidelink_top` as `tidelink_0`):

```
PFX_FCSM = <tidelink_0>/.../u_chiplet_controller/u_wlink/<TideLinkToWlink inst>/wlink_tidelinktl
```

The `u_wlink` instance is named at `axi_chiplet_controller.sv:1597`
(`Wlink #(…) u_wlink`). `wlink_tidelinktl` is the FCSM instance inside
`TideLinkToWlink.v:99` (override). `insert_debug_core.tcl` resolves the FULL
hierarchical net name automatically from the `mark_debug` attr, so you do NOT
hand-type these paths — you only mark the declaration. The paths are listed so
you can verify the probe in the `.ltx` after build (grep the `.ltx` for the leaf
name, per `reference_insert_debug_core` "How to apply").

### Probe list (each line: probe purpose — RTL `file:line` of the marked declaration — leaf net name)

**Ring + wedge (the trigger neighbourhood):**
1. `state[2:0]` — FCSM state (4=LINK_IDLE,5=LINK_DATA,6=send-ACK) — `WlinkGenericFCSM_6.v:361` — `state`
2. `fe_rx_ptr[7:0]` — credit-return pointer (FROZEN = the bug) — `WlinkGenericFCSM_6.v:440` — `fe_rx_ptr`
3. `ne_rx_ptr[7:0]` — credit-consume pointer (keeps advancing while #2 frozen) — `WlinkGenericFCSM_6.v:442` — `ne_rx_ptr`
4. `fe_rx_credit_max_txsync[7:0]` — ring modulus, must stay 0x1f (rules H6) — `WlinkGenericFCSM_6.v:398` — `fe_rx_credit_max_txsync`
5. `fe_rx_is_full` — **PRIMARY TRIGGER** (rising = wedge) — `WlinkGenericFCSM_6.v:470` — `fe_rx_is_full`
6. `send_ack_req` — receiver intends to emit ACK (→ state 6) — `WlinkGenericFCSM_6.v:474` — `send_ack_req`
7. `last_good_pkt_from_rx[7:0]` — the ACK payload this die would send — `WlinkGenericFCSM_6.v:476` — `last_good_pkt_from_rx`

**ack_nack_fifo CDC + decode (did a clean ACK ever dequeue?):**
8. `ack_nack_fifo_io_winc` — write strobe (io_rx_clk) — `WlinkGenericFCSM_6.v:316` — `ack_nack_fifo_io_winc`
9. `ack_nack_fifo_io_rinc` — read strobe (io_tx_clk, gated `& state!=0`) — `WlinkGenericFCSM_6.v:319` — `ack_nack_fifo_io_rinc`
10. `ack_nack_fifo_io_wfull` — CDC backpressure (H3) — `WlinkGenericFCSM_6.v:322` — `ack_nack_fifo_io_wfull`
11. `ack_nack_fifo_io_rempty` — empty (no entry to decode) — `WlinkGenericFCSM_6.v:323` — `ack_nack_fifo_io_rempty`
12. `ack_nack_fifo_io_rdata[18:16]` — dequeued **pkt-type tag** (0=exp,1=notexp,2=ACK,3=NACK,4=crc) — `WlinkGenericFCSM_6.v:321` — `ack_nack_fifo_io_rdata` (probe the whole 19-bit net; tag is bits 18:16, credit byte is 15:8)
13. `isAckPacket` — decoded ACK present (THE credit-return enabler) — `WlinkGenericFCSM_6.v:426` — `isAckPacket`
14. `isNotExpPacket` — **SECONDARY TRIGGER** (mis-frame pulse) — `WlinkGenericFCSM_6.v:425` — `isNotExpPacket`

**Raw RX packet decode feeding the fifo (io_rx_clk; the mis-frame source):**
15. `auto_rx_in_sop` — SOP of the inbound packet — `WlinkGenericFCSM_6.v` (port `io_rx_in_sop`; net `auto_rx_in_sop`) — see note†
16. `auto_rx_in_valid` — inbound word valid — port `io_rx_in_valid` / net `auto_rx_in_valid` †
17. `auto_rx_in_data_id[7:0]` — packet data-id (ACK-id match drives #13) — net `auto_rx_in_data_id` †
18. `crc_corrupt` — **SECONDARY TRIGGER alt** (CRC fail = corrupted ACK) — `WlinkGenericFCSM_6.v:367` — `crc_corrupt`
19. `pkt_is_ack_pkt` — combinational ACK-id decode (pre-fifo) — `WlinkGenericFCSM_6.v:385` — `pkt_is_ack_pkt`
20. `pkt_is_data_pkt` — combinational data decode — `WlinkGenericFCSM_6.v:369` — `pkt_is_data_pkt`

† Signals 15-17: `auto_rx_in_*` are the FCSM input ports
(`WlinkGenericFCSM_6.v` port list `io_rx_in_*`); the internal aliases
`ll_rx_pktnum`/`auto_rx_in_data[7:0]` (`:360`) confirm the bus exists. Mark the
**port-driving net at the `wlink_tidelinktl` instantiation in
`TideLinkToWlink.v`** (the `.io_rx_in_sop(...)`, `.io_rx_in_valid(...)`,
`.io_rx_in_data_id(...)` connections, `TideLinkToWlink.v:~99+`) so the mark is on
a multi-fanout net that won't fold. If marking at the port is awkward, the
nearest reachable proxy is `_crc_corrupt_T = auto_rx_in_sop & auto_rx_in_valid`
(`WlinkGenericFCSM_6.v:362`) which captures SOP∧valid in one bit.

**Probe budget:** 20 probe groups. Total trigger-capable width ≈
3+8+8+8+1+1+8 + 1+1+1+1+19+1+1 + 1+1+8+1+1+1 ≈ **75 bits**. Comfortably within a
4096-deep ILA on a 7z020 (the existing `u_dbg_int` ran ~48-wide aggregates +
many singles before). If LUT/BRAM pressure shows up at impl, **drop probes
4, 7, 16, 20** first (least diagnostic) to get under budget — do NOT drop the
trigger nets (5, 14, 18) or the ring pair (2, 3).

---

## 4. Capture Config #2 — Deskew + RX-framer microscope (RUN SECOND, if Config #1 shows ACKs never dequeue cleanly)

**ILA clock:** the **recovered RX word clock** `gpiorx_0_io_link_clk`
(`WavD2DGpio.v:364`). To make `insert_debug_core.tcl:54` pick this instead of
hclk you must either (a) temporarily point its `clk_candidates` filter at the
recovered-clock net, or (b) add an explicit BD-level `ila` on that clock. The
**lower-risk option is (b)** — but since the recovered clock is INSIDE the
packaged IP, (b) is not reachable from the BD; therefore use (a): a 4-line
variant of the clock-pick block. **Proposed diff in Appendix B.** This is the
only place Config #2 deviates from the established flow; flagged as such.

### Probe list (recovered-clock domain)

**Deskew FIFO (H1 bubble source) — `…/u_wlink/phy/gpio/u_deskew` (`Wlink.v:1123` `phy`, `WlinkGPIOPHY.v:101` `gpio`, `WavD2DGpio.v:353` `u_deskew`):**
1. `out_data[127:0]` — aligned 128-bit word OR a **reduced parity/hash** (see note) — `tidelink_lane_deskew.sv:53` — `out_data`
2. `all_ready` — read-enable; glitch-low = bubble inject — `tidelink_lane_deskew.sv:148` — `all_ready`
3. `primed` — FIFO primed flag (re-prime = re-glitch) — `tidelink_lane_deskew.sv:175` — `primed`
4. `lane_has_data[7:0]` — per-lane occupancy≥1 (the `&` that forms `all_ready`) — `tidelink_lane_deskew.sv:140` — `lane_has_data`

> `out_data` is 128 bits — too wide to spend a probe on for an event capture.
> Probe a **16-bit reduced signature** instead: XOR-fold the 8 lanes
> (`^{out_data[127:112],…,out_data[15:0]}` → 16b) declared as a new
> `mark_debug` wire `deskew_out_sig` in `WavD2DGpio.v`. Appendix A gives the
> one-line wire. This keeps the bubble visible (signature jumps on a duplicate
> word) without burning 128 ILA channels.

**RX framer `llrx` (`Wlink.v:1327`):**
5. `state[1:0]` — byte-align FSM state — `WlinkRxLinkLayer.v:141` — `state`
6. `byte_count[16:0]` — frame byte counter (desyncs on bubble) — `WlinkRxLinkLayer.v:224` — `byte_count`
7. `endOfPacket` — EOP (mis-fires when byte_count desyncs) — `WlinkRxLinkLayer.v:239` — `endOfPacket`
8. `valid` (= `auto_out_valid`/`auto_out_sop`) — decoded word-valid out — `WlinkRxLinkLayer.v:1055,1059` — `valid`

**Probe budget Config #2:** 16(sig)+1+1+8 + 2+17+1+1 ≈ **47 bits**, depth 4096.

---

## 5. Trigger configuration

`insert_debug_core.tcl` builds a BASIC-trigger ILA (`C_ADV_TRIGGER false`,
`:90`). Every probe is `DATA_AND_TRIGGER` (`:186`). So all listed nets are
trigger-capable. Triggers are set at **capture time** in the HW Manager (via the
mapstone-dev `phc_ila_capture` flow), NOT baked into the build.

### Config #1 triggers

* **PRIMARY — the wedge moment:** `fe_rx_is_full` **rising edge** (`0→1`).
  In `phc_ila_capture` terms: probe `*fe_rx_is_full*`, trigger value `R` (rising)
  or compare `==1` with the previous-sample qualifier. This is the canonical
  "ring just latched full" instant.
* **SECONDARY — the mis-frame moment (OR-combine if the HW supports 2 trigger
  units; else run a second capture):** `isNotExpPacket == 1` **OR**
  `crc_corrupt == 1` (a returning ACK that arrived corrupted/misframed). Probe
  `*isNotExpPacket*` / `*crc_corrupt*`, trigger `==1`.

### Capture window / position

We want the **lead-up** (what the framer/decode did as ACKs stopped), so set the
**trigger position late in the window**: capture **3072 pre-trigger / 1024
post-trigger** (75% pre) of the 4096-deep buffer. In HW-Manager terms set
`TRIGGER_POSITION = 3072`. At hclk 25 MHz, 4096 samples ≈ 164 µs — long enough to
see dozens of link-rate ACK cadences leading into the wedge.

> 2025.2 note: `CONTROL.CAPTURE_MODE` is read-only (`reference_insert_debug_core`
> #5) so we use **trigger** conditions only (no capture/storage qualification).
> `TRIGGER_POSITION` is runtime-settable; `MAX_DATA_DEPTH` is not (fixed 4096 at
> build, `:87`) — do not try to change depth at capture.

### Config #2 trigger

* `endOfPacket` rising while `all_ready` was low in the preceding samples — but
  since BASIC trigger can't express "preceding", trigger simply on
  `endOfPacket` **rising** with `TRIGGER_POSITION = 3072`, then read `all_ready`
  / `primed` / `byte_count` in the pre-trigger window to see the bubble. Alt
  trigger: `all_ready` **falling** (catch the bubble-inject directly).

---

## 6. Drive / load — provoke the wedge while armed

The ILA must be armed BEFORE traffic starts decaying. Bring the pair up, arm the
ILA, then start sustained traffic. Use the existing bench helpers (no new infra):

1. **Bring up + bilateral lock** (master phase 8 = eye centre, per memory
   `project_tidelink_hw_deploy_deskew_s2m_2026_06_04`):
   ```
   PHASE_OVERRIDE=0x00100000 pynq_host/scripts/deploy_pair.sh 192.168.4.101 z2_02 die_a /tmp/tidelink_deploy   # master
   PHASE_OVERRIDE=0x00060000 pynq_host/scripts/deploy_pair.sh 192.168.6.101 z2_03 die_b /tmp/tidelink_deploy   # slave
   pynq_host/scripts/sw_coord_autocal_region8_FIX.sh   # SWI_TRAINING_MODE=1 → 8/8 lock + cal_done=1
   ```
   Confirm lock with `pynq_host/scripts/wlink_probe.sh` (SWI_LANE_STATUS:
   FCSM=4/5, cr=crack=1, locked=0xff).
2. **Arm the ILA** on the master (z2_02) — see §7. Trigger = `fe_rx_is_full`
   rising, position 3072.
3. **Start sustained load that drives the credit ring.** Two flavours — run the
   AHB-DATA one first (it is the load that exercises the full RX-FIFO + ACK path
   and is what the HW symptom was observed under):
   * **AHB DATA M→S + drain** (preferred, exercises ledger 1A *and* 1B):
     `/tmp/td_unidir_sustained.sh` (sends AHB data packets M→S; per the debug
     plan STEP 0, verify it both *sends data* and *drains* the slave RX FIFO —
     if it does not drain, add an AHB read loop of `0x44010000` so CURRENT_CREDITS
     does not falsely monotonic-drain and confound the read).
   * **Doorbell/credit recal** (exercises ring 1A only, no RX-FIFO):
     `/tmp/td_doorbell_test.sh` ≥100 each way, or `/tmp/td_credit_diag.sh`.
   The wedge typically appears within the first 1–2 packets/doorbells of
   sustained flow (debug plan §0), so the 164 µs pre-trigger window will hold the
   decay onset.
4. If z2_02 throws "No route to host" (transient PS-AXI bus error), re-ping /
   re-flash before declaring a miss (memory `feedback_lease_grant_before_deploy`;
   `pkill -9` the whole deploy tree, not just the parent).

---

## 7. Build + capture + read-back — exact commands

### 7.1 Build the instrumented MASTER bitstream (no deploy in this doc — these are the commands you will run)

```bash
cd /home/dam1n19/SoCLabs/tidelink
source set_env.sh
# Apply Appendix-A mark_debug diffs first (Config #1) — git-revertible.
# Build the master target with the debug core inserted:
make -C fpga farm_build \
     FPGA_INSERT_DEBUG_CORE=1 \
     FARM_JOBS="pynq-z2-pair-mmcmbypass-oddr-all@srv04936"
# Watch the farm log for the INSTRUMENT: lines proving the core was wired:
#   imp/fpga/run/farm/pynq-z2-pair-mmcmbypass-oddr-all@srv04936.<ts>.log
#   expect: "INSTRUMENT: found N marked debug nets"
#           "INSTRUMENT: probeK = state (width 3)" ... per §3
#           "INSTRUMENT: debug core successfully implemented"
#           "INSTRUMENT: wrote probes file"
```

Outputs (rsynced back to the identical local path):
* `imp/fpga/output/pynq-z2-pair-mmcmbypass-oddr-all/tidelink.bit`
* `imp/fpga/output/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_design_wrapper.ltx`
  (written by `insert_debug_core.tcl:227`)

**Pre-deploy sanity (catches a silently-unwired probe before burning a bench
slot):**
```bash
grep -c 'probe' imp/fpga/output/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_design_wrapper.ltx
# and confirm the leaf names you marked appear:
grep -E 'fe_rx_is_full|isAckPacket|ne_rx_ptr|fe_rx_ptr' \
     imp/fpga/output/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_design_wrapper.ltx
```
If a probe you marked is missing from the `.ltx`, opt_design folded it — fall
back to its proxy (§3 †) and rebuild; do NOT proceed to bench with a missing
trigger probe.

### 7.2 Stage bitstream + .ltx on mapstone-dev

Per `reference_phc_ila_capture` (cat-pipe, NOT scp; mapstone-dev user `david`):
```bash
# bit→bin for fpga_manager:
fpga/scripts/bit2bin.py imp/fpga/output/pynq-z2-pair-mmcmbypass-oddr-all/tidelink.bit \
                        /tmp/tidelink-master-ila.bin
# stage both to ~/td_milestone_stage/ on mapstone-dev (convention):
cat /tmp/tidelink-master-ila.bin | ssh mapstone-dev 'cat > ~/td_milestone_stage/master-ila/tidelink-master-ila.bin'
cat imp/fpga/output/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_design_wrapper.ltx \
    | ssh mapstone-dev 'cat > ~/td_milestone_stage/master-ila/tidelink-master.ltx'
```

### 7.3 Arm, trigger, capture (on mapstone-dev)

The capture pipeline `pynq_host/scripts/phc_ila_capture.{sh,tcl}` lives **on
mapstone-dev** (per `reference_phc_ila_capture`; it is not checked into this repo
tree — it was committed to the deploy host as `2509070/775e2ba/a64eb1e/a22b2e6`).
Master cable glob = `*Z2_02*`, selected by `-b master`.

```bash
ssh mapstone-dev
export VIVADO_BIN=/tools/Xilinx/2025.2/Vivado/bin/vivado
export TIDELINK_LTX=~/td_milestone_stage/master-ila/tidelink-master.ltx
# (bitstream already programmed via PYNQ fpga_manager in the §6 bring-up; the
#  script attaches AFTER programming.)

# Config #1 PRIMARY trigger: fe_rx_is_full rising, 75% pre-trigger:
TIDELINK_TRIGGER_VALUE=R TIDELINK_TRIGGER_POSITION=3072 \
~/SoCLabs/tidelink/pynq_host/scripts/phc_ila_capture.sh \
    -b master \
    -p '*wlink_tidelinktl*fe_rx_is_full*' \
    -t 60 \
    -o ~/td_milestone_stage/captures/master_s2m_ack/
# (then, in another shell, kick the §6 sustained load on z2_02.)
```

The script polls `STATUS` directly (avoids the `wait_on_hw_ila` corrupted-
waveform bug, `reference_insert_debug_core` #6) and dumps **CSV + `.ila`
waveform** to `OUT_DIR` with a timestamp prefix. For the secondary trigger,
re-run with `-p '*isNotExpPacket*'` (or `*crc_corrupt*`) and
`TIDELINK_TRIGGER_VALUE=1`. To enumerate exact probe names first:
```bash
~/SoCLabs/tidelink/pynq_host/scripts/phc_ila_discover.sh -b master -l "$TIDELINK_LTX"
```

### 7.4 What the capture proves

Read the CSV around the trigger sample:
* `fe_rx_ptr` **frozen** while `ne_rx_ptr` **advances** + `state` stuck at 5 →
  ACK never returned → H1/H3 confirmed; go to Config #2 to see *where* in the RX
  front-end the ACK frame died.
* `ack_nack_fifo_io_wfull` asserted → H3 (CDC backpressure).
* `state` (FCSM) never reaches 6 anywhere in the window → receiver never even
  intended to ACK → upstream framing/decode (Config #2).
* `fe_rx_credit_max_txsync != 0x1f` → H6 regression (revisit `ccfd255`).
* In Config #2: `all_ready` glitches low → `byte_count` desync → `endOfPacket`
  mis-fires → `isNotExpPacket`/`crc_corrupt` pulses on the master = the
  deskew-bubble corrupting the return-link ACK (H1, the smoking gun).

---

## 8. Reachability caveats / nearest proxies

* **`out_data[127:0]` (deskew):** too wide to probe directly for an event
  capture — use the 16-bit XOR-fold `deskew_out_sig` proxy (Appendix A / §4 note).
* **`auto_rx_in_*` (signals 15-17):** these are FCSM *ports*; mark the
  **driving net at the `wlink_tidelinktl` instantiation** in `TideLinkToWlink.v`,
  not inside the FCSM module (a port net inside the module may be optimised to
  the port alias). Proxy if needed: `_crc_corrupt_T` (`:362`) for SOP∧valid.
* **`io_rx_clk` vs `io_tx_clk` cross-domain in Config #1:** the deskew/framer
  nets are hclk-sampled snapshots, adequate for "which stage lost the ACK" but
  not cycle-exact bubble timing — that is the explicit purpose of Config #2's
  recovered-clock ILA.
* **`isAckPacket`/`isNotExpPacket`/`crc_corrupt`** are multi-fanout decode nets
  feeding the FCSM and the obs mux — they survive opt_design (already proven: the
  obs versions are exported as `obs_*` today). Safe to mark.
* If `insert_debug_core.tcl` reports a probe group skipped as "dangling"
  (`:178-181`), that net folded — use its proxy and rebuild; never hand-wire a
  `create_debug_core` stanza into any `*_drc.xdc` (blocker b).

---

## Appendix A — Proposed mark_debug diffs (Config #1, + #2 signature wire)

These are the ONLY RTL deltas. All in the project override tree. Git-revertible.
NOT applied by this doc.

```diff
# src/rtl/local_overrides/WlinkGenericFCSM_6.v
-  reg [2:0] state; // @[FC.scala 143:91]        (unique decl at :361 in WlinkGenericFCSM_6.v)
+  (* mark_debug = "true" *) reg [2:0] state; // @[FC.scala 143:91]
-  reg [7:0] fe_rx_ptr; // @[FC.scala 362:48]
+  (* mark_debug = "true" *) reg [7:0] fe_rx_ptr; // @[FC.scala 362:48]
-  reg [7:0] ne_rx_ptr; // @[FC.scala 366:48]
+  (* mark_debug = "true" *) reg [7:0] ne_rx_ptr; // @[FC.scala 366:48]
-  reg [7:0] fe_rx_credit_max_txsync;
+  (* mark_debug = "true" *) reg [7:0] fe_rx_credit_max_txsync;
-  reg send_ack_req; // @[FC.scala 407:48]
+  (* mark_debug = "true" *) reg send_ack_req; // @[FC.scala 407:48]
-  reg [7:0] last_good_pkt_from_rx; // @[FC.scala 414:48]
+  (* mark_debug = "true" *) reg [7:0] last_good_pkt_from_rx; // @[FC.scala 414:48]
# For wires that are multi-fanout decodes (won't fold), mark the declaration:
#   fe_rx_is_full (:470), pkt_is_ack_pkt (:385), pkt_is_data_pkt (:369),
#   crc_corrupt (:367), isAckPacket (:426), isNotExpPacket (:425),
#   ack_nack_fifo_io_winc/io_rinc/io_wfull/io_rempty (:316/:319/:322/:323),
#   ack_nack_fifo_io_rdata[18:0] (:321)
# each as:  (* mark_debug = "true" *) wire ... ;
```
```diff
# src/rtl/local_overrides/TideLinkToWlink.v  (signals 15-17, marked on the
#   net driving the wlink_tidelinktl .io_rx_in_* ports)
#   mark the local wires connected to .io_rx_in_sop / .io_rx_in_valid /
#   .io_rx_in_data_id at the wlink_tidelinktl instantiation (~:99+).
```
```diff
# src/rtl/local_overrides/WavD2DGpio.v  (Config #2 deskew signature proxy)
+  (* mark_debug = "true" *) wire [15:0] deskew_out_sig =
+        deskew_aligned_data[127:112] ^ deskew_aligned_data[111:96]
+      ^ deskew_aligned_data[95:80]   ^ deskew_aligned_data[79:64]
+      ^ deskew_aligned_data[63:48]   ^ deskew_aligned_data[47:32]
+      ^ deskew_aligned_data[31:16]   ^ deskew_aligned_data[15:0];
```
```diff
# deps/tidelink-gpio-phy/rtl/tidelink_lane_deskew.sv  (Config #2)
-  output reg [LANES*WIDTH-1:0] out_data
+  (* mark_debug = "true" *) output reg [LANES*WIDTH-1:0] out_data   # OR rely on deskew_out_sig proxy only
-  wire all_ready = &lane_has_data;
+  (* mark_debug = "true" *) wire all_ready = &lane_has_data;
-  reg primed;
+  (* mark_debug = "true" *) reg primed;
-  wire [LANES-1:0] lane_has_data;
+  (* mark_debug = "true" *) wire [LANES-1:0] lane_has_data;
```
```diff
# src/rtl/local_overrides/WlinkRxLinkLayer.v  (Config #2)
-  reg [1:0] state; // @[LinkLayer.scala 611:44]
+  (* mark_debug = "true" *) reg [1:0] state; // @[LinkLayer.scala 611:44]
-  reg [16:0] byte_count; // @[LinkLayer.scala 657:36]
+  (* mark_debug = "true" *) reg [16:0] byte_count; // @[LinkLayer.scala 657:36]
-  wire endOfPacket = _endOfPacket_T_1 >= _GEN_888; // @[LinkLayer.scala 662:43]
+  (* mark_debug = "true" *) wire endOfPacket = _endOfPacket_T_1 >= _GEN_888;
```

> Build Config #1 with ONLY the WlinkGenericFCSM_6.v + TideLinkToWlink.v marks.
> Build Config #2 with ONLY the WavD2DGpio.v + tidelink_lane_deskew.sv +
> WlinkRxLinkLayer.v marks. Keeping the two mark sets disjoint keeps each ILA's
> probe count + clock domain clean and minimises fold risk.

---

## Appendix B — Config #2 recovered-clock pick (only deviation from the established flow)

`insert_debug_core.tcl:54` hard-filters the ILA clock to `*clk_wiz_0*clk_out1*`.
For Config #2 the ILA must sample `gpiorx_0_io_link_clk` (the recovered RX word
clock, inside the packaged IP). Proposed minimal, REVERTIBLE variant (a copy of
the script for Config #2, or an env-gated branch — do NOT edit the Config #1
path):

```tcl
# Config #2 only: pick the recovered RX link clock instead of hclk.
set clk_candidates [get_nets -hierarchical -filter \
   {NAME =~ "*gpio*io_link_clk*" && NAME !~ "*u_ila_int*" && NAME !~ "*dbg_hub*"}]
# then keep the existing fewest-'/' heuristic; expect gpiorx_0_io_link_clk's
# buffered net. Verify C_CLK_INPUT_FREQ_HZ auto-detect (:106-125) resolves to
# the link rate (~ pad_clk_rx/16), else the dbg_hub readback corrupts.
```

Risk: the recovered clock may not have a `create_clock`/`get_clocks` object, so
the `:106-125` freq auto-detect could fall back to 25 MHz and corrupt readback.
Mitigation: add an explicit `create_clock` on `gpiorx_0_io_link_clk` in the
target timing XDC for the Config #2 build only (revert after). Because this is a
real deviation, run Config #2 only AFTER Config #1 has confirmed the ACK never
dequeues — do not pay this cost speculatively.
```
