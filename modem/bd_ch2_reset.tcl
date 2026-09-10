# bd_ch2_reset.tcl -- move modem+sync+regularizer resets to adc_2_rst/dac_2_rst domains
# (datapath was moved to adc_2_clk/dac_2_clk), verify data-path connectivity, re-validate.
open_project [lindex $argv 0]
open_bd_design [get_files -quiet system.bd]

proc srcof {pin} {
  set net [get_bd_nets -quiet -of_objects [get_bd_pins $pin]]
  if {$net eq ""} { return "<none>" }
  set src [get_bd_pins -quiet -of_objects $net -filter {DIR==O}]
  return "$net : src=$src"
}
puts "VERIFY dac_2_data_i0 <- [srcof axi_adrv9001/dac_2_data_i0]"
puts "VERIFY dac_2_data_q0 <- [srcof axi_adrv9001/dac_2_data_q0]"
puts "VERIFY modem/dut_data_in_0_rx <- [srcof TxRxCompo_ip_0/dut_data_in_0_rx]"
puts "VERIFY modem/IPCORE_CLK <- [srcof TxRxCompo_ip_0/IPCORE_CLK]"
puts "VERIFY modem/IPCORE_RESETN <- [srcof TxRxCompo_ip_0/IPCORE_RESETN]"

proc move_pin_to {pin newsrc} {
  set p [get_bd_pins $pin]
  set net [get_bd_nets -quiet -of_objects $p]
  if {$net ne ""} { disconnect_bd_net $net $p }
  connect_bd_net [get_bd_pins $newsrc] $p
}
# create active-low reset inverters for adc_2_rst / dac_2_rst
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 -quiet inv_adc2_rst
set_property -dict [list CONFIG.C_OPERATION not CONFIG.C_SIZE 1] [get_bd_cells inv_adc2_rst]
connect_bd_net [get_bd_pins axi_adrv9001/adc_2_rst] [get_bd_pins inv_adc2_rst/Op1]
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 -quiet inv_dac2_rst
set_property -dict [list CONFIG.C_OPERATION not CONFIG.C_SIZE 1] [get_bd_cells inv_dac2_rst]
connect_bd_net [get_bd_pins axi_adrv9001/dac_2_rst] [get_bd_pins inv_dac2_rst/Op1]

puts "=== reconnect resets to adc_2/dac_2 domains ==="
foreach pin {TxRxCompo_ip_0/IPCORE_RESETN TxRxCompo_ip_0/AXI4_Lite_ARESETN \
             sync_input/rx_rstn sync_output/rx_rstn valid_regularizer/rstn} {
  catch { move_pin_to $pin inv_adc2_rst/Res }
}
foreach pin {sync_input/tx_rstn sync_output/tx_rstn} {
  catch { move_pin_to $pin inv_dac2_rst/Res }
}
puts "AFTER modem/IPCORE_RESETN <- [srcof TxRxCompo_ip_0/IPCORE_RESETN]"

if {[catch {validate_bd_design} verr]} {
  puts "VALIDATE_FAILED: $verr"
} else {
  puts "VALIDATE_OK"; save_bd_design
}
