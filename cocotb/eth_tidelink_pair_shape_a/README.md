# eth_tidelink_pair_shape_a — reach MAC + HA1588 REGISTERS across TideLink

**Shape-A step (M2 direction): a link-crossed access reaches a register INSIDE
the ethernet MAC and the HA1588 PTP block.** This takes the M1 bench
(`eth_tidelink_pair_m1`, which relayed a *frame* into `eth_scratch_rx`) one
concrete step toward M2: instead of scratch RAM, die_a now drives a link-crossed
access to a **register** inside the OpenCores MAC (`0x4000_0000`) and inside
**HA1588** (`0x4000_1000`) — the register-visibility prerequisite for the PTP
grandmaster chain (reading/writing a real HA1588 or ethmac register across the
chiplet link).

Result: **PASS 1/1.** Four MAC known-constant registers read **byte-exact**
across the link against their golden RTL reset values, and HA1588 SCRATCH
**write/readback** byte-exact for six patterns (incl. walking-ones, all-0,
all-1) — both directions of the link exercised.

## Which shape worked: NARROW Shape-A (no full multicore SoC needed)

Per the lane brief's pragmatism rule (1), I tried the **narrowest Shape-A first**:
reuse the M1 `eth_ss_0` attach (the ethernet subsystem alone behind die_b's
`ahb_mng`), but drive the access to the **ethmac/HA1588 aperture** instead of
scratch. **It worked — no escalation to the chiplet-repo `d2d_ahb_s` / full
multicore SoC was required.**

### FINDING 1 (routing evidence): `eth_ss_0` reaches `ethmac_0` — NOT restricted to scratch

The port-visibility matrix in the subsystem's generated memory-map report is the
proof (`nanoSoC-refactor/ethernet-subsystem-ahb/build_soc/reports/ethernet_ss_ahb_memory_map.txt`):

```
Initiator Connectivity:
  eth_ss_0: bootrom_0, imem_0, dmem_0, eth_scratch_rx_0, eth_scratch_tx_0, ethmac_0, apb_periph
```

