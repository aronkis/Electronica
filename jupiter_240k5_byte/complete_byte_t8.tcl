open_project vivado_prj.xpr
# CDC exceptions: the MATLAB IP packaging emits ADI's axi_adrv9001/axi_dmac
# constraint files as stub .txt (never loaded); without these the async
# PS<->ADRV9001-domain crossings are fully timed and placement quality is a
# lottery (lean-image no-lock, 2026-07-15). Kit file: cdc_exceptions.xdc.
set kdir [file dirname [info script]]
file copy -force $kdir/cdc_exceptions.xdc cdc_exceptions.xdc
add_files -fileset constrs_1 -norecurse cdc_exceptions.xdc
set_property USED_IN {implementation} [get_files cdc_exceptions.xdc]
# T8.9 TMR stall fix: the triplicated accumulator registers MUST NOT be merged
# by equivalent-register removal, or the fix is silently deleted from the
# bitstream (netlist sim would still pass -- Verilator does not merge). Applied
# only when the TMR overlay is in the build (env QPSK_MOVSUM_TMR set).
if {[info exists ::env(QPSK_MOVSUM_TMR)] && $::env(QPSK_MOVSUM_TMR) ne ""} {
  file copy -force $kdir/tmr_keep.xdc tmr_keep.xdc
  add_files -fileset constrs_1 -norecurse tmr_keep.xdc
  set_property USED_IN {synthesis implementation} [get_files tmr_keep.xdc]
  set_property PROCESSING_ORDER LATE [get_files tmr_keep.xdc]
  puts "TMR_XDC_ADDED tmr_keep.xdc (DONT_TOUCH on triplicated accumulator)"
}
# IMAGE A (30.72 MHz rungs R0/R1): re-time the fabric to 30.72 MHz. The ADI RD
# constrains the SSI at 125 MHz, but the f1536 modem is sized for 30.72 MHz and
# cannot close at 125 MHz (interleaver mod/idivide(1537) arithmetic). Applied only
# when QPSK_TARGET_MHZ selects the low rung (< 60 MHz -> Image A; Image B @122.88
# leaves the RD's 125 MHz). PROCESSING_ORDER LATE so it overrides the RD's
# create_clock on the dclk ports. See image_a_3072_clocks.xdc for the LOAD-BEARING
# deploy discipline (Image A boards may load ONLY 1.92/15.36 MSPS profiles).
if {[info exists ::env(QPSK_FRAME)] && $::env(QPSK_FRAME) eq "f1536" \
        && [info exists ::env(QPSK_TARGET_MHZ)] && [string is double -strict $::env(QPSK_TARGET_MHZ)] && $::env(QPSK_TARGET_MHZ) < 60} {
    file copy -force $kdir/image_a_3072_clocks.xdc image_a_3072_clocks.xdc
    add_files -fileset constrs_1 -norecurse image_a_3072_clocks.xdc
    set_property USED_IN {synthesis implementation} [get_files image_a_3072_clocks.xdc]
    set_property PROCESSING_ORDER LATE [get_files image_a_3072_clocks.xdc]
    puts "IMAGE_A_RECLOCK: applied image_a_3072_clocks.xdc -> fabric adc_1_clk @ 30.72 MHz"
}
set project {jupiter_sdr}
set ref_design {rxtx}
set preprocess {off}
set postprocess {off}
set number_of_inputs {4}
set number_of_bits {16}
set number_of_valids {1}
set multiple {2}
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
puts "=== BYTE DMA path: connect DUT byte ports to the byte breakouts (June-proven wiring) ==="
# assert the byte reference-design blocks are present in the BD
foreach c {byte_breakout rx_byte_breakout tx_byte_dma rx_byte_dma byte_ctrl_gpio} {
  if {![llength [get_bd_cells -quiet $c]]} { puts "BYTE_FAIL: cell $c missing (wrong reference design?)"; exit 1 }
}
# CYCLIC-capable MODEM RX DMAC (two_jup/DMAC_IDENTIFIED.md): rx_byte_dma is the
# modem byte-plane S2MM DMAC at 0x9D200000, instantiated by TransceiverToolbox
# matlab_processors.tcl:1061 with CONFIG.CYCLIC 0. Flip it to 1 here. Safe to
# bake: the axi_dmac register path is runtime-opt-in (up_dma_cyclic <=
# up_wdata[0] & DMA_CYCLIC), so the current host runs unchanged until FLAGS
# bit0 is set. Do NOT touch axi_adrv9001_rx1_dma (the ADI IQ-capture DMA at
# 0x44A30000 -- the prior cyclic patch's wrong target).
set_property CONFIG.CYCLIC 1 [get_bd_cells rx_byte_dma]
puts "CYCLIC_RXBYTE_OK rx_byte_dma CONFIG.CYCLIC=[get_property CONFIG.CYCLIC [get_bd_cells rx_byte_dma]]"
# proc: connect a DUT byte pin to a reference-design breakout pin (idempotent:
# extend the breakout pin's existing net if present, else create a new net)
proc bconn {inst dutpin blkpin} {
  set existing [get_bd_nets -quiet -of_objects [get_bd_pins $blkpin]]
  if {[llength $existing]} {
    connect_bd_net -net $existing [get_bd_pins $inst/$dutpin] [get_bd_pins $blkpin]
  } else {
    connect_bd_net [get_bd_pins $inst/$dutpin] [get_bd_pins $blkpin]
  }
}
# TX host->fabric (byte_breakout drives the DUT byte inputs; DUT ready back)
bconn $HDLCODERIPINST dut_byte_data_in  byte_breakout/byte_data
bconn $HDLCODERIPINST dut_byte_first_in byte_breakout/byte_first
bconn $HDLCODERIPINST dut_byte_valid_in byte_breakout/byte_valid
bconn $HDLCODERIPINST dut_byte_ready_out byte_breakout/byte_ready
# RX fabric->host (DUT byte outputs drive rx_byte_breakout; breakout ready back)
bconn $HDLCODERIPINST dut_byte_data_out  rx_byte_breakout/byte_data
bconn $HDLCODERIPINST dut_byte_last_out  rx_byte_breakout/byte_last
bconn $HDLCODERIPINST dut_byte_user_out  rx_byte_breakout/byte_user
bconn $HDLCODERIPINST dut_byte_valid_out rx_byte_breakout/byte_valid
bconn $HDLCODERIPINST dut_byte_ready_in  rx_byte_breakout/byte_ready
# verify every DUT byte port is now driven/connected
foreach dp {dut_byte_data_in dut_byte_first_in dut_byte_valid_in dut_byte_ready_out dut_byte_data_out dut_byte_last_out dut_byte_user_out dut_byte_valid_out dut_byte_ready_in} {
  if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins $HDLCODERIPINST/$dp]]]} { puts "BYTE_FAIL: $dp unconnected"; exit 1 }
}
puts "BYTE_WIRE_OK"
# Workstream B (interrupt-driven DMA): wire the byte-DMA EOT IRQs into the PS
# pl_ps_irq concat. Guarded/idempotent + a no-op on the lean flow (the sourced
# script self-checks for the byte DMA cells), so the lean build is unaffected.
source [file join [file dirname [info script]] wire_byte_irqs.tcl]
update_compile_order -fileset sources_1
validate_bd_design
save_bd_design
add_files -fileset constrs_1 -norecurse projects/jupiter_sdr/system_constr.xdc
puts "=== STOCK TX WIRING (no gather) — verify sync_output drives the DAC ==="
foreach p {dac_1_data_i0 dac_1_data_q0 dac_1_data_i1 dac_1_data_q1} { if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_adrv9001/$p]]]} { puts "WIRE_FAIL: $p undriven"; exit 1 } }
puts "WIRE_OK"
if {[catch {validate_bd_design} verr]} { puts "VALIDATE_FAILED: $verr"; exit 1 }
puts "VALIDATE_OK"; save_bd_design
# DDS diet (2026-07-18): the P1D/P1E debug-class images from this kit never
# use the DAC DDS tone path; disabling it frees ~11k LUTs -- required since
# p1e pushed the ZU3EG past detail placement (5504 vs 5434 CLBs).  PHY LOs
# and the modem DMA TX path are unaffected.
set_property CONFIG.DDS_DISABLE 1 [get_bd_cells axi_adrv9001]
if {[catch {validate_bd_design} verr]} { puts "VALIDATE_FAILED(dds): $verr"; exit 1 }
puts "DDS_DIET_OK"; save_bd_design
set_property top system_top [current_fileset]
generate_target all [get_files system.bd]
update_compile_order -fileset sources_1
set_param general.maxThreads 6
catch {reset_run impl_1}; catch {reset_run synth_1}
foreach r [get_runs -quiet system_*_synth_1] { catch { reset_run $r } }
puts "=== synth ==="; launch_runs synth_1 -jobs 6; wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "SYNTH_FAILED [get_property STATUS [get_runs synth_1]]"; exit 1 }
# --- pre-implementation timing gate: assert WNS>=0 at the target fabric clock ---
puts "=== pre-impl timing gate ==="; source [file join [file dirname [info script]] timing_gate.tcl]
puts "=== impl+bit ==="; launch_runs impl_1 -to_step write_bitstream -jobs 6; wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "IMPL_FAILED [get_property STATUS [get_runs impl_1]]"; exit 1 }
set b projects/common/boot/jupiter_sdr; file mkdir boot
file copy -force [get_property DIRECTORY [get_runs impl_1]]/system_top.bit boot/system_top.bit
foreach f {u-boot.elf zynq.bif fsbl.elf bl31.elf pmufw.elf regs.init} { file copy -force $b/$f boot/$f }
cd boot; exec bootgen -arch zynqmp -image zynq.bif -o BOOT.BIN -w
puts "BYTE_BUILD_DONE md5=[exec md5sum BOOT.BIN]"; exit
