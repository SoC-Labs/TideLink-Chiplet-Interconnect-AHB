# Formal and SVA: CRC-replay contract (verification P1, first increment)

Contract on the RX side of every `WlinkGenericFCSM*` (E = `exp_pkt_num` at the cycle a CRC error is detected):

| ID | Statement | Assertion (`verif/sva/fc_crc_contract_sva.sv`) |
|---|---|---|
| C1 | `exp_pkt_num` stays at E until a CRC-clean packet numbered E is accepted | `a_c1_exp_frozen` |
| C2 | no NACK-enqueue suppression while the replay is outstanding; L9b never fires, L9c never swallows the replay; with CRC checking on, L9b/L9c are dead | `a_c2_nack_enq`, `a_c2_no_reanchor`, `a_c2_no_l9c_on_replay`, `a_c2_l9_dead_when_crc` |
| C3 | no out-of-order commit while E is outstanding | `a_c3_no_commit_past_hole` |
| C4 | CRC error leads to `send_nack_req` within `NACK_MAX` cycles | `a_c4_nack_issued` (simulation only) |
| covers | CRC seen, follower while pending, replay accepted, follower then replay, waived first-data error | `c_*` |

`CRC_MODE` (bind-time, `+define+TL_FC_SVA_CRC_MODE=0|1|2`): 0 follows the node's `disable_crc` flop (default),
1 = CRC always on (TL-018/019 ASIC overrides), 2 = CRC-off regime.

## Waiver W1 (found by this work)

The SoC Labs L9 one-shot resync accepts the first data packet after reset or app-enable whatever its number.
A CRC error on that first packet breaks C1/C3: a later packet is committed and `exp_pkt_num` moves past the hole.
Formal counterexample at depth 3 to 4; simulation `test_sideband_hit_first_after_bringup` shows 50 assertion hits
(the end result is still exact, after 17 NACK/revert rounds). The default build waives it (`WAIVE_FIRST_DATA=1`) and
counts it (`waived_first_data=`); `+define+TL_FC_SVA_STRICT_FIRST` (formal: `TL_FC_STRICT=1`) reports it.

## Run

```
make fc_sva                      # sim: 2 sideband cases + must-fail arm (~3.5 min)
make fc_sva_full                 # sim: 4 cases + crc_matrix_quick with SVA on + must-fail arm
TL_FC_SVA=1 make -C cocotb/tidelink_axi_datanode_recovery <any target>   # SVA in any existing suite
module load vc_formal && verif/formal/run_formal.sh main 1     # proof, ~35 s
verif/formal/run_formal.sh mutant 1                            # +define+SOCL_L9_ALWAYS: must show counterexamples
TL_FC_STRICT=1 verif/formal/run_formal.sh main 1               # W1 counterexample
verif/formal/ci_formal.sh                                      # both, pass/fail
```

Log markers: `TL_FC_SVA FAIL <id>` (assertion fired) and one `TL_FC_SVA SUMMARY <instance> ... crc= follower= replay=`
line per bound instance (shows the checker saw traffic).

## Formal setup (VC Formal FPV, `verif/formal/`)

Top `WlinkGenericFCSM_6` standalone, CRC generator included (inputs free). Assumptions in `fc_formal_env.sv`:
credit modulus in [4:31]; data packet numbers inside the credit ring; receiver CRC mode fixed by `CRC_MODE`.
No TX-side or replay-buffer model is needed for C1 to C3, which are safety properties of the RX cone.
C4 is a liveness-style bound that needs TX-side fairness assumptions; it is excluded from the proof (`TL_FC_FORMAL_SKIP_C4`)
and stays a simulation assertion (unconstrained TX side gave a counterexample at depth 66). The 3 FIFO memories are
cut by cone of influence.
