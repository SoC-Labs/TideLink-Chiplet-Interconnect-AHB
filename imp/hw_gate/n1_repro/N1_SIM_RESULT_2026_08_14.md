# N1 — SIM RESULT: **OUTCOME 1, HANG REPRODUCED**. Tapeout blocker.

Branch `integ/tidelink-consolidated-2026-08-07`, HEAD `7701335`. Simulation only —
no board touched, nothing committed, no vendor IP modified, working tree left clean.

**VERDICT — outcome 1 of the three.** The write backstop **does** permanently disable
the read backstop. A coincident stuck READ + stuck WRITE on the `ahb_sub` port expires
the one shared age timer together; the read's 2-cycle AHB ERROR is fully masked by
`synth_b_pending`, `sub_rd_os_r` is cleared anyway, and because **both** ERROR fire
sites are gated on `sub_rd_os_r` neither backstop can ever fire for that read again.
Measured: the read received **no ERROR and no completion across 140,000 further hclk**
— more than the full 2^16 per-beat stall window — i.e. an unbounded PS hang with no
recovery. The audit's code-path reading (`ESCAPE_VS_SAFETY_AUDIT_2026_08_13.md`, N1)
is **confirmed in every particular**.

It reproduces **identically on the ASIC-mirror build** (recovery FCSMs absent), where
these backstops are the only recovery left.

A minimal 1-condition RTL fix is included as a patch file and is **sim-proven** to
convert the hang into a legal 2-cycle ERROR one timeout window later.

---

## 1. Test

| | |
|---|---|
| Test file | `cocotb/tidelink_axi_datanode_recovery/test_n1_read_backstop_defeat.py` (NEW) |
| Suite | `tidelink_axi_datanode_recovery` (PairV2TB / `run_bringup_full`, two TIDELINK_PHY_V2 dies at the ~40 ns silicon ratio) |
| RTL under test | `src/rtl/tidelink_top.sv` — working tree, which differs from HEAD **only** by 11 `(* mark_debug *)` attributes (`git diff --stat` = 11 insertions / 11 deletions, all attribute-only). Every line number cited below is identical in HEAD and in the working tree (`grep -n sub_rd_os_r` → :1645, :1658, :1659, :1674, :1675 in both). |
| Build | `EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13` — the same short I5 window the validated `make gaps_*` targets use. The per-beat stall backstop is **left at its 2^16 default** so "does anything rescue it later" is measured across a real stall expiry rather than assumed away. The N1 mechanism is a gating-term interaction and is timeout-value independent. |

```
source ./set_env.sh
make -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_n1 \
     EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13 \
     MODULE=test_n1_read_backstop_defeat \
     TESTCASE=test_n1_control_stuck_read_alone_gets_error          # PASS
make -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_n1 \
     EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13 \
     MODULE=test_n1_read_backstop_defeat \
     TESTCASE=test_n1_coincident_stuck_rd_wr_defeats_read_backstop # FAIL == N1 reproduced
```

Run per-TESTCASE (running the whole module in one sim gives spurious failures).

---

## 2. Why the coincident state is reachable — the previous "route is CLOSED" was wrong

`test_axi_datanode_gaps.py:test_i5_traffic_behind_a_stuck_write_is_bounded` measured
*"the route is CLOSED. XHB500 serialises the sub port"* and wrote the hazard off as
"a latent smell, not a reachable defect". **That conclusion is an artifact of its
address choice.** XHB500's AR gate is, in
`deps/xhb500/generated/xhb_chiplet_slv/logical/xhb500_ahb_to_axi_bridge_chiplet_slv/verilog/`:

```systemverilog
core_addr.sv:151-154   pause_addr_submit = ... | (~cntrl_1_out.hwrite &
                                                  (~ready_for_read || hazard_read)) | ...
core_addr.sv:139       hazard_read   = hazard & ~cntrl_1_out.hwrite;
hazard_list.sv:139     hazard        = |match_addr_i;
hazard_list.sv:84      match_addr_i[i] = (list_pointer > i) &
                                         (hazard_list_addr[i] == chk_addr[31:12]);
```

