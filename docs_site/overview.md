# Overview

## What TideLink is

TideLink is a **chiplet die-to-die interconnect subsystem**: a single RTL block
that a host SoC instantiates on each of two dies so that the two behave, from
the bus point of view, like one system.

The top level is `tidelink_top` (`src/rtl/tidelink_top.sv`, 2786 lines). Its
parameter block spans lines 39–229 (**30** parameters), its port list lines
230–555, and it instantiates 13 direct children. It presents to the host:

- four **AHB subordinate** ports — `ahb_sub_*` (transparent remote access),
  `ahb_tx_*` (mailbox TX aperture), `ahb_fifo_*` (local RX FIFO window) and
  `ahb_ptp_*` (PTP TX write port);
- one **AHB manager** port — `ahb_mng_*`, where the peer die's transparent
  traffic re-emerges;
- one **unified APB subordinate** port, 15-bit address, carrying every
  configuration and observability register in the subsystem;
- the **PHY pads** — `pad_clk_tx`, `pad_tx[7:0]`, `pad_clk_rx`, `pad_rx[7:0]`;
- an **I²C sideband** for autonomous role negotiation, plus PTP hardware-clock,
  interrupt, and AXI-Stream extension interfaces.

Everything crosses the wire as 8 source-synchronous GPIO lanes plus a forwarded
clock. There is no SerDes, no PLL-recovered clock on the receive side, and no
analogue PHY: the link is deliberately buildable in plain digital logic on an
FPGA and in a standard-cell ASIC flow.

## The problem it solves

Splitting an SoC into chiplets breaks the bus. Two problems follow, and TideLink
answers each with a different path.

**1. Remote memory should still look like memory.** Software should be able to
read and write across the die boundary without knowing there is a link in the
way. TideLink's **transparent path** does this: `ahb_sub_*` → address
translation → XHB500 AHB-to-AXI → five independently credited AXI channel
streams over the link → XHB500 AXI-to-AHB → the peer's `ahb_mng_*`. The full
address is forwarded and the peer decodes it.

**2. But a blocking bus cannot absorb link latency.** AHB has no SPLIT/RETRY,
and Cortex-M-class bus matrices have no mechanism to release the CPU while a
transfer is outstanding. A transparent read that has to traverse the PHY, the
link layer, the peer, and back will simply stall the processor for the whole
round trip. So TideLink also provides a **credited mailbox path**: the host
posts words into the `ahb_tx_*` aperture, they are packed into 48-bit
flow-control words, carried over the same link, and written into a 16 KB
credited RX FIFO on the far die, which the peer drains at its own pace through
`ahb_fifo_*`. Nothing blocks; back-pressure is expressed as credit.

The two paths share one PHY, one link layer and one APB register space. Which
one to use is an integration decision, covered in {doc}`integration`.

## Top-level block diagram

```{mermaid}
flowchart LR
    subgraph HOSTA["Host SoC — die A"]
        CPUA["CPU / bus matrix"]
    end

    subgraph TLA["tidelink_top"]
        direction TB
        XLAT["tidelink_addr_translator<br/>8-rule CAM remap"]
        XHBS["xhb500_ahb_to_axi<br/>u_xhb_sub"]
        XHBM["xhb500_axi_to_ahb<br/>u_xhb_mng"]
        FCA["tidelink_fc_adapter<br/>48-bit FC words, TX skid"]
        FIFO["tidelink_fifo<br/>16 KB RX FIFO + APB regs + returner"]
        PTPB["tidelink_ptp / ptp_servo / phc_cdc"]
        ACC["axi_chiplet_controller<br/>Wlink link layer + GPIO PHY<br/>+ I2C + autoneg + calibrator"]
    end

    PADS(["pad_clk_tx / pad_tx[7:0]<br/>pad_clk_rx / pad_rx[7:0]"])

    subgraph TLB["tidelink_top — peer"]
        PEER["mirror-image instance"]
    end

    subgraph HOSTB["Host SoC — die B"]
        CPUB["CPU / bus matrix"]
    end

    CPUA -->|"ahb_sub_*"| XLAT --> XHBS -->|"s_axi_*"| ACC
    CPUA -->|"ahb_tx_*"| FCA --> ACC
    CPUA -->|"apb_* 15-bit"| ACC
    CPUA -->|"ahb_ptp_*"| PTPB --> FCA
    ACC -->|"m_axi_*"| XHBM -->|"ahb_mng_*"| CPUA
    ACC --> FCA --> FIFO -->|"ahb_fifo_*"| CPUA

    ACC <--> PADS
    PADS <--> PEER
    PEER <--> CPUB
```

The APB decode inside `tidelink_top` (`src/rtl/tidelink_top.sv:825-827`) splits
that single port three ways: `0x0000–0x1FFF` to the chiplet controller and
Wlink, `0x2000–0x3FFF` to the TideLink, PTP and role registers, and
`0x4000–0x5FFF` to the address translator. See {doc}`register_map`.

## Key features

::::{grid} 1 1 2 2
:gutter: 2

:::{grid-item-card} Two transport paths, one PHY
A transparent AHB↔AXI bridge path for remote-memory semantics, and a credited
16 KB mailbox path for posted, non-blocking bulk transfer.
:::

