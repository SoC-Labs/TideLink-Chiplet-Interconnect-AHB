# TideLink — Documentation

The product documentation set for the **TideLink** chiplet-interconnect
subsystem (Wlink link layer + XHB500 + FIFO + a dedicated flow-control node +
the GPIO PHY consumed from `deps/tidelink-gpio-phy`), organised by category.

| Document | Covers |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Component/module map and hierarchy, the four AHB ports + APB, clock/reset/CDC structure, data widths, the GPIO PHY's role, and current silicon bring-up status |
| [IMPLEMENTATION.md](IMPLEMENTATION.md) | Functional spec — data path, credit/doorbell flow control, auto-negotiation & role arbitration, the I²C training handshake, cross-lane deskew + lane masking, and single-phase PTP |
| [REGISTER_MAP.md](REGISTER_MAP.md) | The unified APB register address space |
| [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md) | Consuming the subsystem — environment/submodules, flists & build targets, host-SoC wiring, the FPGA build+deploy flow, the ASIC flow, and the APB bring-up sequence |
| [VERIFICATION_PLAN.md](VERIFICATION_PLAN.md) | cocotb + UVM test matrices, the HW bring-up suite and safety gates, the known-issue backlog, and sign-off criteria |

## Recommended reading order

1. **[ARCHITECTURE.md](ARCHITECTURE.md)** — what TideLink is and how the modules fit together.
2. **[IMPLEMENTATION.md](IMPLEMENTATION.md)** — how each block works.
3. **[REGISTER_MAP.md](REGISTER_MAP.md)** — the software-visible register interface.
4. **[INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md)** — how to build it and drop it into a host SoC.
5. **[VERIFICATION_PLAN.md](VERIFICATION_PLAN.md)** — how it is tested and signed off.

## Archive

Point-in-time investigation, audit, bring-up, and planning notes from the
project are retained under [archive/](archive/) for historical reference. Their
durable conclusions (silicon status, known issues, design decisions) have been
folded into the five documents above; the archived copies are **not maintained**.

> The repo-cleanup that produced this product set is recorded in
> [REPO_CLEANUP_ASSESSMENT_2026_06_11.md](REPO_CLEANUP_ASSESSMENT_2026_06_11.md).
