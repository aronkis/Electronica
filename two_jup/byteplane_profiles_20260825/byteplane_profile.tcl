# byteplane_profile.tcl <routed.dcp> <out.txt>
# TX byte-plane implementation profile for the placement-correlate study.
# Machine-parsable KEY=VALUE lines.
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set fp [open $out w]
puts $fp "DCP $dcp"

# ---- global timing ----
set wp [get_timing_paths -setup -max_paths 1]
set hp [get_timing_paths -hold  -max_paths 1]
puts $fp "GLOBAL_WNS [get_property SLACK $wp]"
puts $fp "GLOBAL_WHS [get_property SLACK $hp]"

# ---- TX byte-plane cell set ----
set pats {*ByteWordBuffer* *ByteSerializer* *ByteBitShifter* *TxGateK5*}
set bp {}
foreach p $pats {
  set c [get_cells -quiet -hier -filter "NAME =~ $p && IS_PRIMITIVE"]
  puts $fp "CELLCOUNT $p [llength $c]"
  set bp [concat $bp $c]
}
puts $fp "BP_TOTAL [llength $bp]"

# ---- placement spread of byte-plane FFs ----
set xmin 99999; set xmax -1; set ymin 99999; set ymax -1; set nloc 0
set sites {}
foreach c $bp {
  set s [get_property SITE $c]
  if {$s eq ""} continue
  incr nloc
  lappend sites $s
  if {[regexp {X(\d+)Y(\d+)$} $s -> sx sy]} {
    if {$sx < $xmin} {set xmin $sx}; if {$sx > $xmax} {set xmax $sx}
    if {$sy < $ymin} {set ymin $sy}; if {$sy > $ymax} {set ymax $sy}
  }
}
puts $fp "BP_PLACED $nloc BBOX_X ${xmin}-${xmax} BBOX_Y ${ymin}-${ymax} SPREAD [expr {($xmax-$xmin)*($ymax-$ymin)}]"
puts $fp "BP_DISTINCT_SITES [llength [lsort -unique $sites]]"

# ---- setup paths through the byte plane ----
set sp [get_timing_paths -quiet -setup -through $bp -max_paths 200 -nworst 1]
if {[llength $sp] > 0} {
  set slacks [lsort -real [get_property SLACK $sp]]
  puts $fp "BP_SETUP_MIN [lindex $slacks 0] N [llength $sp]"
  set i 0
  foreach p $sp {
    if {$i >= 10} break
    puts $fp "BP_SETUP_PATH slack=[get_property SLACK $p] dp=[get_property DATAPATH_DELAY $p] skew=[get_property SKEW $p] lvl=[get_property LOGIC_LEVELS $p] ep=[get_property ENDPOINT_PIN $p]"
    incr i
  }
} else { puts $fp "BP_SETUP_MIN NA N 0" }

# ---- hold paths through the byte plane ----
set hp2 [get_timing_paths -quiet -hold -through $bp -max_paths 200 -nworst 1]
if {[llength $hp2] > 0} {
  set slacks [lsort -real [get_property SLACK $hp2]]
  puts $fp "BP_HOLD_MIN [lindex $slacks 0] N [llength $hp2]"
  set i 0
  foreach p $hp2 {
    if {$i >= 10} break
    puts $fp "BP_HOLD_PATH slack=[get_property SLACK $p] skew=[get_property SKEW $p] ep=[get_property ENDPOINT_PIN $p]"
    incr i
  }
} else { puts $fp "BP_HOLD_MIN NA N 0" }

# ---- CE (clock-enable) network into byte-plane FFs: hold + setup on CE pins ----
set cepins [get_pins -quiet -of $bp -filter {REF_PIN_NAME == CE && IS_LEAF}]
puts $fp "BP_CE_PINS [llength $cepins]"
if {[llength $cepins] > 0} {
  set ces [get_timing_paths -quiet -setup -to $cepins -max_paths 50 -nworst 1]
  set ceh [get_timing_paths -quiet -hold  -to $cepins -max_paths 50 -nworst 1]
  if {[llength $ces]>0} { puts $fp "BP_CE_SETUP_MIN [lindex [lsort -real [get_property SLACK $ces]] 0]" } else { puts $fp "BP_CE_SETUP_MIN NA" }
  if {[llength $ceh]>0} { puts $fp "BP_CE_HOLD_MIN [lindex [lsort -real [get_property SLACK $ceh]] 0]" } else { puts $fp "BP_CE_HOLD_MIN NA" }
  # CE-network skew proxy: spread of clock arrival at CE-pin endpoint FF clocks not directly
  # available; use SKEW property spread of the CE-endpoint paths
  set sk [get_property SKEW $ceh]
  set sks [lsort -real $sk]
  puts $fp "BP_CE_HOLD_SKEW_MIN [lindex $sks 0] MAX [lindex $sks end]"
}

# ---- routing detour proxy: worst 10 byte-plane nets by routed delay ----
# (per-net max slow_max delay via get_net_delays on the byte-plane output nets)
set bnets [get_nets -quiet -of $bp -filter {TYPE == SIGNAL}]
set bnets [lsort -unique $bnets]
puts $fp "BP_NETS [llength $bnets]"
set dl {}
foreach n $bnets {
  set nds [get_net_delays -quiet -of_objects $n]
  if {[llength $nds] == 0} continue
  set mx -1
  foreach nd $nds {
    set v [get_property SLOW_MAX $nd]
    if {$v ne "" && $v > $mx} {set mx $v}
  }
  if {$mx >= 0} { lappend dl [list $mx [get_property NAME $n]] }
}
set dl [lsort -real -decreasing -index 0 $dl]
set tot 0.0
foreach e $dl { set tot [expr {$tot + [lindex $e 0]}] }
puts $fp "BP_NETDELAY_SUM [format %.3f $tot] over [llength $dl] nets"
set i 0
foreach e $dl { if {$i>=10} break; puts $fp "BP_NETDELAY [lindex $e 0] [lindex $e 1]"; incr i }

close $fp
puts "PROFILE_DONE $out"
exit 0
