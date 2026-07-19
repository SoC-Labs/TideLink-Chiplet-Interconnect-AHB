# eth_tidelink_pair_m1 — Ethernet-over-TideLink M1 (real subsystem via `eth_ss_0`)

**First co-simulation of the WHOLE `ethernet_ss_ahb` subsystem behind a TideLink
die-to-die pair.** This bench takes the M0 milestone one concrete step further
(the M1 first substep of `docs/ETHERNET_CHIPLET_INTEGRATION.md`, and item #1 of
the M0 bench's "M1 implications"): it **replaces the M0 single-slave scratch RAM
with the real ethernet subsystem `ethernet_ss_ahb`**, attached to die_b's
`ahb_mng` through the subsystem's **external AHB-Lite slave port `eth_ss_0`**. A
link-crossed write from die_a now transits the subsystem's **own AHB matrix**
(`eth_ss_interconnect`) into `eth_scratch_rx` (`0x3000_0000`) — surfacing the
genuine bus-contract behaviour (matrix `hready` wait-states, `hprot[3:0]`/`hsize`
semantics, burst handling, X-init memory) that the M0 zero-wait BRAM could not.

Result: **PASS 1/1, 16/16 words byte-exact** through the real subsystem matrix,
verified two independent ways (peer-window round-trip + hierarchical peek into
`eth_scratch_rx`'s BRAMs).

## The datapath under test

```
die_a peer window (m_ahb_sub) WRITE @ T-delta
  -> XHB500 AHB->AXI -> chiplet controller -> FC -> GPIO-PHY link -> die_b
  -> die_b XHB500 AXI->AHB -> die_b ahb_mng  (presents addr T)
  -> ethernet_ss_ahb.eth_ss_0 -> eth_ss_interconnect  (MATRIX decode, full 32b)
  -> u_region_eth_scratch_rx_0  (eth_scratch_rx @ 0x3000_0000)
READ-back @ the same peer addr -> byte-exact  (+ hierarchical BRAM peek)
```

Only die_b carries the subsystem (die_a -> die_b relay direction). die_a's
`ahb_mng` (the B->A path) is an idle always-ready sink.

## `eth_ss_0` — the attach contract (why it maps cleanly onto `ahb_mng`)

`eth_ss_0` is a **matrix manager-receiving port**: the external master drives
addr/data + control IN (`haddr/htrans/hwrite/hsize/hburst/hprot[3:0]/hwdata/
hmastlock`), the subsystem returns `hrdata/hready/hresp` OUT. There is **NO
`hsel` and NO separate `hreadyout`** (the `hready` output IS the ready feedback).
This is a one-to-one match for `tidelink_top.ahb_mng` (an AHB-Lite manager) —
*cleaner* than the M0 attach, which needed a tied-high `HSEL` and a separate
`HREADYOUT`. The only adaptation is the documented AHB5 width truncation
`ahb_mng_hprot[6:0] -> eth_ss_0_hprot[3:0]` (arch §3b) and `hmastlock` tied 0
(`ahb_mng` has none). Verified from `ethernet_ss_ahb.sv:67-77` and
`tidelink_top.sv:228-242`.

## Memory-map derivation (empirical, in-test)

The subsystem matrix decodes the **full 32-bit** address (unlike the M0 BRAM,
which sliced `HADDR[13:2]` and ignored the upper bits), so the relayed write
**must carry the `eth_scratch_rx` base `0x3000_0000`**. The test does not assume
the peer-window→`ahb_mng` transform — it **derives it at run time** from a tb
address monitor (`s_mng_haddr_seen`):

```
[m1] MEMORY-MAP DERIVATION: peer 0x30000100 -> ahb_mng presented 0x30000100
     (delta=0x00000000; IDENTITY)
[m1] ahb_mng address decodes into subsystem region: eth_scratch_rx
```

So on the exposed `ahb_sub` port, with the address translator at reset
(`tl_addr_trans_cam` global_enable=0) and XHB500 passing `HADDR[31:0]`, the
transform is **identity** (`delta=0`): die_a writing peer `0x3000_0000+off`
lands at `eth_scratch_rx + off`. From the subsystem memory map
(`build_soc/reports/ethernet_ss_ahb_memory_map.txt`), `eth_ss_0` reaches:
`bootrom 0x0000_0000 · imem 0x1000_0000 · dmem 0x1800_0000 · system 0x2000_0000
· eth_scratch_rx 0x3000_0000 · eth_scratch_tx 0x3800_0000 · ethmac 0x4000_0000
(HA1588 @ +0x1000) · apb_periph 0x5000_0000`.

## Files

| File | Purpose |
|---|---|
| `tb_top.sv` | fork of the M0 `tb_top.sv`; die_b `ahb_mng` terminus = `ethernet_ss_ahb` (`eth_ss_0`) + eth clocks/reset + an `ahb_mng` address/control monitor |
| `pad_skid.sv`, `eye_fault.sv` | harness cells, copied verbatim from the M0/pair_v2 bench |
| `test_eth_relay_m1.py` | the relay test (derive transform → relay 16-word frame → byte-exact verify + bus-contract report) |
| `eth_pair_common.py` | eth memory map, frame builder, `eth_scratch_rx` peek, and `EthAHBSubMaster` (robust peer-window master, see findings) |
| `image_spin.hex` | Thumb branch-to-self IMEM image — parks the Cortex-M0+ (copied from the subsystem's own cocotb bench) |
| `Makefile` | VCS; tidelink V2 flist + the subsystem's OWN compile recipe |
| `transcript_tail.txt`, `relay_run.log` | the passing run |

Reused read-only (via `PYTHONPATH`): `pair_v2_common` (`PairV2TB`,
`run_bringup_full`) and `test_v2_xhb_window` (`AHBSubMaster` base class). The
ethernet subsystem RTL is compiled from `nanoSoC-refactor/ethernet-subsystem-ahb`
(read-only reference; nothing there is modified). The OpenCores MAC + Cortex-M0+
core are **flist-referenced from `/research/AAA/**` and never written**.

## Compile set (and the heavyweight deps it drags in)

The combined compile = tidelink V2 pair flist + the subsystem's own proven
recipe (mirrored from `.../cocotb/ethernet_ss_ahb/Makefile`). The 4 cmsdk models
common to both flists (`cmsdk_ahb_to_sram`, `cmsdk_fpga_sram`, `cmsdk_ahb_to_apb`,
`cmsdk_apb_slave_mux`) resolve to **identical absolute paths** under one
`CMSDK_DIR`, so **VCS dedups them** — no manual collision surgery. Heavyweight
deps the full subsystem pulls in (all read-only, flist-referenced):

- **Cortex-M0+ core** (`slcorem0p`, ~50 `cm0p_*`/`CM0PDAP`/`CORTEXM0PLUS` files)
  from `ARM_CORTEXM0PLUS_IP_PATH` (`/research/AAA`).
- **OpenCores EthMAC** (`eth_*`, `ethmac_subsystem_*`) from `ETHMAC_IP_DIR`, and
  **HA1588** (`ha1588*`, `tsu`, `rtc`, `ptp_*`) from `HA1588_IP_DIR`
  (`/research/AAA`).
- **`eth_ss_bootrom.sv`** (generated boot ROM) + IMEM/DMEM region SRAMs + the
  APB subsystem (`timer`/`uart`/`sysctrl`) + `eth_ss_interconnect`.

Elaboration is clean (VCS/Verdi KDB: **0 errors, 0 warnings**). Sim runs in ~14 s.

## Run

```bash
cd cocotb/eth_tidelink_pair_m1
source ../../set_env.sh                                              # tidelink env
source ~/SoCLabs/nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh  # eth env
export TIDELINK_PHY_V2=1
make                         # EPOCH_PROFILE=zero  ->  THE M1 GATE (PASS)
```

Both `set_env.sh` must be sourced (the eth env supplies `ETH_SS_HOME`,
`ETHMAC_AHB_HOME`, `SOCLABS_*`, `ARM_CORTEXM0PLUS_IP_PATH`, `ETHMAC_IP_DIR`,
`HA1588_IP_DIR`; it does **not** overwrite `CMSDK_DIR`).

## Transcript tail (`make EPOCH_PROFILE=zero`)

```
[tb_top] EPOCH_ANCHOR_EN: master=1 slave=1 (deskew: m=0 s=0)
  10720ns  post-autocal: M=0x440300ff S=0x440300ff cal M=DONE S=DONE
 113040ns  [after to_data_mode] M/S: cal_done=1 cal=DONE fcsm=4 cr=1 crack=1
 137040ns  [m1] link up (cal+CR/CRACK); eth subsystem behind die_b ahb_mng
 142220ns  [m1] MEMORY-MAP DERIVATION: peer 0x30000100 -> ahb_mng 0x30000100 (delta=0; IDENTITY) -> eth_scratch_rx
 224160ns  [m1] wrote 16-word frame -> eth_scratch_rx 0x30000040+ (peer 0x30000040+)
 224160ns  [m1] eth_ss_0 BUS CONTRACT on ahb_mng: htrans=2 hsize=2 hburst=0 hwrite=1 (SINGLE-beat)
 389160ns  [m1] w 0 T=0x30000040 sent=0xffffffff read=0xffffffff eth_scratch_rx[16]=0xffffffff
   ...      (w1..w14 — ARP-ish header + checkerboard payload, all byte-exact) ...
 464040ns  [m1] w15 T=0x3000007c sent=0xf6f6f6f6 read=0xf6f6f6f6 eth_scratch_rx[31]=0xf6f6f6f6
 464040ns  [m1] PASS: 16/16-word frame relayed die_a peer window -> link -> die_b
           ethernet_ss_ahb matrix -> eth_scratch_rx, byte-exact (round-trip + hierarchical peek).
 ** TESTS=1 PASS=1 FAIL=0 SKIP=0 **
```

`read=` is the peer-window round-trip (die_a reads back across the link);
`eth_scratch_rx[N]=` is the direct hierarchical peek into the SUBSYSTEM's
`eth_scratch_rx` `cmsdk_fpga_sram` byte-lane BRAMs — so the frame provably landed
**inside the real ethernet subsystem's scratch**, through its own matrix, not in
a bus echo and not in the MAC region.

## Bus-contract findings (the valuable M1 output)

The whole point of M1 over M0 is that the real matrix exposes contract details
the zero-wait single-slave BRAM hid. Measured here (all from cycle-accurate
traces of die_b `ahb_mng` and die_a `m_ahb_sub`):

1. **The matrix inserts a wait state; the XHB AXI→AHB manager handles it
   correctly.** A write on `ahb_mng` is: `htrans=NONSEQ` accepted at `hready=1`,
   then the data phase with **`hready=0` for one cycle**, then `hready=1`,
   `hresp=0`. The M0 BRAM was zero-wait (`HREADYOUT=1` constant); the eth matrix
   is **not**, and the datapath honours the wait state end-to-end. No `hready`
   comb-loop arises (arch §3d) because the response is a registered matrix
   output on the manager side.
2. **Single-beat only — a finding, not a failure.** The observed `ahb_mng`
   contract is `htrans=2 (NONSEQ), hsize=2 (WORD), hburst=0 (SINGLE)`. The
   peer-window master + XHB500 AXI→AHB path emits **single NONSEQ transfers**,
   so an `INCR4` burst relay is **not exercised** — the frame is 16 independent
   single-beat writes. Relaying a whole frame in one AHB burst is an M1/M2
   follow-on (needs a burst-capable peer-window driver and confirmation the XHB
   AXI→AHB bridge emits AHB bursts; today it does not).
3. **X-init `eth_scratch_rx` poisons read-before-write across the link.** The
   `cmsdk_fpga_sram` scratch model is **X-initialised** (vendor-SRAM-faithful,
   not zero-init — echoes the tapeout memory). Reading an **unwritten** scratch
   word returns `X`, and that `X` rides the XHB500 AXI R-channel back onto die_a's
   `m_ahb_sub_hreadyout`, stalling the round-trip. This is *not* a datapath bug
   (written locations read back byte-exact and complete cleanly): the relay
   always writes before it reads, and the in-test memory-map probe uses a
   **write** for the same reason. `file:line` evidence:
   `.../models/memories/cmsdk_fpga_sram.v` read path returns the byte-lane BRAM
   contents unconditionally (`assign read_data = {BRAM3,BRAM2,BRAM1,BRAM0}`),
   which are `X` until first written.
4. **Cold cross-link access shows an accept-pulse oscillation then a sustained
   low on die_a `hreadyout`.** `m_ahb_sub_hreadyout` pulses `1,0,1,0` at the
   address phase, then holds **low for ~250 hclk** (the FC round-trip) before the
   true completion high. `EthAHBSubMaster` therefore (a) tolerates a transient
   `X` on `hreadyout` (treat as in-flight, keep waiting), and (b) requires a
   **sustained-low run** before accepting a high as completion — both are
   HARNESS-only robustness fixes over the pair_v2 `AHBSubMaster` (which
   `int()`-throws on `X` and trips on the accept oscillation). Nothing about the
   DUT changes.

## Simplifications for this passive-slave bring-up (every one documented)

The subsystem's AHB clock/reset are **generated internally by the Cortex-M0+
PRMU** (`slcorem0p_prmu.v:93 assign SYS_HCLK = SYS_FCLK`, `CLKGATE_PRESENT=0`),
so a *true* "core held in reset" passive slave is impossible — holding the core
in reset also holds the matrix + memories in reset. The honest equivalents:

1. **`sys_fclk <- hclk`.** Because `SYS_HCLK == SYS_FCLK` 1:1, the whole
   subsystem + `eth_ss_0` run in the **same `hclk` domain** as die_b's `ahb_mng`
   manager → synchronous attach, **no CDC** (exactly arch §3c: the XHB500 async
   FIFO has already resynchronised the remote access into `hclk`).
2. **MII TX/RX + RTC** driven by benign free-running 25 MHz clocks; the MAC
   transmit/receive datapath is **not** exercised (M1 is the no-PHY frame relay,
   arch §5) — only the AHB/memory layer is under test.
3. **The Cortex-M0+ boots but is PARKED** via `image_spin.hex` (Thumb
   branch-to-self in IMEM), so after bootrom it spins and never issues AHB
   traffic to `eth_scratch_rx`. The byte-exact check independently guards against
   any CPU interference (there was none).
4. **`eth_ss_1`, CPU sideband, DBGAHB, IOP, UART, MDIO** tied idle/off; CPU
   system-passthrough master responds ready/OKAY.

## Scope limits (what M1 here does NOT yet prove)

- **No MAC / HA1588 / PicoTCP in the loop.** The frame lands in `eth_scratch_rx`
  as bytes; nothing parses it as ethernet, no MAC RX ring descriptors, no
  `eth_irq`, no timestamp. (M1b / §6 work.)
- **Shape B, not Shape A.** The attach is the subsystem alone behind `ahb_mng`
  (`eth_ss_0`), not the full multicore SoC via `d2d_ahb_s`. Reaching the MAC BDs
  and HA1588/PHC registers is the next Shape-A step.
- **Single-beat, identity CAM, one direction** (die_a -> die_b) — as finding #2
  and the M0 scope limits.
- **`EPOCH_PROFILE=silicon`** is not the gate: it inherits the pre-existing
  peer-window S->M return-path stall proven identical on the *unmodified* pair_v2
  reference (a PHY/harness item owned by another lane) — not chased here.

## M1 → M2 implications

1. **Shape A next:** swap `eth_ss_0` for `ahb_mng -> d2d_ahb_s -> full multicore
   SoC matrix` (matching `nanosoc_eth_chiplet.sv`) so the far die reaches
   `eth_scratch` **and** MAC BDs **and** HA1588/PHC regs — the substrate for the
   §5 M1a "relay a frame into the far MAC RX ring" and the §6 PTP grandmaster
   chain. This bench proves the AHB-matrix attach that Shape A also relies on.
2. **Burst relay:** finding #2 says the path is single-beat today. A whole-frame
   `INCR` burst needs a burst-capable peer-window driver AND an XHB AXI→AHB
   bridge that emits AHB bursts — confirm/enable before M2 throughput matters.
3. **X-init discipline (finding #3) becomes a firmware/DMA contract:** the far
   die's stack must not read a MAC RX descriptor / scratch word before the MAC (or
   the relay) has written it, or it reads `X` in sim / undefined on silicon.
4. **The wait-state contract (finding #1) is proven end-to-end**, so the FPGA
   Shape-A target can attach the SoC matrix to `ahb_mng` without a wait-state
   adapter — one less integration risk for `kr260-eth-chiplet`.

## Provenance / rules honoured

- **This lane's footprint = this new `cocotb/eth_tidelink_pair_m1/` dir only.** No
  `targets/`, root `Makefile`, `hw_regression/`, `pynq_host/`, or shared-RTL
  edits. The ethernet repos, the pair_v2 bench, and `tidelink_top` are read-only
  references.
- **No `/research/AAA/**` writes.** The OpenCores MAC/HA1588 and the Cortex-M0+
  core are flist-referenced (read) only.
- Not committed (per the lane brief).