A read is blocked **only by a 4KB-PAGE ADDRESS MATCH** against a live EWR entry.
`hazard_full` / `hazard_empty` appear **only in the write arm** — list occupancy alone
never stalls a read. `ready_for_read` (`core_resp.sv:233`) counts outstanding **R beats
only** and is untouched by writes, and an EWR write never sets `wait_for_b`
(`core_wdata.sv:303`, `:248`), so it releases the AHB data phase without waiting for B.

The old test used `OFF_POST=0x400` and `OFF_RD=0x300` — **the same 4KB page** — so its
read was address-hazard-stalled behind the write and the coincidence never formed. Put
the read in a **different 4KB page** and the AR issues immediately while the write's B
is still outstanding. That is the only change needed, and it is an entirely ordinary
software access pattern (posted write to one page, read from another).

This test uses `ADDR_WR = 0x4000_0400` (page `0x40000`) and `ADDR_RD = 0x4000_1300`
(page `0x40001`). No forced handshakes are involved in the primary result.

---

## 3. Stimulus (all through real RTL paths)

1. `_bringup` — link up, CR/CRACK, clean sanity write; clean read of `ADDR_RD` proven
   working **before** the fault, so a later hang cannot be a broken read path.
2. Far terminus stalled — `dut.u_s_mng_bram.force_stall` (`tb_top.sv:1075`), the
   wedged-link model: neither B nor R ever comes back.
3. **3 bufferable (EWR, HPROT[2]=1) writes** in page `0x40000`. XHB500's
   early-write-response releases the AHB master immediately, so they sit outstanding on
   `s_axi` (`sub_wr_os_ctr = 3`) with the bus free. (3 ≥ 2 so the synth-B drain spans
   both ERROR cycles; XHB500's EWR hazard list is depth 4.)
4. **One blocking read** in page `0x40001` → AR accepted onto `s_axi`
   (`sub_rd_os_r = 1`) while the writes are still outstanding.

The TB trap was respected: **no `s_axi_awready`/`s_axi_wready` was ever forced low**
(that wedges XHB500 unrecoverably and would make post-recovery behaviour unobservable).
The primary test forces nothing at all; the backup vehicle
(`test_n1_forced_aw_coincidence`, `skip=True`, force-run only) forces the *valid*
`s_axi_awvalid` and was not needed.

---

## 4. Assertions and what they measured

### (a) The coincident state is genuinely entered — NON-VACUOUS

```
[n1] posted=3/3 sub_wr_os_ctr=3 osr_ctr=17
[n1] COINCIDENCE PROOF: {'rd_os': 1, 'wr_ctr': 3, 'osr_1': 21, 'osr_2': 25,
                         'timer_running': True}
[n1] N1: coincident_cycles=8172 first_coincident=44 coincident_at_expiry=True wr_ctr_max=3
```

`sub_rd_os_r=1` **and** `sub_wr_os_ctr=3` simultaneously, from cycle 44, with the shared
`sub_osr_ctr_r` **advancing** (21 → 25 over 4 cycles) — held for 8,172 consecutive
cycles, i.e. the entire timeout window, and still true **at the expiry**
(`coincident_at_expiry=True`). The test asserts each of these and fails as
"CANNOT CONSTRUCT / DOWNGRADED — THIS IS NOT A PASS" if any is absent, so a vacuous
pass is not reachable.

This is exactly the state last night's HW capture could not produce (`sub_rd_os_r` and
`rd_pipe_r` were 0 on every sample of every window — no read was ever outstanding).

### (b) `sub_err1_r` **is** suppressed by `synth_b_pending` — YES, 100%

```
err1_rises=1   err1_visible_cycles=0   err2_visible_cycles=0   port_err_pulses=0
```

The ERROR fires and is masked on **every** cycle it is asserted. Zero HRESP pulses ever
reach the master port.

