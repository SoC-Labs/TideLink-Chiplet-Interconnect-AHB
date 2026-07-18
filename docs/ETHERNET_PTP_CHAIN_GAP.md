# Ethernet / 1588 → PHC → TideLink PTP — Chain Gap Analysis

**Status date:** 2026-07-18
**Bench:** `cocotb/eth_ptp_chain/` (this work)
**Predecessor:** `cocotb/eth_tidelink_pair_shape_a/` (register visibility, PASSING)
**Architecture reference:** `docs/ETHERNET_CHIPLET_INTEGRATION.md` §6

---

## 0. Where we actually are

The intended architecture is: **the Ethernet/1588 chiplet is the grandmaster;
TideLink PTP propagates that time to the peer die.**

Shape-A proved *register reachability*: die_a can read MAC reset constants and
write/read back `HA1588.SCRATCH` across the chiplet link, through the ethernet
subsystem's own AHB matrix, with no full SoC. That is a bus path, not a clock.

This document restates the four named gaps with current evidence, records what
this work closed, and gives the exact remaining wiring at RTL/BD level.

| Gap | Before | Now |
|-----|--------|-----|
| **1. HA1588 timestamps a real event** | open — MAC datapath never exercised | **CLOSED at the capture step, in sim** (§1). Timestamp *value* read-back blocked by a located bus stall (§1.7) |
| **2. HA1588 → PHC servo hop** | open — "is `ethernet_ss_ahb_phc` the answer?" | **ANSWERED: no.** Three stacked blockers (§2) |
| **3. TideLink PTP TX not driven** | open | still open, but **smaller than believed** (§3) |
| **4. G1 election / sequencing** | open | unchanged; policy not RTL (§4) |

---

## 1. GAP 1 — HA1588 must timestamp a REAL event — **CLOSED IN SIM**

### 1.1 Why Shape-A could never have done this

Shape-A's own SIMPLIFICATION 2 tied `mrxd_i`/`mrxdv_i` to constant `0` and ran
`mtx_clk`/`mrx_clk` as two *independent* 25 MHz oscillators
(`cocotb/eth_tidelink_pair_shape_a/tb_top.sv:930-931, 1045-1047`). HA1588
timestamps MII frame events, so with a dead MII it could not capture — and
`SCRATCH` is a plain RW cell with no hardware side effects, so writing it proves
nothing about the timestamp path.

### 1.2 The minimum honest stimulus (answering the task's question directly)

**HA1588 has no software or register capture trigger.** The registers only
reset the queue, pop the queue, and set a message-ID mask. Specifically:

- Timestamp *sampling* trigger is `wire ts_req = int_gmii_ctrl;`
  (`/research/AAA/ip_library/OpenCores-HA1588/rtl/tsu/tsu.v:190`) — the rising
  edge of MII `tx_en`/`rx_dv`, i.e. **start of carrier, not SFD** (the RTL
  carries its own `// TODO: check frame start delimiter`).
- Queue *write* is `wire q_wr_en = ptp_found && int_eop_d1;` (`tsu.v:348`) — so
  an entry appears **only** for a genuine EtherType-`0x88F7` PTP frame that
  reaches end-of-packet.
- The nearest thing to a "direct trigger" is `RTC_CTRL[0]` TIME_RD, which
  latches RTC time into readable registers. That is **not** a TSU timestamp and
  would not have exercised the MII path.

So a real MII frame is required. That is what this bench drives.

> Note: the separate SoCLabs-written `ptp_event_detector`
> (`ethernet-mac-ahb/src/rtl/ptp_event_detector.v:22-28`) *does* do proper SFD
> detection and EtherType matching, but it is **independent of HA1588** and does
> not feed the TSU — it drives the external PHC. Relevant to Gap 2, not Gap 1.

### 1.3 What the bench does

`cocotb/eth_ptp_chain/tb_top.sv` adds an **MII external loopback** —
`mtxd_o/mtxen_o → mrxd_i/mrxdv_i` on one shared 25 MHz clock (a real loopback is
source-synchronous; driving `mrx_clk` from an independent oscillator, as Shape-A
did, would make it a CDC with no phase relationship). `mcrs_i` tracks the loop;
`mcoll_i` is tied 0 for full-duplex.

Everything else is driven **from die_a, across the link**:

