# dcp_rail_dump.tcl <routed.dcp> <out.txt> -- implemented-design rail forensics
# (N3 2026-08-14): dump the modem DUT's clock/enable network AS IMPLEMENTED:
#   1. every cell of the HDL-Coder timing controller (TxRxComposite_tc) with
#      REF_NAME + LUT INIT (const-folding of the rail generator shows up here)
#   2. every net named like a rail (enb*, ce_out*, clk_enable*) inside the
#      TxRxCompo IP: TYPE (POWER/GROUND = const-folded!), flat fanout, driver
#   3. all BUFGCE/BUFGCE_DIV cells: CE and I net sources
#   4. per-hierarchy sequential-cell census of the DUT (rail-region deltas)
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set fp [open $out w]

set tccells [lsort [get_cells -hier -filter {NAME =~ *TxRxComposite_tc*}]]
puts $fp "TC_CELLS [llength $tccells]"
foreach c $tccells {
  set typ [get_property REF_NAME $c]
  set init "-"
  catch { set init [get_property INIT $c] }
  puts $fp "CELL [get_property NAME $c] $typ INIT=$init"
}

puts $fp "-- rail nets (TxRxCompo scope) --"
foreach pat {*enb* *ce_out* *clk_enable*} {
  foreach n [lsort [get_nets -hier -filter "NAME =~ *TxRxCompo*${pat} || NAME =~ *modem*${pat}"]] {
    set drvp ""
    catch { set drvp [get_pins -quiet -of $n -filter {DIRECTION == OUT && IS_LEAF}] }
    puts $fp "NET [get_property NAME $n] TYPE=[get_property TYPE $n] FO=[get_property FLAT_PIN_COUNT $n] DRV={$drvp}"
  }
}

puts $fp "-- BUFG cells --"
foreach b [lsort [get_cells -hier -filter {REF_NAME =~ BUFG*}]] {
  set ce "-"; set ck "-"
  catch { set ce [get_nets -quiet -of [get_pins -quiet $b/CE]] }
  catch { set ck [get_nets -quiet -of [get_pins -quiet $b/I]] }
  puts $fp "BUFG [get_property NAME $b] [get_property REF_NAME $b] CE={$ce} I={$ck}"
}

puts $fp "-- DUT sequential census (per level-3 hierarchy) --"
set seqs [get_cells -hier -filter {NAME =~ *TxRxCompo* && IS_SEQUENTIAL}]
set census [dict create]
foreach c $seqs {
  set n [get_property NAME $c]
  set parts [split $n /]
  set key [join [lrange $parts 0 4] /]
  dict incr census $key
}
foreach k [lsort [dict keys $census]] { puts $fp "SEQ $k [dict get $census $k]" }

# the tc's counter/enable logic often lands as LUTs on nets named *_tc_* --
# also dump any nets OF the tc cells for driver/const inspection
puts $fp "-- nets of tc cells --"
set tcnets [lsort -unique [get_nets -quiet -of_objects $tccells]]
foreach n $tcnets {
  puts $fp "TCNET [get_property NAME $n] TYPE=[get_property TYPE $n] FO=[get_property FLAT_PIN_COUNT $n]"
}
close $fp
puts "RAIL_DUMP_DONE $out"
exit