### (c) `sub_rd_os_r` **is** cleared unconditionally — YES, with the ERROR undelivered

```
[n1] N1 rd_os CLEARED @8216: err1=1 sb=1 wr_ctr=3 port(rdy=0, rsp=0)
```

Cleared on the very cycle the (masked) ERROR was asserted, with the port showing
`HREADYOUT=0, HRESP=0` — nothing delivered.

### (d) The read never gets an ERROR or any completion — CONFIRMED PERMANENT

```
[n1] PRIMARY read class=HANG posted=3
port_err_pulses=0   hready_high_after_arm=2 (both pre-fault artifacts)
[n1] N1 EXPIRY @73754: rd_os=0 wr_ctr=0 osr_exp=0 st_exp=1 err1=0 sb=0
```

Observed for **140,000 hclk** after the fault. The 2^16 per-beat stall backstop **does**
expire at cycle 73,754 — and does nothing, because `:1645` is `if (sub_rd_os_r)` and
`sub_rd_os_r` is now 0. Nothing else ever fires. The I5 timer is parked at 0 forever
because `sub_axi_outstanding` is 0 once the synth-B drain retires the writes.

---

## 5. Cycle-level evidence (the whole defect in five cycles)

Timer window 2^13; `wr` = `sub_wr_os_ctr`, `sb` = `synth_b_pending`,
`port_rdy/rsp` = `m_ahb_sub_hreadyout` / `m_ahb_sub_hresp`.

```
T   8214 rd_os=1 wr=3 osr_exp=0 st_exp=0 err1=0 err2=0 sb=0 raw=0 port_rdy=0 port_rsp=0 bv=0 br=1
T   8215 rd_os=1 wr=3 osr_exp=1 st_exp=0 err1=0 err2=0 sb=0 raw=0 port_rdy=0 port_rsp=0 bv=0 br=1  <- T: shared timer expires with BOTH outstanding
T   8216 rd_os=0 wr=3 osr_exp=0 st_exp=0 err1=1 err2=0 sb=1 raw=0 port_rdy=0 port_rsp=0 bv=1 br=1  <- err1 AND sb rise together -> ERROR cy1 MASKED; rd_os cleared anyway
T   8217 rd_os=0 wr=2 osr_exp=0 st_exp=0 err1=0 err2=1 sb=1 raw=0 port_rdy=0 port_rsp=0 bv=1 br=1  <- ERROR cy2 MASKED; synth-B drain retires write 1
T   8218 rd_os=0 wr=1 osr_exp=0 st_exp=0 err1=0 err2=0 sb=1 raw=0 port_rdy=0 port_rsp=0 bv=1 br=1  <- drain retires write 2
T   8219 rd_os=0 wr=0 osr_exp=0 st_exp=0 err1=0 err2=0 sb=0 raw=0 port_rdy=0 port_rsp=0 bv=0 br=1  <- drain done, sb clears -- but err1/err2 are spent one-shots and rd_os is gone
T   8220 .. T 148000  rd_os=0 wr=0 err1=0 err2=0 sb=0 raw=0 port_rdy=0 port_rsp=0   (forever)
T  73754 st_exp=1 with rd_os=0  -> the 2^16 stall backstop fires into a dead gate
```

Note `sb` covers **both** ERROR cycles because 3 writes were outstanding — this is why
`N ≥ 2` matters. With exactly one outstanding write the drain clears `sb` one cycle
earlier and the response degenerates to a single-cycle `HRESP=1` with `HREADYOUT=1`, the
AHB protocol violation the audit predicted. Both sub-cases are wrong; the N ≥ 2 case
(the ordinary one — the whole SOAK-DRAIN fix of 2026-08-05 exists because N ≥ 2 EWR
writes outstanding is the normal condition) is the total-hang case.

### Non-vacuity control — the identical vehicle **with no coincident write** recovers

