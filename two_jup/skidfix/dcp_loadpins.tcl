set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set fp [open $out w]
foreach nname {enb_1_2_0 enb_1_2_0_gated} {
  foreach n [get_nets -quiet -hier -filter "NAME =~ *TxRxCompo_ip_0/inst/$nname"] {
    puts $fp "== NET [get_property NAME $n] FO=[get_property FLAT_PIN_COUNT $n]"
    set pins [get_pins -quiet -of [get_nets -segments -of $n] -filter {DIRECTION == IN && IS_LEAF}]
    array unset hist
    foreach p $pins {
      set rp "[get_property REF_NAME [get_cells -of $p]]/[get_property REF_PIN_NAME $p]"
      if {[info exists hist($rp)]} { incr hist($rp) } else { set hist($rp) 1 }
    }
    foreach k [lsort [array names hist]] { puts $fp "  LOAD $k x$hist($k)" }
  }
}
# the bufg_place clock nets: what do THEY drive?
foreach c [get_cells -hier -filter {NAME =~ *bufg_place*}] {
  set on [get_nets -quiet -of [get_pins -quiet $c/O]]
  if {![llength $on]} continue
  puts $fp "== BUFGOUT [get_property NAME $c] FO=[get_property FLAT_PIN_COUNT $on]"
  array unset hist
  foreach p [get_pins -quiet -of [get_nets -segments -of $on] -filter {DIRECTION == IN && IS_LEAF}] {
    set rp "[get_property REF_NAME [get_cells -of $p]]/[get_property REF_PIN_NAME $p]"
    if {[info exists hist($rp)]} { incr hist($rp) } else { set hist($rp) 1 }
  }
  foreach k [lsort [array names hist]] { puts $fp "  LOAD $k x$hist($k)" }
}
close $fp
puts "LOADPIN_DONE"
exit
