# Z2 pickup — state as of 2026-07-30/31

**Branch:** `fix/z2-drop-park-hook` @ `a5df514` + uncommitted (not pushed). **This branch is
shared live with at least one other concurrent session tonight** (same working tree, same git
index — their commits, e.g. `d8ab6db`/`9eaafb7` "I4 AXI data-node observability", landed on this
branch mid-session). Before committing anything, run `git status` and diff carefully — the index
may hold staged content from that other session (e.g. `test_v2_isolated_write_dataloss.py`,
`TIDELINK_ISOLATED_WRITE_ROOTCAUSE_FIX.md` as of 2026-07-31 01:5x) that is **not** part of this
EPOCH_ANCHOR_EN work and should not be swept into the same commit.

**Supersedes:** `docs/HANDOVER_SYNC_CLOCK_GATE_2026_07_29.md` — **that document's root cause is
REFUTED.** Read this one first; read that one only for the raw measurements it records.

---

## 1. Where things actually stand

| | Status |
|---|---|
| **Bring-up** | ✅ **FIXED and reproducible from git.** Zero-poke: `cal=1 fcsm=4 cr=1 ck=1`, EPOCH anchored span 0, LIVEMATCH 8/8, SLICEMAP identity `0x76543210` on both dies (this was true pre-session; re-confirmed tonight — see §6). |
| **Data delivery (RTL fix)** | ✅ **Root-caused (§3), fixed, and proven in sim (§4/§5).** `EPOCH_ANCHOR_EN` now threads end-to-end through real, packaged-IP parameters (not a `+define+`), default `0` everywhere except an env-gated Z2-only BD override. Zero regression on the shared V1/ASIC/KR260 paths. |
| **Data delivery (HW verification)** | 🔶 **Fix confirmed ENGAGED on real silicon** (`anchored=1` both dies simultaneously — §6). **Conclusive S2M data test still open** — blocked tonight by a rig-health lane-lock plateau unrelated to the fix (§6). This is the one open item. |

`fix/z2-drop-park-hook` = `feat/txgen-v1-integration` + **revert of `0a3b1cf` (the 4th PARK hook)**.
Its bitstreams are **bit-identical (sha256) to the HW-proven `tl-trainfb-8lane`**, which independently
proves the PARK hook was the only functional difference. Artefacts:
`~/tidelink_artefacts/tl-nopark-8lane/`. Build env: `TIDELINK_PHY_V2=1 TD_AUTO_LANE_MASK_E4=0
TL_TRAIN_ENTRY_FALLBACK=1`.

**Keep the 3 ENTRY hooks; the 4th (PARK) is harmful** — on a dead-I2C rig it holds `training_mode=1`
forever waiting for a master I2C write that can never arrive, which parks the calibrator in S_HOLD
(`cal=0`) and holds the RX framer in reset (`fcsm=1`).

---

## 2. Two things I got wrong — do not re-derive them

1. **"V2 dropped `| sync_insert` from the pad clock-gate"** — REFUTED three ways. `swi_delay_cycles`
   PORs to 0 (`Wlink.v:2601`, deliberate) ⇒ PSTATE never advances ⇒ **`tx_en ≡ 1` ⇒ the gate is
   PERMANENTLY OPEN** ⇒ the term is a redundant OR into a constant 1. Also `tx_sync_ins_cnt = 0` was
   measured on both dies in the failing builds, and that counter is POR-only-reset saturating ⇒ the
   signal never asserted. Also the term was never in upstream or the V2 lineage — it is a
   **V1-local-override-only** addition, so nothing was "dropped". Reverted on
   `fix/v2-sync-clock-gate` @ `2415766`.
2. **"That fix breaks bring-up"** — also wrong; the A/B was **confounded**. The
   `tidelink-build-trainfb` worktree carries the 45-line PARK hook as an *uncommitted* edit
   (mtime 07-28 21:48) while the working image was built 07-28 15:35Z. Both failing builds had PARK;
   both working images did not.

**Method lesson:** verify the RTL precondition (can this signal even be 0?) and check what else is
dirty in a tree before calling an A/B "one variable".

---

## 3. Why no data crosses — the complete chain (all links verified)

