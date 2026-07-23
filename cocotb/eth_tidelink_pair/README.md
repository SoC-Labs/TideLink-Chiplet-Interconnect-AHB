# eth_tidelink_pair — Ethernet-over-TideLink M0 integration smoke

**First-ever co-simulation of a real ethernet-subsystem component behind a
TideLink die-to-die pair.** This bench closes milestone **M0** of
`docs/ETHERNET_CHIPLET_INTEGRATION.md`: prove *in simulation* that an AHB write
entering die_a's TideLink peer aperture crosses the link and lands, byte-exact,
in an **ethernet-subsystem memory** attached behind die_b's `ahb_mng` port — the
frame-relay datapath's skeleton.

Scope discipline: this is a **smoke**, not the full frame relay. No MAC, no
HA1588, no PicoTCP, no PHY. The point is a *real component from the ethernet
repos* receiving link-crossed AHB writes.

## What it is

`tb_top.sv` is a **fork of `cocotb/tidelink_top_pair_v2/tb_top.sv`** (the proven
two-die V2 pair: two cross-wired `tidelink_top` dies with GPIO-PHY skew
injection, a per-die APB config port, and the master's `ahb_sub` peer window
exposed to cocotb). Instance names (`u_master` / `u_slave`) and `m_`/`s_` signal
names are kept **verbatim** so the pair_v2 Python harness imports unchanged.

**The one change vs the pair_v2 harness:** each die's `ahb_mng` terminus is no
longer the throwaway `tb_ahb_bram_slave` scratch BRAM — it is a **real
ethernet-subsystem memory**:

| Attach target | `nanosoc_region_sram` |
|---|---|
| What it is | The exact module the ethernet subsystem instantiates as `u_region_eth_scratch_rx_0` / `_tx_0` in `nanoSoC-refactor/ethernet-subsystem-ahb/build_soc/rtl/ethernet_ss_ahb.sv` |
| Composition | `nanosoc_region_sram` → `sl_ahb_sram` → `cmsdk_ahb_to_sram` + `cmsdk_fpga_sram` (byte-lane behavioural BRAM) |
| Author | SoC Labs (David Mapstone), `ethernet-subsystem-ahb` repo |
| Sizing | `RAM_ADDR_W=14` → 16 KB (matches the eth scratch default) |
| Timing | zero-wait AHB-Lite slave: `cmsdk_ahb_to_sram` drives `HREADYOUT=1'b1` / `HRESP=1'b0` constant — identical to the reference BRAM terminus, so the `hready<->hresp` comb-loop caveat (arch §3d) does not arise |

### Why this attach shape (justification)

The architecture doc (§3) offers **Shape A** (`ahb_mng → d2d_ahb_s → full
multicore SoC matrix`) and **Shape B** (`ahb_mng → ethernet subsystem alone`).
The scaffold notes (§3, §5) recommend Shape B for the first sim, and explicitly
permit going one level narrower: *"it is ACCEPTABLE AND HONEST to instantiate
only the subsystem's eth scratch SRAM block … as the attach target."* That is
exactly what this bench does, and here is the trade that makes it the right M0
call:

- **It is a real ethernet component, not a stub.** `nanosoc_region_sram` is the
  literal RTL the subsystem uses for `eth_scratch_rx`/`eth_scratch_tx` — the
  memory a relayed frame is *supposed* to land in per §5 M1a.
- **Minimal, honest compile set.** Its only two cmsdk dependencies
  (`cmsdk_ahb_to_sram`, `cmsdk_fpga_sram`) are *already* compiled by
  `flists/tidelink_fpga_v2.flist`, so the only NEW RTL is the two SoC Labs
  wrapper files (`nanosoc_region_sram.v`, `sl_ahb_sram.v`). No OpenCores MAC, no
  HA1588, no 4-clock-domain subsystem, no M0+ core, no bootrom — none of which
  M0 needs, and all of which would turn a 20-second smoke into a heavy build.
- **The full subsystem (`ethernet_ss_ahb` via `eth_ss_0`) and Shape A are
  deferred to M1** on purpose (see "Next steps").

### The datapath under test

```
die_a peer window (m_ahb_sub) WRITE @ 0x4000_0000 + off
  -> XHB500 AHB->AXI -> master chiplet controller s_axi (Wlink AXI target)
  -> FC aw/w/b channels -> chiplet GPIO-PHY link -> die_b
  -> die_b XHB500 AXI->AHB -> die_b ahb_mng
  -> nanosoc_region_sram (u_s_eth_scratch)  [ETHERNET-SUBSYSTEM SCRATCH RAM]
READ-back @ the same addresses -> byte-exact  (+ hierarchical BRAM peek)
```

Both dies present an eth-scratch to the far die (symmetric). M0 exercises
**die_a → die_b**; the master-side terminus is the B→A path, idle here, ready
for a future bidirectional test.

## Files

