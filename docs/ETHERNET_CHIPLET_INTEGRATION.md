# Ethernet Chiplet over TideLink — Integration Architecture

> **Status:** ARCHITECTURE + SCAFFOLD (weekend lane W4, 2026-07-18). This is a
> design document, not an implementation. No RTL is changed by this file. The
> companion scaffold notes are in [W4_ETHERNET_SCAFFOLD_NOTES.md](W4_ETHERNET_SCAFFOLD_NOTES.md);
> the chiplet-repo port plan is `docs/TIDELINK_KR260_PORT_PLAN.md` in the
> `nanosoc-ethernet-chiplet` clone (branch `feat/tidelink-chiplet-port`).

## 0. Goal and the one big correction to the W4 recon

**Goal:** two KR260 boards, each carrying a nanoSoC ethernet chiplet, talking to
each other over the TideLink die-to-die ribbon, with the 1588 grandmaster
timebase crossing the link (HA1588 → PHC → TideLink PTP → far die).

**Correction to the recon in `WEEKEND_PLAN_2026_07_18.md` §W4 and STATUS_LIVE
("no MAC in chiplet repo"):** that statement is now **stale** for the checkout on
disk. The `nanosoc-ethernet-chiplet` clone (HEAD e809fbf) pins
`nanosoc-multicore-system`, and **that submodule DOES instantiate the ethernet
subsystem**. Verified on disk:

- `nanosoc-multicore-system/build_soc/rtl/nanosoc_multicore_soc.sv` instantiates
  `ethernet_ss_ahb_rmii` → `ethmac_subsystem_ahb` (OpenCores MAC + HA1588).
- The chiplet top `src/rtl/nanosoc_eth_chiplet.sv` **already re-exports** the
  full ethernet boundary from `u_soc`: `rmii_ref_clk / rmii_txd / rmii_tx_en /
  rmii_rxd / rmii_crs_dv` (lines 100–104), MDIO (`md_pad_i / mdc_pad_o /
  md_pad_o / md_padoe_o`, 106–109), `eth_irq` (476), `ha1588_servo_locked`
  (480), and the PHC servo (`d2d_phc_*`, source 0).
- Sim proof it is real: `nanosoc-multicore-system/cocotb/soc_eth_ping/` (PicoTCP
  ping), `.../cocotb/ha1588_settime_unit/`, and the `*_eth_ss_*` firmware linker
  scripts under `build_soc/firmware/`.

**Consequence:** the MAC + HA1588 + PHC grandmaster hardware is *already present*
inside the chiplet SoC. The remaining work is not "add a MAC" — it is
**(a) route TideLink's remote-manager port into the SoC so the far die can reach
the ethernet scratch/registers, (b) find PHY pins on KR260 (or defer the PHY),
and (c) close the PTP servo chain across the link.** That is a much smaller job
than the recon implied, and it reshapes the milestone plan (§7).

The MAC itself remains the OpenCores EthMAC under
`/research/AAA/ip_library/OpenCores-EthMAC` (read-only; flist-reference only —
never copy-modify upstream, per the standing rule).

---

## 1. System diagram (two boards, one ribbon)