1. `swi_delay_cycles` forced `16'h6a4 → 16'h0` (`Wlink.v:16-45`, "tdif-04"). Documented reason:
   PSTATE recovery needs `~tx_ready && ll_app.sop` simultaneously — unreachable in the training→FC
   handoff ⇒ **PSTATE deadlock**. Setting 0 escapes it. It fixed a real bug.
2. ⇒ `|io_swi_delay_cycles` false ⇒ PSTATE never leaves state 0 ⇒ **`io_link_tx_tx_en ≡ 1`**.
3. ⇒ `postcount` only decrements when `~tx_en`; it reloads to `8'h7` ⇒ **`postcount ≡ 7`, never 0**
   (`WavD2DGpio_v2.v:2111-2124`).
4. ⇒ `tx_sync_en_w = ~por & insert_en & (force_always | (tx_idle & postcount==0))` collapses to
   `insert_en & force_always` ⇒ **the idle-gated SYNC beacon can NEVER fire.** Only `force_always`
   (manual `0x1C`, `winscan_force_sync`, `ws_serve_active_r`) ever emits SYNC.
5. ⇒ **the shipping deskew corrector never arms.** `Makefile:515-523` states it: the shipping stack
   runs `SYNC_REANCHOR_EN=1`, *"which only arms on a live SYNC beacon that the pair bring-up leaves
   off, AND Wlink does not forward `EPOCH_ANCHOR_EN` down to `tidelink_lane_deskew`."*
6. ⇒ under real inter-lane skew words never reassemble ⇒ all-zeros / undelivered.

**Ruled out by direct silicon measurement** (do not re-chase): the PARK hook, the pad clock-gate term,
`llrx_reset` holding the slave's RX framer (cleared it — anchor held, still `rxw=0`), and peer
`PAIR_CREDIT` starvation (read 0, seeded to 64 via W-add to `0x020`, still no delivery ⇒ it is SW
bookkeeping, not the hardware gate).

---

## 4. The fix, PROVEN IN SIM

```bash
source ./set_env.sh
make -C cocotb/tidelink_top_pair_v2 EPOCH_PROFILE=silicon \
  EXTRA_DEFINES="+define+TB_TOP_EPOCH_ANCHOR_EN" \
  SIM_BUILD=sim_build_silicon_epochen MODULE=test_v2_pair_data
```
⇒ `[tb_top] EPOCH_ANCHOR_EN: master=1 slave=1 (deskew: m=1 s=1)` and **TESTS=3 PASS=3 FAIL=0**,
including `test_03_packet_slave_to_master` — the test that **FAILS by default** with the all-zeros
signature (`got [0,0,0,0] len=0`).

🔑 Use `TB_TOP_EPOCH_ANCHOR_EN` (defparams `u_wlink.phy` ⇒ propagates through the **shipping**
plumbing). **NOT** `TB_TOP_EPOCH_ANCHOR_FORCE`, which defparams `u_deskew` directly and bypasses it.
The banner `(deskew: m=1 s=1)` is the proof the hop is live — a silently-ignored defparam prints
`m=0 s=0`.

🔴 **This failure has been shipping past a GREEN gate on every build** — the farm-gate
silicon-faithful tier reports `sim[silicon_data] test_03 FAIL` as a **non-blocking ADVISORY**.
Consider making that tier blocking for FPGA-bound lineages. (2026-07-30, another session added
`sim_gate_xfail_epoch_shipping` as a sentinel that captures this exact signature — see its comment
in `Makefile` for the measured `TESTS=3 PASS=1 FAIL=2` baseline this fix is closing.)

---

## 5. The RTL/build fix — COMPLETE, structurally verified, zero regression

Already present: `WlinkGPIOPHY_v2.v:63` has `parameter EPOCH_ANCHOR_EN = 1'b0` and forwards it at
`:248`; `WavD2DGpio_v2.v:159` has it and sets the deskew's `SYNC_REANCHOR_EN` as its **complement**
(`:158`) ⇒ **one knob**, mutual-exclusion elab guard satisfied automatically.

**`src/rtl/local_overrides/Wlink.v` had NO occurrence of `EPOCH_ANCHOR_EN` — that was the gap. Now
closed:**

