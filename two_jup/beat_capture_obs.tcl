# beat_capture.tcl -- Vivado XVC capture of the 119.75s burst (two runs).
# argv: <ltx> <outdir> <xvc_url>
set ltx    [lindex $argv 0]
set outdir [lindex $argv 1]
set url    [lindex $argv 2]
file mkdir $outdir
open_hw_manager
connect_hw_server
# fresh-daemon first-contact flake: retry enumeration up to 4x (observed: first
# hw_server contact after a daemon restart fails, second succeeds)
set _ok 0
for {set _try 1} {$_try <= 4} {incr _try} {
  if {![catch { open_hw_target -xvc_url $url } _e]} { set _ok 1; break }
  puts "BEATCAP_ENUM_RETRY $_try: $_e"
  catch { disconnect_hw_server }
  after 3000
  connect_hw_server
}
if {!$_ok} { puts "BEATCAP_FATAL enum failed after 4 tries"; exit 1 }
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev
set ila [lindex [get_hw_ilas] 0]
if {$ila eq ""} { puts "BEATCAP_FATAL no ILA over XVC"; exit 1 }
set probes [get_hw_probes -of_objects $ila]
# probe width: hw_probe exposes it as PROBE.MU_COUNT/name, not PROBE_WIDTH;
# query safely (catch) so a missing property never aborts the session.
proc pwidth {p} {
  foreach prop {PROBE.WIDTH PROBE_WIDTH WIDTH} {
    if {![catch {get_property $prop $p} w] && $w ne ""} { return $w }
  }
  return -1
}
set pf [open $outdir/probes.txt w]
foreach p $probes { puts $pf "[get_property NAME $p] w=[pwidth $p]" }
close $pf
# trig probe: prefer a 1-bit probe whose name contains trig (not latched/status)
set tp ""
foreach p $probes {
  set n [get_property NAME $p]
  if {[string match -nocase *trig* $n] && ![string match -nocase *latch* $n] \
      && [pwidth $p] == 1} { set tp $p; break }
}
if {$tp eq ""} { set tp [lindex $probes 0]; puts "BEATCAP_WARN trig probe by fallback: [get_property NAME $tp]" }
puts "BEATCAP_TRIGPROBE [get_property NAME $tp]"
# qualifier probe (dut_data_valid_out_rx) for run 2
set qp ""
foreach p $probes {
  set n [get_property NAME $p]
  if {[string match -nocase *data_valid_out_rx* $n]} { set qp $p; break }
}

proc do_run {ila tp label marker outdir capture qp} {
  set_property CONTROL.TRIGGER_POSITION 3072 $ila
  set_property TRIGGER_COMPARE_VALUE eq1'b1 $tp
  if {$capture && $qp ne ""} {
    set_property CONTROL.CAPTURE_MODE BASIC $ila
    set_property CAPTURE_COMPARE_VALUE eq1'b1 $qp
  } else {
    set_property CONTROL.CAPTURE_MODE ALWAYS $ila
  }
  run_hw_ila $ila
  exec touch $marker
  puts "BEATCAP_ARMED $label"
  if {[catch {wait_on_hw_ila -timeout 10 $ila} err]} { puts "BEATCAP_TIMEOUT $label ($err)"; return 0 }
  upload_hw_ila_data $ila
  write_hw_ila_data -force -csv_file $outdir/$label.csv [current_hw_ila_data]
  puts "BEATCAP_CAPTURED $label -> $outdir/$label.csv"
  return 1
}
set r1 [do_run $ila $tp run1_raw       $outdir/armed_1 $outdir 0 $qp]
set r2 [do_run $ila $tp run2_qualified $outdir/armed_2 $outdir 1 $qp]
puts "BEATCAP_DONE r1=$r1 r2=$r2"
close_hw_manager
exit