```
        KR260 board A  (die_a / master strap=0)                        KR260 board B  (die_b / flip strap=1)
  ┌───────────────────────────────────────────────┐            ┌───────────────────────────────────────────────┐
  │ Zynq-MP PS  (Cortex-A53, Linux)                │            │ Zynq-MP PS  (Cortex-A53, Linux)                │
  │   devmem / driver  ── AXI HPM ──┐              │            │              ┌── AXI HPM ── devmem / driver     │
  └─────────────────────────────────┼──────────────┘            └──────────────┼─────────────────────────────────┘
                                    │ PS→PL (ctrl 0x8000_0000,                 │
                                    │        data 0xA400_0000,                 │
                                    │        APB  0x8403_xxxx)                 │
  ┌─────────────────────────────────┼──────────────┐            ┌──────────────┼─────────────────────────────────┐
  │ PL: nanosoc_eth_chiplet         ▼              │            │ PL: nanosoc_eth_chiplet ▼                       │
  │  ┌──────────────────────────────────────────┐ │            │ ┌──────────────────────────────────────────┐   │
  │  │ nanosoc_multicore_soc (u_soc)            │ │            │ │ nanosoc_multicore_soc (u_soc)            │   │
  │  │  CPU0(data) CPU1(link-mgmt)              │ │            │ │  CPU0(data) CPU1(link-mgmt)              │   │
  │  │  ┌─────────────────────────────┐         │ │            │ │  ┌─────────────────────────────┐         │   │
  │  │  │ ethernet_ss_ahb_rmii        │         │ │            │ │  │ ethernet_ss_ahb_rmii        │         │   │
  │  │  │  OpenCores MAC + HA1588      │──MII/RMII│ │◄─PHY?──►│ │ │  │  OpenCores MAC + HA1588      │──MII/RMII│   │
  │  │  │  eth_scratch_rx/tx SRAM      │  (§5)    │ │            │ │  │  eth_scratch_rx/tx SRAM      │  (§5)    │   │
  │  │  └───────────┬─────────────────┘         │ │            │ │  └───────────┬─────────────────┘         │   │
  │  │      eth_ss_0/1 (AHB slave, 32/32)       │ │            │ │      eth_ss_0/1 (AHB slave, 32/32)       │   │
  │  │              │ AHB matrix                 │ │            │ │              │ AHB matrix                 │   │
  │  │   d2d_ahb_m ─┤ (0x2E00_0000 window)      │ │            │ │   d2d_ahb_m ─┤                            │   │
  │  │   d2d_ahb_s ─┤ (6th matrix initiator)    │ │            │ │   d2d_ahb_s ─┤                            │   │
  │  │   d2d_phc_*  │ (servo src 0)             │ │            │ │   d2d_phc_*  │                            │   │
  │  └──────────────┼────────────────────────────┘ │            │ └──────────────┼────────────────────────────┘   │
  │   chiplet_d2d_decode  (sub-decode d2d_ahb_m)   │            │   chiplet_d2d_decode                           │
  │  ┌──────────────┴────────────────────────────┐ │            │ ┌──────────────┴────────────────────────────┐   │
  │  │ tidelink_top  (die_a)                     │ │            │ │ tidelink_top  (die_b)                     │   │
  │  │  ahb_sub ◄─ peer window (SoC → far die)   │ │            │ │  ahb_sub ◄─ peer window                    │   │
  │  │  ahb_mng ─► remote die → local SoC        │ │            │ │  ahb_mng ─► remote die → local SoC         │   │
  │  │  GPIO-PHY  pad_clk/pad_tx[7:0]/pad_rx[7:0]│ │            │ │  GPIO-PHY                                  │   │
  │  └──────────────┬────────────────────────────┘ │            │ └──────────────┬────────────────────────────┘   │
  └─────────────────┼──────────────────────────────┘            └──────────────┼─────────────────────────────────┘
                    │  J21 Pi-header ribbon (20 conductors: clk+8 tx, clk+8 rx, i2c_sda/scl)
                    └──────────────────── STRAIGHT-THROUGH ─────────────────────┘
```

Everything from `chiplet_d2d_decode` down is TideLink; everything above `u_soc`'s
`d2d_*` ports is link-agnostic SoC. The only TideLink-aware glue is
`chiplet_d2d_decode.sv` (already written and lint/sim-clean in the chiplet repo).

**The cross-die datapath that matters for ethernet:**
`die_a SoC → d2d_ahb_m → chiplet_d2d_decode → tidelink_top.ahb_sub (peer window
0x2F00_0000) → XHB500 AHB→AXI → ribbon → die_b XHB500 AXI→AHB →
tidelink_top.ahb_mng → die_b d2d_ahb_s → die_b SoC AHB matrix → die_b
eth_scratch_rx / MAC BDs`. This is the "virtual PHY / frame relay" path (§5, M1).

---

## 2. Address maps

### 2a. KR260 PS view (per die — what the A53 / devmem reaches)

Consistent with `WEEKEND_PLAN`, STATUS_LIVE canaries, and the KR260 port memory.

