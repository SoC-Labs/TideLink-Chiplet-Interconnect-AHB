# KR260 AFI width check — one-page bench checklist

**What this fixes:** the KR260 control-plane defect — 32-bit AXI writes/reads at
misaligned lanes are dropped / read as 0 (e.g. `0x8403_0214` write ignored, PHC
`0x8405_0008` ignored), while a hardwired register like `0x8403_0200 = 0x88` still
reads correctly.

**Why:** on plain-Ubuntu KR260 the design's `psu_init` never runs, so the stock SOM
firmware owns the AFI PS-master-port widths. Our BD wants **32-bit** on both used
ports; the firmware may leave one wider. Re-poking `afi_fs` to 32-bit fixes it.

**When:** right after **every** PL load, **before any AXI traffic** (`afi_fs` is
static — only safe to reprogram while the PL is quiescent). Not persisted — re-run
on every boot / every `fpgautil` load. Do this on **BOTH** boards.

Turnkey: `sudo sh pynq_host/scripts/kr260_afi.sh fix` does everything below and
exits non-zero on any failure. The manual commands are here for the bench log.

---

## Registers

| Register  | Address        | Field   | Meaning                     |
|-----------|----------------|---------|-----------------------------|
| LPD_SLCR  | `0xFF419000`   | `[9:8]` | HPM0_LPD width (control)    |
| FPD_SLCR  | `0xFD615000`   | `[9:8]` | HPM0_FPD width (data)       |
| FPD_SLCR  | `0xFD615000`   | `[11:10]`| HPM1_FPD width (UNUSED — leave alone) |

Width field encoding: `00 = 32-bit` (what we want), `01 = 64-bit`,
`10 = 128-bit`, `11 = reserved`.

## 1. CHECK (read-only)

```sh
sudo devmem 0xFF419000 32     # LPD_SLCR
sudo devmem 0xFD615000 32     # FPD_SLCR
```

Decode bits `[9:8]` of each: `(val >> 8) & 0x3`.

| Read      | `[9:8]` before (mismatch) | `[9:8]` after fix | Interpretation      |
|-----------|---------------------------|-------------------|---------------------|
| `0xFF419000` | non-zero (e.g. `0b01`/`0b10`) | `0b00` | HPM0_LPD width |
| `0xFD615000` | non-zero                     | `0b00` | HPM0_FPD width |

If both are already `00` → AFI is **not** the defect (refutes the AFI hypothesis;
escalate to the SmartConnect/BD trace, recovery-plan contingency lane C).

## 2. FIX (read-modify-write, clears `[9:8]` only)

Read first, then write back with `[9:8]` cleared (`& ~0x300`), leaving `[11:10]`
(HPM1) untouched:

```sh
# control plane (LPD)
V=$(sudo devmem 0xFF419000 32); sudo devmem 0xFF419000 32 $(( V & ~0x300 ))
# data plane (FPD) — clears [9:8], preserves HPM1 [11:10]
V=$(sudo devmem 0xFD615000 32); sudo devmem 0xFD615000 32 $(( V & ~0x300 ))
```

Re-read (step 1) to confirm both `[9:8]` now read `00`. If a write does not stick,
the port is being held — stop and investigate before running any AXI traffic.

## 3. CANARIES (prove the control + data planes now decode 32-bit words)

```sh
sudo devmem 0x84030204 32     # role      -> expect 0x00000001
sudo devmem 0x84030214 32     # lane mask -> expect 0x0000E4E4
sudo devmem 0x84030200 32     # NEG ctrl  -> 0x00000088 (works regardless of AFI)
```

PHC round-trip (write-then-read a scratch data-plane register):

```sh
sudo devmem 0x84050008 32 40  # write 40
sudo devmem 0x84050008 32     # -> expect 0x00000028 (= 40 decimal)
```

| Canary        | Expected      | Meaning                                            |
|---------------|---------------|----------------------------------------------------|
| `0x84030204`  | `0x00000001`  | role reg reads through the control plane           |
| `0x84030214`  | `0x0000E4E4`  | lane-mask reg reads through the control plane      |
| `0x84050008` write 40 → read | `40` (`0x28`) | data plane accepts a 32-bit write + read-back |
| `0x84030200`  | `0x00000088`  | **negative control** — hardwired, decodes even with the AFI wrong; proves the APB is alive but says nothing about the fix |

**Pass criteria:** `0x84030204 == 0x1` **and** `0x84030214 == 0xE4E4` **and** the
PHC write reads back `40`. The negative control `0x84030200 == 0x88` is *not* a
gate — it works regardless; it is only there to confirm the APB is responding at
all.

If widths read `00` but the canaries still fail, the AFI width was not the (only)
cause — do **not** keep poking `afi_fs`; escalate to the BD/SmartConnect trace.

## 4. Repeat on the second board

Do all of the above on **both** `kr260_01` (die_a, `10.22.24.159`) and `kr260_02`
(die_b, `10.22.24.153`). Re-run after any power-cycle or PL reload.
