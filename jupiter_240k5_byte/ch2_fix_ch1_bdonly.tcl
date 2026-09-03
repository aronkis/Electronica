# ch2_fix_ch1_bdonly.tcl -- the BD-edit portion of ch2_fix_ch1.tcl WITHOUT the
# embedded synth+impl+bootgen tail (the driver builds once, after bd_ch2_tapfix).
# Moving the modem off ch1 left dac_1_data + util_adc_1_pack inputs undriven
# (opt_design error). Restore ch1 as a plain DMA channel (base reference-design
# wiring). NOTE: util_adc_1_pack is subsequently re-purposed as the modem's
# debug-tap capture by bd_ch2_tapfix.tcl; the load-bearing restore here is the
# DAC side (undriven dac_1_data_* fails opt_design).
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
puts "VALIDATE_OK"
save_bd_design
exit
