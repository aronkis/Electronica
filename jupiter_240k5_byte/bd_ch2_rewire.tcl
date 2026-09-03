# bd_ch2_rewire.tcl -- retarget the modem (TxRxCompo_ip_0) from ADRV9002 channel 1
# (adc_1/dac_1) to channel 2 (adc_2/dac_2) by rewiring the sync/regularizer infra.
# Runs validate_bd_design as a feasibility gate BEFORE committing to synthesis.
set prj [lindex $argv 0]
open_project $prj
set bd [get_files -quiet system.bd]
open_bd_design $bd

proc move_pin_to {pin newsrc} {
  set p [get_bd_pins $pin]
  set net [get_bd_nets -quiet -of_objects $p]
  if {$net ne ""} { disconnect_bd_net $net $p }
  connect_bd_net [get_bd_pins $newsrc] $p
}

puts "=== CLOCKS: modem datapath+sync+regularizer -> adc_2_clk / dac_2_clk ==="
foreach pin {sync_input/rx_clk sync_output/rx_clk valid_regularizer/clk \
             TxRxCompo_ip_0/IPCORE_CLK TxRxCompo_ip_0/AXI4_Lite_ACLK} {
  move_pin_to $pin axi_adrv9001/adc_2_clk
}
foreach pin {sync_input/tx_clk sync_output/tx_clk} {
  move_pin_to $pin axi_adrv9001/dac_2_clk
}
# AXI-Lite interconnect clock for the modem (aclk1 fed adc_1_clk)
catch { move_pin_to axi_hpm0_lpd_interconnect/aclk1 axi_adrv9001/adc_2_clk }

puts "=== Rx DATA: adc_2 i0/q0 -> valid_regularizer (was adc_1 4-lane) ==="
foreach {src dst} {adc_1_data_i0 in_data_0 adc_1_data_q0 in_data_1 \
                   adc_1_data_i1 in_data_2 adc_1_data_q1 in_data_3 adc_1_valid_i0 in_valid} {
  set p [get_bd_pins valid_regularizer/$dst]
  set net [get_bd_nets -quiet -of_objects $p]
  if {$net ne ""} { disconnect_bd_net $net $p }
}
connect_bd_net [get_bd_pins axi_adrv9001/adc_2_data_i0] [get_bd_pins valid_regularizer/in_data_0]
connect_bd_net [get_bd_pins axi_adrv9001/adc_2_data_q0] [get_bd_pins valid_regularizer/in_data_1]
connect_bd_net [get_bd_pins axi_adrv9001/adc_2_valid_i0] [get_bd_pins valid_regularizer/in_valid]
# tie the now-unused in_data_2/3 (ch1 had 2 streams; ch2 has 1) to constant 0
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 -quiet const0_16
set_property CONFIG.CONST_WIDTH 16 [get_bd_cells const0_16]
set_property CONFIG.CONST_VAL 0 [get_bd_cells const0_16]
catch { connect_bd_net [get_bd_pins const0_16/dout] [get_bd_pins valid_regularizer/in_data_2] }
catch { connect_bd_net [get_bd_pins const0_16/dout] [get_bd_pins valid_regularizer/in_data_3] }

puts "=== Tx DATA: sync_output -> dac_2 (was dac_1) ==="
foreach {op dst} {data_out_tx_0 adc_2_dummy} {}
# disconnect sync_output tx from dac_1, reconnect first 2 lanes to dac_2
foreach lane {0 1 2 3} {
  set p [get_bd_pins sync_output/data_out_tx_$lane]
  set net [get_bd_nets -quiet -of_objects $p]
  if {$net ne ""} { disconnect_bd_net $net $p }
}
# dac_2_data_* are sinks already driven by util_dac_2_upack -> disconnect first
move_pin_to axi_adrv9001/dac_2_data_i0 sync_output/data_out_tx_0
move_pin_to axi_adrv9001/dac_2_data_q0 sync_output/data_out_tx_1
# tx valid: sync_output rd_en -> util_dac_2_upack ; sync_input valid_in_tx <- dac_2_valid
move_pin_to util_dac_2_upack/fifo_rd_en sync_output/data_valid_out_tx_0
move_pin_to sync_input/data_valid_in_tx_0 axi_adrv9001/dac_2_valid_i0

puts "=== Rx CAPTURE: sync_output rx -> util_adc_2_pack (2-lane) ==="
foreach lane {0 1 2 3} {
  set p [get_bd_pins sync_output/data_out_rx_$lane]
  set net [get_bd_nets -quiet -of_objects $p]
  if {$net ne ""} { disconnect_bd_net $net $p }
}
# util_adc_2_pack fifo_wr_* are sinks already driven by adc_2 data -> disconnect first
move_pin_to util_adc_2_pack/fifo_wr_data_0 sync_output/data_out_rx_0
move_pin_to util_adc_2_pack/fifo_wr_data_1 sync_output/data_out_rx_1
move_pin_to util_adc_2_pack/fifo_wr_en sync_output/data_valid_out_rx_0

puts "=== VALIDATE ==="
if {[catch {validate_bd_design} verr]} {
  puts "VALIDATE_FAILED: $verr"
} else {
  puts "VALIDATE_OK"
  save_bd_design
}
