# VC Formal FPV: CRC-replay contract (C1-C4) on WlinkGenericFCSM_6, standalone.
#   run via verif/formal/run_formal.sh  (sets env: ROOT, TL_FC_CRC_MODE, TL_FC_MUTANT, TL_FC_STRICT, TL_FC_TIME)
# Assumptions: verif/formal/fc_formal_env.sv (credit range, pktnum in ring, CRC mode).
set root   $::env(ROOT)
set mode   [expr {[info exists ::env(TL_FC_CRC_MODE)] ? $::env(TL_FC_CRC_MODE) : 1}]
set strict [expr {[info exists ::env(TL_FC_STRICT)] && $::env(TL_FC_STRICT)}]
set strictdef [expr {$strict ? "+define+TL_FC_SVA_STRICT_FIRST" : ""}]
set mutant [expr {[info exists ::env(TL_FC_MUTANT)] ? $::env(TL_FC_MUTANT) : 0}]
set tlimit [expr {[info exists ::env(TL_FC_TIME)] ? $::env(TL_FC_TIME) : 300}]

set_fml_appmode FPV
set vopts "-sverilog +define+TL_FC_SVA +define+TL_FC_FORMAL +define+TL_FC_SVA_FCSM6_ONLY +define+TL_FC_FORMAL_SKIP_C4 $strictdef +define+TL_FC_SVA_CRC_MODE=$mode -f $root/verif/formal/fcsm6.f.resolved"
if {$mutant} { append vopts " +define+SOCL_L9_ALWAYS" }
read_file -top WlinkGenericFCSM_6 -format sverilog -sva -vcs $vopts

create_clock io_rx_clk -period 100
create_clock io_tx_clk -period 130
create_clock io_app_clk -period 170
create_reset io_rx_reset -high
create_reset io_tx_reset -high
create_reset io_app_reset -high
sim_run -stable
sim_save_reset

set_fml_var fml_max_time ${tlimit}s
check_fv -block
report_fv -list > report_list.txt
report_fv
# counter-example waveforms (FSDB) for every falsified assertion; convert with fsdb2vcd
foreach p [get_props -usage assert -status falsified] {
  set n [get_attribute $p name]
  regsub -all {[^A-Za-z0-9_]} $n _ f
  fvtrace -property $n -composite -file cex_${f}.fsdb
}
