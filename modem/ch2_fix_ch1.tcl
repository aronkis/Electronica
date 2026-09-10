# ch2_fix_ch1.tcl -- moving the modem off ch1 left dac_1_data + util_adc_1_pack inputs
# undriven (opt_design error). Restore ch1 as a plain DMA channel (base reference-design
# wiring), then re-synth top + impl + bitstream + BOOT.BIN.
open_project vivado_prj.xpr
set_param general.maxThreads 12
open_bd_design [get_files -quiet system.bd]

proc rewire {src sink} {
  set p [get_bd_pins $sink]
  set net [get_bd_nets -quiet -of_objects $p]
  if {$net ne ""} { disconnect_bd_net $net $p }
  connect_bd_net [get_bd_pins $src] $p
}
puts "=== restore ch1 ADC -> util_adc_1_pack (raw capture) ==="
rewire axi_adrv9001/adc_1_data_i0  util_adc_1_pack/fifo_wr_data_0
rewire axi_adrv9001/adc_1_data_q0  util_adc_1_pack/fifo_wr_data_1
rewire axi_adrv9001/adc_1_data_i1  util_adc_1_pack/fifo_wr_data_2
rewire axi_adrv9001/adc_1_data_q1  util_adc_1_pack/fifo_wr_data_3
rewire axi_adrv9001/adc_1_valid_i0 util_adc_1_pack/fifo_wr_en
puts "=== restore util_dac_1_upack -> ch1 DAC (playback) ==="
rewire util_dac_1_upack/fifo_rd_data_0 axi_adrv9001/dac_1_data_i0
rewire util_dac_1_upack/fifo_rd_data_1 axi_adrv9001/dac_1_data_q0
rewire util_dac_1_upack/fifo_rd_data_2 axi_adrv9001/dac_1_data_i1
rewire util_dac_1_upack/fifo_rd_data_3 axi_adrv9001/dac_1_data_q1
rewire axi_adrv9001/dac_1_valid_i0 util_dac_1_upack/fifo_rd_en

if {[catch {validate_bd_design} verr]} { puts "VALIDATE_FAILED: $verr"; exit 1 }
puts "VALIDATE_OK"; save_bd_design
update_compile_order -fileset sources_1
reset_run impl_1
reset_run synth_1
puts "=== re-synth top + impl ==="
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "SYNTH_FAILED [get_property STATUS [get_runs synth_1]]"; exit 1 }
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "IMPL_FAILED [get_property STATUS [get_runs impl_1]]"; exit 1 }
puts "=== package BOOT.BIN ==="
set b projects/common/boot/jupiter_sdr
file mkdir boot
file copy -force vivado_prj.runs/impl_1/system_top.bit boot/system_top.bit
foreach f {u-boot.elf zynq.bif fsbl.elf bl31.elf pmufw.elf regs.init} { file copy -force $b/$f boot/$f }
cd boot
exec bootgen -arch zynqmp -image zynq.bif -o BOOT.BIN -w
puts "CH2_BUILD_DONE md5=[exec md5sum BOOT.BIN]"
exit
