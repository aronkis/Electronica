# resynth_probe4.tcl -- probe-3 project + tx_starve_witness (snoop on the DUT TX byte-in pins) and a 16:1
# counter mux replacing cnt_mux8 on the witness GPIO ch2 (0x9D450008), select = tgen_rx gap[31:28].
# sel: 0 acc_user 1 frames 2 crc_ok 3 crc_fail 4 magic_bad 5 short 6 orphan 7 acc_beats
#      8 ep_gt1k 9 ep_gt2k 10 ep_gt3k 11 ep_gt6k 12 ep_gt12k 13 ep_gt25k 14 max_len 15 starve_clk
open_project vivado_prj.xpr
open_bd_design [get_files system.bd]
set HDLCODERIPINST TxRxCompo_ip_0
add_files -norecurse [file join [file dirname [info script]] tx_starve_witness.v]
add_files -norecurse [file join [file dirname [info script]] cnt_mux16.v]
update_compile_order -fileset sources_1
delete_bd_objs [get_bd_cells cnt_mux]
create_bd_cell -type module -reference cnt_mux16 cnt_mux
create_bd_cell -type module -reference tx_starve_witness tx_starve
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins cnt_mux/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins tx_starve/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]]   [get_bd_pins tx_starve/resetn]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins $HDLCODERIPINST/dut_byte_valid_in]]  [get_bd_pins tx_starve/valid]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins $HDLCODERIPINST/dut_byte_ready_out]] [get_bd_pins tx_starve/ready]
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
connect_bd_net [get_bd_pins tx_starve/ep_gt1k]   [get_bd_pins cnt_mux/c8]
connect_bd_net [get_bd_pins tx_starve/ep_gt2k]   [get_bd_pins cnt_mux/c9]
connect_bd_net [get_bd_pins tx_starve/ep_gt3k]   [get_bd_pins cnt_mux/c10]
connect_bd_net [get_bd_pins tx_starve/ep_gt6k]   [get_bd_pins cnt_mux/c11]
connect_bd_net [get_bd_pins tx_starve/ep_gt12k]  [get_bd_pins cnt_mux/c12]
connect_bd_net [get_bd_pins tx_starve/ep_gt25k]  [get_bd_pins cnt_mux/c13]
connect_bd_net [get_bd_pins tx_starve/max_len]   [get_bd_pins cnt_mux/c14]
connect_bd_net [get_bd_pins tx_starve/starve_clk] [get_bd_pins cnt_mux/c15]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sel_slice/Dout]] [get_bd_pins cnt_mux/sel]
puts "TXSTARVE_WIRE_OK"
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
