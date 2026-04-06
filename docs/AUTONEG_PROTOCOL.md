# TideLink I2C Auto-Negotiation Protocol — Specification and Design Justification

**Version**: 0.1
**Date**: 2026-04-06
**Status**: Proposed — RTL not yet implemented
**Authors**: David Mapstone (d.a.mapstone@soton.ac.uk), SoC Labs, University of Southampton
**License**: Joint work under Arm Academic Access license
**Copyright**: 2026, SoC Labs (www.soclabs.org)

---

## Table of Contents

1. [Overview and Motivation](#1-overview-and-motivation)
2. [Hardware Context](#2-hardware-context)
3. [Protocol State Machine](#3-protocol-state-machine)
4. [Register Additions and Modifications](#4-register-additions-and-modifications)
5. [Hardware Cost Analysis](#5-hardware-cost-analysis)
6. [Key RTL Changes](#6-key-rtl-changes)
7. [Timeout and Error Handling](#7-timeout-and-error-handling)
8. [Software Bypass Mechanism](#8-software-bypass-mechanism)
9. [Integration with the Existing Boot Flow](#9-integration-with-the-existing-boot-flow)
10. [Verification and Test Plan Considerations](#10-verification-and-test-plan-considerations)
11. [Design Justification](#11-design-justification)
12. [Constraints and Limitations](#12-constraints-and-limitations)

---

## 1. Overview and Motivation

### 1.1 The Static Role Assignment Problem

Every `tidelink_top` instance contains an `axi_chiplet_controller` that requires one side of the link to act as I2C master (configuring the remote Wlink over the sideband) and the other to act as I2C slave (receiving that configuration). The role is currently determined statically:

1. Before role lock: `role_effective` follows the `role_strap_i` pin.
2. After role lock: `role_effective` follows `role_cfg_reg` (ROLE_CFG[0]).

The relevant RTL (`axi_chiplet_controller.sv`, lines 252-254):

```systemverilog
wire role_locked    = role_lock_reg;
wire role_effective = role_locked ? role_cfg_reg : role_strap_i;
wire role_is_master = ~role_effective;
```

This approach requires physical differentiation of the two chiplets — via board-level strap pins or firmware compiled with hardcoded role assignments. In a symmetric chiplet design where both dies are identical (same silicon, same mask, same firmware image), there is no mechanism to ensure the two sides consistently adopt opposing roles at power-on. An assembly error, a missing pull resistor, or a firmware update that does not account for role assignment can leave both chiplets attempting to drive SCL as master, or both waiting passively as slaves, preventing link training from ever completing.

### 1.2 The Auto-Negotiation Solution

This specification defines an I2C-based auto-negotiation protocol that uses the existing I2C sideband hardware present in every `axi_chiplet_controller` instance to dynamically agree on master/slave roles before the Wlink link trains. The protocol:

- Requires no physical differentiation between chiplet instances.
- Operates entirely within the existing I2C sideband hardware.
- Adds a new negotiation phase between power-on reset and role lock.
- Is fully backward-compatible via a software bypass that restores the original static-assignment behaviour.

### 1.3 Scope

This document covers the protocol design, register additions, RTL changes, firmware requirements, and verification considerations for the auto-negotiation feature. It is intended to complement the main `TIDELINK_SPECIFICATION.md` and `REGISTER_MAP.md` documents.

---

## 2. Hardware Context

### 2.1 Existing I2C Hardware

The `axi_chiplet_controller` already instantiates **both** an I2C master core and an I2C slave core. Only one is active at any time: the active core is determined by `role_is_master`, which is computed combinationally from the role registers:

```systemverilog
// Reset gating — inactive core is held in reset
wire i2c_mst_reset = ~hresetn | ~role_is_master;   // line 315
wire i2c_slv_reset = ~hresetn |  role_is_master;   // line 316

// Pin mux — active core drives the physical pins
assign i2c_scl_o = role_is_master ? mst_scl_o : slv_scl_o;   // line 568
assign i2c_scl_t = role_is_master ? mst_scl_t : 1'b1;         // line 569
assign i2c_sda_o = role_is_master ? mst_sda_o : slv_sda_o;   // line 570
assign i2c_sda_t = role_is_master ? mst_sda_t : slv_sda_t;   // line 571
```

The I2C master is accessed by software via a full AXI4 sideband port (`s_i2c_axi_*`) that is bridged internally through `mkaxi2axil_bridge` to an AXI-Lite port, which drives `i2c_master_axil`. The I2C slave (`i2c_slave_axil_master`) acts as an AXI-Lite master that bridges received I2C register writes to an internal APB bus, giving the remote I2C master access to Wlink configuration registers.

### 2.2 The Critical Constraint: I2C Mux Follows `role_is_master`

The I2C pin mux is driven directly by `role_is_master`, which itself is driven by `role_effective`, which is driven by `role_strap_i` before lock. This means:

- **Before lock**: whichever value `role_strap_i` presents determines which I2C core is connected to the physical pins.
- **After lock**: `role_cfg_reg` determines it.

For auto-negotiation to work, **both sides must start with the I2C slave active** (so neither side initially drives SCL), and one side must be able to switch to I2C master (begin driving SCL) without first locking the role. This requires a change to how `role_effective` is computed during the negotiation phase. Section 6 details the precise RTL modification required.

### 2.3 The Wlink POR Gating Constraint

Wlink is held in reset until the role is locked:

```systemverilog
wire wlink_por_reset = ~poresetn | ~role_locked;   // line 310
```

Auto-negotiation must complete and `role_lock` must be written before Wlink can train. The negotiation protocol must therefore be fast enough not to exceed the link training timeout of the higher-level system. In practice, the negotiation window is on the order of milliseconds — negligible relative to Wlink GPIO-mode training times (~10,000 cycles at 100 MHz = 100 µs).

### 2.4 I2C Slave Address Consideration

The I2C slave address is configurable via `I2C_SLV_ADDR` (0x2088, 7-bit, default 0x00). For auto-negotiation, both chiplets must use the same slave address so that the claimer (acting as I2C master) can address the peer (acting as I2C slave). The slave address used during negotiation is defined by a new configuration register (`NEGO_ADDR`, Section 4); it defaults to a fixed reserved value (0x7E, which is outside the valid 7-bit range 0x00-0x77, so it cannot conflict with production device addresses assigned after lock — note that the auto-negotiation slave address is only active during the negotiation window, after which `I2C_SLV_ADDR` takes over normal operation).

> **Implementation note**: Address 0x7E is the I2C 10-bit addressing prefix in some I2C implementations. Some I2C slave IP cores accept this address and some do not. Implementers should verify that the target `i2c_slave_axil_master` core accepts 0x7E as a valid 7-bit address or select a different reserved value (e.g. 0x7F, General Call = 0x00). The address is a register default and can be overridden.

---

## 3. Protocol State Machine

### 3.1 State Overview

The auto-negotiation protocol extends the existing role-selection window (between `poresetn` release and `role_lock`) with a defined negotiation phase. The protocol FSM is implemented in a new hardware block (`tidelink_autoneg`) inside `axi_chiplet_controller`.

States:

| State | Name | Description |
|-------|------|-------------|
| `IDLE` | IDLE | Waiting for negotiation to be enabled |
| `NEGO_INIT` | Negotiation Init | Both cores initialised; I2C slave active; negotiation timer running |
| `NEGO_WAIT` | Priority Wait | Waiting for the priority-based backoff timer to expire |
| `NEGO_CLAIM` | Claiming Master | Switched to I2C master; initiating "claim master" I2C write |
| `NEGO_POLL` | Polling Result | Waiting for I2C transaction to complete; checking ACK/NACK |
| `NEGO_DONE` | Negotiation Done | Role decided; setting `role_cfg_reg` and `role_lock_reg` |
| `NEGO_BYPASS` | Bypass Active | Auto-negotiation disabled; static assignment path active |
| `NEGO_ERROR` | Error | Timeout or unresolvable condition; role forced by fallback |

### 3.2 Detailed State Machine

```
After poresetn release:
                    ┌──────────────────────────────────────────────────────────┐
                    │                                                          │
                    ▼                                                          │
               ┌─────────┐  NEGO_EN=0 or          ┌──────────────┐            │
               │  IDLE   │──BYPASS=1─────────────► │ NEGO_BYPASS  │            │
               └─────────┘                         │ (static path)│            │
                    │ NEGO_EN=1, BYPASS=0           └──────────────┘            │
                    │                                      │                   │
                    ▼                                      │ CPU writes        │
               ┌───────────┐                              │ role_lock=1       │
               │ NEGO_INIT │                              ▼                   │
               │           │                         role locked              │
               │ Both sides:                         Wlink trains             │
               │  I2C slave│                                                   │
               │  active   │                                                   │
               └───────────┘                                                   │
                    │                                                           │
                    │ (immediately — priority timer starts)                     │
                    ▼                                                           │
               ┌────────────┐                                                  │
               │ NEGO_WAIT  │◄─────────────────────────────────────────────┐  │
               │            │                                               │  │
               │ Counting   │  SDA goes low before our timer expires?       │  │
               │ down from  │  (peer already claiming)                      │  │
               │ NEGO_DELAY │──Yes: we become slave──────────────────────────► NEGO_DONE
               │            │                                                  │  (slave)
               └────────────┘                                                  │
                    │ Timer expires; SDA still high                             │
                    │ (bus idle, we are first)                                  │
                    ▼                                                           │
               ┌────────────┐                                                  │
               │ NEGO_CLAIM │                                                  │
               │            │                                                  │
               │ Switch I2C │                                                  │
               │ mux to     │                                                  │
               │ master mode│                                                  │
               │            │                                                  │
               │ Write via  │                                                  │
               │ I2C master:│                                                  │
               │  addr=NEGO_│                                                  │
               │  ADDR,     │                                                  │
               │  data=0x01 │                                                  │
               └────────────┘                                                  │
                    │                                                           │
                    ▼                                                           │
               ┌────────────┐  ACK received         ┌────────────┐            │
               │ NEGO_POLL  │──(peer is slave)──────►│ NEGO_DONE  │            │
               │            │                        │            │            │
               │ Wait for   │  NACK received         │ role_cfg   │            │
               │ i2c_nbsy   │──(peer also claimed)──►│ =master(0) │            │
               │ _irq       │  → I2C arbitration     │ or slave(1)│            │
               │            │  winner becomes master │            │            │
               │            │──Timeout──────────────►│ role_lock  │            │
               │            │  (fallback by priority)│ =1 (W1S)   │            │
               └────────────┘                        └────────────┘            │
                    │                                      │                   │
                    │                                      ▼                   │
                    │                               Wlink POR releases         │
                    │                               Link training begins       │
                    │                                                           │
                    │ Overall negotiation timeout                               │
                    ▼                                                           │
               ┌────────────┐                                                  │
               │ NEGO_ERROR │──────────────────────────────────────────────────┘
               │            │  Force role from NEGO_FALLBACK field
               │ (interrupt │  Lock role anyway
               │  asserted) │
               └────────────┘
```

### 3.3 Priority-Based Backoff Mechanism

Each chiplet computes a backoff delay (`NEGO_DELAY`) before attempting to claim master. A lower numeric priority value means a shorter delay, so the higher-priority chiplet claims first. Priority sources (in decreasing precedence):

1. **Software override** (`NEGO_CFG[NEGO_PRI_SEL]=0`): Priority read from `NEGO_PRIORITY[15:0]` register, written by firmware before negotiation starts.
2. **External port** (`NEGO_CFG[NEGO_PRI_SEL]=1`): Platform-specific. The priority value is supplied via a new input port `nego_priority_i[15:0]` to `axi_chiplet_controller`. The SoC integrator can connect this to OTP fuses, a chiplet UID, or an SRAM PUF entropy source (see Section 3.6).
3. **SRAM PUF** (`NEGO_CFG[NEGO_PRI_SEL]=2`): An optional hardware block (`tidelink_sram_puf`) reads N words from the TideLink FIFO SRAM at power-on — before any software writes — and XOR-folds them into a 16-bit priority value. SRAM bitcells settle to random states determined by manufacturing-process transistor mismatch, producing a value that differs between physical dies even when the dies are otherwise identical. This is the recommended source for symmetric chiplet deployments. See Section 3.6.
4. **Hardware default** (`NEGO_CFG[NEGO_PRI_SEL]=3`): The default priority is 0xFFFF (maximum delay) as a safe fallback. In this mode both sides will time out and the `NEGO_FALLBACK` field determines the role.

The delay in clock cycles is:

```
nego_delay_cycles = NEGO_PRIORITY[15:0] × NEGO_TICK + NEGO_BASE_DELAY
```

Where:
- `NEGO_TICK` is the number of `apb_clk` cycles per priority unit (a new parameter, default 1000, giving 10 µs per unit at 100 MHz).
- `NEGO_BASE_DELAY` is a fixed minimum delay in cycles before any side can attempt to claim (a new parameter, default 2000 cycles = 20 µs at 100 MHz), ensuring both I2C slave cores have had time to initialise.

For two chiplets with priorities P0 and P1 (P0 < P1), side 0 begins claiming at `P0 × NEGO_TICK + NEGO_BASE_DELAY` cycles, side 1 at `P1 × NEGO_TICK + NEGO_BASE_DELAY`. So long as `|P1 - P0| × NEGO_TICK` exceeds the I2C START condition setup time plus one I2C byte transfer time (typically ~100 µs at 100 kHz I2C), side 1 will detect the SDA transition and back off before its timer expires.

### 3.4 SDA Bus Monitoring (Early Back-Off)

During `NEGO_WAIT`, the FSM monitors `i2c_sda_i`. An I2C START condition is a HIGH-to-LOW transition on SDA while SCL is HIGH. If `i2c_sda_i` goes low while the local timer has not yet expired, the peer has asserted a START condition first. The local side immediately transitions to `NEGO_DONE` with `role_cfg_reg = 1` (slave).

This early-exit path avoids the need to wait for the full backoff delay and gives the faster chiplet maximum time to complete the I2C transaction before any overall timeout expires.

### 3.5 Multi-Master Arbitration Path

If both chiplets happen to transition to `NEGO_CLAIM` within the same I2C bit window (e.g. because their priority values are identical, or because `NEGO_TICK` is smaller than one I2C bit period), both will attempt to drive SCL and SDA simultaneously. This is the standard I2C multi-master scenario: the I2C specification defines deterministic bit-level arbitration on SDA. Arbitration proceeds as follows:

1. Both masters drive SDA for the address byte.
2. The master driving a logic `1` that observes logic `0` on `i2c_sda_i` has lost arbitration. It releases the bus immediately (SDA goes high-Z) and switches to I2C slave mode. The winning master continues.
3. The `i2c_master_axil` core is expected to handle lost-arbitration as a standard condition (returning a non-OKAY AXI response). The FSM detects this via the `i2c_nbsy_irq` / I2C status register and transitions to `NEGO_DONE` with `role_cfg_reg = 1` (slave).
4. The master that wins arbitration receives an ACK from the peer (which is now in slave mode) and transitions to `NEGO_DONE` with `role_cfg_reg = 0` (master).

> **Hardware assumption**: This relies on `i2c_master_axil` correctly implementing I2C multi-master arbitration loss detection per the I2C specification (Section 3.1.8 of the NXP I2C-bus specification). Implementers must verify this capability of the specific I2C master IP used. If the core does not support arbitration loss detection, the multi-master path is unavailable and `NEGO_TICK` must be set large enough to prevent simultaneous claims (at least one full I2C byte transfer period = ~90 µs at 100 kHz, i.e. `NEGO_TICK ≥ 9` at 100 MHz with `NEGO_TICK` in units of 1000 cycles).

### 3.6 SRAM PUF Priority Source

When `NEGO_CFG[NEGO_PRI_SEL]=2`, the priority value is derived from the power-on state of the TideLink FIFO SRAM. This provides a physically-random, die-unique priority without requiring OTP fuses, dedicated ID straps, or software intervention.

#### 3.6.1 Background: SRAM Power-On State

When an SRAM bitcell powers on without being written, it settles to a logic 0 or 1 determined by the manufacturing-process mismatch between its cross-coupled transistor pair. This is a physical property of the specific silicon die — two dies fabricated from the same mask will have different mismatch patterns due to random dopant variation. The resulting power-on bit pattern is:

- **Die-unique**: Different physical dies produce different patterns, even from the same wafer.
- **Partially stable**: Individual bits reproduce the same value across ~85-95% of power cycles (temperature, voltage, and ageing cause the remaining 5-15% to flip).
- **Uninitialized**: The pattern is only valid before any software write. Once written, the SRAM content reflects software state, not physical mismatch.

This property is the foundation of **SRAM PUF** (Physical Unclonable Function) technology, widely used in secure key generation and device fingerprinting.

#### 3.6.2 Reuse of the TideChart PUF Sampler

The TideChart project already provides a fully implemented and tested SRAM PUF sampler (`tidechart_puf_sampler.sv`, ~149 lines) that reads power-on SRAM state via the TideLink FC sideband. This module is directly reusable for auto-negotiation priority generation — no new PUF hardware is needed.

**Existing PUF data path:**

```
tidechart_puf_sampler
  → AXI-Stream TX: PUF_READ_REQ (subtype 0x0020, payload = SRAM word address)
    → tidelink_fc_adapter (local interception — never crosses die-to-die link)
      → reads SRAM word at addressed location
      → synthesises PUF_READ_RSP (subtype 0x0021, payload = SRAM data)
    → AXI-Stream RX: response returned to sampler
  → XOR-folds all responses into 32-bit accumulator
  → puf_seed[15:0] = acc[31:16] ^ acc[15:0]
  → puf_ready asserts when complete
```

**Key properties (from `tidechart_puf_sampler.sv`):**

| Property | Value |
|----------|-------|
| SRAM words sampled | `PUF_NUM_WORDS` parameter (default 16) |
| Algorithm | 32-bit XOR accumulate, then fold 32→16 bits |
| Completion time | ~3 × `PUF_NUM_WORDS` cycles (~48 cycles at default) |
| Output signals | `puf_seed[15:0]`, `puf_ready`, `puf_raw[31:0]` |
| SRAM access | Local only via FC adapter — no link bandwidth consumed |
| SRAM modification | Read-only — contents preserved |

**Integration with auto-negotiation:**

The `tidelink_autoneg` FSM receives `puf_seed[15:0]` and `puf_ready` from the existing TideChart PUF sampler (routed through `tidelink_top`). When `NEGO_CFG[NEGO_PRI_SEL]=2`:

1. The autoneg FSM waits for `puf_ready` before entering `NEGO_WAIT` (the PUF completes in ~48 cycles, well before `NEGO_BASE_DELAY` of 2000 cycles).
2. `puf_seed[15:0]` is used as the negotiation priority value.
3. No new SRAM access logic, no new mux on the SRAM port, no new RTL module.

**Existing test coverage** (from `cocotb/tidechart_puf_sampler/test_tidechart_puf_sampler.py`):

| Test | Description |
|------|-------------|
| `test_reset` | `puf_ready=0` after reset |
| `test_completes` | Sampling completes within 100 cycles |
| `test_known_data` | XOR-fold correctness for 16 known values |
| `test_different_data` | Different SRAM patterns → different seeds |
| `test_all_zeros` | All-zero SRAM → seed 0x0000 |

**APB visibility** (from `tidechart_apb_regs.sv`):

The PUF seed is also readable via APB at `TC_PUF_STATUS` (0x30): bit [16] = `puf_ready`, bits [15:0] = `puf_seed`. The full 32-bit accumulator is at `TC_PUF_RAW` (0x34). Software can read these for diagnostics or to implement a firmware-based priority override.

**Timing guarantee:**

The PUF sampling window completes before negotiation starts because:
1. Wlink is in reset → no FC adapter writes to the FIFO → SRAM is idle
2. PUF_READ_REQ is handled locally by the FC adapter (no link dependency)
3. `NEGO_BASE_DELAY` (default 2000 cycles) provides >40× margin over PUF completion (~48 cycles)

#### 3.6.3 Collision Probability

With 16 words (512 bits) of SRAM sampled and XOR-folded to 16 bits, the output approximates a uniform distribution over 0x0000-0xFFFF. The probability of two dies producing the exact same 16-bit priority is approximately 1/65,536 per power cycle. When a collision occurs, both sides have equal backoff delays and the I2C multi-master arbitration path (Section 3.5) resolves the tie.

For applications requiring higher collision resistance, `PUF_SAMPLE_WORDS` can be increased (diminishing returns beyond ~32 words due to XOR folding saturation), or the software override path (`NEGO_PRI_SEL=0`) can be used with a firmware-computed hash of a larger SRAM region.

#### 3.6.4 Stability Across Power Cycles

Since ~5-15% of SRAM bits may flip between power cycles, the 16-bit XOR-folded value will vary between boots. This is acceptable for auto-negotiation: the protocol only requires that the two sides produce *different* values, not that each side produces the *same* value every time. Even if a few bits differ between boots, the probability of two distinct dies producing identical 16-bit values on any given boot remains ~1/65,536.

If deterministic role assignment across power cycles is required (always the same side wins master), use the software override (`NEGO_PRI_SEL=0`) or OTP fuse (`NEGO_PRI_SEL=1`) paths instead.

#### 3.6.5 SRAM Content After PUF Sampling

The PUF block performs read-only access. The SRAM content is not modified. After PUF sampling completes and the FIFO begins normal operation, the first packet write will overwrite the sampled region with application data. The PUF priority value is latched in `puf_priority` and remains valid until the next `poresetn`.

---

## 4. Register Additions and Modifications

All new registers are added to the existing `tidelink_apb_regs` Region 4 (chiplet controller role configuration), extending from the current 0x2080-0x208F range to 0x2080-0x209F.

### 4.1 Modified Existing Registers

No existing registers change encoding. The existing startup sequence is extended — ROLE_CFG[1] (`role_lock`) is now written by the `tidelink_autoneg` block rather than firmware (unless bypass is active), but the register definition is unchanged.

The `role_effective` field in ROLE_STATUS gains a new pre-lock meaning in the negotiation phase: it reflects the current negotiation-phase role (`nego_role_r`) rather than `role_strap_i`. See Section 6 for the RTL detail.

### 4.2 New Registers

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2090 | NEGO_CFG | RW | 0x0000_0000 | Negotiation configuration (see below). |
| 0x2094 | NEGO_STATUS | RO | 0x0000_0000 | Negotiation FSM status (see below). |
| 0x2098 | NEGO_PRIORITY | RW | 0x0000_FFFF | 16-bit priority value. Lower = faster claim attempt. Only meaningful when `NEGO_CFG[NEGO_PRI_SEL]=0`. |
| 0x209C | NEGO_TIMEOUT | RW | param | Overall negotiation timeout in `apb_clk` cycles. If negotiation does not complete within this window, `NEGO_ERROR` is asserted and the role is set from `NEGO_CFG[NEGO_FALLBACK]`. Reset default = `NEGO_TIMEOUT_DEFAULT` parameter. |

#### NEGO_CFG Register (0x2090) Fields

| Bit | Name | Access | Description |
|-----|------|--------|-------------|
| [0] | `nego_en` | RW | 1 = enable auto-negotiation. 0 = bypass (static assignment, existing behaviour). |
| [1] | `nego_start` | RW | Write 1 to explicitly start negotiation after `nego_en=1`. Self-clears when FSM leaves IDLE. When 0, negotiation starts automatically on `poresetn` deassertion if `nego_en=1`. |
| [3:2] | `nego_pri_sel` | RW | Priority source: 0=NEGO_PRIORITY register, 1=`nego_priority_i` port, 2=SRAM PUF (see Section 3.6), 3=hardware default (0xFFFF). |
| [4] | `nego_fallback` | RW | Role to adopt on `NEGO_ERROR`: 0=master, 1=slave. Default 1 (slave is the safe fallback — a stuck-slave chiplet does not drive SCL and cannot corrupt the bus). |
| [5] | `nego_force_lock` | RW | 1 = if negotiation completes, FSM writes `role_lock` automatically. 0 = FSM sets role only; firmware must write `role_lock=1` separately. Default 1. |
| [31:6] | Reserved | RO | 0 |

#### NEGO_STATUS Register (0x2094) Fields

| Bit | Name | Description |
|-----|------|-------------|
| [2:0] | `nego_state` | Current FSM state: 0=IDLE, 1=NEGO_INIT, 2=NEGO_WAIT, 3=NEGO_CLAIM, 4=NEGO_POLL, 5=NEGO_DONE, 6=NEGO_BYPASS, 7=NEGO_ERROR |
| [3] | `nego_done` | 1 when FSM has reached NEGO_DONE or NEGO_BYPASS and role is locked. Sticky; cleared only by `poresetn`. |
| [4] | `nego_error` | 1 when FSM reached NEGO_ERROR. Sticky; cleared only by `poresetn`. Triggers `nego_error_irq` (see below). |
| [5] | `nego_won` | 1 if this side won master role during negotiation (set in NEGO_DONE when `role_cfg_reg=0`). |
| [6] | `nego_lost` | 1 if this side adopted slave role during negotiation. |
| [7] | `sda_start_seen` | Sticky. Set when an I2C START condition was detected on `i2c_sda_i` while in NEGO_WAIT. Indicates the early-back-off path was taken. Cleared only by `poresetn`. |
| [31:8] | Reserved | 0 |

### 4.3 New Interrupt

A new interrupt output `nego_error_irq` is added to `axi_chiplet_controller`. It is asserted when `nego_state` reaches `NEGO_ERROR` and remains asserted until firmware writes `poresetn` (i.e. it is a POR-domain sticky flag). The interrupt must be connected to the SoC interrupt controller alongside the existing `wlink_irq`.

### 4.4 Updated Register Map Summary

Extending REGISTER_MAP.md Region 4:

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| 0x2080 | ROLE_CFG | RW | 0 | Role select and lock (unchanged). |
| 0x2084 | ROLE_STATUS | RO | strap | Live role status and I2C state (unchanged). |
| 0x2088 | I2C_SLV_ADDR | RW | 0x00 | 7-bit I2C slave device address (unchanged). |
| 0x208C | I2C_PRESCALE | RW | 0x0001 | 16-bit I2C master clock prescaler (unchanged). |
| 0x2090 | NEGO_CFG | RW | 0 | Auto-negotiation enable, priority source, fallback role. |
| 0x2094 | NEGO_STATUS | RO | 0 | Negotiation FSM state and result. |
| 0x2098 | NEGO_PRIORITY | RW | 0xFFFF | 16-bit negotiation priority (lower = higher priority). |
| 0x209C | NEGO_TIMEOUT | RW | param | Overall negotiation timeout in `apb_clk` cycles. |

---

## 5. Hardware Cost Analysis

### 5.1 What Is Reused Without Modification

| Component | Reuse status | Notes |
|-----------|-------------|-------|
| `i2c_master_axil` | Reused unchanged | Already present; used in master mode to drive the "claim" transaction. |
| `i2c_slave_axil_master` | Reused unchanged | Already present; responds to the peer's "claim" write during NEGO_WAIT. |
| `i2c_mst_reset` / `i2c_slv_reset` logic | Modified (see Section 6) | Must track `nego_role_r` during negotiation rather than locked role. |
| `i2c_scl_o/t`, `i2c_sda_o/t` mux | Modified (see Section 6) | Must track `nego_role_r` during negotiation. |
| I2C physical pins | Reused unchanged | Open-drain SCL/SDA already present. |
| ROLE_CFG / ROLE_STATUS registers | Reused unchanged | Written by FSM instead of firmware in auto-negotiation mode. |
| `s_i2c_axi_*` port | Reused with firmware driver | I2C master is programmed by the `tidelink_autoneg` FSM via the same AXI-Lite path used in normal master operation. |

### 5.2 New RTL Required

| Component | Estimated complexity | Description |
|-----------|---------------------|-------------|
| `tidelink_autoneg` FSM | ~150-200 LUTs | 8-state FSM, counters for NEGO_DELAY and NEGO_TIMEOUT, SDA monitor, I2C transaction sequencer driving `s_i2c_axi_*`. |
| NEGO_CFG / NEGO_STATUS / NEGO_PRIORITY / NEGO_TIMEOUT registers | ~50 flip-flops | Added to `axi_chiplet_controller` role register block. |
| `nego_priority_i[15:0]` input port | 16 wires | New input to `axi_chiplet_controller` and `tidelink_top` for OTP/UID priority. |
| `nego_error_irq` output | 1 wire | New interrupt output. |
| Modified `role_effective` mux | ~5 LUTs | 3-way mux: pre-lock-negotiation / pre-lock-strap / post-lock (see Section 6). |
| `tidechart_puf_sampler` (reused) | 0 (already present) | Existing TideChart PUF sampler. Already instantiated when TideChart is enabled. Provides `puf_seed[15:0]` and `puf_ready` outputs. No new RTL required — only wiring of existing signals to the autoneg FSM. |

### 5.3 I2C Transaction Sequencing by the FSM

In `NEGO_CLAIM` state, the `tidelink_autoneg` FSM must perform one I2C write transaction to the peer. The FSM must drive the AXI-Lite port of `i2c_master_axil`. A minimal I2C master AXI-Lite write sequence for a single-byte write to address `NEGO_ADDR` with data `0x01` (the "claim master" message) is:

1. Write prescaler to I2C control register (AXI-Lite addr 0x0): set `I2C_PRESCALE` value.
2. Write command register: `START | WRITE | addr=NEGO_ADDR | data=0x01 | STOP`.
3. Poll status register until `busy=0` (or wait for `i2c_nbsy_irq`).
4. Read status to determine ACK/NACK/arbitration-lost.

The `tidelink_autoneg` FSM drives these writes as an internal AXI-Lite master. This avoids any firmware involvement in the physical I2C transaction and makes negotiation independent of CPU intervention during the negotiation window.

> **Implementation note**: The specific AXI-Lite register map and command encoding for `i2c_master_axil` must be confirmed against the IP's documentation. The FSM must be designed against the actual register offsets and bit fields of the `i2c_master_axil` core used.

---

## 6. Key RTL Changes

### 6.1 The Problem with the Current `role_effective` Mux

The current logic is:

```systemverilog
wire role_locked    = role_lock_reg;
wire role_effective = role_locked ? role_cfg_reg : role_strap_i;
wire role_is_master = ~role_effective;
```

Before lock, `role_effective` follows `role_strap_i`. If both chiplets have `role_strap_i=1` (slave strap, which is the safe default and the starting state for auto-negotiation), then `role_is_master=0` for both, the I2C slave core is active on both sides, and the I2C master core is held in reset on both sides. This is correct as the starting condition.

The problem arises when one side wants to switch to master during `NEGO_CLAIM`: it cannot do so by writing `ROLE_CFG[0]` because those writes are only honoured while `!role_locked`, and after writing `role_lock=1` to switch modes, Wlink POR deasserts and link training begins — prematurely, before the peer has set its own role.

### 6.2 The Solution: A Negotiation-Phase Role Register

A new single-bit register `nego_role_r` is added inside `axi_chiplet_controller`. It is separate from `role_cfg_reg` and is only writable by the `tidelink_autoneg` FSM. The modified `role_effective` logic is:

```systemverilog
wire role_in_nego   = nego_en && !role_locked;  // negotiation phase active

wire role_effective = role_locked   ? role_cfg_reg    // post-lock: use locked value
                    : role_in_nego  ? nego_role_r      // negotiation phase: FSM-controlled
                    :                 role_strap_i;    // pre-nego: follow strap

wire role_is_master = ~role_effective;
```

Where:
- `nego_en` is `NEGO_CFG[0]` (auto-negotiation enable).
- `nego_role_r` is the negotiation-phase role register written by `tidelink_autoneg`.
- `role_locked` is `role_lock_reg` (unchanged).

The three-way mux adds at most 2 LUT levels to the critical path through `role_is_master` to the I2C mux and reset logic. Since the I2C mux is already a combinational mux and is not in a timing-critical path (I2C runs at 100 kHz, orders of magnitude slower than `apb_clk`), this is not a timing concern.

### 6.3 Negotiation Phase Behaviour

In `NEGO_WAIT`: `nego_role_r = 1` (slave). Both sides start here. The I2C slave is active, the I2C master is held in reset.

In `NEGO_CLAIM`: the FSM sets `nego_role_r = 0` (master). The I2C mux immediately switches to master. The I2C slave is reset, the I2C master is released from reset and initialised. The FSM then drives the I2C write transaction.

In `NEGO_DONE`: the FSM writes `role_cfg_reg` with the decided role, then asserts `role_lock_reg = 1` (if `NEGO_CFG[nego_force_lock]=1`). From this point, `role_locked=1` and `role_effective` follows `role_cfg_reg` permanently. `nego_role_r` is no longer consulted.

### 6.4 I2C Core Reset Sequencing

When `nego_role_r` switches from 1 (slave) to 0 (master) in `NEGO_CLAIM`, the I2C slave core enters reset (`i2c_slv_reset = ~hresetn | role_is_master = 1`) and the I2C master core is released from reset (`i2c_mst_reset = ~hresetn | ~role_is_master = 0`). The I2C master core requires a minimum number of clock cycles after reset deassertion before it can begin a transaction (implementation-dependent; typically 4-8 cycles). The `tidelink_autoneg` FSM must insert a short wait (a new sub-state `NEGO_MST_INIT`, ~16 cycles) between setting `nego_role_r=0` and issuing the first AXI-Lite write to `i2c_master_axil`.

### 6.5 Summary of Changes to `axi_chiplet_controller.sv`

| Location | Change | Lines (approx.) |
|----------|--------|-----------------|
| Port list | Add `nego_priority_i[15:0]` input, `nego_error_irq` output | +2 |
| Role register block | Add `nego_role_r` flip-flop | +3 |
| `role_effective` computation | Replace 2-way mux with 3-way mux | +4 (replaces 1) |
| New module instantiation | `tidelink_autoneg u_autoneg (...)` | +20 |
| Register block | Add NEGO_CFG, NEGO_STATUS, NEGO_PRIORITY, NEGO_TIMEOUT to `ctrl_reg_*` address map | +30 |
| `wlink_por_reset` | Unchanged — POR still gates on `role_locked` only | 0 |

The total change to `axi_chiplet_controller.sv` is approximately +60 lines. All other files in the chiplet controller hierarchy are unchanged.

The `tidelink_autoneg` module is a new file (`logical/top/tidelink_autoneg.sv`) of approximately 150-200 lines.

---

## 7. Timeout and Error Handling

### 7.1 Overall Negotiation Timeout

A 32-bit countdown counter (`nego_timeout_ctr`) is loaded from `NEGO_TIMEOUT` when the FSM enters `NEGO_INIT`. It decrements every `apb_clk` cycle. If it reaches zero before `NEGO_DONE` is reached, the FSM transitions to `NEGO_ERROR`.

Recommended `NEGO_TIMEOUT` default: the parameter `NEGO_TIMEOUT_DEFAULT` should be set to cover the worst-case negotiation: maximum backoff delay (priority 0xFFFF × NEGO_TICK) plus I2C transaction time at the minimum I2C frequency. At 100 MHz `apb_clk` with default parameters (NEGO_TICK=1000, NEGO_BASE_DELAY=2000):

```
Maximum backoff = 0xFFFF × 1000 + 2000 = 65,537,000 cycles = 655 ms @ 100 MHz
I2C transaction at 100 kHz ≈ 90 µs = 9000 cycles
Safety margin: × 2
NEGO_TIMEOUT_DEFAULT ≈ 131,082,000 cycles (≈ 1.31 s @ 100 MHz)
```

This is conservative. In practice, with well-assigned priority values, negotiation completes in milliseconds. The timeout exists only to ensure the system does not hang indefinitely if both chiplets misconfigure their priorities to 0xFFFF.

### 7.2 Error Behaviour

On `NEGO_ERROR`:

1. The FSM forces `nego_role_r` (and subsequently `role_cfg_reg`) to `NEGO_CFG[nego_fallback]`.
2. `role_lock_reg` is set if `NEGO_CFG[nego_force_lock]=1`.
3. `NEGO_STATUS[nego_error]=1` is latched.
4. `nego_error_irq` is asserted.
5. Wlink POR deasserts and link training proceeds with the fallback role.

The fallback role defaults to slave (`nego_fallback=1`). This is the safe choice: a chiplet that defaults to slave does not drive SCL and cannot corrupt the I2C bus. If both chiplets end up as slave after a negotiation timeout, neither will drive SCL — the I2C bus is idle and the sideband channel is non-functional, but neither chiplet causes a bus contention fault. Wlink will still train (its POR is gated only on `role_locked`, not on role value), so the link data path can operate even without a functioning I2C sideband.

### 7.3 I2C Transaction Timeout

In `NEGO_POLL`, the FSM waits for `i2c_nbsy_irq` to fire, indicating the I2C master has completed (or abandoned) the transaction. The `i2c_master_axil` core should have its own internal timeout for SCL stretching, but if the physical bus is open-circuit or the peer's I2C slave is non-responsive, the overall `NEGO_TIMEOUT` counter provides the backstop.

### 7.4 Partial Negotiation Recovery

If `NEGO_ERROR` fires after `nego_role_r` has been switched to master (`NEGO_CLAIM` was entered), the FSM must ensure the I2C bus is released cleanly before setting the fallback slave role. The recommended sequence:

1. Issue an I2C STOP condition via `i2c_master_axil` (if a transaction was in progress).
2. Wait for bus idle.
3. Set `nego_role_r = nego_fallback` (switching back to slave if fallback=1).
4. Assert `nego_error`.

This avoids leaving SCL driven low, which would permanently lock out the I2C bus.

---

## 8. Software Bypass Mechanism

### 8.1 Bypass Mode

When `NEGO_CFG[nego_en]=0` (the reset default), the `tidelink_autoneg` FSM transitions from `IDLE` directly to `NEGO_BYPASS`. In this state, the FSM takes no action: `nego_role_r` is not driven (it defaults to the strap default), and `role_effective` falls back to the pre-negotiation path (`role_strap_i` before lock). The existing boot sequence is completely unchanged.

This means that any system that does not explicitly write `NEGO_CFG[nego_en]=1` operates identically to the pre-auto-negotiation TideLink firmware and RTL. There is zero functional difference for existing deployments.

### 8.2 Software-Controlled Negotiation Start

If `NEGO_CFG[nego_start]=1` at the time `nego_en` is set, the FSM waits in `NEGO_INIT` until firmware writes `nego_start=1`. This allows firmware to:

1. Set up priority (`NEGO_PRIORITY`), slave address, and timeout registers.
2. Set `nego_en=1`, `nego_start=0` (FSM enters NEGO_INIT but waits).
3. Perform other boot tasks while the I2C slave core warms up.
4. Write `nego_start=1` to trigger the backoff timer and begin negotiation.

When `NEGO_CFG[nego_start]=0` (default), negotiation begins automatically as soon as `nego_en=1` is written.

### 8.3 Explicit Role Override Post-Negotiation

After negotiation completes, firmware can verify the result via `NEGO_STATUS[nego_won]` and `NEGO_STATUS[nego_lost]`. If the negotiated role is not acceptable for application reasons, firmware can:

1. Assert `poresetn` to reset the role registers.
2. Set `NEGO_CFG[nego_en]=0` (bypass mode).
3. Write `ROLE_CFG[0]` to force the desired role.
4. Write `ROLE_CFG[1]=1` to lock.

This is the same override path that existed before auto-negotiation. It is available but requires a power-on reset cycle.

### 8.4 Backward Compatibility Summary

| Scenario | Behaviour |
|----------|-----------|
| `NEGO_CFG` never written (default) | `nego_en=0`, NEGO_BYPASS state, identical to pre-feature behaviour |
| Static strap assignment | `nego_en=0`, firmware writes `ROLE_CFG` as before |
| Auto-negotiation enabled | `nego_en=1`, FSM runs protocol, sets `ROLE_CFG` and locks automatically |
| Auto-negotiation enabled, firmware locks manually | `nego_en=1`, `nego_force_lock=0`, FSM sets `role_cfg_reg` only, firmware writes `role_lock=1` |

---

## 9. Integration with the Existing Boot Flow

### 9.1 Existing Phase 1 Boot Sequence (Unchanged in Bypass Mode)

The USER_GUIDE.md Phase 1 sequence is:

```
1. (Optional) Read ROLE_STATUS (0x2084) to check strap default
2. (Optional) Write ROLE_CFG (0x2080) bit[0] to override role
3. Write ROLE_CFG (0x2080) bit[1] = 1 to lock the role
   → Wlink POR deasserts, link training begins
4. Wait for link-up
```

This sequence is entirely preserved in bypass mode (`nego_en=0`). No firmware changes are required for existing deployments.

### 9.2 New Phase 1 Sequence with Auto-Negotiation

When auto-negotiation is enabled, the Phase 1 sequence becomes:

```
1. (Optional) Write NEGO_PRIORITY (0x2098) if using software-defined priority
2. (Optional) Write NEGO_TIMEOUT (0x209C) if overriding the default timeout
3. (Optional) Write I2C_SLV_ADDR (0x2088) to set the negotiation I2C slave address
4. (Optional) Write I2C_PRESCALE (0x208C) to set the I2C clock frequency
5. Write NEGO_CFG (0x2090):
   - bit[0] = 1 (nego_en)
   - bit[3:2] = priority source
   - bit[4] = fallback role
   → FSM enters NEGO_INIT, then NEGO_WAIT automatically
6. Poll NEGO_STATUS (0x2094) bit[3] (nego_done) or wait for wlink_irq / nego_error_irq
7. Check NEGO_STATUS[nego_error] to detect failure
8. (If nego_force_lock=1) Wlink POR has already deasserted; proceed to Phase 2
9. (If nego_force_lock=0) Write ROLE_CFG (0x2080) bit[1] = 1 to lock manually
```

Steps 1-5 may be performed before or after `hresetn` release, as all NEGO_* registers are in the POR-only reset domain.

### 9.3 Interaction with `swi_enable`

Wlink's `swi_enable` defaults to 1, meaning link training (and FC credit exchange) begins automatically once `wlink_por_reset` deasserts. Since `wlink_por_reset = ~poresetn | ~role_locked`, and auto-negotiation writes `role_lock=1` only after the role is decided, there is no race between negotiation and link training. The sequence is strictly:

```
poresetn asserted → role not locked → Wlink in reset → negotiation runs
→ role locked → Wlink POR deasserts → link training starts → FC credits exchanged
```

### 9.4 Interrupt Routing

The new `nego_error_irq` output of `axi_chiplet_controller` should be routed alongside `wlink_irq` to the SoC interrupt controller. Since negotiation is a boot-time event, it is acceptable to assign `nego_error_irq` to the same CPU exception level as `wlink_irq` or to handle it in the boot exception handler.

### 9.5 Updated `tidelink_top` Port List

`tidelink_top` must expose the new `axi_chiplet_controller` ports:

| New Port | Direction | Width | Description |
|----------|-----------|-------|-------------|
| `nego_priority_i` | In | 16 | External priority (e.g. from OTP). Tie to 0xFFFF if unused. |
| `nego_error_irq` | Out | 1 | Negotiation error interrupt. Connect to SoC interrupt controller. |

---

## 10. Verification and Test Plan Considerations

### 10.1 Unit Tests: `tidelink_autoneg` FSM

Test the `tidelink_autoneg` module in isolation:

| Test ID | Description | Pass Criterion |
|---------|-------------|----------------|
| NEGO-U01 | Bypass mode: `nego_en=0`. Verify FSM stays in NEGO_BYPASS and `nego_role_r` is not driven. | `role_effective` follows `role_strap_i` exactly as pre-feature. |
| NEGO-U02 | Normal path: side A has lower priority (P=0x0001), side B has higher (P=0x1000). Side A timer expires first. Side A claims. | Side A: `nego_won=1`, `role_cfg_reg=0` (master). Side B: `nego_lost=1`, `role_cfg_reg=1` (slave). |
| NEGO-U03 | SDA early-exit: inject `i2c_sda_i=0` while side B is in NEGO_WAIT before B's timer expires. | Side B detects START, transitions to NEGO_DONE(slave) without waiting for timer. |
| NEGO-U04 | Timeout path: set both sides to P=0xFFFF. Set `NEGO_TIMEOUT` to a small value. | Both sides reach NEGO_ERROR. Each adopts `nego_fallback` role. `nego_error_irq` asserts. |
| NEGO-U05 | NACK response: side A claims, side B's I2C slave returns NACK (simulated by I2C bus model). | FSM enters NEGO_ERROR or retries per timeout. |
| NEGO-U06 | `nego_force_lock=0`: verify FSM sets `role_cfg_reg` but does NOT set `role_lock_reg`. | `role_locked_o` remains 0 after NEGO_DONE until firmware writes ROLE_CFG[1]. |
| NEGO-U07 | Register read-back: read all NEGO_* registers after negotiation completes. | Values match expected state. |
| NEGO-U08 | I2C master reset sequencing: verify `i2c_mst_reset` deasserts at least 16 cycles before first AXI-Lite write in NEGO_CLAIM. | No AXI-Lite transaction issues within the dead-zone window. |
| NEGO-U09 | PUF priority source: `nego_pri_sel=2`. Inject `puf_ready=1`, `puf_seed=0x1234` on the autoneg FSM inputs. Verify FSM uses 0x1234 as the backoff priority. | Backoff delay corresponds to priority 0x1234. |
| NEGO-U10 | PUF not-ready stall: `nego_pri_sel=2`, hold `puf_ready=0`. Verify FSM waits in `NEGO_INIT` until `puf_ready` asserts. | FSM does not enter `NEGO_WAIT` while `puf_ready=0`. |

### 10.2 Integration Tests: Paired `axi_chiplet_controller`

Instantiate two `axi_chiplet_controller` instances with their I2C pins connected (open-drain model). Use a cocotb testbench.

| Test ID | Description | Pass Criterion |
|---------|-------------|----------------|
| NEGO-I01 | Basic negotiation: A=priority 0x0001, B=priority 0x0010. Both `nego_en=1`. | A becomes master, B becomes slave. Both `nego_done=1`. Link trains. |
| NEGO-I02 | Priority inversion: A=priority 0x1000, B=priority 0x0001. | B becomes master. A becomes slave. |
| NEGO-I03 | Equal priority (potential simultaneous claim): A=B=0x0001. | Exactly one side wins master via I2C arbitration. Both `nego_done=1`. No bus contention error. |
| NEGO-I04 | One side has `nego_en=0`, other has `nego_en=1`. | `nego_en=0` side: strap-based role, locks manually. `nego_en=1` side: may timeout (partner not responding as slave). Verify graceful timeout and fallback. |
| NEGO-I05 | Full boot: negotiation completes, Wlink trains, FC credits exchanged, packet sent. | End-to-end packet transfer succeeds after auto-negotiated role lock. |
| NEGO-I06 | Renegotiation after POR: assert `poresetn` after first negotiation completes. Verify roles can be renegotiated. | Second negotiation completes correctly. |
| NEGO-I07 | `nego_error_irq` routing: verify interrupt reaches CPU interrupt controller model. | CPU ISR fires on NEGO_ERROR. |
| NEGO-I08 | SRAM PUF paired: both sides use `nego_pri_sel=2`. Pre-load each side's SRAM with different random content. | Sides produce different priorities; one wins master, other slave. `nego_done=1` on both. |
| NEGO-I09 | SRAM PUF collision: both sides' SRAMs pre-loaded with identical content (forced collision). | Both produce same priority; I2C arbitration resolves. One wins, one loses. Verify graceful resolution. |

### 10.3 I2C Bus Model Requirements

Tests NEGO-I01 through NEGO-I07 require an I2C bus model that:

1. Implements open-drain wired-AND on SDA and SCL (both sides drive high-Z or low; bus = AND of all drivers).
2. Implements standard I2C arbitration (SDA monitoring per NXP spec Section 3.1.8).
3. Generates ACK/NACK based on slave address match.
4. Reports arbitration-lost condition to the master that lost.

A Python cocotb I2C bus model is preferred for consistency with existing TideLink cocotb tests.

### 10.4 Corner Cases to Explicitly Test

- I2C bus floating (no pull-up resistors modelled): both SDA and SCL stuck high. Verify NEGO_TIMEOUT fires and fallback applies.
- Asymmetric power-on: chiplet A powers on 1 ms before chiplet B. Verify A claims master and B, when it powers on, observes an existing master and adopts slave role.
- Very short `NEGO_TIMEOUT` (fewer cycles than one I2C byte transfer): verify NEGO_ERROR fires correctly and does not leave the I2C master mid-transaction.
- `nego_priority_i` port driven from OTP model: verify correct priority selection when `NEGO_CFG[nego_pri_sel]=1`.

### 10.5 Formal Verification Considerations

The `tidelink_autoneg` FSM is a good candidate for lightweight formal property checking:

- **Mutual exclusion**: It is never the case that both chiplets simultaneously have `role_is_master=1` after `NEGO_DONE`. (Requires a paired-instance formal model with shared I2C bus constraints.)
- **Progress**: From any state other than `NEGO_ERROR` and `NEGO_BYPASS`, the FSM always eventually reaches `NEGO_DONE` or `NEGO_ERROR` within `NEGO_TIMEOUT` cycles.
- **No spurious lock**: `role_lock_reg` is never set while `nego_en=1` and the FSM is not in `NEGO_DONE` or `NEGO_ERROR`.

---

## 11. Design Justification

### 11.1 Why I2C Rather Than a Dedicated Sideband

The most natural alternative would be a dedicated point-to-point sideband wire (e.g. a `nego_priority_o` / `nego_priority_i` pair) that directly compares priority values without any protocol overhead. However, a dedicated sideband would require new pad allocation, and the I2C sideband is already part of the chiplet-to-chiplet interface. Reusing the I2C sideband adds zero new pads and zero new signals at the package boundary — a significant constraint in chiplet systems where pad count is precious.

A GPIO-based handshake (one wire per side, asserted to claim) would also work and would be simpler, but again requires dedicated pads not currently allocated in the TideLink interface. The I2C approach reuses existing hardware at the cost of protocol complexity.

### 11.2 Why Both Cores Are Already Present

`axi_chiplet_controller` already instantiates both I2C cores because the role can change across power cycles. Keeping both cores present and gating the inactive one avoids a topology where adding or removing a core would require RTL changes. For auto-negotiation, this pre-existing dual-core structure is exactly what is needed — the protocol simply controls which core is active during the negotiation window.

### 11.3 Why a Priority-Based Backoff Rather Than a Random Backoff

A purely random backoff (like Ethernet CSMA/CD) would work in principle but would introduce non-determinism in boot time. In chiplet systems, boot time is often bounded by SoC-level bring-up sequences, and a random component would make worst-case analysis difficult. Priority-based backoff (CSMA/CA style) gives deterministic resolution: given fixed, distinct priority values, the winning side is always the same at every power cycle. For symmetric chiplets where roles do not need to vary, this predictability is strictly better.

The priority source hierarchy (software register > OTP port > hardware default) allows different deployment scenarios without RTL changes: a factory-programmed OTP provides permanent deterministic assignment; a software register allows field reconfiguration; the hardware default provides a safe fallback.

### 11.4 Why `nego_role_r` Instead of Modifying `role_cfg_reg` Before Lock

An alternative design would allow `role_cfg_reg` to be written by the FSM before lock (as it can already be written by firmware before lock). The problem is that `role_cfg_reg` feeds `role_effective` only after lock, so modifying it before lock has no effect on the I2C mux. The existing mux is:

```systemverilog
wire role_effective = role_locked ? role_cfg_reg : role_strap_i;
```

Before lock, `role_effective` always follows `role_strap_i`, regardless of `role_cfg_reg`. To switch I2C cores before lock, either (a) `role_locked` must be asserted prematurely (wrong — this releases Wlink POR), or (b) a new signal (`nego_role_r`) must be inserted as a third mux input. Option (b) is cleaner: it does not disturb the existing `role_cfg_reg` write semantics, it does not prematurely assert `role_locked`, and it requires the smallest possible change to the existing mux logic.

### 11.5 Why the Slave Is the Safe Fallback

If negotiation fails and both chiplets end up with `role_is_master=0` (both slaves, from `nego_fallback=1`), neither side drives SCL. The I2C bus is idle. The Wlink data path is unaffected — link training proceeds with `role_locked=1` and the slave-mode APB mux active on both sides. The sideband configuration path is non-functional (neither side can configure the remote Wlink via I2C), but Wlink defaults are often sufficient for initial link-up, particularly at GPIO PHY speeds where no complex PHY tuning is needed.

Conversely, if both chiplets defaulted to master (`nego_fallback=0`), both would drive SCL simultaneously, creating a guaranteed bus contention that could hold SCL low indefinitely (if both drive SCL low at the same time). This would prevent any I2C traffic and could also cause electrical damage if the I2C outputs do not properly implement open-drain drive with current limiting. The slave fallback avoids this failure mode entirely.

### 11.6 Why the SDA Early-Exit Is Beneficial

Without early exit, the lower-priority side would always wait for its full backoff timer before detecting that the higher-priority side has already claimed. This is wasteful and increases the negotiation window unnecessarily. The SDA monitor adds only a few logic gates (an edge detector on `i2c_sda_i` qualified by SCL) and can cut negotiation time by up to `(P_low - P_high) × NEGO_TICK` cycles. For systems where priority values are close together but not identical, this can be a significant saving.

### 11.7 Trade-Offs Accepted

| Trade-off | Impact | Mitigation |
|-----------|--------|------------|
| Relies on `i2c_master_axil` arbitration-loss support | If IP does not implement this, equal-priority scenario is unresolvable without timeout | Set `NEGO_TICK` large enough to guarantee non-simultaneous claims; document requirement |
| Adds boot latency proportional to priority difference | Up to several hundred milliseconds in worst case | Default timeout is generous; expected priority differences are small (< 10 × NEGO_TICK) |
| Negotiation requires I2C slave address consistency | Both sides must use the same `NEGO_ADDR`; misconfiguration causes negotiation failure | Default address is a compile-time parameter; firmware writes it before enabling NEGO |
| FSM drives `s_i2c_axi_*` internally | Existing AXI-Lite fabric master cannot also drive `s_i2c_axi_*` during negotiation | FSM releases bus after `NEGO_DONE`; existing software can use `s_i2c_axi_*` normally after lock |

---

## 12. Constraints and Limitations

### 12.1 I2C Physical Layer Requirements

Auto-negotiation requires the I2C sideband to be electrically functional at power-on:

- Pull-up resistors on SCL and SDA must be present and correctly sized for the clock frequency and bus capacitance.
- Both chiplets must be powered and have released `poresetn` before negotiation begins. A chiplet that is powered but in reset will not respond on the I2C bus, causing the active side to time out.
- The I2C clock frequency (set by `I2C_PRESCALE`) must be consistent with the pull-up resistor values and expected bus capacitance.

### 12.2 Only One Negotiation Per POR Cycle

The auto-negotiation protocol is designed to run exactly once per `poresetn` assertion cycle. Once `role_lock_reg` is set, it survives warm reset (`hresetn`) and the FSM cannot renegotiate without a full power cycle. This is intentional: renegotiating while Wlink is trained could cause role inversion mid-operation, which would corrupt all in-flight transactions. If renegotiation is needed, the system must be fully powered down and re-initialised.

### 12.3 No Protection Against a Misbehaving Peer

If the peer chiplet runs firmware that does not implement auto-negotiation (e.g. an older firmware image), the peer will not respond as an I2C slave during the negotiation window. The local side will time out and adopt the fallback role. This is handled gracefully, but the resulting link may not be fully functional if the peer's role assignment is incompatible with the locally decided role.

### 12.4 I2C Arbitration Is Not Guaranteed on All I2C IP Cores

Section 3.5 notes that the multi-master arbitration path depends on `i2c_master_axil` implementing arbitration-loss detection. This is a stated assumption about the I2C master IP. If this assumption is not satisfied, the simultaneous-claim scenario can result in an unresolvable contention that requires the full `NEGO_TIMEOUT` to expire. System integrators must verify this property of the specific I2C master IP used.

### 12.5 Negotiation Address 0x7E May Conflict

As noted in Section 2.4, I2C address 0x7E is used during negotiation by default. This address must not conflict with any device on the same I2C bus during the boot window. In systems where the I2C sideband is a private point-to-point connection between two chiplets (the typical TideLink deployment), this is not a concern. In systems where the I2C sideband is shared with other I2C devices, the negotiation address must be chosen to avoid conflicts, and the negotiation window must be clearly delineated to avoid confusing other bus participants.

### 12.6 RTL Not Yet Implemented

This specification describes a proposed feature. As of version 0.1, no RTL for `tidelink_autoneg` exists. The register definitions in Section 4 and the RTL changes in Section 6 are forward-looking descriptions intended to guide implementation. All signal names, register offsets, and module interfaces are subject to revision during implementation.
