# TL-059 hardware evidence (KR260, kr260-pair-onchip)

Raw result lines from the KR260 acceptance runs of the TL-059 fix (design E, PR #8, merge `fc0ee9a5`).
Host paths and board IP addresses are scrubbed; nothing else is edited.

| Image | Source commit | bit sha256 | Role |
|---|---|---|---|
| unfixed | `a652c73e` (main before the fix) | `9c4b9422…` | baseline |
| fixed | `a7a5ddd9` (PR #8 head) | `45c7803d…` | fix under test |

Both images: V2 PHY, `git_dirty` false, timing met; the fixed image's build check found all 34 fix
markers, including the 3 TL-059 markers, in the sources Vivado synthesised.

## Files

| File | What it shows |
|---|---|
| `unfixed_crc_stats_{a2b,b2a}.txt` | 30/30 detected sideband CRC shots LOST per direction (DataID 0xA1, payload bytes 4-11) |
| `fixed_crc_stats_{a2b,b2a}.txt` | 30/30 detected shots replayed exactly once per direction; 0 lost, 0 stray, 0 duplicate |
| `fixed_runA_summary.tsv` | full step list of the fixed-image run: autonomy, 2 x 5000-word soak, B19 dip control, CRC controls |
| `fixed_bringups_run{1,2,3}.tsv` | cold bring-ups (POR, deploy, autonomy, 28-word stream start, smoke, health). 31 PASS here plus 1 in run A = 32/32. The 3 FAIL rows are cycles aborted because the second board (kr260-02, not used by this onchip test) did not come back after a JTAG reset |
| `fixed_stream_results.txt` | every stream start on the fixed image: NO_STORM_OBSERVED, exact, 0.31-0.33 ms |
| `unfixed_baseline_stream_results.txt` | the same stream test on the unfixed image (calibration): identical latency, no storm |

Injection: Wlink LINK_ERROR_INJECTION at TLAPB+0x23C of the transmitting die, one single-bit payload error
per shot; die_b is the slave and its Wlink APB bank is writable only with debug-unlock asserted, which the
test sets around each shot.
