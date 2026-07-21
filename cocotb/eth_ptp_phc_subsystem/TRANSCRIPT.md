# eth_ptp_phc_subsystem — measured transcript

First-ever functional (driven) simulation of `ethernet_ss_ahb_phc`, joining the
two previously-separate halves of the grandmaster chain in ONE simv binary.

All runs: `EPOCH_PROFILE` N/A (no TideLink link in this bench), VCS, cocotb.

```
cd cocotb/eth_ptp_phc_subsystem
source ../../set_env.sh
source ~/SoCLabs/nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh
export TIDELINK_PHY_V2=1
rm -rf sim_build && make MODULE=test_phc_chain
```

## Final run — 5/5 PASS

```
running test_phc_chain.test_01_bringup_and_regs (1/5)
  [phc] reset released; sys_hresetn high, hclk running
  [phc] PHC seeded 0x1234, captured seconds = 0x1234
  PASS: PHC + HA1588 reachable through the subsystem AHB
running test_phc_chain.test_02_servo_disciplines_phc (2/5)
  [phc] HA1588 RTC witness: ns 3496 -> 13496 sec=0 TICKING
  [phc] before servo: PHC=100.000000380  RTC≈0 s
  [phc] after servo: PHC 100 s -> 0 s  (HA1588 RTC ≈ 0 s)
  PASS: servo disciplined the PHC onto the real running HA1588 RTC
running test_phc_chain.test_03_negative_control_servo_disabled (3/5)
  [phc] servo disabled: PHC held at 100 s (seeded 100)
  PASS: no servo activity while disabled; test_02 is attributable
running test_phc_chain.test_04_real_mii_ptp_capture (4/5)
  [phc] TSU depth BEFORE frame: rx=0 tx=0
  [phc] MII wire bytes: 55 55 55 55 55 55 55 d5 01 1b 19 00 00 00 00 1a 2b 3c 4d 5e 88 f7 00 02 00 2c ...
  [phc] wire frame @byte8: DA=01 1b 19 00 00 00 EtherType=0x88f7 == PTP OK
  [phc] HA1588 TSU depth tx=1 rx=1; TX.DATA3=0x032a0042 -> msg_id=0 seq_id=0x0042
  PASS: real MII PTP frame timestamped by HA1588 in the SAME sim as the servo join
running test_phc_chain.test_05_tsu_pop_localisation (5/5)
  [phc] TX depth=1
  [phc] pre-pop DATA0..3 = 0x00000000 0x00000000 0x00000000 0x032a0055 (DATA3 seq_id 0x0055)
  [phc] post-pop DATA0..3 = X X X X (X expected: single entry consumed -> empty-FIFO read)
  PASS: timestamp VALUE readable pre-pop; pop completes over a direct master =>
        the eth_ptp_chain wedge is LINK-specific, and the pop is unnecessary

** TESTS=5 PASS=5 FAIL=0 SKIP=0 **
```

## What each test proves

| test | claim | negative control |
|------|-------|------------------|
| 01 | `ethernet_ss_ahb_phc` elaborates AND RUNS; die can reach HA1588 + PHC over eth_ss_0 through the real interconnect + AHB->APB bridge | — (floor) |
| 02 | **THE JOIN**: `ha1588_servo` steps the PHC off a 100 s offset onto the REAL running HA1588 RTC, driven entirely through the subsystem AHB. `ha1588_hw_capture` + `ha1588_hw_set_time` witnessed on the top-level nets | test 03 |
| 03 | with the servo disabled the PHC holds its 100 s offset (no capture, no set-time) — makes 02 attributable to the servo | is the control |
| 04 | real L2 PTP frame DMA'd by the MAC, put on the MII wire by the real TX FSM, looped back, and timestamped by HA1588 (tx+rx TSU depth=1, seq_id 0x0042) — the capture half runs in the SAME simv as 02 | wire recorder = the instrument check |
| 05 | the eth_ptp_chain TSU-pop wedge is **LINK-specific**: over a DIRECT AHB master the pop + DATA reads complete; the value is readable PRE-pop (FWFT); the pop empties a depth-1 queue to X | direct-master vs cross-link |

## Honest scope limits (rigour bar)

- **Loopback, not a wire.** HA1588 timestamps a frame this same MAC sent — it
  cannot detect a common-mode offset shared by both MII directions.
- **The servo tracks the HA1588 RTC, not the TSU timestamp.** The RTL does not
  route the MII timestamp into the servo. The honest claim is that the same
  HA1588 that timestamps real MII traffic provides the RTC the servo disciplines
  the PHC to — not "a timestamped MII event moves the PHC".
- **No TideLink link here.** The PHC time is read through the real subsystem AHB,
  not across the chiplet link. Reading the disciplined PHC time across the link
  (demo item 3) is the remaining gap (see docs/ETHERNET_PTP_CHAIN_GAP.md §7).
- **Ideal MII/AHB timing != silicon rate.** M2 (physical PHY) is still required
  before any 1588 conformance claim.

## Files

| Path | Role |
|------|------|
| `tb_top.sv` | instantiates `ethernet_ss_ahb_phc`; MII loopback + wire recorder; eth_ss_0 driven by cocotb |
| `test_phc_chain.py` | the 5 tests + a minimal AHB-Lite master on eth_ss_0 |
| `Makefile` | expands `ethernet_ss_ahb_phc.flist`; stale-simv guard via flist_deps.mk |
| `image_spin.hex` | parks the M0+ (copied from eth_ptp_chain) |
```
```
