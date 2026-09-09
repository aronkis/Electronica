#!/usr/bin/env python3
"""Insert the traffic-gen splice into a fresh complete_byte_t8.tcl. Idempotent."""
import sys

BLOCK = r'''
# ---- TGEN (spec 2026-08-17): qpsk_traffic_gen between byte_breakout and the
# ---- DUT byte-TX pins; config via tgen_ctrl_gpio @0x9D400000 (dual, outputs).
puts "=== TGEN: splice qpsk_traffic_gen into the TX byte path ==="
add_files -norecurse [file join [file dirname [info script]] qpsk_traffic_gen.v]
update_compile_order -fileset sources_1
create_bd_cell -type module -reference qpsk_traffic_gen traffic_gen
# break the four direct breakout->DUT nets made by bconn above, keep pin handles
foreach {bo dut tg_h tg_d} {
  byte_data  dut_byte_data_in  host_data  dut_data
  byte_valid dut_byte_valid_in host_valid dut_valid
  byte_first dut_byte_first_in host_first dut_first
} {
  set n [get_bd_nets -quiet -of_objects [get_bd_pins byte_breakout/$bo]]
  if {[llength $n]} { delete_bd_objs $n }
  connect_bd_net [get_bd_pins byte_breakout/$bo]     [get_bd_pins traffic_gen/$tg_h]
  connect_bd_net [get_bd_pins traffic_gen/$tg_d]     [get_bd_pins $HDLCODERIPINST/$dut]
}
set n [get_bd_nets -quiet -of_objects [get_bd_pins byte_breakout/byte_ready]]
if {[llength $n]} { delete_bd_objs $n }
connect_bd_net [get_bd_pins traffic_gen/host_ready] [get_bd_pins byte_breakout/byte_ready]
connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_byte_ready_out] [get_bd_pins traffic_gen/dut_ready]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins traffic_gen/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]]   [get_bd_pins traffic_gen/resetn]
# config GPIO: dual-channel, all outputs, defaults 0 (pass-through at reset)
set _gdefs [get_ipdefs -filter {NAME == axi_gpio}]
if {[llength $_gdefs] == 0} { puts "TGEN_FAIL: no axi_gpio ipdef"; exit 1 }
if {[llength $_gdefs] > 1} { set _gdefs [lsort -decreasing $_gdefs]; puts "TGEN_NOTE: multiple axi_gpio defs, using [lindex $_gdefs 0]" }
create_bd_cell -type ip -vlnv [lindex $_gdefs 0] tgen_ctrl_gpio
set_property -dict [list CONFIG.C_IS_DUAL 1 CONFIG.C_ALL_OUTPUTS 1 CONFIG.C_ALL_OUTPUTS_2 1 \
  CONFIG.C_GPIO_WIDTH 32 CONFIG.C_GPIO2_WIDTH 32 CONFIG.C_DOUT_DEFAULT 0x00000000 \
  CONFIG.C_DOUT_DEFAULT_2 0x00000000] [get_bd_cells tgen_ctrl_gpio]
connect_bd_net [get_bd_pins tgen_ctrl_gpio/gpio_io_o]  [get_bd_pins traffic_gen/ctrl]
connect_bd_net [get_bd_pins tgen_ctrl_gpio/gpio2_io_o] [get_bd_pins traffic_gen/gap]
# attach to the same interconnect that carries byte_ctrl_gpio (0x9D300000):
set bc_intf [get_bd_intf_pins -quiet -of_objects \
  [get_bd_intf_nets -of_objects [get_bd_intf_pins byte_ctrl_gpio/S_AXI]] \
  -filter {MODE == Master}]
set icell [get_bd_cells -of_objects $bc_intf]
set nmi [get_property CONFIG.NUM_MI $icell]
set_property CONFIG.NUM_MI [expr {$nmi + 1}] $icell
set newm [format "M%02d_AXI" $nmi]
connect_bd_intf_net [get_bd_intf_pins $icell/$newm] [get_bd_intf_pins tgen_ctrl_gpio/S_AXI]
# clock/reset for the new M port + gpio: mirror byte_ctrl_gpio's
foreach p {ACLK ARESETN} sfx {s_axi_aclk s_axi_aresetn} {
  set src [get_bd_nets -of_objects [get_bd_pins byte_ctrl_gpio/$sfx]]
  connect_bd_net -net $src [get_bd_pins tgen_ctrl_gpio/$sfx]
  catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d_$p" $nmi]] }
  catch { connect_bd_net -net $src [get_bd_pins $icell/${newm}_[string tolower $p]] }
  catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d" $nmi]_[string tolower $p]] }
  if {$p eq "ACLK"} {
    set _ckpin [get_bd_pins -quiet $icell/[format "M%02d_ACLK" $nmi]]
    if {[llength $_ckpin] && ![llength [get_bd_nets -quiet -of_objects $_ckpin]]} {
      puts "TGEN_WARN: ${newm} clock unwired -- validate_bd_design will decide"
    }
  }
}
assign_bd_address -target_address_space /sys_ps8/Data \
  [get_bd_addr_segs tgen_ctrl_gpio/S_AXI/Reg] -offset 0x9D400000 -range 64K
if {![llength [get_bd_cells -quiet traffic_gen]]} { puts "TGEN_FAIL: cell missing"; exit 1 }
puts "TGEN_WIRE_OK"

# ---- TGEN_RX (spec fix 2026-08-18): qpsk_traffic_gen_rx between the DUT
# ---- byte-RX outputs and rx_byte_breakout (the fabric-to-processor seam);
# ---- config via tgen_rx_ctrl_gpio @0x9D410000. Layer B proper: generator ->
# ---- S2MM DMA -> DDR -> host, NO modem DSP in the path.
puts "=== TGEN_RX: splice qpsk_traffic_gen_rx at the RX/DMA seam ==="
add_files -norecurse [file join [file dirname [info script]] qpsk_traffic_gen_rx.v]
update_compile_order -fileset sources_1
create_bd_cell -type module -reference qpsk_traffic_gen_rx traffic_gen_rx
foreach {dut brk tg_u tg_d} {
  dut_byte_data_out  byte_data  dut_data  dma_data
  dut_byte_valid_out byte_valid dut_valid dma_valid
  dut_byte_last_out  byte_last  dut_last  dma_last
  dut_byte_user_out  byte_user  dut_user  dma_user
} {
  set n [get_bd_nets -quiet -of_objects [get_bd_pins rx_byte_breakout/$brk]]
  if {[llength $n]} { delete_bd_objs $n }
  connect_bd_net [get_bd_pins $HDLCODERIPINST/$dut]   [get_bd_pins traffic_gen_rx/$tg_u]
  connect_bd_net [get_bd_pins traffic_gen_rx/$tg_d]   [get_bd_pins rx_byte_breakout/$brk]
}
set n [get_bd_nets -quiet -of_objects [get_bd_pins $HDLCODERIPINST/dut_byte_ready_in]]
if {[llength $n]} { delete_bd_objs $n }
connect_bd_net [get_bd_pins rx_byte_breakout/byte_ready] [get_bd_pins traffic_gen_rx/dma_ready]
connect_bd_net [get_bd_pins traffic_gen_rx/dut_ready]    [get_bd_pins $HDLCODERIPINST/dut_byte_ready_in]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins traffic_gen/clk]]    [get_bd_pins traffic_gen_rx/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins traffic_gen/resetn]] [get_bd_pins traffic_gen_rx/resetn]
# second dual GPIO on the same interconnect, next free M port
create_bd_cell -type ip -vlnv [lindex $_gdefs 0] tgen_rx_ctrl_gpio
set_property -dict [list CONFIG.C_IS_DUAL 1 CONFIG.C_ALL_OUTPUTS 1 CONFIG.C_ALL_OUTPUTS_2 1 \
  CONFIG.C_GPIO_WIDTH 32 CONFIG.C_GPIO2_WIDTH 32 CONFIG.C_DOUT_DEFAULT 0x00000000 \
  CONFIG.C_DOUT_DEFAULT_2 0x00000000] [get_bd_cells tgen_rx_ctrl_gpio]
connect_bd_net [get_bd_pins tgen_rx_ctrl_gpio/gpio_io_o]  [get_bd_pins traffic_gen_rx/ctrl]
connect_bd_net [get_bd_pins tgen_rx_ctrl_gpio/gpio2_io_o] [get_bd_pins traffic_gen_rx/gap]
set nmi [get_property CONFIG.NUM_MI $icell]
set_property CONFIG.NUM_MI [expr {$nmi + 1}] $icell
set newm [format "M%02d_AXI" $nmi]
connect_bd_intf_net [get_bd_intf_pins $icell/$newm] [get_bd_intf_pins tgen_rx_ctrl_gpio/S_AXI]
foreach p {ACLK ARESETN} sfx {s_axi_aclk s_axi_aresetn} {
  set src [get_bd_nets -of_objects [get_bd_pins byte_ctrl_gpio/$sfx]]
  connect_bd_net -net $src [get_bd_pins tgen_rx_ctrl_gpio/$sfx]
  catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d_$p" $nmi]] }
  catch { connect_bd_net -net $src [get_bd_pins $icell/${newm}_[string tolower $p]] }
  catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d" $nmi]_[string tolower $p]] }
  if {$p eq "ACLK"} {
    set _ckpin [get_bd_pins -quiet $icell/[format "M%02d_ACLK" $nmi]]
    if {[llength $_ckpin] && ![llength [get_bd_nets -quiet -of_objects $_ckpin]]} {
      puts "TGEN_WARN: ${newm} clock unwired -- validate_bd_design will decide"
    }
  }
}
assign_bd_address -target_address_space /sys_ps8/Data \
  [get_bd_addr_segs tgen_rx_ctrl_gpio/S_AXI/Reg] -offset 0x9D410000 -range 64K
if {![llength [get_bd_cells -quiet traffic_gen_rx]]} { puts "TGEN_FAIL: rx cell missing"; exit 1 }
puts "TGEN_RX_WIRE_OK"

# ---- TXCHK (TX-side Layer B isolation, 2026-08-18): tx_seam_checker snoops the
# ---- DUT TX byte pins (post-mux, pre-modulator); counters on all-INPUTS dual
# ---- axi_gpio @0x9D420000 (ch1=bit_errors, ch2=frames_checked). Snoop-only.
puts "=== TXCHK: tx_seam_checker at the DUT TX pins ==="
add_files -norecurse [file join [file dirname [info script]] tx_seam_checker.v]
update_compile_order -fileset sources_1
create_bd_cell -type module -reference tx_seam_checker tx_checker
foreach {dut pin} {
  dut_byte_data_in   data
  dut_byte_valid_in  valid
  dut_byte_first_in  first
  dut_byte_ready_out ready
} {
  connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins $HDLCODERIPINST/$dut]] [get_bd_pins tx_checker/$pin]
}
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins traffic_gen/clk]]    [get_bd_pins tx_checker/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins traffic_gen/resetn]] [get_bd_pins tx_checker/resetn]
create_bd_cell -type ip -vlnv [lindex $_gdefs 0] txchk_gpio
set_property -dict [list CONFIG.C_IS_DUAL 1 CONFIG.C_ALL_INPUTS 1 CONFIG.C_ALL_INPUTS_2 1 \
  CONFIG.C_GPIO_WIDTH 32 CONFIG.C_GPIO2_WIDTH 32] [get_bd_cells txchk_gpio]
connect_bd_net [get_bd_pins tx_checker/bit_errors]     [get_bd_pins txchk_gpio/gpio_io_i]
connect_bd_net [get_bd_pins tx_checker/frames_checked] [get_bd_pins txchk_gpio/gpio2_io_i]
set nmi [get_property CONFIG.NUM_MI $icell]
set_property CONFIG.NUM_MI [expr {$nmi + 1}] $icell
set newm [format "M%02d_AXI" $nmi]
connect_bd_intf_net [get_bd_intf_pins $icell/$newm] [get_bd_intf_pins txchk_gpio/S_AXI]
foreach p {ACLK ARESETN} sfx {s_axi_aclk s_axi_aresetn} {
  set src [get_bd_nets -of_objects [get_bd_pins byte_ctrl_gpio/$sfx]]
  connect_bd_net -net $src [get_bd_pins txchk_gpio/$sfx]
  catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d_$p" $nmi]] }
  catch { connect_bd_net -net $src [get_bd_pins $icell/${newm}_[string tolower $p]] }
  catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d" $nmi]_[string tolower $p]] }
}
assign_bd_address -target_address_space /sys_ps8/Data \
  [get_bd_addr_segs txchk_gpio/S_AXI/Reg] -offset 0x9D420000 -range 64K
if {![llength [get_bd_cells -quiet tx_checker]]} { puts "TGEN_FAIL: txchk cell missing"; exit 1 }
puts "TXCHK_WIRE_OK"
'''

ANCHOR = 'puts "BYTE_WIRE_OK"'

def main():
    path = sys.argv[1]
    src = open(path).read()
    if 'TGEN_WIRE_OK' in src:
        print('patch_tgen: already patched'); return 0
    if ANCHOR not in src:
        print('patch_tgen: FATAL anchor missing'); return 1
    open(path, 'w').write(src.replace(ANCHOR, ANCHOR + '\n' + BLOCK, 1))
    print('patch_tgen: inserted'); return 0

if __name__ == '__main__':
    sys.exit(main())
