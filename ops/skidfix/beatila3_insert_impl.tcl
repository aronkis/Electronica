# beatila3_insert_impl.tcl -- RECOVERY tail for the BEATILA-3 build: the project
# flow skipped XDC debug insertion ([Chipscope 16-240] "already implemented"
# because the BD carries a native system_ila). This script opens the failed run's
# post-synth linked checkpoint, executes the debug-core commands DIRECTLY (the
# XDC is plain Tcl), hard-verifies the core BEFORE spending impl time, then runs
# opt/place/route/bitstream manually with the same gates. BUILD ONLY.
# argv: <synth_linked_dcp> <debug_xdc> <outdir>
set dcp [lindex $argv 0]
set xdc [lindex $argv 1]
set out [lindex $argv 2]
file mkdir $out
open_checkpoint $dcp

puts "=== BEATILA3R: direct debug-core insertion ==="
if {[catch { source $xdc } err]} { puts "BEATILA3R_INSERT_FAIL: $err"; exit 1 }
# gate 1: core exists with 10 fully-connected probe ports BEFORE impl time
set _c [get_debug_cores -quiet u_ila_beat3]
if {![llength $_c]} { puts "BEATILA3R_INSERT_FAIL: u_ila_beat3 not created"; exit 1 }
set _n 0; set _bad 0
foreach _p [get_debug_ports -quiet u_ila_beat3/probe*] {
  incr _n
  set _w [get_property PORT_WIDTH $_p]
  set _nets [get_nets -quiet -of_objects $_p]
  if {[llength $_nets] < $_w} { puts "BEATILA3R_PORT_BAD $_p width=$_w nets=[llength $_nets]"; incr _bad }
}
if {$_n < 10 || $_bad > 0} { puts "BEATILA3R_INSERT_FAIL: ports=$_n bad=$_bad"; exit 1 }
puts "BEATILA3R_INSERT_OK ports=$_n"

puts "=== BEATILA3R: opt/place/route ==="
opt_design
# gate 2: core survived opt (the phase that synthesizes debug cores)
if {![llength [get_cells -quiet u_ila_beat3]]} { puts "BEATILA3R_ILA_FAIL: lost at opt"; exit 1 }
puts "BEATILA3R_OPT_OK"
place_design
phys_opt_design
route_design
if {![llength [get_cells -quiet u_ila_beat3]]} { puts "BEATILA3R_ILA_FAIL: lost at route"; exit 1 }
set _wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "BEATILA3R_TIMING_WNS $_wns"
report_timing_summary -file $out/timing_routed.rpt -quiet
write_checkpoint -force $out/system_top_routed_b3r.dcp

puts "=== BEATILA3R: bitstream + probes ==="
write_bitstream -force $out/system_top.bit
write_debug_probes -force $out/debug_nets_b3r.ltx
puts "BEATILA3R_DONE bit=$out/system_top.bit ltx=$out/debug_nets_b3r.ltx wns=$_wns"
exit