| File | Purpose |
|---|---|
| `tb_top.sv` | top: V2 pair + eth-scratch `ahb_mng` termini (fork of `tidelink_top_pair_v2/tb_top.sv`) |
| `pad_skid.sv`, `eye_fault.sv` | harness cells, copied verbatim from the pair_v2 bench |
| `test_eth_relay_smoke.py` | the smoke test |
| `eth_pair_common.py` | frame builder + eth-scratch hierarchical peek; re-exports `PairV2TB`/`run_bringup_full`/`AHBSubMaster` from the pair_v2 bench |
| `Makefile` | VCS + cocotb; V2 flist + the two SoC Labs eth-scratch RTL files |
| `README.md` | this file |

Reused **read-only** from the pair_v2 bench (via `PYTHONPATH`): `pair_v2_common`
(`PairV2TB` bring-up + APB/AHB helpers) and `test_v2_xhb_window` (`AHBSubMaster`,
the peer-window AHB-Lite driver). The ethernet RTL is compiled directly from
`nanoSoC-refactor/ethernet-subsystem-ahb` (read-only reference; nothing there is
modified).

## Run

```bash
cd cocotb/eth_tidelink_pair
source ../../set_env.sh
export TIDELINK_PHY_V2=1
make                        # EPOCH_PROFILE=zero (clean skew) -> PASS. THE M0 GATE.
make EPOCH_PROFILE=silicon  # v37 skew fingerprint -> stalls (see "silicon" gap below)
```

Simulator = VCS (same as the pair bench). Always a V2 build (`TIDELINK_PHY_V2`
rides in `flists/tidelink_fpga_v2.flist`). The test reuses the pair_v2
`force_calibrator_sim_bypass()` bring-up convention.

## What is proven (result: **PASS 1/1**, 16/16 words byte-exact)

The test brings the V2 pair link up (POR → role-lock → passive autocal → data
mode → bilateral CR/CRACK), then relays a 16-word (64 B, minimum ethernet frame)
burst from die_a's peer window into die_b's ethernet-scratch RAM and checks
byte-exactness two independent ways: a **round-trip read** back through the peer
window, and a **hierarchical peek** straight into the eth-scratch `cmsdk_fpga_sram`
byte-lane BRAMs.

### Transcript tail (`make EPOCH_PROFILE=zero`)

```
[tb_top] EPOCH_ANCHOR_EN: master=1 slave=1 (deskew: m=0 s=0)
  10720ns  post-autocal: M=0x440300ff S=0x440300ff cal M=DONE S=DONE
 113040ns  [after to_data_mode] M: cal_done=1 cal=DONE fcsm=4 cr=1 crack=1
 113040ns  [after to_data_mode] S: cal_done=1 cal=DONE fcsm=4 cr=1 crack=1
 137040ns  [eth-relay] link up (cal+CR/CRACK); starting frame relay
 218920ns  [eth-relay] wrote 16-word frame to peer window 0x40000040+
 383900ns  [eth-relay] w 0 addr=0x40000040 sent=0xffffffff read=0xffffffff eth_scratch[16]=0xffffffff
 388900ns  [eth-relay] w 1 addr=0x40000044 sent=0xffff0200 read=0xffff0200 eth_scratch[17]=0xffff0200
 393880ns  [eth-relay] w 2 addr=0x40000048 sent=0x00000001 read=0x00000001 eth_scratch[18]=0x00000001
 398880ns  [eth-relay] w 3 addr=0x4000004c sent=0x08060001 read=0x08060001 eth_scratch[19]=0x08060001
   ...      (w4..w14 — checkerboard payload, all byte-exact) ...
 458780ns  [eth-relay] w15 addr=0x4000007c sent=0xf6f6f6f6 read=0xf6f6f6f6 eth_scratch[31]=0xf6f6f6f6
 458780ns  [eth-relay] PASS: 16/16-word frame relayed die_a peer window -> link -> die_b ethernet-scratch RAM, byte-exact (round-trip + hierarchical peek).
 ** TEST test_eth_relay_smoke.test_eth_relay_smoke   PASS      458780.00 ns   10.69 s **
 ** TESTS=1 PASS=1 FAIL=0 SKIP=0 **
```

Note the two independent checks agree on every word: `read=` is the peer-window
round-trip (die_a reads back across the link), `eth_scratch[N]=` is the direct
hierarchical peek into die_b's `cmsdk_fpga_sram` byte-lane BRAMs — so the frame
provably *landed in the ethernet component*, it is not a bus echo. (`eth_scratch`
word index = `(0x40 + i*4) >> 2` = 16 + i, since the terminus decodes
`HADDR[13:2]` and ignores the `0x4000_0000` aperture bits.)

Claims:

1. **(a) Elaborate/compile** — the combined stack (TideLink V2 pair + two
   ethernet-subsystem `nanosoc_region_sram` termini) compiles and runs under
   VCS. `tidelink_top`'s `ahb_mng` port surface drives a real ethernet-subsystem
   AHB slave with **no glue** beyond the documented HPROT-width truncation
   (`hprot[6:0]` → `HPROT[3:0]`) and a tied-high `HSEL` (dedicated single-slave
   terminus). No new CDC (the `ahb_mng ↔ eth-scratch` handoff is entirely in the
   `hclk` domain — arch §3c).
