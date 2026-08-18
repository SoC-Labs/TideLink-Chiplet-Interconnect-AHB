# awready-wedge two-core ILA capture — runbook

**Goal:** on silicon, confirm or refute **H1** — the D2D write-wedge root is the AW-node
`a2l_fc_replay` window filling on peer-ACK/credit silence, killing `s_axi_awready` with no
self-clear (`memory: tidelink-awready-root-a2l-replay-no-timeout`). Discriminate against **H2**
(`swi_enable` level, kills all 5 FC channels) and against the FCSM-state-7 starvation angle.

**Status of this dir:** staged, isolated, untracked. NOTHING here has run on a board. Two gates
stand before it does: (1) the instrumented build completing + verified, (2) **David's explicit
authorization to deliberately wedge a board** (see §0). A general "run HW validation" directive
does NOT cover §0 — the induction blind-writes a standing forbidden address and bricks the die.

---

## 0. Authorization gate (David only — not a peer relay, not implied)

The induction step (`wedge_awready_deterministic.py`) blind-writes `ahb_tx = 0xA4000000` to outrun
credit. `0xA4000000` / `0x84030000` are the bare-link addresses the standing rule says NEVER touch,
*because* a blind write there wedges the PS. This tool does that **on purpose, once, for the
capture**, then recovers via JTAG-POR. Do not run §5 without David's explicit yes to this specific
board-brick. tidelink-63 concurs the authorization is David's alone and declined to nudge past it.

## 1. Prerequisites (all must be true before touching a board)

- [ ] Instrumented bitstream built + **timing met** + **probe list confirmed** (build agent report).
      Netlist line = `origin/main` (2c2f8d43) + cherry-picks `2ce60c2` (TL-037) + `be26f51` (N3).
- [ ] `.bin` (fresh `bit2bin_zynqmp.py`, no byte-swap) + `.ltx` (probes) in hand.
- [ ] Board lease held for the target die (`lease show` first; `lease acquire <board> --ttl N` as its
      OWN command; token-scoped release; never force-revoke a shared dam1n19 lease).
- [ ] `por_recover.sh` (JTAG-POR) staged + reachable (`pynq_host/scripts/weekend/por_recover.sh`).
      Confirm the fpgahub socket path / flock / MAX_POR on **mapstone-dev** (per-board endpoints 404
      from this host — `memory: fpgahub-perboard-endpoints-mapstone-dev`).
- [ ] David's §0 authorization recorded.

Boards: **kr260_01 @ 10.22.24.159**, **kr260_02 @ 10.22.24.153**. Wedge the die whose FC node we probe
(die_a). NEVER the two-board bare-link addresses outside this controlled induction.

## 2. Deploy the instrumented bitstream

```
# from mapstone-dev (per lease + kpor discipline):
~/bin/kpor kr260-01 --wait
make -C fpga deploy_kr260 TARGET=kr260-pair-onchip KR260_HOST=10.22.24.159   # instrumented .bin
```

## 3. Bring-up confirm (both dies healthy BEFORE inducing anything)

```
kr260_onchip_autonomy.py    # expect fcsm=4, cal=1, role_locked=1 on BOTH dies = pass
```
If either die isn't FCSM=4 / role_locked, STOP — a wedge capture off a bad link tells us nothing.

## 4. Arm the ILA (trigger FIRST, before induction)

**CORRECTION vs the original plan — it is ONE core, not two.** This repo's debug flow (as-built,
verified in the bitstream) instantiates a SINGLE ILA `u_dbg_int` on **hclk** (`clk_wiz_0_clk_out1`,
25.011 MHz), 4096-deep, **58 probe groups / 160 net-bits**, all 18 requested signals present on BOTH
dies (`tidelink_0`=die_a, `tidelink_1`=die_b), all DONT_TOUCH-pinned. The io_tx_clk-domain FCSM
signals (`state`, `send_ack/nack_req`, `auto_tx_out_advance`, `socl_l7_wdog*`, `curr_ch`) are sampled
**async on hclk** — which is fine here because we capture a FROZEN wedge (values are static once
awready is dead), NOT a live cross-domain transition. There is no Core 2 and no cross-trigger to set.
Configure at runtime (Vivado hw_manager / xsct):

- **Single trigger (hclk):** sustained `s_axi_awvalid & ~s_axi_awready`, or equivalently `a2l_full==1`
  held — the wedge signature. Trigger position ~1/4 for pre-wedge context; 4096-deep is the whole core.
