#!/usr/bin/env python3
"""Insert the skid-fix BD surgery into a fresh copy of complete_byte_t8.tcl.

Idempotent: refuses to double-patch. The block goes right after the
`puts "BYTE_WIRE_OK"` line -- the BD already carries the reference-design
breakout->DMA intf net (matlab_processors.tcl ad_connect) at that point,
and validate_bd_design runs after.
"""
import sys

BLOCK = r'''
# ---- SKID FIX (TICK_FIX_SIM.md section 2): 1-deep skid buffer + beat-parity
# ---- witness spliced between rx_byte_breakout/m_axis and rx_byte_dma/s_axis.
# ---- DUT IP untouched (e49c011b lineage preserved); witness readout via
# ---- byte_ctrl_gpio channel 2 (0x9D300008).
puts "=== SKID FIX: qpsk_axis_skid between rx_byte_breakout and rx_byte_dma ==="
add_files -norecurse [file join [file dirname [info script]] qpsk_axis_skid.v]
update_compile_order -fileset sources_1
set _skid_net [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins rx_byte_breakout/m_axis]]
if {![llength $_skid_net]} { puts "SKID_FAIL: rx_byte_breakout/m_axis has no intf net"; exit 1 }
delete_bd_objs $_skid_net
create_bd_cell -type module -reference qpsk_axis_skid axis_skid
connect_bd_intf_net [get_bd_intf_pins rx_byte_breakout/m_axis] [get_bd_intf_pins axis_skid/s_axis]
connect_bd_intf_net [get_bd_intf_pins axis_skid/m_axis] [get_bd_intf_pins rx_byte_dma/s_axis]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins axis_skid/aclk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]] [get_bd_pins axis_skid/aresetn]
set_property -dict [list CONFIG.C_IS_DUAL 1 CONFIG.C_GPIO2_WIDTH 32 CONFIG.C_ALL_INPUTS_2 1] [get_bd_cells byte_ctrl_gpio]
connect_bd_net [get_bd_pins axis_skid/witness] [get_bd_pins byte_ctrl_gpio/gpio2_io_i]
if {![llength [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins rx_byte_dma/s_axis]]]} { puts "SKID_FAIL: rx_byte_dma/s_axis unconnected after splice"; exit 1 }
if {![llength [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins rx_byte_breakout/m_axis]]]} { puts "SKID_FAIL: rx_byte_breakout/m_axis unconnected after splice"; exit 1 }
puts "SKID_WIRE_OK"
'''

ANCHOR = 'puts "BYTE_WIRE_OK"'

def main():
    path = sys.argv[1]
    src = open(path).read()
    if 'SKID_WIRE_OK' in src:
        print('patch_complete_tcl: already patched -- refusing to double-patch')
        return 0
    if ANCHOR not in src:
        print('patch_complete_tcl: FATAL anchor not found:', ANCHOR)
        return 1
    out = src.replace(ANCHOR, ANCHOR + '\n' + BLOCK, 1)
    open(path, 'w').write(out)
    print('patch_complete_tcl: skid block inserted after BYTE_WIRE_OK in', path)
    return 0

if __name__ == '__main__':
    sys.exit(main())
