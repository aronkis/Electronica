# resynth_probe2.tcl -- open the completed DMAC-probe project, splice rx_seam_checker (snoop-only)
# on the DUT RX byte pins, three all-inputs dual gpios @0x9D460000/470000/480000, rebuild.
open_project vivado_prj.xpr
open_bd_design [get_files system.bd]
set HDLCODERIPINST TxRxCompo_ip_0
add_files -norecurse [file join [file dirname [info script]] rx_seam_checker.v]
update_compile_order -fileset sources_1
create_bd_cell -type module -reference rx_seam_checker rx_checker
foreach {dut pin} {dut_byte_data_out data dut_byte_valid_out valid dut_byte_user_out user dut_byte_ready_in ready} {
  connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins $HDLCODERIPINST/$dut]] [get_bd_pins rx_checker/$pin]
}
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins rx_checker/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]]   [get_bd_pins rx_checker/resetn]
set _gdefs [get_ipdefs -filter {NAME == axi_gpio}]
if {[llength $_gdefs] > 1} { set _gdefs [lsort -decreasing $_gdefs] }
set bc_intf [get_bd_intf_pins -quiet -of_objects [get_bd_intf_nets -of_objects [get_bd_intf_pins byte_ctrl_gpio/S_AXI]] -filter {MODE == Master}]
set icell [get_bd_cells -of_objects $bc_intf]
foreach {gname a b addr} {rxchk_gpio0 frames crc_ok 0x9D460000 rxchk_gpio1 crc_fail magic_bad 0x9D470000 rxchk_gpio2 short_frm orphan_w 0x9D480000} {
  create_bd_cell -type ip -vlnv [lindex $_gdefs 0] $gname
  set_property -dict [list CONFIG.C_IS_DUAL 1 CONFIG.C_ALL_INPUTS 1 CONFIG.C_ALL_INPUTS_2 1 CONFIG.C_GPIO_WIDTH 32 CONFIG.C_GPIO2_WIDTH 32] [get_bd_cells $gname]
  connect_bd_net [get_bd_pins rx_checker/$a] [get_bd_pins $gname/gpio_io_i]
  connect_bd_net [get_bd_pins rx_checker/$b] [get_bd_pins $gname/gpio2_io_i]
  set nmi [get_property CONFIG.NUM_MI $icell]
  set_property CONFIG.NUM_MI [expr {$nmi + 1}] $icell
  set newm [format "M%02d_AXI" $nmi]
  connect_bd_intf_net [get_bd_intf_pins $icell/$newm] [get_bd_intf_pins $gname/S_AXI]
  foreach p {ACLK ARESETN} sfx {s_axi_aclk s_axi_aresetn} {
    set src [get_bd_nets -of_objects [get_bd_pins byte_ctrl_gpio/$sfx]]
    connect_bd_net -net $src [get_bd_pins $gname/$sfx]
    catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d_$p" $nmi]] }
  }
  assign_bd_address -target_address_space /sys_ps8/Data [get_bd_addr_segs $gname/S_AXI/Reg] -offset $addr -range 64K
}
puts "RXCHK_WIRE_OK"
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
