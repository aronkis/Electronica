open_project vivado_prj.xpr
set project {jupiter_sdr}
set ref_design {rxtx}
set preprocess {off}
set postprocess {off}
set number_of_inputs {4}
set number_of_bits {16}
set number_of_valids {1}
set multiple {1}
set HDLVerifierAXI {off}
update_ip_catalog -delete_ip {./ipcore/TxRxCompo_ip_v1_0/component.xml} -repo_path {./ipcore} -quiet
update_ip_catalog -add_ip {./ipcore/TxRxCompo_ip_v1_0.zip} -repo_path {./ipcore}
update_ip_catalog
set HDLCODERIPVLNV [get_property VLNV [get_ipdefs -filter {NAME==TxRxCompo_ip && VERSION==1.0}]]
set HDLCODERIPINST TxRxCompo_ip_0
set BDFILEPATH [get_files -quiet system.bd]
open_bd_design $BDFILEPATH
create_bd_cell -type ip -vlnv $HDLCODERIPVLNV $HDLCODERIPINST
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins $HDLCODERIPINST/AXI4_Lite_ACLK] [get_bd_pins axi_adrv9001/adc_1_clk] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/AXI4_Lite_ACLK] [get_bd_pins axi_adrv9001/adc_1_clk] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins rx_rstn_inverter/Res]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]] [get_bd_pins $HDLCODERIPINST/AXI4_Lite_ARESETN] [get_bd_pins rx_rstn_inverter/Res] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/AXI4_Lite_ARESETN] [get_bd_pins rx_rstn_inverter/Res] }
connect_bd_intf_net [get_bd_intf_pins $HDLCODERIPINST/AXI4_Lite] [get_bd_intf_pins axi_hpm0_lpd_interconnect/M07_AXI]
create_bd_addr_seg -range 0x10000 -offset 0x9D000000 [get_bd_addr_spaces sys_ps8/Data] [get_bd_addr_segs $HDLCODERIPINST/AXI4_Lite/reg0] SEG_${HDLCODERIPINST}_reg0
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_valid_in_rx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_valid_in_rx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_valid_out_rx] [get_bd_pins sync_output/data_valid_in_rx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_valid_out_rx] [get_bd_pins sync_output/data_valid_in_rx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_valid_out_rx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_valid_out_rx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_valid_in_rx] [get_bd_pins sync_input/data_valid_out_rx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_valid_in_rx] [get_bd_pins sync_input/data_valid_out_rx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_rx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_rx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_out_0_rx] [get_bd_pins sync_output/data_in_rx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_0_rx] [get_bd_pins sync_output/data_in_rx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_rx_1]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_rx_1]] [get_bd_pins $HDLCODERIPINST/dut_data_out_1_rx] [get_bd_pins sync_output/data_in_rx_1] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_1_rx] [get_bd_pins sync_output/data_in_rx_1] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_rx_2]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_rx_2]] [get_bd_pins $HDLCODERIPINST/dut_data_out_2_rx] [get_bd_pins sync_output/data_in_rx_2] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_2_rx] [get_bd_pins sync_output/data_in_rx_2] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_rx_3]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_rx_3]] [get_bd_pins $HDLCODERIPINST/dut_data_out_3_rx] [get_bd_pins sync_output/data_in_rx_3] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_3_rx] [get_bd_pins sync_output/data_in_rx_3] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_out_rx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_out_rx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_in_0_rx] [get_bd_pins sync_input/data_out_rx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_in_0_rx] [get_bd_pins sync_input/data_out_rx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_out_rx_1]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_out_rx_1]] [get_bd_pins $HDLCODERIPINST/dut_data_in_1_rx] [get_bd_pins sync_input/data_out_rx_1] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_in_1_rx] [get_bd_pins sync_input/data_out_rx_1] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_valid_out_tx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_valid_out_tx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_valid_in_tx] [get_bd_pins sync_input/data_valid_out_tx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_valid_in_tx] [get_bd_pins sync_input/data_valid_out_tx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_valid_in_tx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_valid_in_tx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_valid_out_tx] [get_bd_pins sync_output/data_valid_in_tx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_valid_out_tx] [get_bd_pins sync_output/data_valid_in_tx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_tx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_tx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_out_0_tx] [get_bd_pins sync_output/data_in_tx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_0_tx] [get_bd_pins sync_output/data_in_tx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_tx_1]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_tx_1]] [get_bd_pins $HDLCODERIPINST/dut_data_out_1_tx] [get_bd_pins sync_output/data_in_tx_1] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_1_tx] [get_bd_pins sync_output/data_in_tx_1] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_out_tx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_out_tx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_in_0_tx] [get_bd_pins sync_input/data_out_tx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_in_0_tx] [get_bd_pins sync_input/data_out_tx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_out_tx_1]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_out_tx_1]] [get_bd_pins $HDLCODERIPINST/dut_data_in_1_tx] [get_bd_pins sync_input/data_out_tx_1] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_in_1_tx] [get_bd_pins sync_input/data_out_tx_1] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins $HDLCODERIPINST/IPCORE_CLK] [get_bd_pins axi_adrv9001/adc_1_clk] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/IPCORE_CLK] [get_bd_pins axi_adrv9001/adc_1_clk] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins rx_rstn_inverter/Res]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]] [get_bd_pins $HDLCODERIPINST/IPCORE_RESETN] [get_bd_pins rx_rstn_inverter/Res] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/IPCORE_RESETN] [get_bd_pins rx_rstn_inverter/Res] }
add_files -norecurse {projects/jupiter_sdr/system_top.v}
update_compile_order -fileset sources_1
validate_bd_design
save_bd_design
add_files -fileset constrs_1 -norecurse projects/jupiter_sdr/system_constr.xdc
puts "=== STOCK TX WIRING (no gather) — verify sync_output drives the DAC ==="
foreach p {dac_1_data_i0 dac_1_data_q0 dac_1_data_i1 dac_1_data_q1} { if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_adrv9001/$p]]]} { puts "WIRE_FAIL: $p undriven"; exit 1 } }
puts "WIRE_OK"
if {[catch {validate_bd_design} verr]} { puts "VALIDATE_FAILED: $verr"; exit 1 }
puts "VALIDATE_OK"; save_bd_design
set_property top system_top [current_fileset]
generate_target all [get_files system.bd]
update_compile_order -fileset sources_1
set_param general.maxThreads 12
catch {reset_run impl_1}; catch {reset_run synth_1}
foreach r [get_runs -quiet system_*_synth_1] { catch { reset_run $r } }
puts "=== synth ==="; launch_runs synth_1 -jobs 8; wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "SYNTH_FAILED [get_property STATUS [get_runs synth_1]]"; exit 1 }
puts "=== impl+bit ==="; launch_runs impl_1 -to_step write_bitstream -jobs 8; wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "IMPL_FAILED [get_property STATUS [get_runs impl_1]]"; exit 1 }
set b projects/common/boot/jupiter_sdr; file mkdir boot
file copy -force [get_property DIRECTORY [get_runs impl_1]]/system_top.bit boot/system_top.bit
foreach f {u-boot.elf zynq.bif fsbl.elf bl31.elf pmufw.elf regs.init} { file copy -force $b/$f boot/$f }
cd boot; exec bootgen -arch zynqmp -image zynq.bif -o BOOT.BIN -w
puts "AGCFIX_DONE md5=[exec md5sum BOOT.BIN]"; exit
