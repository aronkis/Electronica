# dcp_glitch_probe.tcl <routed.dcp> <out.txt> -- byte-plane CE/rail GLITCH-PATH
# forensic on the SHIPPING implementation (HANDOFF_20260815 morning-queue #1).
# The wit-forensic proved synthesis re-hosts CE/rail logic with deterministic
# silicon divergence; this probe asks whether the shipping image's own
# byte-plane enable network has glitch-prone structure:
#   1. every BUFGCE/BUFGCE_DIV whose CE is driven by combinational logic
#      (LUT depth >= 1) -- CE pins of clock buffers sample asynchronously to
#      the gated domain and a LUT-composed CE can glitch;
#   2. timing of the paths INTO those CE pins (setup+hold, worst 5 each);
#   3. the byte-plane enable nets (enb*, *_gated) : driver type, LUT INIT,
#      fanout, and min-pulse-width slack of the loads;
#   4. multi-driver / combinational-loop check on the same nets.
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set fp [open $out w]

puts $fp "== 1. BUFGCE census with CE drivers =="
foreach c [get_cells -hier -filter {REF_NAME =~ BUFGCE*}] {
  set cep [get_pins -quiet $c/CE]
  if {![llength $cep]} { continue }
  set cenet [get_nets -quiet -of $cep]
  set drv [get_pins -quiet -of $cenet -filter {DIRECTION == OUT && IS_LEAF}]
  set drvcell ""
  set drvref ""
  set drvinit "-"
  if {[llength $drv]} {
    set drvcell [get_cells -of [lindex $drv 0]]
    set drvref [get_property REF_NAME $drvcell]
    catch { set drvinit [get_property INIT $drvcell] }
  }
  puts $fp "BUFGCE [get_property NAME $c] CE_net=[get_property NAME $cenet] drv=$drvref INIT=$drvinit drvcell=$drvcell"
}

puts $fp "== 2. worst setup+hold into BUFGCE CE pins =="
foreach c [get_cells -hier -filter {REF_NAME =~ BUFGCE*}] {
  set cep [get_pins -quiet $c/CE]
  if {![llength $cep]} { continue }
  foreach dtype {max min} {
    set paths [get_timing_paths -quiet -to $cep -delay_type $dtype -max_paths 3]
    foreach p $paths {
      puts $fp "CEPATH $dtype [get_property NAME $c] slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] start=[get_property STARTPOINT_PIN $p]"
    }
  }
}

puts $fp "== 3. byte-plane enable nets: structure =="
foreach pat {*enb_1_2_0* *enb_gated* *byte*en*} {
  foreach n [get_nets -quiet -hier -filter "NAME =~ $pat && TYPE != POWER && TYPE != GROUND"] {
    set drv [get_pins -quiet -of $n -filter {DIRECTION == OUT && IS_LEAF}]
    set drvref "-" ; set drvinit "-"
    if {[llength $drv]} {
      set dc [get_cells -of [lindex $drv 0]]
      set drvref [get_property REF_NAME $dc]
      catch { set drvinit [get_property INIT $dc] }
    }
    puts $fp "ENBNET [get_property NAME $n] TYPE=[get_property TYPE $n] FO=[get_property FLAT_PIN_COUNT $n] drv=$drvref INIT=$drvinit"
  }
}

puts $fp "== 4. pulse-width / min-period violations (byte-plane scope) =="
set pw [report_pulse_width -return_string -all_violators -no_header]
puts $fp $pw

close $fp
puts "GLITCH_PROBE_DONE $out"
exit
