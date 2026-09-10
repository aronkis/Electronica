# beatila3_preflight.tcl (v2) -- ZERO-BUILD preflight for BEATILA-3: open build-1's
# routed DCP and verify every target net BY NAME so the debug XDC is written against
# proven names. v2: uses -filter {NAME =~ } (the -hier glob with '/' in the pattern
# matches nothing -- the v1 bug; the rail census always used -filter).
# argv: <routed_dcp> <report_out>
set dcp  [lindex $argv 0]
set rpt  [lindex $argv 1]
open_checkpoint $dcp
set f [open $rpt w]
set targets {
  {serctr     "*u_Serializer*HDL_Counter*"}
  {decis      "*u_QPSK_Demodulator*Delay12_out1*"}
  {dataOut    "*u_QPSK_Demodulator*Delay8_out1*"}
  {startOut   "*u_QPSK_Demodulator*Delay10_out1*"}
  {validOut   "*u_QPSK_Demodulator*Delay9_out1*"}
  {avgEst_re  "*Average_Estimates*Unit_Delay_Enabled_Synchronous_out1_re*"}
  {avgEst_im  "*Average_Estimates*Unit_Delay_Enabled_Synchronous_out1_im*"}
  {rail       "*TxRxCompo_ip_0*enb_1_2_0"}
  {rail_gated "*TxRxCompo_ip_0*enb_1_2_0_gated"}
  {trig       "*burst_det*trig*"}
}
set nfail 0
foreach t $targets {
  set tag [lindex $t 0]; set pat [lindex $t 1]
  set nets [get_nets -hier -quiet -filter "NAME =~ $pat"]
  set n [llength $nets]
  puts $f "TAG $tag COUNT $n"
  foreach nn [lrange $nets 0 9] {
    puts $f "  NET $nn TYPE=[get_property TYPE $nn] FO=[get_property FLAT_PIN_COUNT $nn]"
  }
  if {$n == 0} { puts $f "  MISSING $tag"; incr nfail }
}
set clknets [get_nets -hier -quiet -filter {NAME =~ "*axi_adrv9001_adc_1_clk*"}]
puts $f "TAG ila_clk COUNT [llength $clknets]"
foreach nn [lrange $clknets 0 3] { puts $f "  NET $nn" }
set hubs [get_cells -hier -quiet -filter {NAME =~ "*dbg_hub*" || REF_NAME =~ "*dbg_hub*" || ORIG_REF_NAME =~ "*dbg_hub*" || NAME =~ "*xsdbm*"}]
puts $f "TAG dbg_hub COUNT [llength $hubs]"
foreach c [lrange $hubs 0 5] { puts $f "  CELL $c REF=[get_property REF_NAME $c]" }
puts $f [expr {$nfail==0 ? "BEATILA3_PREFLIGHT_OK" : "BEATILA3_PREFLIGHT_FAIL nmissing=$nfail"}]
close $f
puts "preflight done -> $rpt"
exit
