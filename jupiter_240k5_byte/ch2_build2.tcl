# ch2_build2.tcl -- reset ALL runs (BD changed for ch2), synth+impl+bitstream, package BOOT.BIN
open_project vivado_prj.xpr
set_param general.maxThreads 12
update_compile_order -fileset sources_1
puts "=== reset all runs (BD changed) ==="
foreach r [get_runs -quiet system_*_synth_1] { catch { reset_run $r } }
catch { reset_run impl_1 }
catch { reset_run synth_1 }
set ooc [get_runs -quiet system_*_synth_1]
puts "=== launch OOC synth ([llength $ooc] IPs) + synth_1 ==="
launch_runs -jobs 8 {*}$ooc synth_1
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  puts "SYNTH_FAILED status=[get_property STATUS [get_runs synth_1]]"
  exit 1
}
puts "=== synth done -> impl + write_bitstream ==="
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  puts "IMPL_FAILED status=[get_property STATUS [get_runs impl_1]]"
  exit 1
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
