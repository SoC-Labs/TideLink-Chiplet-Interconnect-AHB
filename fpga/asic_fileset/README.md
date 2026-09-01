# ASIC-file-set FPGA image

An FPGA bitstream built from **the RTL that tapes out**, so the tapeout sources
can be exercised on real hardware for the first time.

Branch `rev2/asic-fpga`. Target `kr260-pair-onchip` (two TideLink dies in one
bitstream, cross-connected entirely in fabric — no PHY or I2C signal reaches a
pin, so there is no bring-up lottery and no ribbon).

Build it with:

```sh
source ./set_env.sh
export TIDELINK_PHY_V2=1 TD_ASIC_FILESET=1
make -C fpga package_ip   TARGET=kr260-pair-onchip
make -C fpga build_design TARGET=kr260-pair-onchip
fpga/scripts/verify_asic_fileset_image.sh kr260-pair-onchip   # <- the proof
```

Without `TD_ASIC_FILESET=1` you get the ordinary FPGA image. The knob is
refused unless `TIDELINK_PHY_V2=1` is also set.

---

## Why this image exists

`flists/tidelink_top_full_asic_v2.flist` (what tapes out) and
`flists/tidelink_fpga_v2.flist` (what every FPGA image and every cocotb suite
has ever compiled) resolve **ten module files to different sources**. Five of
them are the AXI flow-control state machines:

| module | ASIC copy | FPGA copy | `socl_` in ASIC | `socl_` in FPGA |
|---|---|---|---|---|
| `WlinkGenericFCSM.v`   | `deps/…/wlink/` 1159 ln | `src/rtl/local_overrides/` 1357 ln | 0 | 73 |
| `WlinkGenericFCSM_1.v` | `deps/…/wlink/` 1159 ln | `src/rtl/local_overrides/` 1332 ln | 0 | 72 |
| `WlinkGenericFCSM_2.v` | `deps/…/wlink/` 1159 ln | `src/rtl/local_overrides/` 1337 ln | 0 | 72 |
| `WlinkGenericFCSM_3.v` | `deps/…/wlink/` 1159 ln | `src/rtl/local_overrides/` 1332 ln | 0 | 72 |
| `WlinkGenericFCSM_4.v` | `deps/…/wlink/` 1159 ln | `src/rtl/local_overrides/` 1332 ln | 0 | 72 |
| `WlinkGenericFCReplayAddrSync_18.v` | `deps/…/wlink/` 99 ln | `src/rtl/local_overrides/` 170 ln | 0 | 0 |
| `WlinkGenericFCReplayV2_7.v` | `deps/…/wlink/` 175 ln | `src/rtl/local_overrides/` 226 ln | 0 | 0 |
| `WlinkGenericFCReplayV2_9.v` | `deps/…/wlink/` 175 ln | `src/rtl/local_overrides/` 226 ln | 0 | 0 |
| `i2c_master.v` | `deps/…/i2c/rtl/` 905 ln | `src/rtl/local_overrides/` 902 ln | 0 | 0 |
| `tidelink_sram.sv` | `src/rtl/fifo/asic/` 61 ln | `src/rtl/fifo/fpga/` 112 ln | 0 | 0 |
| **total** | **7210 ln** | **8326 ln** | | |

The five FCSM copies differ by five named recovery features — the L6 CR-emit
gate, the L7 CRACK-emit gate, the sticky-NACK bring-up forgive, the TL-033
state-7 emit-starvation watchdog, and periodic re-ACK — all present on the FPGA
side, **all absent from the files that tape out**. `_7`/`_9` were re-pointed at
the hardened overrides on the FPGA side only, by `bf813a74`, which is why they
are divergent as well; the AddrSync_18 override carries the a2l ACK-pointer
reset-skew fix.

This divergence is proven in simulation on `rev2/integration`
(`ASIC_FLIST=1` on `tidelink_top_pair_v2`;
`test_asic_l7_starvation_backstop` shows the ASIC arm wedging at FCSM state 7
where the FPGA arm escapes). **It had never been run on hardware.**

---

## What is ASIC-sourced, and what is not

### ASIC-sourced — every module in the design except one

All **186 file entries** of `flists/tidelink_top_full_asic_v2.flist` are
compiled. Ten of them are the divergent modules above, and every one is
byte-identical (sha256) to the tapeout source, verified at two hops: the copy
`ipx::package_project` imported, and the copy the synthesiser actually opened.

Three ASIC sources are **materialised** rather than read in place —
`tidelink_top.sv`, `Wlink.v`, `axi_chiplet_controller.sv`. A standalone copy is
emitted under `imp/fpga/gen_v2/` with `` `define TIDELINK_PHY_V2 `` (and the
FPGA-only `TD_AUTO_LANE_MASK_E4` lane-mask knob) textually prepended; the body
below that header is byte-identical to the ASIC source, and the header records
the path it came from. This is not a source change: the ASIC flist delivers
`TIDELINK_PHY_V2` as a flist-level `+define+`, which is one of the four
mechanisms proven (2026-06-11) **not** to survive `ipx::package_project` into
the packaged IP's out-of-context synthesis. The FPGA flist solves the identical
problem the identical way, via `src/rtl/v2shims/`. The list of three is derived,
not guessed: it is exactly the set of ASIC-flist files carrying a live
`` `ifdef `` on either macro.

### NOT ASIC-sourced — one module

| module | supplied by | why |
|---|---|---|
| `rf_16k` | `fpga/asic_fileset/rf_16k_fpga.v` | **substituted** |

