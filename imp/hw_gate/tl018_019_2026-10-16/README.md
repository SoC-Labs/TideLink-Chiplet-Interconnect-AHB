# TL-018 / TL-019 hardware evidence (KR260, kr260-pair-onchip)

Raw result lines from the KR260 runs of branch `fix/tl018-019-asic-fc-overrides` at `4038de9c`
(AXI FC nodes reset with link CRC ON; ASIC flists take the hardened local overrides).
Host paths and board IP addresses are scrubbed; nothing else is edited.

| Image | Source commit | bin sha256 | Built-source check |
|---|---|---|---|
| fix under test | `4038de9c` | `28f8f391…` | 34/34 fix markers in the sources Vivado synthesised (`markers_built.txt`) |

## Files

| File | What it shows |
|---|---|
| `axi_check.txt` | all 10 AXI nodes (AW/W/B/AR/R x 2 dies) read `SM_CONTROL=0x708`, CRC check ON from reset with no software write; wrong-DataID arm inert; 20 x 64-word clean traffic exact with AXI CRC counters unmoved; 10/10 W-node payload shots each +1 CRC and replayed exact |
| `run_axicheck_summary.tsv` | full step list of that run: POR, deploy, autonomy (zero host writes), stream start (no storm), 2 x 5000-word soak, B19 dip control, CRC controls, sideband 60/60 |
| `sideband_crc_stats_{a2b,b2a}.txt` | TL-059 regression on this image: 30/30 detected sideband shots replayed exactly once per direction |
| `stream_{a2b,b2a}.txt` | 28-word stream start after bring-up: NO_STORM_OBSERVED, exact |
| `run_tl038_summary.tsv`, `tl038_0x23c.txt` | TL-038 re-run at the real injector address 0x23C (the August runs used the unmapped 0x003C alias): liveness control (a B-node payload shot moves the CRC counter and replays), then 8/8 header-byte-1 B-node shots, no wedge, data exact |

## Limits

- The KR260 image is built from the FPGA flist. TL-019 changes the ASIC flist; the node RTL is the
  same file set (`asic_fileset_identity` gate), but the ASIC flist itself has no hardware vehicle before silicon.
- A7 is not testable on this image (`AUTO_ANCHOR_EN=0`), so steps 18-21 were skipped.
- ASIC area, timing and LEC for the added recovery logic are not measured here.
