# Hardware A/B — HPROT tie-down, eth-chiplet vehicle, 2026-08-20

**Vehicle:** `kr260-eth-chiplet` (the target that instantiates `nanosoc_eth_chiplet.sv`).
die_a = kr260-01 (10.22.24.159), die_b = kr260-02 (10.22.24.153, flip a2lonly-28409f5).
**Arms differ by exactly 2 hunks** (the `.ahb_sub_hprot` line + the coupled guard demotion);
`ETH_IMEM_IMG` count 0 in both; trees otherwise byte-identical.
**Matched conditions both arms:** link `fcsm=4 cal=1` on both dies, CAM `0x2F->0x2D` programmed,
DMA channel `power/control=on`, ZDMA ADMA ch0 posted burst `AWCACHE=0x3`, dst `0x4_2F00_1000`.

## Result

| induce size | ARM B (pre-fix) | ARM A (fix in) |
|---|---|---|
| 256 B   | —                    | **COMPLETED** |
| 1024 B  | —                    | **COMPLETED** |
| 4096 B  | **ERROR** ISR=0x600 STS=0x3 | **COMPLETED** ISR=0x400 STS=0x0 |
| 16384 B | —                    | **COMPLETED** |
| 32768 B | —                    | **COMPLETED** |
| 65536 B | **ERROR** ISR=0x600 STS=0x3 | **COMPLETED** ISR=0x400 STS=0x0 |

## The decisive registers (0x4_2E03_21F8, marker 0xB5)

| field | ARM B (pre-fix) | ARM A (fix in) | meaning |
|---|---|---|---|
| `[4] pipe_hprot_r[2]` | **1** | **0** | the tie-down IS in effect on silicon |
| `[7:5] sub_wr_os_hwm` | **4** (saturated, earlier run) / 1 | **1** | hazard list never saturates with the fix |
| `[8] sub_wr_stuck_sticky` | **1** (fired) | **0** | write-stuck witness fires only pre-fix |
| `[0] raw hreadyout` | **0** (held) | **1** (ready) | |
| RegionF `0x21E0` | **0xAD400401** — `data_healthy=0` | **0xAD800000** — healthy | AXI-node fault only pre-fix |

Earlier same-day ARM B run, link up: `0xB5000491` -> `hprot2=1, hwm=4` (**hazard list SATURATED**,
`stall_stuck=1`) — the measured root-cause mechanism, reproduced on this vehicle.

## Verdict
**The tie-down is HARDWARE VALIDATED on the vehicle that instantiates the changed file.** The identical
posted-burst induction that faults the pre-fix build completes cleanly with the fix, and the
observability plane confirms the mechanism: `hprot[2]` no longer reaches the bridge, so the hazard
list cannot saturate.

## Caveats — do not over-read
- An earlier ARM A run at 65536 B hung the board. That run had a DIFFERENT link state (die_a
  re-anchored) and is treated as VOID, not as a negative result. Under matched conditions ARM A
  completes every size tested including 65536 B.
- Bring-up here is a documented marginal-eye lottery; it failed on several attempts in this session.
  Both arms were only compared at `fcsm=4` on both dies.
- ARM B faults (bounded AXI error) rather than hanging unboundedly. This build carries TL-037/N3/
  TL-043, which the tapeout pin does NOT — so the bounded outcome may be those backstops working.
  NOT established; it is a hypothesis worth a separate test.
- `TOTAL_BYTE` is a free-running counter that is not reset between runs; read DONE/ERROR and the
  OBS word, not that number.
- Throughput is still unmeasured. The fix forces AXI singles; the cost is real and unquantified.
- FPGA != ASIC configuration (ECC/CRC/FCSM differ). This validates the edit, not the tapeout config.
