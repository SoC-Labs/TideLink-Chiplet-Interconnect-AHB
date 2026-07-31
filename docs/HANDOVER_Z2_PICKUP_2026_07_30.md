# Z2 pickup — state as of 2026-07-30

**Branch:** `fix/z2-drop-park-hook` @ `a5df514` (not pushed)
**Supersedes:** `docs/HANDOVER_SYNC_CLOCK_GATE_2026_07_29.md` — **that document's root cause is
REFUTED.** Read this one first; read that one only for the raw measurements it records.

---

## 1. Where things actually stand

| | Status |
|---|---|
| **Bring-up** | ✅ **FIXED and reproducible from git.** Zero-poke: `cal=1 fcsm=4 cr=1 ck=1`, EPOCH anchored span 0, LIVEMATCH 8/8, SLICEMAP identity `0x76543210` on both dies. |
| **Data delivery** | ❌ Still zero. Root cause fully chained (§3) and the fix **proven in sim** (§4). Remaining work is one parameter hop (§5). |

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
Consider making that tier blocking for FPGA-bound lineages.

---

## 5. Remaining work — one missing parameter hop

Already present: `WlinkGPIOPHY_v2.v:63` has `parameter EPOCH_ANCHOR_EN = 1'b0` and forwards it at
`:248`; `WavD2DGpio_v2.v:159` has it and sets the deskew's `SYNC_REANCHOR_EN` as its **complement**
(`:158`) ⇒ **one knob**, mutual-exclusion elab guard satisfied automatically.

**`src/rtl/local_overrides/Wlink.v` has NO occurrence of `EPOCH_ANCHOR_EN` — that is the gap.**

1. Add `parameter EPOCH_ANCHOR_EN = 1'b0` to `Wlink.v`; pass it on its `WlinkGPIOPHY` instantiation.
2. Pass it from `axi_chiplet_controller.sv`'s Wlink instance.
3. Surface it on `tidelink_top.sv` → `src/rtl/asic/tidelink_dft_wrapper.sv` →
   `fpga/vivado_ip/tidelink_vivado_wrapper.v`. **The IP-face param is MANDATORY** — a `+define+` or
   RTL default does NOT reach packaged-IP OOC synth (documented trap; same class as
   `DEBUG_UNLOCK_DEFAULT` / `TRAIN_ENTRY_FALLBACK`).
4. `make package_ip` then **verify STRUCTURALLY** (`grep` the packaged copy), never by md5.
5. Re-run §4 **without** the TB define but with the new param = 1: must still print `(deskew: m=1
   s=1)` and 3/3. That proves the real plumbing end to end.
6. Then FPGA build + HW test.

⚠ **This is a real netlist change** (swaps which deskew corrector is compiled in) ⇒ needs a ratify
decision like any tapeout-affecting change.
⚠ **Sim proof ≠ silicon proof.** The silicon profile is a MODEL of the v37 skew fingerprint, not the
z2 boards' actual skew.

---

## 6. Rig + traps

die_a = `z2_02` = **192.168.4.101** = MASTER · die_b = `z2_01` = **192.168.2.101** = SLAVE.
(⚠ `tl39.sh`'s `b` points at 192.168.6.101 = z2_03 — the WRONG board. Drive by IP.)
Leases: `show` first, `acquire` each **alone**, never chained with board ops. POR members are
`pynq_z2_02_ps` and `pynq_z2_01_pl`. POR is mandatory before every deploy.

Instruments staged on both boards: `/home/xilinx/tlsnap.py` (`snap` | `rate <s>` | `set A V` |
`syncclr`) and `/home/xilinx/tltx1.py` (credit-gated single-word TX, run detached).

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

R8 `0x4403_2100` bits: `[0]` training `[1]` recal `[2]` insert_en `[3]` force_always `[4]` robust
`[5]` sync_obs_clr(W1). APB base `0x4403_2000`. ⚠ `0x21AC/0x21B0/0x21B4` hard-stall the CPU.

---

## 7. Separate defects found en route (not blockers, worth filing)

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
