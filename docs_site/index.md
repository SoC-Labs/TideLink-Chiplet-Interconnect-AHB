# TideLink

**TideLink is a chiplet die-to-die interconnect subsystem.** It carries AXI and
AHB traffic between two dies over a source-synchronous GPIO PHY, using Wlink
flow-control nodes for credit-based transport and the Arm XHB500 AHB↔AXI
bridges to present a normal bus face to the host SoC on each side.

It is developed by [SoC Labs](https://soclabs.org) at the University of
Southampton. The RTL top level is `tidelink_top`
(`src/rtl/tidelink_top.sv`, 2786 lines, 30 parameters, 13 direct child
instances) and it runs today on PYNQ-Z2 and KR260 FPGA vehicles as well as in
an ASIC synthesis and place-and-route flow.

## What it gives you

A host SoC instantiates `tidelink_top` and gets **two complementary
cross-chiplet paths**:

- **A transparent bridge path.** An AHB subordinate port (`ahb_sub_*`) whose
  transactions are address-translated, converted to AXI by XHB500, carried over
  the link as five per-channel flow-controlled streams (AW/W/B/AR/R), and
  re-emitted as AHB on the peer die's manager port (`ahb_mng_*`). Remote memory
  looks like local memory.
- **A credited mailbox path.** A TX aperture (`ahb_tx_*`) and an RX FIFO window
  (`ahb_fifo_*`) that move packets into a 16 KB credited buffer on the far die.
  This path exists because AHB is blocking and Cortex-M bus matrices have no
  SPLIT/RETRY — a long link round-trip on the transparent path stalls the CPU,
  whereas the mailbox path is posted and credit-gated.

Alongside those, TideLink distributes **time** (IEEE-1588-style PTP over Wlink
short packets, closed by a hardware servo), negotiates **roles** over an I²C
sideband so two identical dies can decide master/slave without firmware, and
exposes a deep **observability** surface over a single unified APB port.

## Who this is for

::::{grid} 1 1 2 2
:gutter: 3

:::{grid-item-card} SoC integrators
Instantiating `tidelink_top` in a host design: which ports to connect, which
to tie off, which parameters are safe to change, and where the wedge hazards
are.

Start with {doc}`overview`, then {doc}`integration` and {doc}`parameters`.
:::

:::{grid-item-card} Firmware and host-software authors
Driving the link from a CPU: the APB register map, the address apertures, the
bring-up sequence and the registers that must never be probed.

Start with {doc}`register_map`, then {doc}`bringup`.
:::

:::{grid-item-card} Verification engineers
Running and extending the gate: 43 blocking simulation suites plus sentinels,
the cocotb and UVM environments, lint and CDC sign-off.

Start with {doc}`verification`, then {doc}`simulation_tests`.
:::

:::{grid-item-card} Board and bring-up engineers
Building bitstreams, deploying to PYNQ-Z2 and KR260, and running the numbered
hardware test suite without wedging a board.

Start with {doc}`boards`, then {doc}`hardware_tests`.
:::

::::

## Contents

```{toctree}
:maxdepth: 2
:caption: Introduction

overview
architecture
functionality
```

```{toctree}
:maxdepth: 2
:caption: Integration

register_map
integration
parameters
```

```{toctree}
:maxdepth: 2
:caption: Verification

verification
simulation_tests
hardware_tests
```

```{toctree}
:maxdepth: 2
:caption: Hardware

boards
bringup
```

```{toctree}
:maxdepth: 2
:caption: Reference

known_issues
build_registry
contributing
```

## A note on sources

Every page in this site is written against the RTL and the in-repo runbooks,
and cites them by path and line. Where a long-standing document in `docs/`
disagrees with the instantiated RTL, **the RTL is authoritative** and the page
says so explicitly. Known doc-versus-RTL divergences are collected in
{doc}`known_issues`.