```
die_a peer window -> [TideLink] -> die_b ahb_mng -> eth_ss_0 -> subsystem matrix
   |
   +- zero-init HA1588 regs 0x00..0x7C     (PRECONDITION: reg.v has NO reset)
   +- RTC period + PERIOD_LD               (else timestamps read back zero)
   +- TSU msgid mask + queue reset         (mask defaults 0 => never captures)
   +- program MAC (addr/IPG/PACKETLEN/BDs)
   +- stage a real L2 PTP Sync frame into eth_scratch_tx (0x3800_0000)
   +- arm TX BD, set MODER.TXEN
                    |
                    v
      MAC's OWN DMA master reads the frame out of eth_scratch_tx
      real MII TX FSM -> [LOOPBACK] -> real MII RX FSM
                    |
              HA1588 TSU captures
                    |
      die_a reads the timestamp back ACROSS THE LINK   <-- the demo result
```

The `ethmac_0_dma` initiator can reach `eth_scratch_tx_0`/`eth_scratch_rx_0`, and
so can `eth_ss_0` — that overlap
(`ethernet-subsystem-ahb/build_soc/reports/ethernet_ss_ahb_memory_map.txt`) is
what lets die_a stage a frame the far MAC will DMA out. No CPU involvement: the
Cortex-M0+ stays parked on the spin image.

### 1.4 Four non-obvious preconditions (each cost real debugging)

1. **The HA1588 register file has NO RESET.** `reg.v` declares the registers
   with no reset clause ⇒ *every* HA1588 register is X at power-up, not just
   `SCRATCH`. The block's own TB zero-initialises 0x00..0x7C before anything
   else (`ethernet-mac-ahb/cocotb/ha1588_ahb/test_ha1588_ahb.py:154-155`). Any
   bench skipping this is reading and writing X-valued control state.
2. **`ptp_msgid_mask` defaults to 0** ⇒ nothing is ever queued until software
   writes `TSU_RXSTAT/TXSTAT[31:24]` (`ptp_parser.v:184-189`). Bit0 = Sync.
3. **The frame must be genuinely PTP** (EtherType `0x88F7`, enabled
   messageType) and must reach EOP (`tsu.v:348`).
4. **The RTC must be ticking** or a capture reads back all-zero — a false
   negative that looks like a capture failure.

### 1.5 Result — and the instrument that saved the investigation

Per `MEMORY.md`'s standing rule (*verify the INSTRUMENT before theorizing about
the DUT*), the tb records the bytes physically on the MII wire before any
register is believed. That paid off on run 1:

```
[chain] MII wire bytes: 55 55 55 55 55 55 55 d5 | 00 19 1b 01 1a 00 | ...
[chain] wire frame starts at byte 8: EtherType=0x0200 NOT PTP
[chain] HA1588 TX TSU depth = 0
[chain] HA1588 RX TSU depth = 0
```

Staged word0 was `0x011b1900`; the wire carried `00 19 1b 01`. **Every DMA word
came out byte-reversed** — the OpenCores MAC emits the *least* significant byte
of each 32-bit DMA word first. The EtherType landed as `0x0200`, HA1588's parser
correctly refused to match, and both queues stayed at depth 0.

That was a **true negative, not a broken capture**. Without the wire recorder, a
silent `depth = 0` is indistinguishable from "HA1588 cannot timestamp" and would
have sent the investigation after the timestamp unit instead of the byte order.
Fix: `BIG_ENDIAN_DMA_WORDS = False` in `test_ptp_chain.py` (one line).

With the byte order corrected, the same bench produced:

```
[chain] MII wire bytes: 55 55 55 55 55 55 55 d5 01 1b 19 00 00 00 00 1a 2b 3c 4d 5e 88 f7 ...
[chain] wire frame starts at byte 8: DA=01 1b 19 00 00 00  SA=00 1a 2b 3c 4d 5e
        EtherType=0x88f7 == PTP (0x88f7) OK
[chain] HA1588 TX TSU depth = 1  <-- A TIMESTAMP WAS CAPTURED
[chain]   TX.DATA3(pre-pop) @0x4000107c = 0x032a0042
```

`DATA3` is `ptp_infor = {msg_id[31:28], cksum[27:16], seq_id[15:0]}` (`tsu.v:349`):

| field | value | meaning |
|-------|-------|---------|
| `msg_id` | `0x0` | messageType = **Sync** |
| `cksum`  | `0x32a` | parser checksum |
| `seq_id` | **`0x0042`** | **exactly the sequenceId die_a staged** |

