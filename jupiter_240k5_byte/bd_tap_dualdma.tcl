# bd_tap_dualdma.tcl {ch1|ch2} -- make the debug-tap mux STREAMABLE.
#
# HW finding (tap_smoke 2026-07-12): the adrv9002 driver statically exposes ONE
# complex pair per capture device (rx-lpc AND rx2-lpc = voltage0_i/q only), so
# the tap pair on pack channels 2/3 (voltage1) can never reach iio no matter
# the fabric wiring. No DT fix -- the channel table is compiled into the driver.
#
# Fix: route the tap mux pair (sync_output/data_out_rx_2/3, fan-out from the
# pack1 ch2/3 connections which stay) into util_adc_2_pack ch0/1 -> rx2 DMA.
# Host-visible result on BOTH images:
#   axi-adrv9002-rx-lpc  voltage0 = receiver input  (legacy Tap-A, untouched)
#   axi-adrv9002-rx2-lpc voltage0 = iq_debug_mux out (0x10C: 0=AGC out,
#                                   1=postSymbolSync, 2=postCarrierSync, 3=constellation)
# Both packs share the composite's clock + debugValid enable -> the two streams
# are sample-locked at the fabric level (start offsets differ per DMA start).
#
# ch1 arg: also move pack2 + rx2-DMA fifo_wr into the adc_1 domain (composite
#          domain on the ch1 image) -- otherwise improper CDC on the tap data.
# ch2 arg: pack2 is already in the composite's adc_2 domain (bd_ch2_tapfix);
#          only the data/en repins are needed.
set mode [lindex $argv 0]
if {$mode ni {ch1 ch2}} { puts "usage: bd_tap_dualdma.tcl {ch1|ch2}"; exit 2 }
open_project vivado_prj.xpr
open_bd_design [get_files -quiet system.bd]

proc rewire {src sink} {
  set p [get_bd_pins $sink]
  set net [get_bd_nets -quiet -of_objects $p]
  if {$net ne ""} { disconnect_bd_net $net $p }
  connect_bd_net [get_bd_pins $src] $p
}

if {$mode eq "ch1"} {
  puts "=== ch1: pack2 + rx2 DMA fifo_wr -> adc_1 (composite) domain ==="
  rewire axi_adrv9001/adc_1_clk util_adc_2_pack/clk
  rewire axi_adrv9001/adc_1_clk axi_adrv9001_rx2_dma/fifo_wr_clk
  rewire axi_adrv9001/adc_1_rst util_adc_2_pack/reset
} else {
  puts "=== ch2: pack2 + rx2 DMA fifo_wr -> adc_2 (composite) domain ==="
  # explicit re-domain: harmless when already native adc_2, REQUIRED when the
  # source project carries the dualdma-ch1 state (pack2 moved to adc_1)
  rewire axi_adrv9001/adc_2_clk util_adc_2_pack/clk
  rewire axi_adrv9001/adc_2_clk axi_adrv9001_rx2_dma/fifo_wr_clk
  rewire axi_adrv9001/adc_2_rst util_adc_2_pack/reset
}

puts "=== tap mux pair -> util_adc_2_pack ch0/1 (rx2-lpc voltage0) ==="
rewire sync_output/data_out_rx_2       util_adc_2_pack/fifo_wr_data_0
rewire sync_output/data_out_rx_3       util_adc_2_pack/fifo_wr_data_1
rewire sync_output/data_valid_out_rx_0 util_adc_2_pack/fifo_wr_en

if {[catch {validate_bd_design} verr]} { puts "DUALDMA_VALIDATE_FAILED: $verr"; exit 1 }
puts "DUALDMA_VALIDATE_OK ($mode)"
save_bd_design
exit
