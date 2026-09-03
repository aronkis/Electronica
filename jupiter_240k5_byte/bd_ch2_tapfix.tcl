# bd_ch2_tapfix.tcl -- byte+tap-era corrections to the trackB ch2 recipe (which
# was proven on the pre-byte gather design and predates tx/rx_byte_* + the tap):
#  A. byte-path AXIS clocks + the 4-ch capture pack/DMA follow the composite to
#     the adc_2 domain (rewire left them on adc_1_clk -> real unsynchronized
#     crossing INTO the byte link; invisible to validate_bd_design because the
#     HDL-coder IP pins carry no clock association)
#  B. modem debug capture back on util_adc_1_pack / rx1 DMA (axi-adrv9002-rx-lpc):
#     the ONLY capture device whose devicetree exposes 4 iio channels (rx2-lpc
#     has just voltage0_i/q) -- on the rx2 DMA the tap pair (voltage1) is
#     unreachable no matter the fabric wiring
#  C. util_adc_2_pack restored to stock raw adc_2 capture (rx2-lpc = 2ch raw ADC2)
#  D. sync_input IQ-TX data pins refed from util_dac_2_upack: the rewire moved
#     the CONTROL plumbing (upack2 rd_en <- modem tx valid, dac_2_valid ->
#     sync_input valid) but left the four DATA pins on upack1 (dac_1 domain)
# Run AFTER bd_ch2_rewire + bd_ch2_reset + ch2_fix_ch1 BD edits, BEFORE synthesis.
open_project vivado_prj.xpr
open_bd_design [get_files -quiet system.bd]

proc rewire {src sink} {
  set p [get_bd_pins $sink]
  set net [get_bd_nets -quiet -of_objects $p]
  if {$net ne ""} { disconnect_bd_net $net $p }
  connect_bd_net [get_bd_pins $src] $p
}

puts "=== A. byte path + capture pack/DMA clocks -> adc_2 domain ==="
foreach pin {tx_byte_dma/m_axis_aclk byte_breakout/s_axis_aclk rx_byte_dma/s_axis_aclk \
             rx_byte_breakout/m_axis_aclk util_adc_1_pack/clk axi_adrv9001_rx1_dma/fifo_wr_clk} {
  rewire axi_adrv9001/adc_2_clk $pin
}
rewire axi_adrv9001/adc_2_rst util_adc_1_pack/reset

puts "=== B. modem debug taps -> util_adc_1_pack (rx-lpc: the 4-ch DT device) ==="
foreach i {0 1 2 3} { rewire sync_output/data_out_rx_$i util_adc_1_pack/fifo_wr_data_$i }
rewire sync_output/data_valid_out_rx_0 util_adc_1_pack/fifo_wr_en

puts "=== C. util_adc_2_pack -> stock raw adc_2 capture ==="
rewire axi_adrv9001/adc_2_data_i0  util_adc_2_pack/fifo_wr_data_0
rewire axi_adrv9001/adc_2_data_q0  util_adc_2_pack/fifo_wr_data_1
rewire axi_adrv9001/adc_2_valid_i0 util_adc_2_pack/fifo_wr_en

puts "=== D. sync_input IQ-TX data <- util_dac_2_upack (dac_2 domain) ==="
# upack2 is 2-channel (stock tx2 = one complex stream); the composite ignores
# the second TX pair -- tie data_in_tx_2/3 to the 16-bit zero constant
foreach i {0 1} { rewire util_dac_2_upack/fifo_rd_data_$i sync_input/data_in_tx_$i }
foreach i {2 3} { rewire const0_16/dout sync_input/data_in_tx_$i }

if {[catch {validate_bd_design} verr]} { puts "TAPFIX_VALIDATE_FAILED: $verr"; exit 1 }
puts "TAPFIX_VALIDATE_OK"
save_bd_design
exit
