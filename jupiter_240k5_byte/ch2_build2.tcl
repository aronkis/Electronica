# ch2_build2.tcl -- reset ALL runs (BD changed for ch2), synth+impl+bitstream, package BOOT.BIN
open_project vivado_prj.xpr
set_param general.maxThreads 6
update_compile_order -fileset sources_1
puts "=== reset all runs (BD changed) ==="
foreach r [get_runs -quiet system_*_synth_1] { catch { reset_run $r } }
catch { reset_run impl_1 }
catch { reset_run synth_1 }
set ooc [get_runs -quiet system_*_synth_1]
puts "=== launch OOC synth ([llength $ooc] IPs) + synth_1 ==="
launch_runs -jobs 6 {*}$ooc synth_1
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  puts "SYNTH_FAILED status=[get_property STATUS [get_runs synth_1]]"
  exit 1
}
puts "=== synth done -> pre-impl timing gate (shipping netlist) ==="
# The ch2 dual-DMA-tap re-synth is the netlist that actually ships (BOOT.BIN);
# gate WNS at the target fabric clock HERE (Image B: 122.88 via QPSK_TARGET_MHZ).
# For Image A the 30.72 reclock xdc is in constrs_1 so synth_1 is already at 30.72.
source [file join [file dirname [info script]] timing_gate.tcl]
catch {close_design}
launch_runs impl_1 -to_step write_bitstream -jobs 6
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  puts "IMPL_FAILED status=[get_property STATUS [get_runs impl_1]]"
  exit 1
}
# --- final IMPLEMENTED worst setup slack on the shipping design ---
if {![catch {open_run impl_1 -name impl_1} _ir]} {
  set _ip [get_timing_paths -quiet -setup -max_paths 1 -nworst 1]
  if {[llength $_ip]} {
    puts "CH2_IMPL_WNS wns=[get_property SLACK [lindex $_ip 0]]"
  }
  report_timing_summary -quiet -max_paths 1 -file impl_timing_summary.rpt
  catch { puts "CH2_IMPL_TNS [get_property STATS.TNS [get_runs impl_1]]" }
}
puts "=== package BOOT.BIN ==="
set b projects/common/boot/jupiter_sdr
file mkdir boot
file copy -force vivado_prj.runs/impl_1/system_top.bit boot/system_top.bit
foreach f {u-boot.elf zynq.bif fsbl.elf bl31.elf pmufw.elf regs.init} { file copy -force $b/$f boot/$f }
cd boot
exec bootgen -arch zynqmp -image zynq.bif -o BOOT.BIN -w
puts "CH2_BUILD_DONE md5=[exec md5sum BOOT.BIN]"
exit