A TSU entry can only exist via `ptp_found && eop` (`tsu.v:348`), so `depth = 1`
is proof HA1588's own parser matched a genuine PTP frame and the hardware
enqueued a timestamp for it. The identity fields matching what die_a itself
staged proves the far die timestamped **our** frame — and die_a read that back
**across the link**.

**Both TSUs captured** — TX *and* RX, `depth = 1` each, identical
`d3 = 0x032a0042`. The RX capture is the stronger of the two: it can only occur
if the frame completed the loopback and was re-parsed by the real MII **RX** FSM,
which confirms the whole datapath — not just the transmit half — is live.

**GAP 1 IS CLOSED AT THE CAPTURE STEP.** Final run: `TESTS=1 PASS=1 FAIL=0`.

### 1.7 What is NOT closed — the queue-pop stalls the cross-link read

The 80-bit timestamp **value** (`DATA0..DATA2`) is loaded into the readable
registers by the queue-pop (`CTRL` bit0). Pre-pop those words read `0`. And the
pop itself **wedges the cross-link read**:

```
[chain] TX: issuing queue pop (CTRL bit0), then re-reading
[chain]   TX.DATA0(post-pop) @0x40001070 STALLED (no HREADY within 8000 cycles)
[chain]   TX.DATA1(post-pop) @0x40001074 STALLED (no HREADY within 8000 cycles)
```

On the first attempt a single such read consumed the **entire 60000-cycle**
harness timeout — a genuine bus hang, not an impatient timeout. `POP_TSU_QUEUE`
in `test_ptp_chain.py` reproduces it; it is `False` by default so the bench is
deterministic.

**This bench therefore does NOT claim the timestamp value was read.** The claim
is bounded at: capture occurred, and its PTP identity crossed the link.

> **A hypothesis I checked and REFUTED, recorded so nobody re-chases it.**
> HA1588's upstream register file has no resets, and a patched copy exists at
> `ethernet-mac-ahb/src/rtl/ha1588_patches/reg.v` whose header says it adds
> resets to "all edge-detector pipeline regs" — precisely the `txqu_rd_d2..d5`
> flops behind the pop. X-propagation from those looked like an excellent
> explanation for the stall. **It is wrong for this build:** the expanded flist
> actually compiled (`sim_build_zero/eth_expanded.flist:42-47`) uses the
> *fully* patched set — `rtc.v`, `ptp_parser.v`, `ptp_queue.v`, `reg.v`,
> `ha1588.v` all from `ha1588_patches/`. The stall has another cause; the pop's
> WISHBONE ack path (`reg.v:394-406`, `tx_q_rd_ack = txqu_rd_d4 && !txqu_rd_d5`)
> through `wb_slv_wrapper` → `ahb3lite_to_wb` is the place to look next.
> Estimated: **0.5–1 d** to localise with a waveform on `u_ethmac_0`.

> **Separate real finding, worth fixing anyway.** The *standalone* HA1588 flist
> `ethernet-mac-ahb/flist/ha1588_ahb.flist:5-9` is only **1/4 patched**: it
> takes `ptp_queue.v` from `ha1588_patches/` but `rtc.v`, `reg.v` and
> `ha1588.v` from the unpatched upstream IP — so the block-level bench runs
> against a reset-less register file while the subsystem bench does not. That
> divergence is a trap for anyone comparing the two. **0.5 h** to align.

**Transcripts are in `cocotb/eth_ptp_chain/TRANSCRIPT.md`.**

### 1.6 Honest scope limits

- **This is a loopback, not a wire.** HA1588 timestamps a frame this same MAC
  transmitted. It exercises the real MII timestamp path, the real TX/RX FSMs and
  the real parser, but it is not an independent time source — it cannot detect a
  systematic offset common to both directions. `docs/ETHERNET_CHIPLET_INTEGRATION.md`
  §9 risk 3 already flags this; M2 (physical PHY) remains the real 1588 proof.
- **Capture is on carrier rise, not SFD** (`tsu.v:190`), so the timestamp
  includes preamble time. Fine for a demo, wrong for a conformance claim.
- Only die_b carries the ethernet subsystem; die_a is the initiator.

---

## 2. GAP 2 — the HA1588 → PHC servo hop — **ANSWERED: `ethernet_ss_ahb_phc` does NOT close it**

The task asked whether the PHC variant closes this hop. It does not. It is a
structurally complete but **functionally hollow** integration, and it has never
been simulated — there is **no testbench, cocotb suite, or sim target for
`ethernet_ss_ahb_phc` anywhere**, which is why none of the below has surfaced.

