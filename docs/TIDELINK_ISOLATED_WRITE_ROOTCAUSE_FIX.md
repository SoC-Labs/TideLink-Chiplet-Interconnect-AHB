# TideLink isolated-write data-loss — root-cause, version-check, and repro

**Re:** NanoSoC Compute-Chiplet handover `TIDELINK_ISOLATED_WRITE_DATA_LOSS.md`
(2026-07-30): an isolated D2D peer-aperture write (not immediately followed by
another AHB transfer) crosses with its **address correct but write data
delivered as `0x0000_0000`** — the mailbox doorbell (`MSG_VALID`) and any
isolated D2D payload lost.

**Bottom line: the reported defect is ALREADY FIXED on the current TideLink
line.** It was fixed by `cb33c9f` ("xhb: fix ahb_sub hready comb loop — silicon
window write-vanish root cause"), which is in the current tree but **not** in the
compute chiplet's pinned tidelink submodule (`3f3de09`). A tight IP-level repro
on the current tree confirms isolated writes (including the doorbell) and
back-to-back **distinct-data** writes now deliver correctly; reverting the fix
reproduces the loss. No new RTL change is required — the correct remedy for the
compute chiplet is to advance its tidelink submodule past `cb33c9f`.

---

## 1. Version-check — is the bug present on the current tree? **No.**

| | Report pin `3f3de09` (`v2026.07.16-chiplet-verified`) | Current `HEAD` (`18491ef`) |
|---|---|---|
| `cb33c9f` (write-vanish root-cause fix) | **absent** (divergent lineage) | **present** |
| `tidelink_top.sv` ahb_sub pipe/hready logic | pre-fix (hready-gated) | fixed |
| `deps/axi-chiplet-controller` (AXI4ToWlink.v — suspect #3) | `efe5623` | `efe5623` (**identical**) |
| XHB500 `xhb_sub` bridge (suspect #1) | generated from `configs/` | same config (**identical**) |

`cb33c9f` was authored 2026-07-05 (before the pin's date, 2026-07-09) but is
**not an ancestor of the pin** — the compute chiplet pinned a branch that forked
before the fix landed. The **only** outbound-path RTL that differs between the
pin and HEAD is `tidelink_top.sv`. Suspects #1 (XHB500 W-channel) and #3
(`AXI4ToWlink`) are byte-identical across the two lines and are therefore
**ruled out** as the fix locus — consistent with the observation below that the
data-loss is entirely an `ahb_sub`-side address/data-phase alignment issue.

`cb33c9f`'s own commit message already names this exact symptom: *"window WRITES
phantom-completed at the bridge (vanish), HWDATA was captured one cycle late
(poison)"* — the write-vanish and the data-poison the report describes.

---

## 2. The outbound path and the exact mechanism

```
ahb_sub ─▶ [addr translate] ─▶ 1-cycle ADDRESS pipe (pipe_*_r) ─▶ xhb_sub (XHB500 AHB→AXI)
                                       │                              ▲
   ahb_sub_hwdata ───── RAW (NOT pipelined) ──────────────────────────┘
```

* The address phase is pipelined by **one cycle** to break the 256:1
  translator mux path: `tidelink_top.sv:1528-1537` latches `pipe_haddr_r` etc.,
  presented to XHB500 at `tidelink_top.sv:1605-1611` while `pipe_valid_r`.
* **HWDATA is wired RAW to XHB500** — `tidelink_top.sv:2217` `.hwdata(ahb_sub_hwdata)`.
  There is no `pipe_hwdata_r`.
* XHB500 samples HWDATA in **its** data phase — one cycle after it accepts the
  (pipelined) address:
  `xhb500_ahb_to_axi_bridge_chiplet_slv_core_wdata.sv:186-193`
  (`write_data_valid` set on `hsel & hready & htrans[1] & hwrite`), and
  `:133-134` (`wdata_in = { last, strb, hwdata }`).

So XHB500's notion of the data phase is offset by the address pipe. The design
keeps it correct for a **spec-compliant** master by making the pipe-fill cycle
also stall the master: `ahb_sub_hreadyout = (ext_is_nonseq && !pipe_valid_r) ?
0 : raw` (`tidelink_top.sv:1648-1652`). That one wait-state delays the master's
data phase by exactly the same cycle the address pipe delays the address, so a
compliant master (which holds HWDATA stable until HREADY) presents HWDATA in
XHB500's data phase and the beat crosses intact.

### Why the report's pin lost the data

On `3f3de09` the address-phase detector was **gated by `ahb_sub_hready`**:

```
// pre-cb33c9f
wire ext_addr_phase = ahb_sub_hsel & ahb_sub_htrans[1] & ahb_sub_hready;
wire xhb_sub_hready = pipe_valid_r ? raw : (ext_is_nonseq ? 1'b0 : ahb_sub_hready);
```

In the compute-chiplet SoC (and on the FPGA rig) `ahb_sub_hready` is driven
**combinationally from `ahb_sub_hreadyout`** by the fabric / Vivado wrapper
(`tidelink_vivado_wrapper.v`: `assign ahb_sub_hready = sub_hreadyout_int`).
During the pipe-fill cycle `ahb_sub_hreadyout = 0`, so the looped
`ahb_sub_hready = 0`, so `ext_addr_phase` collapses — and because
`ahb_sub_hreadyout` itself then depends on `ext_is_nonseq`, the net is a
combinational ring (Vivado: "1 combinational loop"). The address pipe latches
divergently or not at all: the write **phantom-completes and vanishes**, or
XHB500 samples HWDATA a cycle late — exactly the report's `LAND=0x2A00_00xx
data=0`.

`cb33c9f` removes the `& ahb_sub_hready` term and switches the `xhb_sub_hready`
else-arm to XHB500's own raw hreadyout (`tidelink_top.sv:1419`, `:1617-1618`),
breaking the ring so the fill-stall re-alignment holds unconditionally.

### The masking artefact the report identified

Every prior D2D proof used a **back-to-back pair with identical data**. Back-to-
back means the first write's HWDATA is still on the bus during the second's
address phase (AHB pipelining), so a one-cycle-late sample still catches a valid
word; identical data makes any shift invisible. An isolated write drops to
IDLE (HWDATA→0) right after, so a late sample catches `0`. Confirmed below.

---

## 3. Tight IP-level repro (`cocotb/tidelink_top_pair_v2/test_v2_isolated_write_dataloss.py`)

Drives the **real** outbound path `m_ahb_sub → XHB500 → AXI → Wlink → far die →
XHB500 → s_mng (ahb_mng) → far BRAM`, isolating the SoC and the CAM. Includes an
**HREADY-aware far-`ahb_mng` monitor** (`MngWriteMonitor`) that samples
`s_mng_hwdata` in each data phase and is **cross-checked against the far BRAM
ground truth every test** (the report's own sender monitor was inconclusive
because it ignored wait-states; this one is verified, not trusted).

### Results on the CURRENT tree (4/4 PASS)

| Test | Stimulus | Result |
|---|---|---|
| `test_isolated_distinct_write_delivers` | isolated write `0xD2D0DB01`; doorbell `MSG_VALID=1` | far ahb_mng = `0xD2D0DB01` / `0x00000001` ✓ |
| `test_back_to_back_distinct_writes` | b2b **distinct** `0xD2D0BEEF@+0x100`, `0xFEEDFACE@+0x104` | each lands at its own addr ✓ (no shift) |
| `test_isolated_promptdrop_write` | non-compliant master, HWDATA withdrawn early | hold=1 → `0` (symptom!); hold=2 → lands |
| `test_isolated_write_hready_loopback` | compliant isolated write **under hready↔hreadyout loopback** | far ahb_mng = `0xD2D010AB` ✓ |

The HREADY-aware monitor agreed with the BRAM in every case.

### RED evidence — reverting `cb33c9f`

Re-introducing the two `cb33c9f` lines (`& ahb_sub_hready` on `ext_addr_phase`;
`ahb_sub_hready` else-arm) and rebuilding:

* `test_isolated_write_hready_loopback` → **FAIL**: `ahb_sub WRITE 0x40000300
  did not complete` — the address pipe never latches under the looped hready and
  the write **wedges/vanishes** at the bridge (the write-vanish class).
* The three const-high-hready tests are **unchanged** (still pass) — because a
  bench that ties `ahb_sub_hready` high never exercises the loop. This is why the
  idealized cocotb window test (`test_v2_xhb_window`) never caught it and why the
  compute-chiplet SoC (fabric-looped hready) did.

Restoring `cb33c9f` → `test_isolated_write_hready_loopback` **PASSES** again.
Clean RED→GREEN, attributing the fix to `cb33c9f`.

### The `prompt-drop hold=1 → 0` result — not a residual defect

`test_isolated_promptdrop_write` reproduces the exact symptom (`addr ok, data=0`)
even on the current tree, but only for a master that **withdraws HWDATA one cycle
before XHB500's data phase** (drives it aligned to its own pre-pipe data phase,
then forces the bus to 0). That is **not spec-compliant AHB** — HWDATA must be
held stable for the whole data phase until HREADY. It cannot be "fixed" in the
bridge without breaking the compliant path: a compliant master presents HWDATA
in XHB500's data-phase cycle (C+2), whereas the prompt-drop master presents it a
cycle earlier (C+1) and withdraws it — the two present the word in **different**
cycles, so no single HWDATA-capture register can satisfy both. Adding a
`pipe_hwdata_r` to chase the early word would corrupt every compliant write.
Real masters (the M4, the DMA) hold HWDATA to HREADY and land correctly (tests 1,
2, 4).

---

## 4. Fix and validation

* **RTL fix:** already in tree as `cb33c9f` (`tidelink_top.sv:1419`, `:1617-1618`).
  No further RTL change is made or needed. A speculative HWDATA pipeline was
  considered and rejected (it would regress the compliant path — §3).
* **Regression guard added:** `test_v2_isolated_write_dataloss.py` (4 tests, all
  GREEN on the current tree; the loopback test goes RED if the hready-gating is
  ever re-introduced). Recommend adding it to the FPGA sim gate alongside
  `test_v2_xhb_window` and `test_v2_xhb_window_bridge`.
* **No regression:** `test_v2_xhb_window` (4/4) and `test_v2_xhb_window_bridge`
  (the cb33c9f mechanism gate) still pass; only an additive test file and this
  doc are added. RTL is byte-identical to `HEAD`.

## 5. Is the "trailing barrier write" workaround sound? — **Unnecessary here.**

On the current tree an isolated D2D write (including the doorbell) delivers its
data with **no following transfer** (test 1). The barrier would only mask a
**non-compliant** master that withdraws HWDATA early; the correct remedy for that
is a compliant master (hold HWDATA to HREADY), which the M4/DMA already are.

**Recommendation for the compute chiplet:** advance the `tidelink` submodule past
`cb33c9f` (ideally to a current vetted pin) rather than adopt barrier writes in
firmware / `program_cam` / `mailbox_send`. If a pin bump is not immediately
possible, the barrier write is a safe interim mitigation, but it is papering over
a fix that already exists upstream.

---

## 6. Reproduce

```sh
cd cocotb/tidelink_top_pair_v2
source ../../set_env.sh
export TIDELINK_PHY_V2=1
export PATH=$VCS_HOME/bin:$PATH
rm -rf sim_build*
make MODULE=test_v2_isolated_write_dataloss EPOCH_PROFILE=zero
```

To see the RED: temporarily restore the pre-`cb33c9f` form of
`tidelink_top.sv:1419` (`... & ahb_sub_hready`) and `:1617-1618` (else-arm
`ahb_sub_hready`), rebuild, and `test_isolated_write_hready_loopback` fails.