:::{grid-item-card} Source-synchronous GPIO PHY
8 data lanes plus a forwarded clock. Per-lane bit-slip and 16-step sub-bit
phase calibration, cross-lane deskew, and a lane checker that locks on a
per-lane training pattern.
:::

:::{grid-item-card} Credit-based flow control
Two independent credit systems: the Wlink link-layer credit ring
(CR/CRACK/ACK/NACK short packets with a replay FIFO) and the application-level
mailbox credit counter with clamp and saturate guards.
:::

:::{grid-item-card} Hardware autonomy
Two identical dies negotiate master/slave over an I²C sideband before role
lock, then train, exchange credits and reach data mode with no firmware in the
loop. A strap fallback keeps this working on a dead I²C bus.
:::

:::{grid-item-card} PTP time distribution
SYNC (`0x50`) and DELAY_REQ (`0x51`) Wlink short packets, idle-gated hardware
timestamp capture, and a PI servo that closes the clock-sync loop in hardware
rather than in firmware.
:::

:::{grid-item-card} Deep observability
Autoneg state, calibrator state, FC credit values, RX-framer stickies, AXI
data-node health and cross-lane deskew health are all readable over APB —
built to replace Vivado ILA captures with a one-second register read.
:::

::::

### Numbers worth knowing

| Property | Value | Source |
|---|---|---|
| PHY lanes | 8 data + 1 forwarded clock | `NUM_PHY_LANES = 8`, `tidelink_top.sv:51` |
| Link word | 128 bit (8 lanes × 16 bit) | PHY TX segmenter, `WavD2DGpio` |
| FC word | 48 bit — `[47:46]` type, `[45:32]` offset, `[31:0]` payload | `tidelink_fc_adapter.sv:13,152-158` |
| RX FIFO / TX aperture | 16 KB (`RAM_ADDR_W = 14`) | `tidelink_top.sv:43` |
| Mailbox credits | 4096 32-bit words (`MAX_CREDITS = 1 << (RAM_ADDR_W-2)`) | `tidelink_fifo_ctrl.sv` |
| Internal AXI | 12-bit ID, 36-bit address, 32-bit data | `tidelink_top.sv:562-645` |
| APB port | 15-bit address, one unified port | `tidelink_top.sv:825-827` |
| Top-level parameters | 30 (22 of them on the Vivado IP face) | `tidelink_top.sv:39-229`; `fpga/vivado_ip/tidelink_vivado_wrapper.v:42-201` |

## Status summary

TideLink is a **working, silicon-intent subsystem under active bring-up**, not a
finished product. The honest position as of the documented tree
(`fix/z2-drop-park-hook` @ `9eaafb7`):

| Area | Status |
|---|---|
| **RTL** | Mature. 62 files, ~50,000 lines under `src/rtl`. Elaborates for FPGA (V1 and V2 PHY), ASIC, and the DFT wrapper skeleton. |
| **Simulation gate** | 43 blocking suites plus 2 known-defect sentinels, run by `make sim_gate`. The suite list and wiring cross-check are printed by `make sim_gate_inventory`. |
| **CDC sign-off** | SpyGlass re-run 2026-05-28 at integration SHA `6666c1be`: 0 fatals, 0 errors, 4 warnings (none CDC), 0 unsynchronised crossings, 0 convergences — verdict **GO** (`docs/reference/SPYGLASS_CDC_SIGNOFF.md`). |
| **FPGA** | 22 build targets (`fpga/Makefile:56`). The KR260 on-chip pair — two dies in one bitstream — is the proven vehicle; a sustained soak on 2026-07-23 moved 30,500 byte-exact packets with zero wedges. |
| **PYNQ-Z2 pair** | Works, but bring-up is a genuine marginal-eye lottery; the converge script re-rolls it. |
| **ASIC** | Synthesis and place-and-route flows exist (`syn/asic/`, `flows/makefile.asic`). The DFT wrapper `src/rtl/asic/tidelink_dft_wrapper.sv` is explicitly a **skeleton** — scan bus and MBIST tunnels, no BIST controller and no TAP. |
| **UVM** | Seven environments compile, elaborate and link. `uvm-top-system` has a live functional blocker and its CI job remains `allow_failure: true`. |
| **Bug registry** | 17 tracked bugs (TL-001…TL-017) in `docs/BUG_REGISTRY.yaml`: 1 open rank-1 critical, 0 open functional-high, 2 open tapeout-high. |

:::{warning}
**Two trees diverge.** The recovery, PTP and header-ECC fixes live on
`integ/axirec-on-chiplet`; the standalone branch documented here carries none
of them, so several registry items are structurally open *here* even though the
RTL fix exists *there*. Neither line is on `main`. See {doc}`known_issues`.
:::

:::{danger}
**There are hardware hazards that destroy a board or hang a CPU.** An
`ahb_tx_*` write on a link that is not fully up wedges the PS and needs a
physical power cycle; several APB offsets hard-stall the CPU on read; a KR260
never returns from `sudo reboot`. Read the hazard tables in
{doc}`register_map` and {doc}`boards` **before** touching hardware.
:::

## Where to go next

- {doc}`architecture` — the module tree, the four traffic planes, and the PHY
  and link-layer structure.
- {doc}`functionality` — bring-up sequencing, flow control, the end-to-end data
  path, and PTP.
- {doc}`register_map` — every APB region, plus the never-probe list.
- {doc}`verification` — how to run the gate and what its verdicts mean.
