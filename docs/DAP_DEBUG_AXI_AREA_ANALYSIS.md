# DAP Debug AXI Node Area Overhead Analysis for TideLink WLINK

## Context

The goal is to evaluate the area cost of adding a dedicated AXI debug path through the WLINK chiplet interconnect, allowing an Arm SoC-400 DAP AHB-AP to transparently access processor debug infrastructure (DHCSR, FPB, DWT, SCB at `0xE000_xxxx`) on a remote die. On Cortex-M processors, debug is accessed via AHB — so an AXI node through WLINK is required.

Currently TideLink has a single AXI channel for system bus traffic. A dedicated debug AXI channel avoids contention and provides an isolated debug path.

## Current Baseline (DC synthesis, TSMC 65nm @ 250 MHz)

**Total tidelink_top: 431,856 µm²**

Current AXI node breakdown (5 FC channels, `beatBytes=4, idBits=12, dataFifoSize=32, nonDataFifoSize=8`):

| AXI FC Channel | Area (µm²) | Key Cost Driver |
|----------------|-----------|-----------------|
| AW (Address Write) | 20,522 | 101-bit × 8-deep non-data FIFO |
| W (Write Data) | 34,498 | 37-bit × 32-deep replay FIFO (22,285 µm²) |
| B (Write Response) | 12,182 | 14-bit × 8-deep non-data FIFO |
| AR (Address Read) | 20,866 | 101-bit × 8-deep non-data FIFO |
| R (Read Data) | 31,534 | 47-bit × 32-deep replay FIFO (20,095 µm²) |
| **AXI Total** | **119,602** | **Replay FIFOs dominate (42K of 120K)** |

## Analysis Approach

### Step 1: Create WLINK Chisel Config Variants

Add new config classes to `WlinkConfigs.scala`. Three variants, all keeping the existing system AXI + GeneralBus + TideLink FC + PTP nodes unchanged:

**Variant A — Second AXI, full-size (upper bound):**
Same params as the system AXI node (`beatBytes=4, idBits=12, dataFifoSize=32, nonDataFifoSize=8`). Worst-case area reference.

```scala
class WithWlinkTideLinkDapFullConfig(/* ... */) extends Config((site, here, up) => {
  case WlinkParamsKey => WlinkParams(
    // ... existing phyParams, gbParams, tideLinkParams, shortPacketParams ...
    axiParams = Some(Seq(
      WlinkAxiParams(base=0x0, size=size, beatBytes=4, idBits=12, name="axi_sys"),
      WlinkAxiParams(base=0x0, size=size, beatBytes=4, idBits=12, name="axi_dap",
        startingLongDataId=0x90, startingShortDataId=0x20)
    ))
  )
})
```

**Variant B — Second AXI, DAP-optimized (target):**
Reduced FIFOs and ID width for single-outstanding DAP traffic.

```scala
WlinkAxiParams(base=0x0, size=size, beatBytes=4, idBits=4, name="axi_dap",
  dataFifoSize=4, nonDataFifoSize=4,
  startingLongDataId=0x90, startingShortDataId=0x20)
```

**Variant C — Second AXI, minimal (lower bound):**
Absolute minimum — 1-bit ID, depth-2 FIFOs.

```scala
WlinkAxiParams(base=0x0, size=size, beatBytes=4, idBits=1, name="axi_dap",
  dataFifoSize=2, nonDataFifoSize=2,
  startingLongDataId=0x90, startingShortDataId=0x20)
```

### Step 2: Generate Verilog for Each Variant

```bash
cd deps/axi-chiplet-controller/wav-wlink-hw
make wlink CONFIG=wav.wlink.Wlink8LaneAXI32bitTideLinkDapFullConfig    OUTPUTDIR=output_dap_full
make wlink CONFIG=wav.wlink.Wlink8LaneAXI32bitTideLinkDapOptConfig     OUTPUTDIR=output_dap_opt
make wlink CONFIG=wav.wlink.Wlink8LaneAXI32bitTideLinkDapMinConfig     OUTPUTDIR=output_dap_min
```

### Step 3: Synthesize Each WLINK Variant

Use the existing DC flow to synthesize each WLINK variant standalone:

```bash
cd syn/asic/design-compiler
make syn MODULE=wlink_dap_full
make syn MODULE=wlink_dap_opt
make syn MODULE=wlink_dap_min
```

This isolates WLINK-only area delta without `tidelink_top` wrapper noise. Compare the `area.rpt` hierarchy breakdown for each, specifically the new `axi2wl_1` (second AXI node) sub-hierarchy.

### Step 4: Estimate Total Integration Cost

For each variant, the total additional area = WLINK delta + XHB500 bridge pair + address translator channel:

| Component | Estimate | Notes |
|-----------|----------|-------|
| Second AXI FC channels (WLINK) | Measured in Step 3 | Primary variable |
| XHB500 AHB→AXI bridge (local) | ~10-15K µm² | DAP AHB master → AXI tgt |
| XHB500 AXI→AHB bridge (remote) | ~10-15K µm² | AXI ini → remote AHB bus |
| Address translator ch1 (per die) | ~3-5K µm² | 8-rule CAM + APB regs, already coded |

XHB500 area can be measured from the current baseline — the existing pair is in the `tidelink_top` local logic (135K total, minus 89K SRAM = 46K logic, which includes XHB500 pair + FIFO + FC adapter + addr translator ch0 + APB mux).

### Step 5: Results Comparison Table

| Variant | WLINK Delta (µm²) | + XHB500 Pair | + Addr Trans ch1 | Total Delta | % Increase over 432K |
|---------|-------------------|---------------|-----------------|-------------|---------------------|
| A (full) | ~120K (est.) | ~20-30K | ~3-5K | ~143-155K | ~33-36% |
| B (DAP-opt) | ~60-70K (est.) | ~20-30K | ~3-5K | ~83-105K | ~19-24% |
| C (minimal) | ~40-50K (est.) | ~20-30K | ~3-5K | ~63-85K | ~15-20% |

## Data Path (SoC-400 Integration)

```
Local Die (DAP side):
  DAP AHB-AP (AHB master)
    → AHB bus fabric
      → Address Translator ch1 (APB-configurable remap)
        → XHB500 AHB→AXI bridge
          → WLINK axi_tgt_1 (new)
            → [chiplet link, 8 GPIO lanes]

Remote Die:
            → WLINK axi_ini_1 (new)
          → XHB500 AXI→AHB bridge
        → Address Translator ch1 (APB-configurable remap)
      → AHB bus fabric
    → Cortex-M debug regs (0xE000_xxxx)
    → System memory (for flash programming)
```

## Address Translator for DAP Path

The address translator is **required** for the DAP path in a non-specific chiplet configuration. The DAP AHB-AP issues accesses using the local die's address view, but the remote die may have a different memory map. The runtime-configurable CAM rules remap addresses appropriately.

The existing `tidelink_addr_translator` module already supports a second channel:
- Module default: `NUM_CHANNELS=2`, `NUM_RULES=8` per channel
- Current instantiation: `NUM_CHANNELS=1` at `tidelink_top.sv:1307`
- Channel 1 logic (regs + CAM) is already coded in the `generate` block at `tidelink_addr_translator.sv:157`
- **Change needed**: Set `NUM_CHANNELS=2` and wire channel 1 to the DAP AHB path

Each channel adds: 1× `tl_addr_trans_regs` (8 APB-accessible rules) + 1× `tl_addr_trans_cam` (combinational address remap). Estimated area: ~3-5K µm².

## Key Files to Modify

| File | Change |
|------|--------|
| `WlinkConfigs.scala` | Add 3 new config classes (variants A/B/C) |
| `Wlink Makefile` | No change — use existing `make wlink CONFIG=...` |
| `tidelink_top.sv` | Set `NUM_CHANNELS=2`, add XHB500 pair, wire DAP AXI/AHB ports |
| `tidelink_addr_translator.sv` | No change — channel 1 already implemented |
| `DC common.mk` | Add WLINK-only synthesis targets for each variant |
| `flist/` | Add variant-specific filelists pointing to each generated output dir |

## DAP-Specific Design Considerations

- **Single outstanding**: AHB-AP issues 1 transaction at a time for debug register access → `idBits=4` and small FIFOs are safe
- **Flash programming**: If AHB-AP is used for bulk memory download, it can burst → consider `dataFifoSize=8` minimum for Variant B
- **Latency**: Debug probes (DSTREAM, ULINKpro, J-Link) tolerate multi-cycle wait states — WLINK round-trip latency is acceptable
- **Address space**: DAP AHB-AP has full 32-bit address range — `size` parameter should match system address space
- **Address translation**: Required on both dies — local die remaps DAP addresses to remote address space, remote die may need further remapping to local peripherals. Each die's TideLink instance runs `NUM_CHANNELS=2` on its address translator
- **Packet ID allocation**: System AXI uses 0x80-0x8F (long) and default short IDs. DAP AXI must use non-colliding IDs (0x90+ long, 0x20+ short)

## Verification

- Reuse existing `cocotb/tidelink_top/` testbench framework
- Add DAP-style single-beat read/write sequences through the new AXI path
- Verify round-trip latency and that system AXI traffic is unaffected
- Chisel `WlinkApplicationLayerChecks` automatically validates packet ID collisions at generation time