### 2.1 Blocker A — the generated top cannot even bind to the PHC RTL

`build_soc_phc/rtl/ethernet_ss_ahb_phc.sv:549-594` instantiates:

```verilog
phc_ahb #( ... ) u_phc_0 (
    .HCLK(...), .HRESETn(...), .HSEL(...), .HADDR(...),
    .HBURST(...), .HPROT(...), .HMASTLOCK(...), ...
```

but the PHC declares (`ptp-hardware-clock-ahb/src/rtl/phc_ahb.sv:22,30-45`):

```verilog
module PHC_AHB #( ... )(
    input wire hclk, hresetn,
    input wire ahbs_hsel, ahbs_hready, ...
```

Three independent problems: **module name case** (`phc_ahb` vs `PHC_AHB`),
**port naming** (`HSEL` vs `ahbs_hsel`), and **three ports that do not exist on
the PHC at all** (`HBURST`, `HPROT`, `HMASTLOCK`). Also `ahbs_haddr` is
`[APB_ADDR_W-1:0]` (12 bits) while the interconnect drives 32
(`eth_ss_interconnect.sv:195`). *Verified directly, not just via report.*

### 2.2 Blocker B — servo source 1 is tied off

Only the 1PPS pulse reaches the PHC. Every value and adjustment path is hard-tied
to zero (`sys_desc/ethernet_ss_ahb_phc.yaml:407-419`, verbatim in generated RTL
`build_soc_phc/rtl/ethernet_ss_ahb_phc.sv:578-590`):

```yaml
- { port: hw_capture_1,   conn: rtc_time_one_pps }   # the ONLY live connection
- { port: hw_set_time_1,  conn: 1'b0 }               # "future: expose from MAC"
- { port: hw_set_seconds_1,     conn: 48'h0 }
- { port: hw_adj_valid_1,       conn: 1'b0 }
- { port: hw_adj_ns_incr_frac_1, conn: 32'h0 }
- { port: servo_locked,   conn: 1'b0 }
- { port: eth_rx_capture, conn: 1'b0 }               # despite the MAC exporting it
```

Consequence: setting `SERVO_CTRL.SRC_SEL=1` selects a source that **can never set
time or adjust frequency**. The clock free-runs; only snapshot-on-1PPS works.

Critically, **both sides of this wire already exist and are simply not joined**:
`u_ha1588_servo` *is* instantiated (`ethmac_subsystem_apb.v:615-649`) and its
outputs *are* plumbed to the AHB wrapper's top-level ports
(`ethmac_subsystem_ahb.v:101-113`) — but the PHC variant's `u_ethmac_0`
connection list (`ethernet_ss_ahb_phc.yaml:263-294`) **omits every one of them**.

> Ironic finding: the **non-PHC** `ethernet_ss_ahb_m0.yaml:214-228` exposes the
> *complete* servo interface as top-level ports. **The base subsystem is better
> prepared for an external PHC than the PHC variant is.**

### 2.3 Blocker C — the PHC cannot export what the HA1588 servo needs

Even with A and B fixed, the loop will not close:

- `PHC_AHB` does not export `ha1588_servo_en` or `sync_interval`
  (`phc_ahb.sv:30-97`), so `SERVO_CTRL.HA1588_SERVO_EN` and `SYNC_INTERVAL` are
  trapped inside `phc.sv` and can never reach `ha1588_servo.enable/.sync_interval`.
- `sys_desc/phc_ahb.yaml:89-91` declares `seconds_o`/`nanoseconds_o`/
  `sub_nanoseconds_o` live-time outputs "for external HA1588-style hardware
  servos". **These do not exist in the RTL** — neither `PHC_AHB` nor `phc`
  declares them. But `ha1588_servo.sv:43-44` *requires* `phc_seconds`/
  `phc_nanoseconds` for its interval timer. The YAML descriptor is ahead of the
  RTL.

Corroboration: even the closest existing TB ties them off —
`ethernet-mac-ahb/cocotb/ethmac_phc_sync/tb_top.sv:115-116` has
`wire [47:0] phc_seconds = 48'b0;`.

### 2.4 CDC hazard worth flagging

HA1588 lives in `rtc_clk`; the PHC runs on `SYS_HCLK`. The only crossing today is
raw `rtc_time_one_pps` fed straight into `hw_capture_1` with **no synchroniser**
(`ethernet_ss_ahb_phc.yaml:393-394, 407`). `ha1588_servo.sv:76-120` implements a
proper toggle-handshake CDC for exactly this — and is bypassed.