`src/rtl/fifo/asic/tidelink_sram.sv` instantiates `rf_16k`, a TSMC 65nm
compiled register file. It is a **hard macro with no RTL anywhere in the ASIC
file set** — Fusion Compiler binds it from the memory compiler's
`.lib`/`.lef`/`.gds` at `read_design` time, the ASIC flist contains no `rf_16k`
line at all, and `syn/asic/sim_stubs/rf_16k_stub.v` is explicitly marked *"DO
NOT add this file to any synthesis / PnR flist"*.

So the substituted thing is the **leaf memory macro**, not the wrapper:
`tidelink_sram.sv` is compiled verbatim from `src/rtl/fifo/asic/`, and the
substitute stands in for a file that does not exist in the ASIC sources to
begin with. **Say it plainly anyway: one module in this image is not the ASIC
source.**

The substitute is port-identical and its byte-lane write template is
syntax-identical to `cmsdk_fpga_sram.v`, so the inferred BRAM structure matches
a normal FPGA build. Three deviations, all in the file's header:

* **Read-during-write to the same address is undefined.** Matches every
  previous TideLink FPGA image (they all used `cmsdk_fpga_sram`); does **not**
  match the read-first ordering of the ASIC sim stub.
* `EMA` / `EMAW` / `RET1N` are accepted and ignored — margin and retention
  controls with no FPGA analogue. `tidelink_sram.sv` ties them to nominal.
* No timing, margin or retention modelling. **This image proves FUNCTION, not
  timing.**

`rf_16k`'s `WEN` is per-**bit**; this model is per-**byte**. That is exact for
the sole caller, which drives `WEN` byte-replicated at `tidelink_sram.sv:47`, and
a simulation-only assertion fires if any future caller does otherwise.

### Skipped

`deps/tidelink-phy/rtl/tidelink_sync_word.svh` — a header, listed as a source
in the ASIC flist because VCS compiles the whole flist as one compilation unit.
Vivado compiles each source separately and the header is `` `include ``-guarded,
so the modules that need it resolve it through the `+incdir+` the same flist
already carries. **Headers define no modules: zero netlist impact.**

---

## Coverage of the divergence

**All 7,210 lines of divergent ASIC source are in this image — 100%.**

Every one of the ten divergent files is compiled verbatim, proven by sha256 at
two hops. Nothing was substituted *for* an ASIC file. The one substituted
module, `rf_16k`, contributes **zero** ASIC lines because it has no ASIC RTL to
contribute: it is a compiled hard macro. All 61 lines of the ASIC
`tidelink_sram.sv` wrapper that instantiates it — including the
`CEN`/`GWEN`/per-bit-`WEN` polarity adaptation, which is the part that could
actually be wrong — are present and synthesised. The 5,795 lines of
recovery-stripped FCSM that motivated the whole exercise are present at 100%.

Measured line counts (`wc -l`, this branch):

```
             ASIC side   FPGA side
5x FCSM         5795        6690
AddrSync_18       99         170
ReplayV2_7/_9    350         452
i2c_master       905         902
tidelink_sram     61         112
             ---------   ---------
total           7210        8326
```

The 6,542 figure this work was commissioned against predates `bf813a74`, which
made `WlinkGenericFCReplayV2_7/_9` divergent (+350 ASIC lines) and took the
count from eight files to ten. The conclusion is unchanged and stronger: the
image contains the divergent tapeout sources in full.

## Proving it — do not take this file's word for it

```sh
fpga/scripts/verify_asic_fileset_image.sh kr260-pair-onchip
```

Four independent checks, closing the chain from repo source to synthesised
netlist:

1. Vivado's own `[Synth 8-6157] synthesizing module '<m>' [<file>:<line>]` lines
   in the tidelink OOC synthesis run log — **the tool naming the physical file**,
   not a flist and not a build banner.
2. sha256 of that file — the one the synthesiser opened — against the ASIC
   source on disk. (1) alone only proves a path was opened.
3. sha256 of the packaged IP's imported copy against the same source, so a
   divergence at either hop is localised.
4. `grep -c socl_` on the synthesised copy: 0 for a tapeout FCSM. Run in **both
   directions** — the same grep on the FPGA twin must return non-zero, or "0
   hits" is a dead grep and proves nothing.

---

## Provenance — read this before quoting the manifest

`fpga/scripts/build_provenance.tcl` was made ASIC-aware here: the manifest now
records `phy_marker: "V2-ASICFILESET"` and
`flist: "tidelink_top_full_asic_v2.flist"`. Before that it returned
`tidelink_fpga_v2.flist` unconditionally on any V2 build, so the manifest would
have **named the wrong file list** — asserting the recovery-bearing FPGA FCSMs
in an image that holds the recovery-stripped tapeout ones.

**`git_dirty` on this branch is still FAIL-OPEN and must not be trusted.**
`tl_git_sha` returns a bare `"unknown"` on `rev-parse` failure (early return,
the dirty check never runs) and its `git status` `catch` short-circuits, so an
indeterminate tree is stamped `git_dirty: false`. The fix exists as `df0f1f24`
but lives **only** on `rev2/hygiene` and is **not an ancestor** of this branch:

```
$ git merge-base --is-ancestor df0f1f24 HEAD  ->  rc=1 (NOT an ancestor)
$ git branch -a --contains df0f1f24
  rev2/hygiene
  remotes/origin/rev2/hygiene
```

It was deliberately not cherry-picked here. **Pin this image by the artefact
sha256** recorded below, not by the manifest's dirty flag.

---

## Exercising the divergence on hardware

`fpga/hw_regression/asic_l7_starvation_hwtest.py` (+ its board agent and its
offline unit test) asks whether the AXI FC nodes recover from the state-7
starvation the sim test drives. **It has never been run.** Read its docstring
first — in particular the part explaining that FCSM `state` for the five
divergent nodes is **not observable on hardware at all**, so the test is
behavioural and its most likely honest outcome is COULD-NOT-EVALUATE.