| PS address | What | Notes |
|---|---|---|
| `0x8000_0000` | TideLink **control** (AXI-Lite / status) | ctrl plane relocated here by `tl_socmap` (commit 63540e3) to dodge an AXI-hang trap |
| `0x8400_0000` | GP1 **data TX** aperture (→ `ahb_tx`) | wedge hazard if link down |
| `0x8401_0000` | GP1 **data RX FIFO** (→ `ahb_fifo`) | local RX FIFO read window |
| `0x8402_0000` | PTP TX write port (→ `ahb_ptp`) | |
| `0x8403_xxxx` | **APB** unified config regs | canary `0x8403_0204`==1, `0x8403_0214`==0xe4e4 |
| `0xA400_0000` | **peer / data window** into far die (`ahb_sub` → XHB500 AXI) | the frame-relay entry point (§5) |

> ⚠ Do **not** probe `0x4403_xxxx` on ZynqMP (undecoded, hangs the PS with no
> timeout) — that is the Z2 base; KR260 is `0x84xx`/`0xA4xx`. See
> `reference_tidelink_address_map`.

### 2b. nanoSoC view (per die — what a Cortex-M0+ inside the chiplet SoC reaches)

Two regions matter: the SoC's own ethernet subsystem, and the D2D window.

**Ethernet subsystem (inside `u_soc`, driven from the SoC matrix / DMA-230 / CPUs).**
The chiplet uses the *embedded* subsystem (folded into the SoC matrix), so the
SoC's generated map governs; the block offsets below are the subsystem's own
(from `ethernet-subsystem-ahb`, base variant — the PHC variant compresses the
stride). Treat these as the *shape*, and read the SoC's generated
`*_memory_map.txt` for the absolute bases in the multicore build:

| Block | Base (standalone base variant) | Size | Contents |
|---|---|---|---|
| eth_scratch_rx | `0x3000_0000` | 16 KB | MAC RX ring / received frames |
| eth_scratch_tx | `0x3800_0000` | 16 KB | MAC TX ring / frames to send |
| ethmac (MAC + HA1588) | `0x4000_0000` | — | MAC regs+BDs at `+0x0000`; **HA1588 PTP regs at `+0x1000`** |
| apb_periph | `0x5000_0000` | — | timer / UART / sysctrl |
| (PHC variant only) phc_0 | `0x1A00_0000` (compressed map) | 4 KB | `phc_ahb` PTP HW clock regs |