1. ✅ Added `parameter EPOCH_ANCHOR_EN = 1'b0` to `Wlink.v`; passed on its `WlinkGPIOPHY`
   instantiation (guarded `` `ifdef TIDELINK_PHY_V2 `` — V1's `WlinkGPIOPHY` has no such parameter).
2. ✅ Passed from `axi_chiplet_controller.sv`'s Wlink instance.
3. ✅ Surfaced on `tidelink_top.sv` → **both** `src/rtl/asic/tidelink_dft_wrapper.sv` (ASIC top) and
   `fpga/vivado_ip/tidelink_vivado_wrapper.v` (FPGA IP face) — they are parallel consumers of
   `tidelink_top`, not a serial chain. **The IP-face param is MANDATORY** — a `+define+` or RTL
   default does NOT reach packaged-IP OOC synth (documented trap; same class as
   `DEBUG_UNLOCK_DEFAULT` / `TRAIN_ENTRY_FALLBACK`). Default stays `1'b0` at **every** level,
   including the vivado wrapper's own default (unlike `USE_T3A`/`USE_CLKBUF` it is NOT flipped ON
   FPGA-wide) — this is a real netlist change and KR260's already-proven images must stay untouched.
4. ✅ `make package_ip` then verified **STRUCTURALLY**: `grep EPOCH_ANCHOR_EN` on the packaged
   `imp/fpga/tidelink_ip/src/{Wlink.v,axi_chiplet_controller.sv,tidelink_top.sv,
   tidelink_vivado_wrapper.v}` all show it, and `component.xml` carries it as a real
   `spirit:resolve="user"` model parameter (not a dead define) — same shape as `TRAIN_ENTRY_FALLBACK`.
   🔴 **Trap hit + fixed while doing this**: `make -C fpga package_ip` **without**
   `TIDELINK_PHY_V2=1` exported silently packages the **V1** flist (`set_env.sh` does NOT export
   this var by default) — the banner in `imp/fpga/run/package_ip.log` literally prints which mode
   was used (`TIDELINK filelist: V1 ... (TIDELINK_PHY_V2=<unset> -> tidelink_fpga.flist)`), so check
   it after every `package_ip` run. This produced a confusing, unrelated-looking "5 files STALE"
   failure at `build_design` time — always export `TIDELINK_PHY_V2=1 TD_AUTO_LANE_MASK_E4=0` before
   `package_ip`, not just before `build_design`.