`eth_ss_0` (the external AHB-Lite slave port that die_b's `ahb_mng` drives) is
wired to **`ethmac_0`** through the subsystem's own AHB matrix
(`eth_ss_ahb_interconnect`), which decodes the full 32-bit address. So the
register-visibility M2 goal is achievable **through the eth_ss_0 attach alone** —
the far die reaches the MAC BDs/registers and the HA1588 PTP registers without
the multicore SoC. (The full Shape-A `ahb_mng → d2d_ahb_s → multicore matrix` is
still the ASIC-faithful wiring for reaching the *rest* of the SoC — CPUs,
mailbox, apb_periph timers — but it is **not** required for MAC/HA1588 register
access. See "Remaining gap".)

### The datapath under test

```
die_a peer window (m_ahb_sub) @ 0x40000000 (MAC) / 0x40001004 (HA1588)
  -> XHB500 AHB->AXI -> chiplet controller -> FC -> GPIO-PHY link -> die_b
  -> die_b XHB500 AXI->AHB -> die_b ahb_mng  (presents addr T, identity)
  -> ethernet_ss_ahb.eth_ss_0 -> eth_ss_ahb_interconnect  (MATRIX decode, full 32b)
  -> u_ethmac_0 -> cmsdk_ahb_to_apb -> ethmac_subsystem_apb
        paddr[15:12]==0 -> Port 0 = OpenCores MAC   (apb->WISHBONE bridge)
        paddr[15:12]==1 -> Port 1 = HA1588 PTP
READ-back @ the same peer addr -> byte-exact
```

Only die_b carries the subsystem (die_a → die_b relay direction). die_a's
`ahb_mng` (B→A path) is an idle always-ready sink. The tb harness is **identical
to the M1 bench** (`tb_top.sv`, `pad_skid.sv`, `eye_fault.sv`, `image_spin.hex`
copied verbatim) — only the *test* changed to target the register aperture, which
is exactly why the narrow shape is a small, low-risk step.

## The registers chosen (with reset values / RW justification)

### A. Known-constant / ID read: MAC MODER == `0x0000_A000`

`MAC.MODER @ 0x4000_0000` has a **genuine hardware reset value** (a flop, NOT
X-init), so reading it *cold* — with no prior write — proves a real register read
across the link. Golden value verified by the standalone subsystem cocotb bench
`ethernet-mac-ahb/cocotb/ethmac_subsystem_apb/test_ethmac_subsystem_apb.py:315`
(CP2.1: `MODER default expected 0xA000`), which drives the **identical**
AHB→APB→WISHBONE register path this bench crosses. Three further golden-reset
reads corroborate (all from the same repo's `VERIFICATION_PLAN.md` reset table
and asserted by the standalone tests):

| Register | Addr | Golden reset | Read across link |
|---|---|---|---|
| MODER     | `0x4000_0000` | `0x0000_A000` | ✅ `0x0000a000` |
| PACKETLEN | `0x4000_0018` | `0x0040_0600` | ✅ `0x00400600` |
| MIIMODER  | `0x4000_0028` | `0x0000_0064` | ✅ `0x00000064` |
| TX_BD_NUM | `0x4000_0020` | `0x0000_0040` | ✅ `0x00000040` |

### B. Scratch-safe RW write/readback: HA1588 SCRATCH @ `0x4000_1004`

`HA1588.SCRATCH` (offset `0x04` inside the HA1588 block at `+0x1000`) is a
**general-purpose SW scratch register with NO hardware side effects**
(`ethernet-mac-ahb/sys_desc/register_maps/ha1588.yaml:58-63`). It is the correct
RW-safe choice: the neighbouring `HA1588.RTC_CTRL @ +0x1000` is **unsafe** — its
bits are self-clearing *pulse actions* (`RTC_RST` resets the RTC counters,
`TIME_LD` loads time). Writing SCRATCH cannot perturb the RTC, the MAC, or any
datapath. Also proven RW by `test_ethmac_subsystem_apb.py:270-272` (CP1.2: PTP
SCRATCH write `0xDEADBEEF`/readback) and `ha1588_ahb/test_ha1588_ahb.py`
(walking-ones + `0xCAFEBABE`). Reaching `+0x1000` **lands inside the HA1588 PTP
block itself**, which is the actual grandmaster timestamp unit — the exact block
M2's PTP chain needs to reach across the link.

Six patterns written+read-back byte-exact: `0xDEADBEEF, 0xCAFEBABE, 0xA5A5A5A5,
0x5A5A5A5A, 0x00000000, 0xFFFFFFFF`.

## Findings (file:line)

1. **`eth_ss_0` reaches `ethmac_0` (no scratch-only restriction)** —
   `build_soc/reports/ethernet_ss_ahb_memory_map.txt` Initiator Connectivity
   line for `eth_ss_0`. This is what makes the narrow shape sufficient.
2. **MAC/HA1588 address split is `paddr[12]`** — `ethmac_subsystem_apb.v:127-131`
   (`DECODE4BIT = paddr[15:12]`; `159`): `0` → MAC (`0x0000-0x0FFF`), `1` →
   HA1588 (`0x1000-0x1FFF`). Within `ethmac_0` the AHB→APB bridge takes
   `HADDR[15:0]` (`ethmac_subsystem_ahb.v:138`), so `0x4000_1004` → `paddr
   0x1004` → HA1588 SCRATCH.
3. **The `ethmac_regs.rdl` MODER field defaults DISAGREE with the RTL reset**
   (a documentation drift, harmless here). The RDL (`ethmac_regs.rdl:78-88`) sets
   `CRCEN=HUGEN=PAD=RECSMALL=1`, which sums to `0x1E000`; the **RTL truth is
   `0xA000`** (only CRCEN+PAD), as asserted by the standalone tests and observed
   here. Trust the RTL/tests, not the RDL field arithmetic, for reset values.
4. **The register read path honours long WISHBONE wait-states end-to-end.** A MAC
   register read (AHB→APB→WISHBONE→APB→AHB→XHB500→FC→link→...) is *longer* latency
   than the M1 scratch-SRAM write, and the peer-window master's sustained-low +
   X-tolerant completion detector (inherited from M1's `EthAHBSubMaster`) handles
   it with no adapter — reads and writes both complete with `HRESP=OKAY`. This
   confirms the M1 "wait-state contract proven end-to-end" finding extends to the
   deeper WISHBONE register path.

## Contracts carried over from M1 (honoured here)

- **Identity address transform** (derived at run time from the tb `ahb_mng`
  monitor, not assumed): peer `0x4000_0000+off` → `ahb_mng 0x4000_0000+off`,
  `delta=0` (`tl_addr_trans_cam` global_enable=0, XHB500 passes `HADDR[31:0]`).
- **Single-beat only** — the peer-window + XHB AXI→AHB path emits single NONSEQ
  transfers (M1 finding #2); every register access here is one word.
- **X-init discipline** — HA1588 registers are X-init (write before read); the
  RW test always writes first. MAC MODER/PACKETLEN/etc. are the exception (real
  reset flops), which is exactly why they serve as cold-read ID constants.
- **Passive-slave simplifications** — `sys_fclk<-hclk` (no CDC), benign 25 MHz
  MII/RTC clocks (MAC datapath not exercised, no PHY), Cortex-M0+ parked via
  `image_spin.hex`. Same as M1.

## Files

| File | Purpose |
|---|---|
| `tb_top.sv`, `pad_skid.sv`, `eye_fault.sv`, `image_spin.hex` | **copied verbatim from the M1 bench** — the eth subsystem behind die_b `ahb_mng` via `eth_ss_0` is unchanged; the shape-A step is purely which addresses the test drives |
| `eth_pair_common.py` | M1 helpers + the MAC/HA1588 register addresses & golden reset values |
| `test_eth_regs_shape_a.py` | the register test (derive transform → 4 MAC const reads → HA1588 SCRATCH write/readback) |
| `Makefile` | VCS; tidelink V2 flist + the subsystem's own compile recipe (mirrors M1) |
| `transcript_tail.txt` | the passing run |

## Run

```bash
cd cocotb/eth_tidelink_pair_shape_a
source ../../set_env.sh
source ~/SoCLabs/nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh
export TIDELINK_PHY_V2=1
make                         # EPOCH_PROFILE=zero -> THE SHAPE-A GATE (PASS)
```

(The `cfs_ident_exec` SIGSEGV during compile is a harmless Verdi KDB
post-processing step — elaboration reports `0 error(s), 0 warning(s)`, `simv`
builds and runs; identical to the M1 bench.)

## Remaining gap to the full PTP grandmaster chain

This bench proves **register visibility** (the M2 prerequisite): a real MAC and a
real HA1588 register are read/written across the chiplet link. The remaining gap
to the full grandmaster chain (HA1588 timestamping a real event → PHC → TideLink
PTP → far die):

1. **HA1588 must timestamp a real (or loopback) MII event, not just answer
   register reads.** Here the MAC datapath is *not* exercised (benign MII clocks,
   no PHY, no frame in the MAC RX ring). M1b/§5 of the arch doc — put the MAC in
   internal loopback so HA1588 taps a real TX→RX edge and captures
   `rtc_time_ptp_{ns,sec}` — is still to do. Without it, any "timestamp" is
   synthetic (arch §9 risk 3).
2. **The HA1588 → PHC servo hop is not wired in this bench.** The subsystem here
   is the *base* `ethernet_ss_ahb`, whose `ethmac_subsystem_apb` exposes the
   `ha1588_hw_*` servo bus, but the **PHC (`phc_ahb`) is not instantiated** — the
   `d2d_phc_*` servo source-0 chain (`nanosoc_eth_chiplet.sv:299-310`) lives in
   the chiplet repo, above `tidelink_top`. `tidelink_top`'s `phc_*` ports are
   tied off in this tb (as in M1). Closing this needs the PHC-variant subsystem
   (or the chiplet top) and a servo co-sim.
3. **TideLink PTP TX (`ahb_ptp` @ `0x2E02_0000` / `tl_ptp_irq`) is not driven.**
   The PTP Sync/Follow-Up/Delay-Req messages that must ride the same relay path
   are not generated here; that is the `tidelink_ptp` / `tidelink_ptp_servo`
   integration, tied off in this tb.
4. **Grandmaster election finding G1 (dual-root)** remains open (arch §6,
   `nanosoc_eth_chiplet.sv:357`) — the role must be pinned, not auto-elected.
5. **True Shape-A escalation (`ahb_mng → d2d_ahb_s → multicore matrix`) is only
   needed to reach the *rest* of the SoC** (CPUs, mailbox, apb_periph), NOT for
   MAC/HA1588 registers (Finding 1). If a future test needs the far die to reach
   a CPU-side mailbox or the SoC's own PHC region, that is when the chiplet-repo
   `chiplet_d2d_decode` + multicore SoC subset must be instantiated.

So: **register visibility into MAC + HA1588 across the link — PROVEN. The live
timestamp→servo→PTP-message loop — still ahead**, and it needs the PHC + the
MAC-loopback event source + the TideLink PTP TX, none of which this bench (or M1)
instantiates.

## Provenance / rules honoured

- **This lane's footprint = this new `cocotb/eth_tidelink_pair_shape_a/` dir
  only.** No `targets/`, root `Makefile`, `hw_regression/`, or shared-RTL edits.
  The ethernet repos, the M1/pair_v2 benches, and `tidelink_top` are read-only
  references.
- **No `/research/AAA/**` writes** — the OpenCores MAC, HA1588, and Cortex-M0+
  are flist-referenced (read) only.
- **Not committed** (per the lane brief).
