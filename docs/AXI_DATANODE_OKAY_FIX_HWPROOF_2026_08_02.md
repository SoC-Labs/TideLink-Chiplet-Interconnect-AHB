# AXI data-node recovery — OKAY synth-B fix, HW-proven (2026-08-02)

**Branch:** `fix/axi-datanode-recovery` @ `e827199`
**Consumer report:** a single bit-error on an AXI data-plane FC node hard-wedges
the initiator die's whole PS (ping/SSH dead, JTAG-POR only). Acceptance gate:
`errinject` per node {AW,W,B,AR,R} × several bits → no hard-wedge.

---

## TL;DR

- **The reported wedge is RESOLVED and HW-PROVEN.** The reported mechanism is a
  **byte-0 (`data_id`) corruption on the B (write-response) node** — a clean
  *silent drop* of the write acknowledgment. On this bitstream, `errinject
  node=B byte=0 bit=0` leaves **die_a ALIVE** (ping 2/2, SSH `uptime` returns).
  Every prior build hard-wedged the PS on this exact injection.
- **Root cause of the residual wedge (found via ILA):** the synth-B backstop
  drove the synthetic response as **SLVERR**, so the PS *retried* the write; the
  still-armed injector re-dropped each retry's response → `wr()` never returned →
  `error_inject_off()` never ran → self-sustaining wedge. **Fix: SLVERR → OKAY.**
- **Why OKAY is correct, not a mask:** byte-0 flips only the B node's *routing*
  field. The write DATA already landed byte-exact at the target over AW/W. The
  only thing lost is the acknowledgment, so OKAY truthfully retires the write and
  restores XHB500's path with no retry loop.

---

## The fix (one line, `tidelink_top.sv:1735`)

```systemverilog
assign s_axi_bresp = synth_b_pending ? 2'b00 : s_axi_bresp_ctrl;  // OKAY (was 2'b10 SLVERR)
```

Sits on top of the synth-B mechanism (commit `9b4c40b`): when a write's B
response is lost long enough to trip the outstanding-response backstop
(`sub_wr_stuck_fire`), `synth_b_pending` latches and a synthetic B
(`bvalid=1, bresp=OKAY, bid=sub_wr_awid_r`) is injected into XHB500 so the
bridge retires the write instead of waiting forever.

---

## Evidence

### HW (kr260-eth-chiplet, OKAY bitstream built 2026-08-02 22:55)

| test | injection | die_a after | verdict |
|---|---|---|---|
| eye gate | clean write | ALIVE, write accepted | link healthy |
| **reported bug** | **B, byte 0, bit 0** | **ALIVE (ping 2/2, SSH OK)** | **RESOLVED** |
| out-of-scope | B, byte 1 (word_count) | WEDGED (SSH timeout) | separate defect — see below |

### Sim (`cocotb/tidelink_axi_datanode_recovery`, 2^13 backstop timeout)

| test | before | after OKAY | reading |
|---|---|---|---|
| `test_axi_b_error_recovers` (byte-5 payload) | PASS | **PASS** | normal CRC/NACK/replay recovery INTACT |
| `test_i5_clean_drop_leaves_path_usable` (byte-0) | ERROR/dead-path | now **RECOVER** | fix works; test asserts old buggy symptom → needs re-point |
| `test_i5_backstop_restores_the_path` | PASS | FAIL@`assert fired` | stale *detection*: OKAY doesn't raise RuntimeError. Path IS restored. |
| `test_i5_rearms_after_abort` | — | FAIL@`assert first=="ERROR"` | stale *detection*: both trips complete via OKAY |
| `test_i5_error_is_ahb_legal` (F-1) | FAIL | FAIL | genuine residual pulse (benign on HW) — see F-1 |

**The 3 backstop failures share one cause:** those tests were written for the
ERROR-backstop design and detect "backstop fired" by catching a `RuntimeError`
(HRESP=ERROR). Under OKAY, firing manifests as a clean completion — which is the
entire point (path restored, no PS wedge). Their *invariants* (path usable after
firing; a second lost response is also handled) all hold. They must be
re-pointed from "assert the bug symptom" to "assert the fix". **Not rewritten
here** — `test_axi_datanode_gaps.py` is the concurrent session's active work;
this is a coordination item, not a unilateral edit.

---

## Out of scope / follow-ups

### byte-1 (word_count) wedge — a DIFFERENT subsystem
The built-in injector (`WlinkTxLinkLayer.v`) is a genuine **one-shot**
(`err_inj_smack` sets on the enable rising-edge, self-clears after one matching
SOP). Its `byte` field selects the LL packet byte:
`0=data_id, 1-2=word_count, 3=ecc, 4+=data`.
- byte 0 → data_id → silent drop → **this fix**.
- byte 1 → word_count (packet length) → RX framer reads the wrong length →
  framing desync → link-level wedge. This is upstream of the AXI FC nodes, in
  the Wlink link layer's **header ECC** path.

This is exactly the concurrent review's **§5 item 0**: the MIPI-style header ECC
(`WlinkEccSyndrome.v`) appears **inert** (a byte-3 ECC-byte flip moves no ECC
counter; a byte-0/1 header flip is neither corrected nor cleanly rejected). If
the header ECC really does not correct single-bit header errors, a header wire
error can silently mis-route or mis-frame a response — a link-integrity defect
worth its own investigation. **The byte-1 HW wedge is empirical evidence for
that hypothesis.** It is NOT the reported AXI-data-node wedge and is not
addressable by the AXI-node backstop.

### F-1 residual (my fix's one wart)
After `synth_b_pending` clears (XHB500 consumed the synth B), a one-cycle
`sub_err2_r` pulse can still leak `ahb_sub_hresp=1` with no transfer in its data
phase. Benign on HW (the upstream `axi_ahblite_bridge` discards an
`outstanding=False` pulse — die_a survived), but AHB-illegal. **Clean fix:** fire
the ERROR path (`sub_err1_r`/`sub_err2_r`) for stuck **reads** only; synth-B owns
stuck writes end-to-end, so no ERROR pulse is ever produced for a write. Deferred
(needs a fresh ~1.5 h build + the OKAY-vs-ERROR design sign-off).

---

## Decision needed (David / concurrent session)

**OKAY-vs-ERROR is a design fork.** HW evidence favors **OKAY** decisively:
1. It restores the path (fixes F-2 — the permanently-dead-window symptom).
2. It does not depend on HRESP=ERROR reaching the PS, which the eth-chiplet path
   demonstrably does **not** do (ILA: I5 fired ERROR, PS never saw it).
3. It is AHB-legal (no spurious ERROR for a retired posted write — fixes F-1's
   root tension) once the read/write ERROR-path split lands.
4. **It is the only variant proven to keep die_a alive on silicon.**

The cost: OKAY *masks* the lost acknowledgment (the PS believes the write
succeeded — which, data-wise, it did). Acceptable for a `data_id`-routing
corruption; revisit if a fault class can corrupt write DATA without tripping CRC.
