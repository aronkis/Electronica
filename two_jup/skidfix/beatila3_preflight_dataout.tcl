# beatila3_preflight_dataout.tcl -- follow-up: find the post-synth name of the
# serializer-output / FEC-bitsIn stream net (Delay8_out1 was renamed/absorbed).
# Equivalent observation points (any ONE suffices for the readout rule):
#   - the QPSK_Rx-level net QPSK_Demodulator_dataOut
#   - the FEC_Decoder_Wrapper input bitsIn / its delayMatch register bitsIn_1
#   - any Delay8 remnant anywhere under QPSK_Rx
# argv: <routed_dcp> <report_out>
set dcp  [lindex $argv 0]
set rpt  [lindex $argv 1]
open_checkpoint $dcp
set f [open $rpt w]
set pats {
  {qrx_dataOut "*u_QPSK_Rx*QPSK_Demodulator_dataOut*"}
  {fec_bitsIn  "*u_FEC_Decoder_Wrapper*bitsIn*"}
  {feccap_bits "*FecCapture*bitsIn*"}
  {delay8_any  "*u_QPSK_Rx*Delay8*"}
  {demod_nout  "*u_QPSK_Demodulator_n_*"}
}
foreach t $pats {
  set tag [lindex $t 0]; set pat [lindex $t 1]
  set nets [get_nets -hier -quiet -filter "NAME =~ $pat"]
  puts $f "TAG $tag COUNT [llength $nets]"
  foreach nn [lrange $nets 0 11] {
    puts $f "  NET $nn TYPE=[get_property TYPE $nn] FO=[get_property FLAT_PIN_COUNT $nn]"
  }
}
puts $f "DATAOUT_QUERY_DONE"
close $f
puts "done -> $rpt"
exit