- **Decode probes (all on this one core):** `a2l_full`, `fifo_io_wbin_ptr`[4] (a2l_app_addr),
  `link_addr_to_app_clk_r_addr`[4] (a2l_link_addr_app_clk), `ack_nack_fifo_io_rdata`[19] (link_ack_addr),
  `ack_nack_fifo_io_rempty`/`_io_wfull`, `isAckPacket`/`isNackPacket`/`crcCorruptSeen`, `swi_enable`,
  `enable_app_clk_demet_io_out`, `state`[3], `send_ack_req`/`send_nack_req`, `auto_tx_out_advance`,
  `curr_ch`[3], `socl_l7_wdog_cnt`[16]/`socl_l7_wdog_force_clear`.
- **BONUS probes that came along free:** 22 pre-existing `u_fc_adapter/dbg_tx_*` nets, incl.
  `dbg_tx_hreadyout`, `dbg_tx_hready`, `dbg_tx_a2l_valid` — the XHB500-side HREADYOUT-hang consequence
  ([[tidelink-d2d-wedge-xhb500-respfsm-hang]]); a bonus corroboration channel in the same capture.
- Vivado dbg_hub readback caveat: if probes read garbage, re-apply `PROBES.FILE` via
  `current_hw_device` (documented workaround; the real root was a stale ILA XDC stanza, since cleared).

**Build reproduction (if the bitstream is ever lost)** — beyond `make build_design TARGET=kr260-pair-onchip
FPGA_INSERT_DEBUG_CORE=1`, three env knobs were REQUIRED: `TIDELINK_PHY_V2=1` (else silent-V1 flist →
the local_overrides FCSM/FCReplay don't compile), `_BD_GLOBAL_SYNTH=1` (else the deep-in-IP nets stay
in the OOC checkpoint → ILA forms with 0 probes), `FPGA_ALLOW_CRITICAL_WARNINGS=1` (global synth emits
benign `[Synth 8-9873]` identical-module-overwrite CWs; this bypasses only the blanket CW-count gate —
the surgical silent-drop ERROR promotions and combinational-loop DRC still enforce).

## 5. Induce the wedge (deterministic, ATTENDED — needs §0)

On the target die (die_a), with the ILA armed and POR staged:
```
python3 wedge_awready_deterministic.py --count 64 --i-understand-this-bricks-the-board
```
Blind-sends 64 packets to `ahb_tx` with NO credit gating → outruns the peer's returned credit →
`a2l_fc_replay` fills → `s_axi_awready` low → Core-1 trigger fires → cross-triggers Core 2.
The script's own post-write credit readback wedging IS the PS-bus signature (it wraps that read).

## 6. Read out + decode

Upload the ILA core (all 160 net-bits, both dies). Decode (from the awready-root memory):

| Observation | Verdict |
|---|---|
| `a2l_full=1` + **frozen** `link_ack_addr` + **zero** ack/nack/crc traffic | **H1** — peer-ACK/credit silence fills the replay window |
| `swi_enable`/`enable` drop + all-5-FC-channels dead | **H2** — swi level |
| `state` stuck at `3'h7` + `auto_tx_out_advance` flat-0 | FCSM-starvation angle (same instance, answered same capture) |

Feed the raw core dumps to tidelink-63 for the H1/H2/neither adjudication (its layer).

## 7. Recover (mandatory — die is bricked until this runs)

```
# from mapstone-dev:
bash pynq_host/scripts/weekend/por_recover.sh <die_a target>   # JTAG-POR via fpgahub socket
kr260_onchip_autonomy.py                                       # confirm re-bringup: fcsm=4 both dies
```
Then token-scoped `lease release`. Leave both boards FCSM=4 / role_locked before ending.

---

## Method note (why deterministic, not the soak)

`kr260_recover_gate.py::induce_wedge()` is a bounded write **soak** (≤3000 beats) that WAITS for the
intermittent wedge and can return "no wedge" — a lottery, possibly several brick+POR cycles for one
usable capture. The deterministic blind-batch (this dir) is one attempt, one clean brick+POR cycle,
high confidence the trigger is in-window, and it exercises the credit/FC layer (H1) directly rather
than the XHB500/ahb_sub boundary the `errinject` tooling hits. tidelink-63 recommends deterministic.
