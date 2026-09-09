# resynth_probe3.tcl -- probe-2 project: drop the three unreadable rxchk GPIOs (bus error on M17..M19,
# cause unknown), route the six checker counters + acc_user/acc_beats through an 8:1 mux onto the
# WORKING witness GPIO channel 2 (0x9D450008), selected by tgen_rx_ctrl_gpio gap[31:28] (0x9D410008).
open_project vivado_prj.xpr
open_bd_design [get_files system.bd]
set icell [get_bd_cells axi_hpm0_lpd_interconnect]
foreach g {rxchk_gpio0 rxchk_gpio1 rxchk_gpio2} { delete_bd_objs [get_bd_cells $g] }
set_property CONFIG.NUM_MI 17 $icell
# refresh checker source (verdict_done declaration order) and add the mux
remove_files [get_files rx_seam_checker.v]
add_files -norecurse [file join [file dirname [info script]] rx_seam_checker.v]
add_files -norecurse [file join [file dirname [info script]] cnt_mux8.v]
update_compile_order -fileset sources_1
delete_bd_objs [get_bd_cells rx_checker]
create_bd_cell -type module -reference rx_seam_checker rx_checker
set HDLCODERIPINST TxRxCompo_ip_0
foreach {dut pin} {dut_byte_data_out data dut_byte_valid_out valid dut_byte_user_out user dut_byte_ready_in ready} {
  connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins $HDLCODERIPINST/$dut]] [get_bd_pins rx_checker/$pin]
}
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins rx_checker/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]]   [get_bd_pins rx_checker/resetn]
create_bd_cell -type module -reference cnt_mux8 cnt_mux
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins cnt_mux/clk]
set n [get_bd_nets -quiet -of_objects [get_bd_pins tgen_rx_wit_gpio/gpio2_io_i]]
if {[llength $n]} { delete_bd_objs $n }
connect_bd_net [get_bd_pins cnt_mux/q] [get_bd_pins tgen_rx_wit_gpio/gpio2_io_i]
connect_bd_net [get_bd_pins traffic_gen_rx/acc_user]  [get_bd_pins cnt_mux/c0]
connect_bd_net [get_bd_pins rx_checker/frames]        [get_bd_pins cnt_mux/c1]
connect_bd_net [get_bd_pins rx_checker/crc_ok]        [get_bd_pins cnt_mux/c2]
connect_bd_net [get_bd_pins rx_checker/crc_fail]      [get_bd_pins cnt_mux/c3]
connect_bd_net [get_bd_pins rx_checker/magic_bad]     [get_bd_pins cnt_mux/c4]
connect_bd_net [get_bd_pins rx_checker/short_frm]     [get_bd_pins cnt_mux/c5]
connect_bd_net [get_bd_pins rx_checker/orphan_w]      [get_bd_pins cnt_mux/c6]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins traffic_gen_rx/acc_beats]] [get_bd_pins cnt_mux/c7]
set sdefs [get_ipdefs -filter {NAME == xlslice}]
create_bd_cell -type ip -vlnv [lindex [lsort -decreasing $sdefs] 0] sel_slice
set_property -dict [list CONFIG.DIN_WIDTH 32 CONFIG.DIN_FROM 31 CONFIG.DIN_TO 28 CONFIG.DOUT_WIDTH 4] [get_bd_cells sel_slice]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins tgen_rx_ctrl_gpio/gpio2_io_o]] [get_bd_pins sel_slice/Din]
connect_bd_net [get_bd_pins sel_slice/Dout] [get_bd_pins cnt_mux/sel]
puts "RXCHK3_WIRE_OK"
validate_bd_design
save_bd_design
puts "VALIDATE_OK"
update_ip_catalog -rebuild -repo_path {./ipcore}
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