### 2.5 The wiring plan

The correct connectivity already exists as a **proven precedent** in
`ethernet-mac-ahb/cocotb/ethmac_phc_sync/tb_top.sv:195-285`. Reproduce it:

```
  ethmac_subsystem_ahb (die_b)                         phc / PHC_AHB
  ─────────────────────────────                        ─────────────
  ha1588_hw_capture              ──────────────────►  hw_capture_1_i
  ha1588_hw_set_time             ──────────────────►  hw_set_time_1_i
  ha1588_hw_set_seconds   [47:0] ──────────────────►  hw_set_seconds_1_i
  ha1588_hw_set_nanoseconds[29:0]──────────────────►  hw_set_nanoseconds_1_i
  ha1588_hw_adj_valid            ──────────────────►  hw_adj_valid_1_i
  ha1588_hw_adj_ns_incr_frac[31:0]─────────────────►  hw_adj_ns_incr_frac_1_i
  ha1588_servo_locked            ──────────────────►  servo_locked_i          (*)
  ha1588_servo_phase_step_active ──────────────────►  servo_phase_step_active_i (*)
  rx_ptp_event / tx_ptp_event    ──────────────────►  eth_rx_capture / eth_tx_capture
                                 ◄──────────────────  hw_cap_seconds_1_o      -> phc_hw_cap_seconds
                                 ◄──────────────────  hw_cap_nanoseconds_1_o  -> phc_hw_cap_nanoseconds
                                 ◄──────────────────  hw_cap_sub_nanoseconds_1_o
  ha1588_servo_en   ◄───────────────────────────────  SERVO_CTRL.HA1588_SERVO_EN (**)
  ha1588_sync_interval[29:0] ◄──────────────────────  SYNC_INTERVAL              (**)
  phc_seconds[47:0] / phc_nanoseconds[29:0] ◄───────  live time                  (**)

  (*)  blocked: discarded one level down at ethmac_subsystem_ahb.v:239-240 -> `( )`
  (**) blocked: ports do not exist on PHC_AHB/phc  (Blocker C)
```

And symmetrically, TideLink is **servo source 0** — `tidelink_top`'s `phc_*` port
set (`src/rtl/tidelink_top.sv:306-329`) is **the same interface shape** as
`ethmac_subsystem_ahb`'s `ha1588_*` set (`ethmac_subsystem_ahb.v:101-113`):
`hw_capture` out; `phc_seconds/nanoseconds` + `phc_hw_cap_*` in;
`hw_set_time/seconds/nanoseconds` + `hw_adj_valid/ns_incr_frac` out. This is a
**designed-in symmetric 2-source servo pair**, and it is the strongest evidence
that the intended architecture is coherent — the two consumers were built to the
same contract. Source select is `servo_src_sel` (`phc.sv:169-186`) from
`SERVO_CTRL` bit 0 @ `0x0A0` (`phc_apb_regs.sv:293`, `src/rdl/phc_apb_regs.rdl:387`).

---

## 3. GAP 3 — TideLink PTP TX is not driven

**Smaller than the recon implied.** The PTP block is *not* stubbed: `STUB_PTP`
and `STUB_SERVO` both default to `1'b0` (`src/rtl/tidelink_top.sv:104,106`), so
the real `tidelink_ptp` + `tidelink_ptp_servo` are instantiated in every build
including the Shape-A/chain benches (`:1601 gen_ptp_real`).

What is missing is purely **tb/BD-level tie-off**, on both dies:

- `ahb_ptp_*` slave port driven idle — `cocotb/eth_ptp_chain/tb_top.sv:561-570`
  (die_a) and `:775-784` (die_b): `ahb_ptp_hsel = 1'b0`, `haddr = 4'h0`, rdata
  unused.
- `phc_*` tied to constants — same file `:550-576` and `:765-790`:
  `phc_nanoseconds = 30'h0`, `phc_seconds = 48'h0`, `phc_hw_cap_* = 0`,
  `phc_locked_i = 1'b1`, all outputs unconnected.

So Gap 3 is "connect an AHB master to `ahb_ptp` and join `phc_*` to a real PHC
instance", not "implement PTP TX". Note `phc_locked_i` is currently forced `1`,
which bypasses `PHC_LOCK_GATE_EN` — acceptable while there is no PHC, but it must
not survive into a build that has one.

