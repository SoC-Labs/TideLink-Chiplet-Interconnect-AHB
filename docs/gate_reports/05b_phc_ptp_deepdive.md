# PHC/PTP hop deep-dive (sub-agent of #5) — 2026-07-30

Q1 bind: ethernet_ss_ahb_phc bind failure (module-case phc_ahb vs PHC_AHB, port HSEL vs ahbs_hsel, 3 nonexistent ports HBURST/HPROT/HMASTLOCK, 12-vs-32 haddr width) is FIXED via phc_ahb_soc_wrapper.sv (adapter). Elaborates 0 errors; eth_ptp_phc_subsystem sim 5/5 PASS (first-ever functional sim, 2026-07-21). BUT that _phc variant is used ONLY in the standalone subsystem suite + ethernet-subsystem-ahb FPGA; the chiplet uses discrete top-level phc_ahb u_phc_0 (nanosoc_multicore_soc.sv:1033) + ethernet_ss_ahb_rmii (:834), NOT the _phc subsystem.

Q2 RESOLVES the phc_locked memory-vs-RTL discrepancy: phc_locked is DECORATIVE — RTL ties nanosoc_eth_chiplet.sv:707 .phc_locked_i(1'b1) AND PHC_LOCK_GATE_EN=0 (tidelink_ptp.sv:35, tidelink_top.sv:57) so the arm-gate is hardwired 1 (tidelink_ptp.sv:372) — it gates NOTHING, only a status bit HW_SYNC_STATUS[18]. Operationally gate on R_SERVO_OFFSET = last_offset_r @ APB 0x060 (tidelink_ptp_servo.sv:138,177; |offset|<=12000ns converged, PTP_DEMO_RUNBOOK.md:261). servo_locked SERVO_STATUS[0]@0x05C is corroboration-only. => memory's "gate on R_SERVO_OFFSET" is CORRECT; the tied-0-vs-1'b1 is moot (decorative either way). Unit test proves the gate works when EN=1 (not the deployed path).

Q3 two servo sources into one PHC (SERVO_CTRL.SRC_SEL@0x0A0): src0 = cross-die TideLink d2d_phc_* (nanosoc_eth_chiplet.sv:304-315,694-706); src1 = local HA1588 servo (fully wired PHC<->eth-ss). HONEST LIMIT: servo disciplines PHC to the FREE-RUNNING HA1588 RTC, NOT to a timestamped MII event (eth_ptp_phc_subsystem TRANSCRIPT §59-67).

Q4 NO PHC/PTP suite is in sim_gate (6 suites all excluded: eth_ptp_chain, eth_ptp_phc_subsystem, tidelink_phc_cdc, tidelink_ptp, tidelink_ptp_servo, debug/phc_pair). HA1588->servo->PHC hop UNGATED in CI. Only HA1588 register visibility gated (eth_m0/m1/shape_a). SIM_GATE_COVERAGE.md:334 lists two-board PTP as UNGATED.

Q5 PHC IS in the chiplet (discrete top-level, not _phc variant).

green-but-blind: (1) phc_locked lock-check vacuous (constant + gate off). (2) no PHC/PTP in sim_gate. (3) eth_ptp_phc_subsystem tracks free-running RTC not MII TSU. (4) eth_ptp_chain never reads the 80-bit timestamp + never touches PHC. (5) debug/phc_pair + test_ptp_link_sync use a tb PHC MODEL not real IP. (6) B1/B6 hollow-tie class (eth capture tied 0, servo hardwired-on) now appears fixed but re-verify.
