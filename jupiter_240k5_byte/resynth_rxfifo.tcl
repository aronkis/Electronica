# resynth_rxfifo.tcl -- re-synthesize/implement an ALREADY-COMPLETED byte-image
# project after a source-only change (rxfifo_inject.sh). The BD is untouched
# (TxRxCompo_ip_0 already exists and is wired); only the IP's HDL changed in the
# packaged zip + extracted ipshared copy. Tail of complete_byte_t8.tcl verbatim.
open_project vivado_prj.xpr
update_ip_catalog -rebuild -repo_path {./ipcore}
report_ip_status -quiet
set_property top system_top [current_fileset]
generate_target all [get_files system.bd]
update_compile_order -fileset sources_1
set_param general.maxThreads 6
catch {reset_run impl_1}; catch {reset_run synth_1}
foreach r [get_runs -quiet system_*_synth_1] { catch { reset_run $r } }
puts "=== synth ==="; launch_runs synth_1 -jobs 6; wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "SYNTH_FAILED [get_property STATUS [get_runs synth_1]]"; exit 1 }
puts "=== pre-impl timing gate ==="; source [file join [file dirname [info script]] timing_gate.tcl]
puts "=== impl+bit ==="; launch_runs impl_1 -to_step write_bitstream -jobs 6; wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "IMPL_FAILED [get_property STATUS [get_runs impl_1]]"; exit 1 }
set b projects/common/boot/jupiter_sdr; file mkdir boot
file copy -force [get_property DIRECTORY [get_runs impl_1]]/system_top.bit boot/system_top.bit
foreach f {u-boot.elf zynq.bif fsbl.elf bl31.elf pmufw.elf regs.init} { file copy -force $b/$f boot/$f }
cd boot; exec bootgen -arch zynqmp -image zynq.bif -o BOOT.BIN -w
puts "BYTE_BUILD_DONE md5=[exec md5sum BOOT.BIN]"; exit
