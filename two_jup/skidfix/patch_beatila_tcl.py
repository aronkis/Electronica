#!/usr/bin/env python3
"""Insert the BEATILA splice (XVC debug bridge + system ILA + burst-onset
trigger) into a fresh complete_byte_t8.tcl. Idempotent -- refuses double-patch.

Style/lineage: two_jup/skidfix/patch_tgen_tcl.py. Design: two_jup/BEAT_ILA_DESIGN.md.
Prereq: copy jupiter_240k5_byte/rtl_sim/burst_onset_det.v next to the tcl (kit dir).
Address map added: beat_arm_gpio @0x9D430000, debug_bridge_0 (XVC) @0x9D440000.
"""
import sys

BLOCK = r'''
# ---- BEATILA (spec 2026-08-19): burst-onset ILA overlay for the 119.75 s
# ---- periodic error bursts. Three pieces, all BD-level (generated DUT HDL is
# ---- never touched): (1) XVC debug bridge pair @0x9D440000 so hw_server can
# ---- reach the ILA over /dev/mem without JTAG, (2) burst_onset_det + arm
# ---- GPIO @0x9D430000, (3) system_ila beat_ila on the DUT clock (adc_1_clk,
# ---- 30.72 MHz Image A) probing the DUT top-level RX/byte-plane ports.
puts "=== BEATILA: XVC bridge + burst_onset_det + system_ila ==="

# -- shared handles (self-contained: do not rely on TGEN block variables)
set _bgdefs [get_ipdefs -filter {NAME == axi_gpio}]
if {[llength $_bgdefs] == 0} { puts "BEATILA_FAIL: no axi_gpio ipdef"; exit 1 }
set _bgdefs [lsort -decreasing $_bgdefs]
set _bic_intf [get_bd_intf_pins -quiet -of_objects \
  [get_bd_intf_nets -of_objects [get_bd_intf_pins byte_ctrl_gpio/S_AXI]] \
  -filter {MODE == Master}]
set _bicell [get_bd_cells -of_objects $_bic_intf]
if {![llength $_bicell]} { puts "BEATILA_FAIL: cpu interconnect not found"; exit 1 }
# attach helper: next free M port on the byte_ctrl_gpio interconnect, clocks
# mirrored from byte_ctrl_gpio (the proven TGEN pattern)
proc _beat_attach {gcell addr} {
  global _bicell
  set nmi [get_property CONFIG.NUM_MI $_bicell]
  set_property CONFIG.NUM_MI [expr {$nmi + 1}] $_bicell
  set newm [format "M%02d_AXI" $nmi]
  connect_bd_intf_net [get_bd_intf_pins $_bicell/$newm] [get_bd_intf_pins $gcell/S_AXI]
  foreach p {ACLK ARESETN} sfx {s_axi_aclk s_axi_aresetn} {
    set src [get_bd_nets -of_objects [get_bd_pins byte_ctrl_gpio/$sfx]]
    catch { connect_bd_net -net $src [get_bd_pins $gcell/$sfx] }
    catch { connect_bd_net -net $src [get_bd_pins $_bicell/[format "M%02d_$p" $nmi]] }
  }
  assign_bd_address -target_address_space /sys_ps8/Data \
    [get_bd_addr_segs $gcell/S_AXI/Reg] -offset $addr -range 64K
}

# -- (1) XVC debug bridges. Preferred path: ADI helper procs (adi_board.tcl +
# -- adi_xilinx_ila.tcl); ad_hpmx_interconnect recovers NUM_MI from the live BD
# -- and the BD carries nets literally named sys_cpu_clk / sys_cpu_resetn, so
# -- the vendor recipe works in this re-opened project. Raw fallback otherwise.
if {[catch {
  set sys_zynq 2
  set use_smartconnect 1
  source projects/scripts/adi_board.tcl
  source projects/common/xilinx/adi_xilinx_ila.tcl
  ad_ila_setup_xvc 0x9D440000
  puts "BEATILA_XVC_ADI_OK"
} _berr]} {
  puts "BEATILA_NOTE: ADI xvc path failed ($_berr) -- raw fallback"
  set _bddefs [lsort -decreasing [get_ipdefs -filter {NAME == debug_bridge}]]
  if {[llength $_bddefs] == 0} { puts "BEATILA_FAIL: no debug_bridge ipdef"; exit 1 }
  create_bd_cell -type ip -vlnv [lindex $_bddefs 0] debug_bridge_0
  set_property -dict [list CONFIG.C_DEBUG_MODE 2 CONFIG.C_NUM_BS_MASTER 1 \
    CONFIG.C_BSCAN_MUX 2 CONFIG.C_XVC_HW_ID 0x0002] [get_bd_cells debug_bridge_0]
  create_bd_cell -type ip -vlnv [lindex $_bddefs 0] debug_bridge_1
  set_property CONFIG.C_DEBUG_MODE 1 [get_bd_cells debug_bridge_1]
  connect_bd_intf_net [get_bd_intf_pins debug_bridge_0/m0_bscan] \
                      [get_bd_intf_pins debug_bridge_1/S_BSCAN]
  connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins byte_ctrl_gpio/s_axi_aclk]] \
                      [get_bd_pins debug_bridge_1/clk]
  _beat_attach debug_bridge_0 0x9D440000
  puts "BEATILA_XVC_RAW_OK"
}

# -- (2) burst_onset_det on the DUT clock + dual arm/status GPIO @0x9D430000
add_files -norecurse [file join [file dirname [info script]] burst_onset_det.v]
update_compile_order -fileset sources_1
create_bd_cell -type module -reference burst_onset_det burst_det
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins $HDLCODERIPINST/IPCORE_CLK]] \
                    [get_bd_pins burst_det/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]] \
                    [get_bd_pins burst_det/resetn]
# error-count source: DUT overlay port dut_bit_err_out if the IP was built with
# the bit-error telemetry overlay; otherwise tie 0 (soft_force / ILA-side
# mark_debug trigger remain usable) and say so loudly.
set _bep [get_bd_pins -quiet $HDLCODERIPINST/dut_bit_err_out]
if {[llength $_bep]} {
  connect_bd_net -net [get_bd_nets -of_objects $_bep] [get_bd_pins burst_det/err_cnt]
  puts "BEATILA_ERRSRC: dut_bit_err_out"
} else {
  create_bd_cell -type ip -vlnv [lindex [lsort -decreasing \
    [get_ipdefs -filter {NAME == xlconstant}]] 0] beat_zero32
  set_property -dict [list CONFIG.CONST_WIDTH 32 CONFIG.CONST_VAL 0] \
    [get_bd_cells beat_zero32]
  connect_bd_net [get_bd_pins beat_zero32/dout] [get_bd_pins burst_det/err_cnt]
  puts "BEATILA_ERRSRC: NONE (tied 0) -- hw err trigger needs the telemetry overlay port; use soft_force + ILA mark_debug trigger"
}
create_bd_cell -type ip -vlnv [lindex $_bgdefs 0] beat_arm_gpio
set_property -dict [list CONFIG.C_IS_DUAL 1 CONFIG.C_ALL_OUTPUTS 1 CONFIG.C_ALL_INPUTS_2 1 \
  CONFIG.C_GPIO_WIDTH 32 CONFIG.C_GPIO2_WIDTH 32 CONFIG.C_DOUT_DEFAULT 0x00000000] \
  [get_bd_cells beat_arm_gpio]
connect_bd_net [get_bd_pins beat_arm_gpio/gpio_io_o]  [get_bd_pins burst_det/ctrl]
connect_bd_net [get_bd_pins burst_det/status]         [get_bd_pins beat_arm_gpio/gpio2_io_i]
_beat_attach beat_arm_gpio 0x9D430000

# -- (3) system_ila beat_ila: NATIVE, 4096 deep, advanced trigger + storage
# -- qualification (dual capture strategy: raw cycles, or store-qualified on
# -- dut_data_valid_out_rx for ~17 ms of symbol-rate context). 16 probes.
set _bidefs [lsort -decreasing [get_ipdefs -filter {NAME == system_ila}]]
if {[llength $_bidefs] == 0} { puts "BEATILA_FAIL: no system_ila ipdef"; exit 1 }
create_bd_cell -type ip -vlnv [lindex $_bidefs 0] beat_ila
set_property -dict [list \
  CONFIG.C_MON_TYPE {NATIVE} CONFIG.C_DATA_DEPTH {4096} \
  CONFIG.C_ADV_TRIGGER {true} CONFIG.C_EN_STRG_QUAL {true} \
  CONFIG.C_INPUT_PIPE_STAGES {2} CONFIG.C_NUM_OF_PROBES {16} \
  CONFIG.ALL_PROBE_SAME_MU {true} CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
  CONFIG.C_PROBE1_WIDTH {32} CONFIG.C_PROBE6_WIDTH {64} \
  CONFIG.C_PROBE8_WIDTH {16} CONFIG.C_PROBE9_WIDTH {16} \
  CONFIG.C_PROBE10_WIDTH {16} CONFIG.C_PROBE11_WIDTH {16} \
  CONFIG.C_PROBE12_WIDTH {16} CONFIG.C_PROBE13_WIDTH {16} \
  ] [get_bd_cells beat_ila]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins $HDLCODERIPINST/IPCORE_CLK]] \
                    [get_bd_pins beat_ila/clk]
connect_bd_net [get_bd_pins burst_det/trig]   [get_bd_pins beat_ila/probe0]
connect_bd_net [get_bd_pins burst_det/status] [get_bd_pins beat_ila/probe1]
set _bpi 2
foreach dp {dut_byte_valid_out dut_byte_last_out dut_byte_user_out dut_byte_ready_in
            dut_byte_data_out  dut_data_valid_out_rx
            dut_data_out_0_rx dut_data_out_1_rx dut_data_out_2_rx dut_data_out_3_rx
            dut_data_in_0_rx  dut_data_in_1_rx  dut_data_valid_in_rx dut_byte_valid_in} {
  set _bn [get_bd_nets -quiet -of_objects [get_bd_pins $HDLCODERIPINST/$dp]]
  if {![llength $_bn]} { puts "BEATILA_FAIL: $dp has no net"; exit 1 }
  connect_bd_net -net $_bn [get_bd_pins beat_ila/probe$_bpi]
  incr _bpi
}
foreach c {burst_det beat_arm_gpio beat_ila debug_bridge_0 debug_bridge_1} {
  if {![llength [get_bd_cells -quiet $c]]} { puts "BEATILA_FAIL: cell $c missing"; exit 1 }
}
puts "BEATILA_WIRE_OK"
'''

# splice after the last instrument block present: TXCHK (tgenrx variant) if
# there, else the bare byte-plane anchor (lean variant). Both precede
# validate_bd_design in complete_byte_t8.tcl.
ANCHORS = ['puts "TXCHK_WIRE_OK"', 'puts "BYTE_WIRE_OK"']

def main():
    path = sys.argv[1]
    src = open(path).read()
    if 'BEATILA_WIRE_OK' in src:
        print('patch_beatila: already patched'); return 0
    for anchor in ANCHORS:
        if anchor in src:
            open(path, 'w').write(src.replace(anchor, anchor + '\n' + BLOCK, 1))
            print('patch_beatila: inserted after %r' % anchor); return 0
    print('patch_beatila: FATAL anchor missing'); return 1

if __name__ == '__main__':
    sys.exit(main())