5. ✅ Re-ran §4 **without** the TB define, instead overriding the true top-level parameter via
   `EXTRA_DEFINES="-pvalue+tb_top.u_master.EPOCH_ANCHOR_EN=1 -pvalue+tb_top.u_slave.EPOCH_ANCHOR_EN=1"`
   (no tb_top.sv edit needed — passing `-pvalue+` via `COMPILE_ARGS=` directly on the `make` command
   line does NOT work, it clobbers the Makefile's own `COMPILE_ARGS +=` accumulation including the
   `-f <flist>`; use the Makefile's existing `EXTRA_DEFINES` passthrough instead) — prints
   `[tb_top] EPOCH_ANCHOR_EN: master=1 slave=1 (deskew: m=1 s=1)` and **TESTS=3 PASS=3 FAIL=0**,
   proving the real plumbing end to end (not the old `u_wlink.phy` defparam shortcut). The default
   (param=0) path re-confirmed unchanged: `TESTS=3 PASS=1 FAIL=2` with the identical FCSM-state-5 /
   all-zeros signature the new `sim_gate_xfail_epoch_shipping` sentinel captures — nothing about the
   shipping default moved. `sim_gate_v1elab`, `sim_gate_asicelab`, `sim_gate_asicelab_v2`,
   `sim_gate_dftelab`, `sim_gate_v2_data` (default, zero-skew), `sim_gate_epoch_silicon`
   (forced-corrector), and the full `sim_gate_quick` aggregate (14/14 substantive suites) all PASS —
   no V1/ASIC/KR260-shared-path regression from the new parameter.
6. ✅ Wired an env-gated `CONFIG.EPOCH_ANCHOR_EN {1'b1}` block into
   `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl` and `...-flip-all/tidelink_design.tcl`
   (mirrors the existing `TL_TRAIN_ENTRY_FALLBACK` pattern exactly): export `TL_EPOCH_ANCHOR_EN=1`
   before `build_design` to opt in. **KR260 targets and the plain `pynq-z2-pair` target never set
   this env var, so their packaged-IP consumption is byte-identical (still 0).**
7. ✅ Both Z2 targets built (WNS +0.359ns pair-all, +0.322ns flip-all — both close timing cleanly)
   and HW-deployed. See §6 for the full HW account — **fix confirmed engaged in real silicon**;
   conclusive data-delivery re-test is the one thing still open.

⚠ **This is a real netlist change** (swaps which deskew corrector is compiled in) ⇒ needs a ratify
decision like any tapeout-affecting change. Scoped to the Z2 pair-all/flip-all targets only via the
env-gate above, specifically to avoid re-litigating KR260's already-proven images.
⚠ **Sim proof ≠ silicon proof.** The silicon profile is a MODEL of the v37 skew fingerprint, not the
z2 boards' actual skew.

**Build + deploy recipe:**
```bash
source ./set_env.sh
export TIDELINK_PHY_V2=1 TD_AUTO_LANE_MASK_E4=0   # BEFORE package_ip too, not just build_design
make -C fpga package_ip
export TL_TRAIN_ENTRY_FALLBACK=1 TL_EPOCH_ANCHOR_EN=1
make -C fpga build_design TARGET=pynq-z2-pair-all
make -C fpga build_design TARGET=pynq-z2-pair-flip-all
```
Bitstreams staged at `mapstone-dev:~/tidelink_artefacts/tl-epochfix-8lane/` (`tidelink.bin` sha256
`e2ec5d5b117c…`, `tidelink-flip.bin` sha256 `7310bca090f4…`, manifests present, sha verified on both
ends of the transfer).

---

## 6. HW attempt 2026-07-30/31 — fix confirmed engaged, data test blocked by a rig-health plateau

**Deploy:** both dies flashed clean via `deploy_pair.sh` from the artefact dir above —
`fpga_manager: operating`, correct `ROLE_CFG` (`0x02` die_a, `0x03` die_b) both sides.

### 6.1 Two fpgahub infra gaps found + fixed en route (fleet-wide, not Z2-RTL-specific)

1. **`pynq_z2_02_ps` / `pynq_z2_01_ps` were bound to the `nanosoc-multicore-system` fpgahub
   manifest** (not TideLink — TideLink has no manifest registered for these boards at all), whose
   own `reset` action needs a `host.sudo_password` secret that is declared **nowhere**, for **any**
   `pynq_z2_*` board (`[boards.pynq_z2_0N.targets.ps.secrets]` is empty across the whole fleet).
   `fpgahub board reset --method default` silently **prefers a manifest-declared `reset` action over
   the board's own working `zynq_slcr_reset`**, so it failed with `no secret named
   'host.sudo_password' declared`. **Fixed** by adding a `reset.jtag` stanza (byte-for-byte mirrors
   `pynq_z2_03`'s pre-existing, working "bypasses manifest" stanza) to `/etc/fpgahub/config.toml`
   for both `pynq_z2_02` and `pynq_z2_01` — script: `~/fix_z2_reset_jtag_bypass.sh` on mapstone-dev
   (idempotent, backs up config.toml, restarts fpgahubd). `fpgahub board reset pynq_z2_0{1,2}
   --method jtag` now works for the `_ps` member on both boards.
   ⚠ Restarting `fpgahubd` to load a config change **drops every active lease fleet-wide** — check
   nobody else is mid-deploy anywhere before doing this again.
2. **`_pl` members have no reset method configured at all**, for any pynq_z2 board (pre-existing,
   not fixed tonight) — `_ps`-side JTAG SLCR reset is the *only* automated POR fpgahub offers here.
   The PL fabric's own state clears via the fresh bitstream reprogram at deploy time instead.

### 6.2 POR reliability — power-cycle, not JTAG, is what actually works

The JTAG SLCR reset (`--method jtag`) **twice left both boards fully unresponsive to ARP** for 2+
minutes after issuing successfully (`ok ... SLCR soft-reset issued`) — not a hang, a board that
never came back on the network. The documented UART-reboot fallback (`--method uart`, "fallback
when JTAG SLCR fails on running Linux") **also did not recover it** once. Both times, only a real
**hub power-cycle** (`pynq_z2_02_ps` = rshtech port 3; equivalent port for z2_01) brought both boards
back — reliably, within ~15-45s, every time it was tried. This matches
`[[project_kr260_first_light_2026_07_16]]`-class "board found dead, needed a hub power-cycle"
precedent, just for Z2 now too.
**Treat power-cycle as the reliable POR for this rig until investigated further — do not rely on
`--method jtag` alone if the board must come back.** `fpgahub hub power-cycle <NAME>` exists but its
`NAME` argument scoping (whole-hub vs specific port) was not established with confidence tonight —
resolve that before scripting it; a wrong guess risks cutting power to unrelated boards on the same
switch. Physical/manual power-cycle was used instead both times.

### 6.3 A second stale-IP trap, in `bringup_pair_converge.sh`

Its default `SLAVE_IP=192.168.6.101` = **z2_03, the spare NOT on the ribbon** — same class of trap as
`tl39.sh`'s wrong `b` (§7). Confirmed by running it once unmodified: die_a trained normally, die_b
(actually z2_03) read flat zeros the entire time because there is no physical link there. **Always
pass `MASTER_IP=192.168.4.101 SLAVE_IP=192.168.2.101` explicitly.**

### 6.4 Bring-up result — plateau, not convergence

**57 total re-deploys (12+20+25) across three runs with the corrected IPs, never reached the
script's own 16/16 (full 8-lane lock both sides) criterion.** Per-iteration lock masks plateaued at
12–15/16 and repeated near-identical patterns (e.g. `0xf1`(die_a)/`0xee`(die_b) recurring 6+ times,
`0xfe`/`0xfe` recurring 5+ times) — the script's own interpretation guide names this exact shape:
*"best climbs with re-deploys then plateaus high (12-15/16): per-lane sub-UI / IDELAYE2-tap
ceiling."* Reads as a **physical marginal-lane condition on the rig tonight**, not a software/RTL
regression — the same class of issue `[[project_pb_lottery_killed_rebuild_variance_2026_07_18]]`
addressed via a BUFG placement hoist; whether that fix's benefit has eroded since (cable reseat,
environmental drift, connector wear) is unconfirmed. **Do not re-chase this as an EPOCH_ANCHOR_EN
issue** — it reproduces identically regardless of which corrector is selected.

### 6.5 One window DID reach bilateral LINK_IDLE — the fix's real-silicon proof-of-engagement

One iteration reached bilateral FCSM=4/LINK_IDLE (die_a lock=`0xf5`, die_b lock=`0xee` — 7/8 lanes
each, **different** lanes missing per side) with cr=1/ck=1 both sides. Captured via `tlsnap.py`
before it could drop:
```
EPOCH=0x00000001 anchored=1 span=0 | LIVEMATCH=0xff (8/8) | SLICEMAP=0x76543210   -- BOTH dies
```
**`anchored=1` on both dies simultaneously is the hardware analogue of the sim banner's `(deskew:
m=1 s=1)` — direct proof the fix is genuinely engaged in the running bitstream, not just present in
the source.**

⚠ **Do NOT "fix" the still-set `swi_training_mode` (R8 bit0) in this state by running
`sync_bootstrap`.** The convergence script's own code explicitly gates that off exactly here
(`fs>=4 && cr=1` ⇒ SKIP), with the comment: *"sync_bootstrap in that state is HARMFUL: CTRL_DIS
zeros the deskew offsets and ... would break S->M."* Confirmed this is not the blocker by testing
data transfer directly instead (§6.6) rather than perturbing the state.

### 6.6 Data test in that window — inconclusive, NOT negative

`tltx1.py` (credit-gated single-word TX, already staged on die_a; copied to die_b via mapstone-dev
for this test — die_b did not have it before) → `tlfifo.py` (RX FIFO drain, already staged on both).
Sent one tagged word each direction, baseline-checked empty/full-credit RX FIFO on the receiver
first each time:
- **S2M (die_b→die_a):** TX confirmed clean (`txp=1 txw=1`, no stall, no credit issue) — die_a RX
  FIFO stayed **EMPTY**.
- **M2S (die_a→die_b) tested immediately after, as a sanity check, and ALSO failed identically** —
  same TX-confirmed / RX-empty pattern. **M2S is the direction sim proves already works regardless
  of `EPOCH_ANCHOR_EN`** (`test_02_packet_master_to_slave` passes in both the default and fixed sim
  configs). Both directions failing together, in a 7/8-lane (not 8/8) lock state, points at the
  missing lane breaking 128-bit word reassembly **generically** — not at anything S2M-specific, and
  not at the fix.

**Conclusion: this was a link-quality-too-low test, not a fix disproof. Do NOT read the S2M failure
here as evidence against `EPOCH_ANCHOR_EN` without re-testing in a clean 8/8-both-sides window.**

### 6.7 Rig state at end of session

Both leases released (had already expired naturally — 1hr TTL, session ran long). Both boards
confirmed free via `fpgahub board lease show`. Both dies left powered, still holding the
`tl-epochfix-8lane` image from the last deploy. No further re-deploys attempted after the decision
to stop for the night.

---

## 7. Pickup for the next session — what's actually left

1. **Characterize the rig's physical health before more software retries.** Which lane(s) sit at
   the IDELAYE2-tap ceiling, on which die — `sweep_perlane.py` / `sweep_dia.py` (staged on die_a) or
   a physical cable reseat + re-test. 57 re-deploys without a clean 16/16 is enough data to say this
   isn't going to resolve itself by re-rolling further.
2. **Once an 8/8-both-sides window is reachable (however achieved), redo the exact S2M + M2S pair
   test from §6.6 in that window.** That, and only that, is the real fix verification this handover
   is waiting on — everything upstream of it (RTL, sim, packaging, HW engagement) is done and
   verified.
3. **POR:** use a real power-cycle, not `--method jtag`, until the JTAG-reset-doesn't-reliably-return
   behaviour is separately understood. If it's used again and a board doesn't come back within
   ~30-45s, go straight to power-cycle rather than waiting longer or trying `--method uart`.
4. **Before committing:** re-check `git status` — this branch had concurrent commits and staged
   files from another session land on it mid-work tonight (see header). Stage the EPOCH_ANCHOR_EN
   files by explicit path, not `git add -A`.
5. If the data test in §6.6 passes cleanly in a real 8/8 window: the fix is done — ratify the
   netlist-change decision (§5's ⚠), then decide whether `TL_EPOCH_ANCHOR_EN=1` becomes the
   permanent default for the Z2 golden targets or stays an opt-in flag.
6. If it does NOT pass even at a clean 8/8 lock: that would be genuine new information (silicon
   skew fingerprint differs materially from the sim `EPOCH_PROFILE=silicon` model) — re-open §3/§4,
   do NOT assume the RTL threading itself is at fault (it's structurally verified sound).

---

## 8. Rig + traps

die_a = `z2_02` = **192.168.4.101** = MASTER · die_b = `z2_01` = **192.168.2.101** = SLAVE.
(⚠ `tl39.sh`'s `b` and `bringup_pair_converge.sh`'s default `SLAVE_IP` both point at
192.168.6.101 = z2_03 — the WRONG board, a spare not on the ribbon. Drive by IP explicitly.)
Leases: `show` first, `acquire` each **alone**, never chained with board ops. POR is mandatory
before every deploy — **use a hub power-cycle, not `fpgahub board reset --method jtag`** (§6.2: the
JTAG method left both boards unresponsive twice tonight; power-cycle recovered them reliably both
times). `fpgahub board reset pynq_z2_0{1,2} --method jtag` now at least works (fixed 2026-07-30/31,
§6.1) if you do use it, but don't rely on it to bring a dead board back.

Instruments staged on **both** boards (as of 2026-07-31): `/home/xilinx/tlsnap.py` (`snap` |
`rate <s>` | `set A V` | `syncclr`), `/home/xilinx/tltx1.py` (credit-gated single-word TX, run
detached — was die_a-only before tonight, now on both), and `/home/xilinx/tlfifo.py` (`status` |
`drain N` — sequential RX FIFO reader, never random-access, never write to the window).

Traps that cost real time this session:
1. **Counters SATURATE at 0xFFFF and are NOT read-clear**; `sync_obs_clr` does not clear them. Use
   deltas on an unsaturated counter.
2. **`LIVEMATCH` is NOT a health metric** — sticky-OR at Hamming tol 5 ⇒ ~10.5%/beat on noise ⇒
   `0xff` is the **noise floor**. A LOW value means **starvation**, not corruption.
3. **No software re-anchor** — `calibrated_once_q` makes `SWI_RECAL` a no-op. POR + winscan only.
4. **`tl39.py recal` wipes beacon bits** (`keep = rd(R8) & 1`). Pulse by hand: `0x1C→0x1E→0x1C`.
5. **`force_always` bypasses the payload-corruption drain guard** — anchor with `0x1C`, don't carry
   data with it.
6. **`sim_gate` without `source ./set_env.sh`** fails every suite in 4-5 s, looking like RTL breakage.
7. **V2 compiles `deps/tidelink-phy/rtl/wav/WavD2DGpioTx.v` (593 lines)**, not the 408-line
   `src/rtl/local_overrides/` copy, which is **V1-only**. Read the right file.
8. **`make package_ip` without `TIDELINK_PHY_V2=1` exported silently packages the V1 flist** — check
   the banner in `imp/fpga/run/package_ip.log` every time (§5 step 4).
9. **`bringup_pair_converge.sh`'s default `SLAVE_IP` is the wrong board** (§6.3) — same trap class
   as `tl39.sh`'s `b`, just rediscovered in a different script.
10. **`fpgahub board reset --method default` can silently resolve to a totally unrelated project's
    manifest action** if one happens to be bound to that board (§6.1) — check
    `fpgahub manifest show <target>` if a reset fails with an unexpected secret/error.

R8 `0x4403_2100` bits: `[0]` training `[1]` recal `[2]` insert_en `[3]` force_always `[4]` robust
`[5]` sync_obs_clr(W1). APB base `0x4403_2000`. ⚠ `0x21AC/0x21B0/0x21B4` hard-stall the CPU.

---

## 9. Separate defects found en route (not blockers, worth filing)

1. **`deps/tidelink-phy/rtl/wav/WavD2DGpio.v:541` lacks the payload-corruption drain guard**
   (`& (postcount == 8'h0)`). Three PHY-BIST flists/Makefiles compile that copy ⇒ those builds
   re-introduce silicon-proven beacon-on-payload corruption.
2. **V2 moved SYNC insertion post-mask → pre-mask** ⇒ on a 4-lane (`0xE4`) build V1 and V2 put
   physically different beacons on the wire. Undocumented.
3. Beacon training-gate polarity: V2 uses **raw**, V1 used **held** ⇒ V2's first post-training beacon
   is 64 words earlier.
4. `check_wav_drift.sh` cannot see `src/rtl/local_overrides/` ⇒ blind to the whole
   V1-override ↔ V2-override ↔ submodule-fork triangle.
5. `src/sw/tidelink_regs.generated.h:304-306` declares the fcsm field **4 bits** vs **3** in RTL.
6. `SOCL_L7_MIN_CRACK_EMITS` lowered 32→8 on the AXI FCSM nodes but `WlinkGenericFCSM_6.v:192` still
   defaults 32 and is not overridden at `TideLinkToWlink.v:149`.
7. **Another session reports `b98b944` (I1 FCSM, in `main`) breaks eth-chiplet bring-up**
   (`cr_seen=0 fcsm=0/1`). This branch's lineage predates the consolidation ⇒ unaffected. **Do not
   build z2 from `main` until that is bisected.**
8. **fpgahub: every `pynq_z2_*_ps` board's `[...secrets]` stanza is empty, and `_pl` has no reset
   method configured at all** (§6.1) — a fleet-wide gap, not urgent (the jtag-bypass workaround
   covers `_ps`), but worth a real fix (either populate the secret + fix the manifest binding, or
   just remove the dead `reset.default` shadowing) so `fpgahub board reset <board>` works
   out-of-the-box again.