---

## 4. GAP 4 — G1 election / sequencing

Unchanged by this work, and **not an RTL gap**:
`docs/ETHERNET_CHIPLET_INTEGRATION.md:375-380` records that `link_active`
precedes data-mode, so grandmaster role must be **pinned by strap**, not
auto-elected, until resolved. Contract: `docs/TIDECHART_G1_SEQUENCING_CONTRACT.md`.
For a demo this is a precondition (pin die_b = grandmaster), not a blocker.

Adjacent, and worth not forgetting: `apb_debug_unlock_i`/`mask_hs_bypass_i` are
tied `1'b1` in silicon (MEMORY.md), so APB debug is permanently unlocked — a
strap wanted before tapeout, independent of PTP.

---

## 5. Remaining work and effort estimate

| # | Item | Where | Est. |
|---|------|-------|------|
| 1 | Fix PHC instantiation: module name case, `ahbs_*` port names, drop `HBURST`/`HPROT`/`HMASTLOCK`, truncate `haddr` to `APB_ADDR_W` | `sys_desc/ethernet_ss_ahb_phc.yaml` (generator source) + regenerate `build_soc_phc/` | **0.5 d** |
| 2 | Wire HA1588 servo → PHC source 1 (the 8 signals in §2.5) | `ethernet_ss_ahb_phc.yaml:263-294` (`u_ethmac_0` conn list) + `:407-419` (PHC conn list) | **0.5 d** |
| 3 | Stop discarding `ha1588_servo_locked` / `phase_step_active` | `ethmac_subsystem_ahb.v:239-240` | **0.5 h** |
| 4 | Add `seconds_o`/`nanoseconds_o`/`sub_nanoseconds_o` + `ha1588_servo_en`/`sync_interval` exports to `phc`/`PHC_AHB` (YAML already specifies them; RTL does not implement) | `ptp-hardware-clock-ahb/src/rtl/phc.sv`, `phc_ahb.sv` | **1–2 d** |
| 5 | Synchronise `rtc_time_one_pps` into `SYS_HCLK` (or route via `ha1588_servo`'s existing handshake) | PHC variant top | **0.5 d** |
| 6 | First-ever subsystem-level sim for `ethernet_ss_ahb_phc` | new cocotb dir; model on `ethmac_phc_sync/tb_top.sv` | **1 d** |
| 7 | Extend `eth_ptp_chain` to instantiate a PHC on die_b and drive TideLink `ahb_ptp` + `phc_*` | `cocotb/eth_ptp_chain/tb_top.sv` | **1–2 d** |
| 8 | Pin grandmaster by strap (G1) | config/firmware | **0.5 d** |
| 9 | Localise the TSU queue-pop bus stall (§1.7) — waveform on `u_ethmac_0`, `reg.v:394-406` ack path through `wb_slv_wrapper`/`ahb3lite_to_wb` | `ethernet-mac-ahb` | **0.5–1 d** |
| 10 | Align `flist/ha1588_ahb.flist` to the fully-patched HA1588 set (§1.7) | `ethernet-mac-ahb/flist/ha1588_ahb.flist:5-9` | **0.5 h** |

**Distance to demo:** items 1–3 + 6 (~2.5 d) yield *PHC snapshots disciplined by
HA1588 captures* — enough for a visible grandmaster→PHC hop. A genuinely
**closed** servo loop additionally needs item 4 (~1–2 d), which is real RTL work
in the PHC IP, not integration. Item 7 then joins TideLink as source 0. Call it
**~4–6 engineering days to a sim-complete chain**, plus M2 (physical PHY) before
any 1588 *conformance* claim.

---

## 6. Files

| Path | Role |
|------|------|
| `cocotb/eth_ptp_chain/tb_top.sv` | MII loopback + wire recorder + RTC witness |
| `cocotb/eth_ptp_chain/test_ptp_chain.py` | the chain test (Gap 1) |
| `cocotb/eth_ptp_chain/test_smoke_mii_loop.py` | elaboration smoke |
| `cocotb/eth_ptp_chain/eth_pair_common.py` | HA1588 TSU + MAC TX register map |
| `cocotb/eth_ptp_chain/TRANSCRIPT.md` | measured transcripts, both runs |

Nothing outside `cocotb/eth_ptp_chain/` and this file was modified. No commits.
`/research/AAA/**` was read via flist reference only.