`test_n1_control_stuck_read_alone_gets_error` — **PASS**. Same far-terminus stall, same
read, no posted writes:

```
[n1] CONTROL: coincident_cycles=0 wr_ctr_max=0 err1_rises=1 err1_visible=1
              err2_visible=1 synthb_rises=0 port_err_pulses=2
T   8215 rd_os=1 wr=0 osr_exp=1 err1=0 err2=0 sb=0 port_rdy=0 port_rsp=0
T   8216 rd_os=0 wr=0 osr_exp=0 err1=1 err2=0 sb=0 port_rdy=0 port_rsp=1   <- ERROR cy1 DELIVERED
T   8217 rd_os=0 wr=0 osr_exp=0 err1=0 err2=1 sb=0 port_rdy=1 port_rsp=1   <- ERROR cy2 DELIVERED (legal 2-cycle AHB ERROR)
[n1] CONTROL read class=ERROR
```

The **only** difference between recovery and permanent hang is whether a write happened
to be outstanding on the same shared timer. That is the finding.

---

## 6. ASIC consequence — stated explicitly

**The ASIC is the worse case, and it was measured directly, not inferred.**

- `flists/tidelink_top_full_asic_v2.flist:315-320` holds `WlinkGenericFCSM` 0-4 on the
  recovery-**stripped** `deps` copies (2026-07-29 decision, pending silicon-ILA
  ratification), while `flists/tidelink_fpga_v2.flist:304-308` uses the
  `local_overrides` copies **with** recovery. `src/rtl/tidelink_top.sv` is in the ASIC
  flist at `:409`. So on the ASIC these two backstops are the **only** recovery
  mechanism left on the `ahb_sub` path — precisely the thing N1 disables.
- The primary result above was obtained on the **FPGA** config (recovery FCSMs
  **present**) — i.e. the *more* protected build — and still hangs.
- Re-run under `ASIC_MIRROR=1` (`WlinkEccSyndrome`=local, `WlinkGenericFCSM*`=deps —
  the shipping ASIC-V2 wlink error-path combination): **bit-identical failure**, same
  cycles.

```
ASIC_MIRROR=1 : coincident_cycles=8172 first_coincident=44 coincident_at_expiry=True
                wr_ctr_max=3 err1_rises=1 err1_visible=0 err2_visible=0 port_err_pulses=0
                EXPIRY @8215 rd_os=1 wr_ctr=3 ; rd_os CLEARED @8216 err1=1 sb=1
                EXPIRY @73754 st_exp=1 rd_os=0 ; read class=HANG
```

Consequence on silicon: any coincident stuck read + stuck write on `ahb_sub` — which is
the *ordinary* shape of a wedged link, not an exotic corner — produces a **PS hang with
no bus error, no timeout, and no software-visible symptom**, from which nothing in the
shipping ASIC recovers. It interacts with **TL-037** (no AXI firewall): the read path's
only backstop is defeated exactly where the firewall is absent. FPGA-proven recovery
results do not transfer, and no existing gate test covers this — the ERROR-suppression
and the unconditional clear are each individually invisible to every test that drives
one channel at a time.

**Recommendation: tapeout blocker until fixed.** The fix below is one condition.

---

## 7. Minimal RTL change that breaks the chain — sim-proven

`imp/hw_gate/n1_repro/n1_fix_sub_rd_os_r_conditional_abandon.patch`
(patch file only; `git apply --check` verified against **both** the working tree and
HEAD `7701335`; nothing applied, nothing committed).

The chain has two links. `:1645` is self-healing — it fires a masked ERROR but does not
clear `sub_rd_os_r`, so the next window re-fires it. **The unconditional clear at `:1675`
is the sole non-self-healing link**, so that is the whole fix:

```systemverilog
-                if (sub_rd_os_r) sub_err1_r <= 1'b1;  // 2-cycle ERROR (read only)
-                sub_rd_os_r   <= 1'b0;                 // abandon the timed-out READ txn
+                if (sub_rd_os_r && (sub_wr_os_ctr == 3'd0) && !synth_b_pending) begin
+                    sub_err1_r  <= 1'b1;  // 2-cycle ERROR (read only)
+                    sub_rd_os_r <= 1'b0;  // abandon the timed-out READ txn
+                end
```

