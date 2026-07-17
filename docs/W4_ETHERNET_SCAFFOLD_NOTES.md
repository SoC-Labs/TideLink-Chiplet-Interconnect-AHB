# W4 Ethernet Chiplet — Scaffold Notes (concrete next steps)

> Companion to [ETHERNET_CHIPLET_INTEGRATION.md](ETHERNET_CHIPLET_INTEGRATION.md).
> This file is the **scaffold**: the concrete implementation steps, the target
> dir skeleton, flist deltas, and the cocotb smoke design — with effort
> estimates. **No FPGA target dirs are created here** (they would collide with
> the W1 build lane); this notes file *is* the scaffold, W1 (or a follow-on)
> materialises the dirs.

## 0. Where the work lands (lane boundaries)

- **W4 (this lane) footprint in tidelink = new `docs/` files ONLY.** No
  `targets/`, `Makefile`, `hw_regression/`, or `pynq_host/scripts/` edits.
- The FPGA target dir (`fpga/targets/kr260-eth-chiplet/`) is a **W1** deliverable
  — its skeleton is specified below so W1 can materialise it without re-deriving
  it.
- The cocotb smoke *can* be W4-authored as a new `cocotb/` dir (does not collide),
  but is written here as a design so it can be reviewed before the RTL wiring
  exists. Recommend landing it on `feat/ethernet-chiplet-integration`.

## 1. FPGA target skeleton — `fpga/targets/kr260-eth-chiplet/` (DO NOT CREATE YET)

Model it on `fpga/targets/kr260-pair-nptp/` (die_a) + `kr260-pair-flip-nptp/`
(die_b). The delta from the bare-link target is: instantiate
`nanosoc_eth_chiplet` instead of bare `tidelink_top`, and terminate `ahb_mng` in
the SoC (`d2d_ahb_s`) instead of `tidelink_ahb_mng_bram.v`.

```
fpga/targets/kr260-eth-chiplet/            (die_a, strap=0, master)
├── tidelink_design.tcl            # BD: instantiate nanosoc_eth_chiplet;
│                                  #     wire PS AXI HPM -> ctrl/data/APB;
│                                  #     eth boundary tied for M1 (no PHY)
├── tidelink_design_wrapper.v      # top wrapper: nanosoc_eth_chiplet + PS BD
├── kr260_tidelink.xdc             # J21 ribbon pins (copy from kr260-pair-nptp)
├── kr260_tidelink_timing.xdc      # link timing constraints (copy)
├── kr260_tidelink_drc.xdc         # DRC waivers (copy)
├── kr260_tidelink_extrefclk.xdc   # ext ref clk (copy)
├── kr260_ethchiplet.xdc           # NEW: eth boundary — M1 ties rmii idle;
│                                  #      M2 adds PMOD RMII pins (LAN8720)
├── tidelink_phy_clk_div2.v        # link clock /2 (copy)
├── ribbon_wiring.md               # copy; note eth-chiplet variant
└── (NO tidelink_ahb_mng_bram.v)   # removed — SoC is the ahb_mng terminus

fpga/targets/kr260-eth-chiplet-flip/       (die_b, strap=1) — same, flip XDC
```

**Build knobs (must match the KR260 port constraints):**
- `TIDELINK_PHY_V2=1` (or you build a fix-less V1 bitstream), `TIDELINK_SOC=kr260`.
- `USE_IDELAY=0` (HDIO bank 44 can't host IDELAY), `IOB FALSE` on `pad_rx`.
- `HARDEN_SWI_ENABLE=0` (per R6, matches the deployed kr260 tcls).
- Do **not** inject `TD_AUTO_LANE_MASK_E4` if the 8-lane widening work lands
  (memory §0) — orthogonal to this lane, but the target inherits the recipe.

**Open scoping question (RISK 1 in the arch doc):** the full multicore+eth+link
may not fit/close timing on `xck26`. **Fallback = Shape B** — a smaller target
that hangs the ethernet subsystem (`ethernet_ss_ahb`) directly off `ahb_mng`
(via `eth_ss_0`) without the full multicore SoC. Skeleton is the same minus
`u_soc`; the wrapper instantiates `ethernet_ss_ahb` + a small AHB glue from
`ahb_mng` to `eth_ss_0`.

## 2. Flist deltas

Existing relevant flists:
- `flists/tidelink_fpga_v2.flist` — the V2 FPGA link (used by the pair sim).
- `flists/tidelink_top_full_asic_v2.flist` — ASIC.

New flists needed (materialised with the target, not now):

```
flists/tidelink_eth_chiplet_fpga.flist        # NEW
  -f flists/tidelink_fpga_v2.flist             # the V2 link (deskew override etc.)
  # chiplet integration (from nanosoc-ethernet-chiplet):
  <chiplet>/src/rtl/chiplet_d2d_decode.sv
  <chiplet>/src/rtl/nanosoc_eth_chiplet.sv
  <chiplet>/src/rtl/tidechart_shim.sv          # optional (M1 can omit TideChart)
  # multicore SoC + ethernet subsystem (from nanosoc-multicore-system):
  -f <multicore>/flist/nanosoc_multicore_soc.flist
  # which pulls ethernet_ss_ahb + ethmac_subsystem_ahb, and (read-only):
  #   ETHMAC_IP_DIR=/research/AAA/ip_library/OpenCores-EthMAC  (flist-ref only)
  #   HA1588_IP_DIR=/research/AAA/ip_library/OpenCores-HA1588  (flist-ref only)
```

**Flist rules to honour (memory landmines):**
- Merge ONTO integ; never resolve `FCSM_6`/`fc_adapter`/flists toward `dieb`
  (reverts the A→B credit fix — tapeout chip-killer).
- The ASIC flist has **no deskew override** — an eth-chiplet ASIC flist must add
  `local_overrides/tidelink_lane_deskew_v2.sv` (known gap) before M3.
- `-verilog_define` does NOT reach a packaged-IP OOC synth — if the chiplet is
  packaged as IP, the `TIDELINK_PHY_V2` define must ride in the flist's v2 shims,
  not on the synth command line (see `project_verilog_define_never_reaches_ooc_ip`).

## 3. Cocotb integration smoke (M0) — design

**Reference harness:** `cocotb/tidelink_top_pair_v2/` (`tb_top.sv` +
`pair_v2_common.py` + `Makefile`). It already instantiates two cross-wired
`tidelink_top` dies with GPIO-PHY skew injection, an APB config port per die, and
**a per-die `ahb_mng` BRAM terminus** (`tb_ahb_bram_slave`, tb_top.sv:360-420).
The M0 smoke swaps that BRAM terminus for the ethernet subsystem's `eth_ss_0`.

**New dir:** `cocotb/tidelink_eth_chiplet_pair/` (does NOT collide with other
lanes). Skeleton:

```
cocotb/tidelink_eth_chiplet_pair/
├── tb_top.sv          # fork of tidelink_top_pair_v2/tb_top.sv, with die_b's
│                      # ahb_mng terminus = ethernet_ss_ahb.eth_ss_0 instead of
│                      # the scratch BRAM (Shape B — subsystem alone, no full SoC,
│                      # to keep the sim small and fast).
├── Makefile           # fork of the pair_v2 Makefile; VERILOG_SOURCES adds the
│                      # eth flist; MODULE=test_eth_relay_smoke
├── eth_pair_common.py # extends pair_v2_common.py: eth_scratch addr helpers,
│                      # frame-builder (ARP/UDP), HA1588 reg reads
└── test_eth_relay_smoke.py
```

**Test `test_eth_relay_smoke.py` (the smoke):**
1. Bring the pair up (reuse `pair_v2_common` bring-up: cal/fcsm, link_active).
2. From die_a, write a small frame (e.g. 64 B ARP request) across die_a's **peer
   window** (`0x2F00_0000 + far_off`) where `far_off` targets die_b's
   `eth_scratch_rx` range.
3. Read die_b's `eth_scratch_rx` (locally in the TB, on die_b's `eth_ss_0`
   slave) and assert the frame bytes are **byte-exact**.