**D2D window (from the SoC's `d2d_ahb_m`, sub-decoded by `chiplet_d2d_decode.sv`).**
`haddr[24]` splits 0x2E from 0x2F; inside 0x2E, `haddr[19:16]` selects the block:

| nanoSoC address | HSEL | TideLink aperture |
|---|---|---|
| `0x2E00_0000` | `hsel_tx` | `ahb_tx` (TX send; **gated by `link_active_i`** — faults if link down) |
| `0x2E01_0000` | `hsel_fifo` | `ahb_fifo` (RX FIFO) |
| `0x2E02_0000` | `hsel_ptp` | `ahb_ptp` (PTP TX) |
| `0x2E03_0000` | `hsel_tlapb` | TideLink APB config (15-bit window) |
| `0x2E04_0000` | `hsel_tcapb` | TideChart APB config (12-bit window) |
| `0x2F00_0000` | `hsel_peer` | **peer window (16 MB)** — `ahb_sub` into the far die |
| anything else in 0x2E | — | internal default responder → two-cycle AHB **ERROR** |

### 2c. Across-link view (the frame relay, die_a initiator → die_b target)

A write from die_a into its **peer window `0x2F00_0000 + off`** appears on die_b's
`ahb_mng` and is routed by die_b's chiplet integration into die_b's SoC matrix
(`d2d_ahb_s`). The `off` within the 16 MB peer aperture is what die_b's matrix
decodes — so die_a chooses the *far-die* SoC address by construction:

```
die_a M0+  writes 0x2F00_0000 + (far_off)
      → tidelink_top.ahb_sub → XHB500 → ribbon
      → die_b tidelink_top.ahb_mng  (haddr = far_off)
      → die_b chiplet integration → die_b d2d_ahb_s → die_b SoC matrix
      → e.g. die_b eth_scratch_rx  (far_off in die_b's eth-scratch range)
```

Symmetric in the other direction (die_b initiates via *its* peer window into
die_a). This is bidirectional and needs no PHY.

> **Today's FPGA terminus gap:** on the *bare* tidelink `kr260-pair-*` FPGA
> targets, `ahb_mng` terminates in `tidelink_ahb_mng_bram.v` (a 4 KB scratch
> BRAM), **not** in a SoC. That is correct for the pure-link bring-up but is a
> dead end for ethernet. The chiplet build replaces that BRAM terminus with
> `d2d_ahb_s` into the SoC — see §3 and §7-M1.

---

## 3. The `ahb_mng` → `eth_ss` attach design

### 3a. What connects to what

`tidelink_top.ahb_mng` is an **AHB-Lite manager output** (die is the manager on
this bus; the far die's remote access exits here). Ports (from
`src/rtl/tidelink_top.sv:228-242`, `SYS_ADDR_W=SYS_DATA_W=32`):

```
output ahb_mng_haddr[31:0], ahb_mng_hburst[2:0], ahb_mng_hprot[6:0],
       ahb_mng_hsize[2:0], ahb_mng_htrans[1:0], ahb_mng_hwdata[31:0],
       ahb_mng_hwrite
input  ahb_mng_hready, ahb_mng_hrdata[31:0], ahb_mng_hresp
```

`eth_ss_0/1` are **AHB-Lite target/slave** ports on the ethernet subsystem
(32/32; from the Explore recon of `ethernet_ss_ahb.sv`): `hsel, haddr[31:0],
htrans[1:0], hwrite, hsize[2:0], hburst[2:0], hprot[3:0], hwdata[31:0],
hmastlock, hready` in; `hrdata[31:0], hresp, hreadyout` out.

**But note the actual attach in the chiplet is one level up:** `ahb_mng` drives
`d2d_ahb_s`, the SoC's **6th matrix initiator**, *not* `eth_ss` directly. The SoC
matrix then routes to eth_scratch / MAC / anything else the far die addresses.
`eth_ss_0/1` remain the *external test/DMA* slave ports (used by cocotb BFMs and
the DMA-230), and stay available for a direct-attach variant if wanted. Two
attach shapes:

- **Shape A (recommended, matches the chiplet RTL): `ahb_mng → d2d_ahb_s → SoC
  matrix`.** The far die reaches *everything* the local SoC exposes in the peer
  aperture (eth scratch, MAC BDs, mailbox SRAM). This is already the wiring in
  `nanosoc_eth_chiplet.sv`. Nothing new to design; the FPGA target just has to
  instantiate `nanosoc_eth_chiplet` instead of bare `tidelink_top`.
- **Shape B (narrow, FPGA-lite): `ahb_mng → eth_ss_0` directly.** Skip the full
  SoC; wire the remote manager straight into the ethernet subsystem's external
  slave. Useful only if a future target wants ethernet-without-the-full-multicore.
  Not needed for the KR260 demo.

### 3b. Bus widths, prot mismatch

- All AHB is 32-bit addr / 32-bit data end to end. No width bridging.
- **HPROT width mismatch:** TideLink is AHB5 (`hprot[6:0]`); the SoC matrix takes
  `hprot[3:0]`. Take the low 4 bits (`d2d_ahb_s_hprot[6:0]` fed from
  `ahb_mng_hprot`, upper bits dropped) — already handled in the chiplet wiring
  (`chiplet_d2d_decode.sv` note at `d2d_ahb_s_hprot`).
- `ahb_mng` carries `hburst`/`hprot` but the historic BRAM terminus left them
  unconnected (single/word accesses only). Through the SoC matrix, bursts are
  supported; the ethernet DMA-230 already uses them internally.

### 3c. Clocking — the four async domains

The ethernet subsystem has **four asynchronous clock domains** (from
`cdc/ethernet_ss_ahb.sgdc`):

| Domain | Clock | Rate | Feeds |
|---|---|---|---|
| system | `sys_fclk` → `hclk` | ≤250 MHz constraint (KR260: run at the chiplet `hclk`) | CPUs, AHB matrix, memories, APB, MAC register side |
| RTC / PTP | `rtc_clk` | ~100 MHz (10 ns) | HA1588 time-base, PHC |
| MII TX | `mtx_clk_i` | 25 MHz | MAC transmit nibble path |
| MII RX | `mrx_clk_i` | 25 MHz | MAC receive nibble path |

TideLink adds its own domains: `hclk` (AHB), the GPIO-PHY `pad_clk` (KR260 link
rate ≈ 2.343 MHz today, /8 of 18.75 MHz; 25 MHz proven in sim), `user_ref_clk`,
`phc_clk`. **Crossing rule:** the `ahb_mng ↔ d2d_ahb_s` handoff is entirely in
the **`hclk` domain on both sides** — TideLink presents the remote access already
resynchronised into `hclk` at `ahb_mng` (the XHB500 async FIFO does the CDC). So
the SoC-matrix attach is same-domain and needs **no new CDC**. The MII TX/RX and
RTC domains stay local to each die's ethernet subsystem — they never cross the
ribbon (only *timestamps and time*, as register/PTP-message data, cross).

> ⚠ **D2D_HREADY_LOOP caveat** (`chiplet_d2d_decode.sv:85-93`,
> `docs/D2D_HREADY_LOOP.md`): TideLink's `ahb_sub_hreadyout` reads `ahb_sub_hready`
> combinationally, so the peer subordinate's `hready` must be broken with
> `dph_peer`, not fed straight back. The same discipline applies to any new
> slave you hang off `ahb_mng`/`d2d_ahb_s`: register the ready, or reuse the
> proven `tidelink_ahb_mng_bram.v` loopback pattern (constant `HREADY=1`).

### 3d. Resets

- `hresetn` / `poresetn`: on KR260 both dies tie `hresetn` + `poresetn` to
  `peripheral_aresetn` (per the KR260 recovery memory). The SoC exports
  `sys_poresetn / sys_hresetn`; feed TideLink's resets from the same tree so the
  link and the SoC come out of reset together.
- MII/RTC domain resets are internal to the ethernet subsystem (derived from
  `sys_hresetn` through the subsystem's PRMU-style reset). No new reset crossing.
- **Ordering:** SoC `poresetn` → `hresetn` → TideLink bring-up (role strap,
  cal/fcsm) → link_active → *then* the far-die peer window is usable. The TX
  aperture is gated by `link_active_i` so early accesses fault cleanly rather
  than wedge (see `chiplet_d2d_decode.sv` TX wedge gate).

### 3e. IRQ routing

The chiplet already gathers 16 D2D interrupts (`d2d_irq[15:0]`,
`nanosoc_eth_chiplet.sv:312-322`): `[7:0]` → CPU0 NVIC (data plane), `[15:8]` →
CPU1 NVIC (link management). Ethernet adds:

| IRQ | Source | Route |
|---|---|---|
| `eth_irq` | MAC `int_o` (RX/TX done, error) | CPU0 NVIC (data plane) |
| `phc_pps_irq` | PHC 1PPS (PHC variant) | CPU0 or CPU1 (time plane) |
| `phc_alarm_irq` | PHC alarm-match | CPU1 (link-mgmt / grandmaster) |
| `tl_ptp_irq` | TideLink PTP | already in `d2d_irq` (CPU0) |

`eth_irq` is exported at the chiplet boundary today; wire it into the SoC's NVIC
(it currently reaches the boundary as an observability output — confirm whether
the SoC already lands it on `cpu_0_irq` internally, or whether the chiplet needs
a one-line NVIC hookup; flagged as a verify item in the port plan).

---

## 4. PHY options matrix (KR260 — J21 is consumed by the ribbon)

The TideLink ribbon uses the entire 40-pin Raspberry-Pi header (J21): 20
conductors (clk + 8 TX, clk + 8 RX, I2C SDA/SCL) — see
`fpga/targets/kr260-pair-nptp/ribbon_wiring.md`. So a MAC PHY needs pins
elsewhere. RMII (the proven interface — LAN8720 on MPS3/Z2) needs ~9 signals:
`ref_clk` (50 MHz), `txd[1:0]`, `tx_en`, `rxd[1:0]`, `crs_dv`, `mdio`, `mdc`.

| Option | Pins available? | MAC fit | Effort | Verdict |
|---|---|---|---|---|
| **No PHY — MAC-to-MAC frame relay over TideLink** | none needed | native (uses eth_scratch + peer window) | low | **★ RECOMMENDED for M1.** Proves the whole chiplet path, HA1588 timestamping, and the PTP grandmaster chain with zero PHY hardware. See §5. |
| **PMOD (12-pin) RMII** | KR260 has 2× PMOD (`som240` / carrier PMOD). 12 pins = 8 usable I/O + 3V3 + GND. RMII needs 9 signals — **marginal but fits** (drop `mdc/mdio` to a 2nd PMOD or bit-bang, or use a fixed-config PHY). | native MAC (add `rmii_to_mii` bridge, already in the eth repo) | medium | **★ RECOMMENDED for M2** (real wire). Needs a Waveshare LAN8720-style PMOD adapter + XDC. 50 MHz ref_clk timing on PMOD I/O is the risk. |
| **SFP+ cage** | KR260 has SFP+ (GT lanes). | **wrong MAC** — needs a 1000BASE-X / SGMII PCS-PMA, not the OpenCores 10/100 MII MAC. | high | **Out of scope.** Would replace the MAC. Note for a future 1G variant only. |
| **PS-GEM bridged to PL (EMIO)** | ZynqMP PS-GEM can route to PL via EMIO. | EMIO exposes **GMII** (not RGMII — RGMII-over-EMIO is not supported). But this is the *PS's own* GEM MAC, not our OpenCores MAC + HA1588 — using it bypasses the chiplet's MAC/1588 entirely. | high | **Not a fit** for the chiplet demo (defeats the purpose — no HA1588). Viable only as a plain-Linux-networking fallback, unrelated to the chiplet. |

**Recommendation:** **M1 = no PHY (frame relay).** **M2 = PMOD RMII** on one or
both boards for a genuine external link. SFP+/PS-GEM are explicitly out of scope
and documented only so the option isn't re-litigated.

---

## 5. The M1 "no-PHY" demo shape (virtual PHY / frame relay)

The MAC is a streaming (MII/RMII) block; TideLink carries **AHB/AXI**, not a raw
50 MHz nibble stream. So a *true* MII-cross over TideLink would need an
RMII↔packet bridge (not worth it). Instead M1 relays at the **frame-buffer /
memory** layer, which is exactly what TideLink is good at:

1. **Board A** builds an ethernet frame in its TX path. Two sub-variants:
   - **M1a (simplest, no MAC in the loop):** firmware/DMA stages the frame bytes
     in board A's `eth_scratch_tx`, then writes them across the peer window into
     **board B's `eth_scratch_rx`** (die_a `0x2F00_0000 + far_off`, far_off in
     B's RX-scratch range). Board B's stack sees a "received frame" and PicoTCP
     processes it (ping/ARP/UDP). No PHY, no MII clocking — pure TideLink AHB.
   - **M1b (MAC in internal loopback):** put each MAC in its internal loopback so
     the HA1588 timestamps a real TX→RX event; relay the *timestamped* frame +
     its capture over TideLink. Proves HA1588 in-path.
2. **HA1588 / PTP grandmaster chain** runs alongside (§6): board A is
   grandmaster, its PHC time crosses TideLink to board B's PHC, and the PTP
   Sync/Follow-Up/Delay-Req messages ride the same frame-relay path.
3. **Success = board B's PicoTCP answers an ARP/ping that originated as a frame
   on board A, delivered entirely over TideLink**, and board B's PHC locks to
   board A's time (servo_locked). Both are observable: `eth_irq` on B,
   `ha1588_servo_locked`, PHC offset shrinking.

This is the highest-value first milestone: it exercises the *entire* chiplet
interconnect (peer window → ribbon → ahb_mng → SoC matrix → eth scratch), the
MAC, HA1588, and the PTP servo — with **no external hardware beyond the ribbon
already on the bench.**

---

## 6. PTP / 1588 grandmaster chain

The hardware for this is already instantiated; the chain is wiring + firmware:

```
  Board A (grandmaster)                                    Board B (slave clock)
  ───────────────────────                                  ─────────────────────
  MAC MII/GMII stream tap                                  MAC MII/GMII stream tap
        │ (rx/tx_gmii_data, giga_mode)                           │
        ▼                                                        ▼
  HA1588 timestamp unit  ── rtc_time_one_pps ──┐          HA1588 timestamp unit
  (ethmac_subsystem_ahb, regs @ +0x1000)       │                 │
        │ rtc_time_ptp_{ns,sec}                 │ 1PPS            │
        ▼                                       ▼                 ▼
  PHC (phc_ahb, servo)  ◄── hw_capture_1 = HA1588 1PPS   PHC (phc_ahb, servo)
        │  servo_locked, hw_set_time, hw_adj                     ▲
        ▼                                                        │ servo source 0
  d2d_phc_*  (TideLink PHC servo SOURCE 0)  ── seconds/ns ──────►│ (cross-die)
        │  hw_capture / hw_set_time / hw_adj_valid               │
        ▼                                                        │
  tidelink_top  phc_* ports ── PTP messages over the link ──────►│
  (ahb_ptp 0x2E02_0000 TX;  tl_ptp_irq)                          │
```

Key facts (verified on disk):

- **HA1588 lives inside the MAC subsystem** (`ethmac_subsystem_ahb` →
  `ha1588_ahb`), taps the MII stream, drives `rtc_time_ptp_ns[31:0] /
  rtc_time_ptp_sec[47:0] / rtc_time_one_pps`. Register base `+0x1000` in the MAC.
- **PHC** (`phc_ahb`, from the `ptp-hardware-clock-ahb` project) is a downstream
  servo/clock; its `hw_capture_1` is driven by the HA1588 1PPS. PHC variant maps
  it at `0x1A00_0000` (4 KB) and exports `phc_pps_out / phc_pps_irq /
  phc_alarm_irq`.
- **TideLink** consumes the PHC as **servo source 0** via the chiplet's
  `d2d_phc_*` bus (`nanosoc_eth_chiplet.sv:299-310`): `d2d_phc_seconds[47:0],
  d2d_phc_nanoseconds[29:0], hw_capture, hw_set_time, hw_adj_valid, ...`. These
  land on `tidelink_top`'s `phc_*` ports (seen in the pair TB at
  `cocotb/tidelink_top_pair_v2/tb_top.sv` — `phc_seconds/phc_nanoseconds/phc_pps/
  phc_hw_cap_*`). TideLink's PTP TX port is `ahb_ptp` (`0x2E02_0000`), IRQ
  `tl_ptp_irq`.

**Grandmaster election caveat (open finding G1):** the TideChart co-sim found a
**dual-root election** issue — `link_active` precedes data-mode, and the ASIC
integration inherits it (`nanosoc_eth_chiplet.sv:357`, STATUS_LIVE W2b row). The
PTP grandmaster selection must be pinned (strap board A as grandmaster) rather
than left to auto-election until that is resolved. Track it as a demo
precondition, not a blocker for M1 (M1 pins the roles anyway).

**Chain never crosses MII/RTC domains over the ribbon** — only *time values* and
PTP *messages* cross, as `hclk`-domain register/AHB data. The CDC into `hclk`
happens in the PHC and in TideLink's XHB500 FIFO.

---

## 7. Staged milestone plan

| Milestone | Scope | Deliverable | Gate |
|---|---|---|---|
| **M0 — sim smoke** | TideLink pair + ethernet subsystem behind `ahb_mng`, cocotb, no PHY. Extend the `tidelink_top_pair_v2` harness so die_b's `ahb_mng` terminus is the ethernet subsystem's `eth_ss_0` (Shape B) or a SoC stub; drive a frame from die_a's peer window; check it lands in die_b eth_scratch_rx. | New cocotb test dir (see scaffold notes §M0). Runs under `make sim_gate`. | Frame byte-exact in far scratch; no bus wedge. |
| **M1 — KR260 no-PHY demo** | Build `nanosoc_eth_chiplet` for KR260 (one bitstream per board), deploy over the existing ribbon, run the frame-relay + PTP demo (§5, §6). | New FPGA target `kr260-eth-chiplet` (built by W1 lane, not W4). Host script drives the relay. | Board B PicoTCP answers a board-A-originated ARP/ping over TideLink; PHC servo_locked. |
| **M2 — physical PHY** | Add a PMOD RMII adapter (LAN8720-class) to one/both boards; real frame in/out of a wire; PTP over a real ethernet segment. | PMOD XDC + `rmii_to_mii` bridge wired; PHY bring-up runbook. | ping over a real cable; HA1588 timestamps a wire event. |
| **M3 — chiplet-repo ASIC alignment** | Reconcile the FPGA integration back into `nanosoc-ethernet-chiplet` for tapeout: ensure the ASIC flist carries the same eth-attach + PHC servo; close the dual-root election finding. | Port plan executed in the chiplet repo (`docs/TIDELINK_KR260_PORT_PLAN.md`). | ASIC elaboration + lint clean; sim parity with FPGA. |

---

## 8. Repo / branch / tag strategy across the four repos

| Repo | Role | Branch (this work) | Push? | Notes |
|---|---|---|---|---|
| `tidelink` (this repo) | link IP + FPGA targets + docs | **W4 footprint = new `docs/` files ONLY.** FPGA target dir is the **W1** lane's job (see scaffold notes). Integration work would land on `feat/ethernet-chiplet-integration` (per WEEKEND_PLAN). | **never** push a remote | do NOT touch `targets/`, `Makefile`, `hw_regression/`, `pynq_host/scripts/` (other lanes). |
| `nanosoc-ethernet-chiplet` | integration top (SoC+TideLink+TideChart) — the **ASIC-facing** home | **`feat/tidelink-chiplet-port`** (created; carries `docs/TIDELINK_KR260_PORT_PLAN.md`). | **never** push | local commits only; MAC lives via submodule, never edited here. |
| `ethernet-subsystem-ahb` / `nanoSoC-refactor/ethernet-subsystem-ahb` | M0+ subsystem (MAC+HA1588+PicoTCP), MPS3-proven | read-only reference for W4. A future patch series (KR260 RMII PMOD target, M2) would go on a `feat/kr260-rmii-pmod` branch. | **never** push | staged patches only; upstream OpenCores under `/research/AAA/**` is read-only. |
| `ethernet-mac-ahb` | MAC + HA1588 wrappers | read-only reference. | **never** push | flist-references `/research/AAA/ip_library/OpenCores-EthMAC` — never copy-modify. |

**Tag strategy:** tag each milestone in `nanosoc-ethernet-chiplet` locally
(`eth-chiplet-m0-sim`, `-m1-kr260`, `-m2-phy`, `-m3-asic`) as it passes its gate,
mirroring the tidelink gate-tag convention. No remote tags until David signs off.

---

## 9. Top risks

1. **The `ahb_mng` FPGA terminus is a dead-end BRAM today.** The KR260 demo needs
   the terminus swapped to the SoC (`d2d_ahb_s`) — i.e. the FPGA target must build
   `nanosoc_eth_chiplet`, not bare `tidelink_top`. That is a real new FPGA target
   (W1 lane) and a bigger PL build than the pure-link one — timing/utilisation on
   `xck26` is unproven for the full multicore+eth+link. **Mitigation:** M0 proves
   the attach in sim first; M1 can fall back to Shape B (ethernet subsystem alone
   behind `ahb_mng`, no full multicore) if the full SoC won't close timing.
2. **KR260 link is still fragile / not throughput-grade.** cal=1 both dies but
   master fcsm=2 residual; the AFI poke doesn't survive reboot; data crossing has
   historically been a lock lottery. A frame relay demands *reliable* AHB delivery
   across the link, which is exactly the harder mode. **Mitigation:** gate M1 on a
   clean bilateral link (STATUS_LIVE canaries), keep frames small, and lean on the
   content-anchored deskew fix; treat M1 as "works on a healthy link", not "works
   every POR".
3. **PTP grandmaster dual-root election (finding G1) + no PHY means synthetic
   timestamps.** With no wire in M1, HA1588 timestamps a loopback/relayed event,
   not a real PHY edge — the servo can lock to an artifact and *look* right while
   proving less than a wire would. Combined with the un-pinned grandmaster
   election, "PHC locked" could be a false positive. **Mitigation:** pin the
   grandmaster role explicitly in M1, verify the offset against an independent
   PPS, and treat M2 (real wire) as the real 1588 proof point. (Echoes the
   standing rule: *verify the instrument before trusting the DUT.*)