2. **(b) Link still comes up with the eth-scratch attached** — the eth memory on
   the datapath does not perturb bring-up; cal + CR/CRACK reach the same state as
   the pair_v2 reference.
3. **(c) A frame crosses the link into a real ethernet component** — the 16-word
   frame written into die_a's peer window is read back byte-exact from die_b's
   ethernet-scratch RAM, confirmed both by the peer-window round-trip and by the
   direct BRAM peek. This is the M0 gate: *an AHB write entering die_a's peer
   aperture lands in an ethernet-subsystem memory behind die_b's ahb_mng.*

### Documented gap: the `silicon` skew profile stalls the peer-window return path (NOT the eth attach)

`make EPOCH_PROFILE=silicon` (the v37 fingerprint: scattered 3..7-word epoch skew
on the master's RX, i.e. the S→M direction) **fails**: the link still brings up
clean (`cal=DONE`, `cr=1`, `crack=1` both dies), but the very first peer-window
write's completion times out — `ahb_sub WRITE 0x40000040 did not complete`. The
forward M→S path into die_b's eth-scratch is unaffected; what stalls is the
write's **B-response returning die_b→die_a over the deliberately-skewed S→M
lanes**, which the EPOCH anchor does not recover for the AXI-FC round-trip here.

**This is a pre-existing peer-window / PHY-layer limitation, independent of the
ethernet attach.** Proof: the *unmodified* pair_v2 reference
`test_v2_xhb_window` fails **identically** under the same profile —
`ahb_sub WRITE 0x40000000 did not complete`, same timeout, same sim time
(1337080 ns). The eth bench inherits the reference's behaviour bit-for-bit
(passes on `zero`, stalls on `silicon`); swapping the BRAM terminus for the
eth-scratch RAM adds **no new failure mode**. Recovering the AXI-FC peer-window
round-trip under the S→M silicon fingerprint is PHY/harness work (the pair_v2
lane's domain), not an M0-eth blocker. The M0 gate is therefore `EPOCH_PROFILE=
zero`, which passes.

## Gaps / honest scope limits (what M0 does NOT prove)

- **Memory only, not the subsystem.** The terminus is the eth-scratch *RAM
  primitive*, not `ethernet_ss_ahb` with its bus matrix, MAC, HA1588, and 4
  clock domains. So M0 does **not** surface the AHB-matrix `hready`/burst
  semantics or the 32/32 `eth_ss_0` slave-port contract that arch §3b/§9 flag as
  the real integration risks. Those are **M0.5/M1** work (attach `ethernet_ss_ahb`
  via `eth_ss_0`, or the full SoC via `d2d_ahb_s`).
- **Single-word (non-burst) accesses.** `AHBSubMaster` drives single-beat NONSEQ
  transfers; the frame is 16 separate word writes, not an AHB burst. `ahb_mng`
  carries `hburst` but the eth-scratch terminus (like the historic BRAM) does
  not exercise bursts. Burst relay is an M1 item.
- **Identity address translation.** `tl_addr_trans_cam` is at reset
  (global_enable=0), so the peer offset reaches `ahb_mng` unchanged and the
  eth-scratch decodes `HADDR[13:2]`. A non-identity CAM mapping (far-die address
  remap) is untested here.
- **No frame semantics.** The "frame" is byte-exactness stimulus; nothing parses
  it as ethernet. No MAC RX ring descriptors, no `eth_irq`, no PicoTCP.
- **One direction.** Only die_a → die_b is exercised; the symmetric B→A terminus
  is wired but idle.

## M1 implications / next steps

1. **Swap the terminus RAM for `ethernet_ss_ahb` via `eth_ss_0`** (Shape B
   proper) — this is the smallest step that surfaces the real matrix `hready`,
   burst, and `hprot[3:0]` contract (arch §3b, RISK 1/§9). Keep this bench as the
   fast regression; add a heavier `*_ss_pair` bench for the subsystem.
2. **Then Shape A** (`ahb_mng → d2d_ahb_s → full multicore SoC matrix`), matching
   `nanosoc_eth_chiplet.sv`, so the far die reaches eth scratch **and** MAC BDs
   **and** the HA1588/PHC registers — the substrate for §5 M1a (relay a frame
   into the far MAC RX ring) and §6 (PTP grandmaster chain).
3. **Bursts + non-identity CAM** to relay a whole frame in one AHB burst and to
   let die_a address a specific far-die scratch/BD region.
4. **Wire into `make sim_gate`** *after* it passes standalone (do not
   co-schedule with a Vivado build). Per the lane boundaries, that
   `Makefile`/`hw_regression` edit belongs to another lane — W4 hands off the
   "add to sim_gate" step rather than editing those files.

## Provenance / rules honoured

- **W4 footprint = this new `cocotb/` dir only.** No `targets/`, root `Makefile`,
  `hw_regression/`, `pynq_host/`, or RTL edits. The ethernet repos and the
  pair_v2 bench are read-only references.
- **No `/research/AAA/**` writes.** The OpenCores MAC/HA1588 are not compiled by
  this smoke; the cmsdk models are read via the flist (`$CMSDK_DIR`), never
  modified.
- Not committed (per the lane brief).