4. (Stretch) put die_b's MAC in loopback, confirm HA1588 captured a timestamp
   (read `rtc_time_ptp_ns/sec` at MAC `+0x1000`), assert non-zero + monotone.

**Profiles / knobs:** reuse `EPOCH_PROFILE=zero` (clean skew) for the first pass;
`silicon` profile later to prove the relay survives the realistic skew fingerprint.

**Wire into the gate:** add the dir to the root `make sim_gate` aggregate **only
after it passes standalone** (do not co-schedule with a Vivado build — OOM mimics
a regression). Note: this is a `Makefile`/`hw_regression` edit = another lane's
file, so W4 hands the "add to sim_gate" step to that lane rather than editing it.

## 4. Effort estimates

| Item | Effort | Depends on | Owner lane |
|---|---|---|---|
| M0 cocotb smoke (Shape B, frame relay only) | **0.5–1 day** | pair_v2 harness (exists); ethernet_ss_ahb elaborates in sim | W4 / integration |
| M0 + HA1588 timestamp assertion (stretch) | **+0.5 day** | MAC loopback config in sim | integration |
| `kr260-eth-chiplet` FPGA target skeleton (Shape A) | **1–2 days** | `nanosoc_eth_chiplet` builds for xck26 (unproven — RISK 1) | W1 |
| Scoping synth: does multicore+eth+link fit/close on xck26? | **0.5–1 day** | clean HEAD of chiplet + multicore submodules | W1 |
| Fallback `kr260-eth-chiplet` Shape B (subsystem alone) | **1 day** | Shape A synth fails | W1 |
| M1 firmware (frame stage + peer-window push + PTP exchange) | **2–3 days** | M0 sim green; PicoTCP stack (exists) | firmware |
| `eth_irq` NVIC hookup verify + fix if needed | **0.25 day** | read multicore SoC RTL | integration |
| M2 PMOD RMII (XDC + rmii_to_mii + PHY bring-up) | **2–4 days** | M1 working; PMOD LAN8720 adapter on the bench | W1 + firmware |
| M3 ASIC alignment (flist + deskew + finding G1) | **2–3 days** | M1 proven | ASIC |

**Critical path to a demo:** M0 smoke (1 day) → xck26 scoping synth (1 day) →
FPGA target (1–2 days) → M1 firmware (2–3 days) ≈ **1 working week** to a KR260
no-PHY ethernet-over-TideLink demo, assuming the full SoC closes timing on xck26
(else +1 day for the Shape-B fallback).

## 5. First three things to do (in order)

1. **Materialise `cocotb/tidelink_eth_chiplet_pair/` M0 smoke** (Shape B). Fastest
   proof the attach works; needs no board and no FPGA build. Fork
   `tidelink_top_pair_v2/tb_top.sv`, swap die_b's `ahb_mng` BRAM for
   `ethernet_ss_ahb.eth_ss_0`, relay a frame die_a→die_b, assert byte-exact.
2. **Scoping synth of `nanosoc_eth_chiplet` for xck26** (W1) — answers RISK 1
   before anyone invests in the full FPGA target.
3. **Verify `eth_irq` NVIC delivery** in `nanosoc_multicore_soc` — cheap, and it
   decides whether M1 firmware can rely on interrupt-driven RX or must poll.
