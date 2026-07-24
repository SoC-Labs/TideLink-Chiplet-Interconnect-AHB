# Third-Party Notices and Statement of Modifications

This document records the provenance of third-party material redistributed in
this repository, and states the modifications SoC Labs has made to it — as
required by **Section 4(b) of the Apache License, Version 2.0**.

See [`LICENSE`](LICENSE) for the full Apache-2.0 text and [`NOTICE`](NOTICE) for
the attribution notices.

---

## 1. Wavious `wlink` — Apache License 2.0

**Copyright 2021 Wavious, Inc.** — <https://github.com/Wavious/wlink>

TideLink is built on the Wavious `wlink` chiplet interconnect. The upstream
project is written in Chisel; the files in `src/rtl/local_overrides/` are
**Verilog elaborated from those Chisel sources and then modified by SoC Labs**.

### Why local overrides exist

The generated Verilog is the build input for both the FPGA and ASIC flows. Where
a defect or an integration requirement demanded an RTL change, SoC Labs kept a
modified copy under `src/rtl/local_overrides/` and pointed the filelists
(`flists/*.flist`) at the local copy, rather than editing the upstream
submodule. Each override therefore **shadows** its upstream counterpart.

### Nature of the modifications

SoC Labs' changes to the Wavious-derived files fall into these categories:

| Area | Files | Change |
|---|---|---|
| Flow-control state machine | `WlinkGenericFCSM*.v` | Bring-up recovery fixes — notably forgiving `send_nack_req` during the credit-handshake window so a transient `isNotExpPacket` cannot wedge the FCSM at `SEND_NACK`; and the link CRC power-on default. |
| GPIO PHY (D2D) | `WavD2DGpio*.v`, `WlinkGPIOPHY*.v` | Source-synchronous capture-clock restructuring (clock-buffer parent hoisting), per-lane deskew/IDELAY control, and V2 lane-mask handling for the forwarded-clock GPIO PHY. |
| Link/replay layer | `Wlink.v`, `WlinkRxLinkLayer.v`, `WlinkGenericFCReplay*.v`, `WavMultibitSync_18.v` | Integration plumbing for the TideLink wrapper and clock-domain-crossing adjustments. |
| Packet adaptation | `ShortPacketToWlink.v`, `TideLinkToWlink.v` | Adaptation of the TideLink packet interface onto the wlink short-packet transport. |

**The authoritative, per-line record of every modification is the git history of
this repository.** Use `git log --follow -- src/rtl/local_overrides/<file>` to
see exactly what changed and why. Several files also carry an in-file
`SoC Labs LOCAL OVERRIDE` comment block describing the specific change and the
hardware failure that motivated it.

> **Note:** not every Wavious-derived file currently carries an in-file
> attribution header. This document, together with `NOTICE`, provides the
> required attribution and change statement for all of them.

---

## 2. verilog-i2c — MIT License

**Copyright (c) 2015-2017 Alex Forencich** — <https://github.com/alexforencich/verilog-i2c>

- `src/rtl/local_overrides/i2c_master.v`
- `src/rtl/local_overrides/i2c_master_axil.v`

Used for the I²C sideband channel that carries out-of-band bring-up and
negotiation between the two dies. These files **retain their original MIT
licence text in-file**; consult the header of each file for the full terms.

---

## 3. Plotly.js — MIT License

**Copyright (c) 2016-2024 Plotly, Inc.** — <https://github.com/plotly/plotly.js>

- `pynq_host/throughput_gui/static/vendor/plotly.min.js`

Vendored as a pre-built minified bundle so the board-side throughput dashboard
functions on an FPGA board with no internet access. Unmodified.

---

## 4. Licensed IP referenced but **NOT** distributed here

This repository does **not** contain any Arm IP. The following are resolved at
build time from a separately-licensed installation, via environment variables
set by [`set_env.sh`](set_env.sh):

| Component | Resolved via | Notes |
|---|---|---|
| Arm Corstone-101 / BP210 (CMSDK) | `$CMSDK_DIR`, `$CMSDK_FPGA_SRAM_V` | AHB infrastructure and SRAM models |
| Arm XHB-500 bus bridge | `$XHB500_IP_DIR` | Generated into `deps/xhb500/generated/`, which is **gitignored** |

**You must obtain your own licence for these components from Arm.** Without
them the simulation and synthesis flows will not build; the TideLink RTL in
`src/rtl/` is independent of them.