Abandon the read **only when its ERROR will actually be visible**: no synth-B drain in
flight (`!synth_b_pending`) and none about to arm on this same expiry — inside this
branch `sub_osr_expired == 1`, so `sub_wr_stuck_fire` reduces to `sub_wr_os_ctr != 0`.
Otherwise `sub_rd_os_r` stays set, `sub_osr_ctr_r` restarts, the synth-B drain retires
the stuck writes, and the next window delivers a legal ERROR. Recovery is deferred by
one timeout window instead of being lost forever. No new state, no new signal, no
change to the write path, no change to the `:1898`/`:1906` muxes.

**Verified in sim** (fixed copy staged via `+incdir+` override — the tracked tree was
never modified — same TESTCASE, same stimulus, same short window):

```
[n1] posted=3/3 sub_wr_os_ctr=3 ; COINCIDENCE PROOF {'rd_os':1,'wr_ctr':3,'timer_running':True}
[n1] N1: coincident_cycles=8175 first_coincident=44 coincident_at_expiry=True wr_ctr_max=3
        err1_rises=1 err1_visible=1 err2_visible=1 synthb_rises=1 port_err_pulses=2
[n1] N1 EXPIRY @8215:  rd_os=1 wr_ctr=3 osr_exp=1   <- read NOT abandoned; writes drain
[n1] N1 EXPIRY @16411: rd_os=1 wr_ctr=0 osr_exp=1   <- one window later, alone
[n1] N1 rd_os CLEARED @16412: err1=1 sb=0 wr_ctr=0 port(rdy=0, rsp=1)   <- ERROR DELIVERED
[n1] PRIMARY read class=ERROR
TESTS=1 PASS=1 FAIL=0
```

Non-vacuity of the fix run: the coincident state is entered **identically**
(`coincident_cycles=8175`, `first_coincident=44`, `wr_ctr_max=3`,
`coincident_at_expiry=True`) and the synth-B write backstop still fires
(`synthb_rises=1`) — the fix does not dodge the scenario, it survives it. The write
path behaviour is unchanged: the same one synth-B drain retires the same 3 writes.

Recovery latency cost: exactly one timeout window (8215 → 16411 = 8196 cycles = 2^13
in this build; 2^16 hclk ≈ 2.6 ms at 25 MHz in the shipping build) — bounded, and
compared against never.

**Not yet done for this fix:** `make sim_gate`, and a check that no existing test
depends on the read being abandoned on a coincident expiry. Both are required before
it lands.

---

## 8. Files

| Path | |
|---|---|
| `cocotb/tidelink_axi_datanode_recovery/test_n1_read_backstop_defeat.py` | the test (new, untracked) |
| `imp/hw_gate/n1_repro/n1_fix_sub_rd_os_r_conditional_abandon.patch` | the fix, patch only |
| `imp/hw_gate/n1_repro/N1_SIM_RESULT_2026_08_14.md` | this file |

Raw logs (session scratchpad, not in the repo):
`n1_control.log`, `n1_primary.log`, `n1_fix_primary.log`, `n1_asic_primary.log` under
`/tmpdir/claude-74755/-home-dam1n19-SoCLabs-tidelink/029fa128-e7f4-41b2-a3bf-6880af5cca50/scratchpad/`.

**Working tree state.** `git diff --stat` on `src/rtl/tidelink_top.sv` shows
11 insertions / 11 deletions — the pre-existing `mark_debug` edits from another session,
byte-identical before and after this work (md5 `03b1c3b935f789dd3e9b7597ee518fe6` at both
ends). Nothing under `/research/AAA/ip_library` or `phys_ip_library` was read-modified or
written. Nothing was committed. No board was touched.
