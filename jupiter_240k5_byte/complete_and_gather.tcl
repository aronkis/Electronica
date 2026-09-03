# complete_and_gather.tcl
# =============================================================================
# Single-session Vivado recipe that folds the two manual surgeries
# (/tmp/complete_mult2.tcl  +  /tmp/gather_fix.tcl) into ONE build:
#
#   1. Open the partial project left behind when build_variant fails at the
#      "Create Project" step (its generated vivado_insert_ip.tcl uses the wrong
#      add_ip path `./ipcore`; the correct form is `./ipcore/TxRxCompo_ip_v1_0.zip`).
#   2. Insert + wire the modem IP  TxRxCompo_ip_0  (the multiple=2 composite DUT)
#      -- this is the body of the working vivado_insert_ip_TEMPLATE.tcl / complete_mult2.
#   3. GATHER SURGERY:
#        a. DISCONNECT sync_output/data_out_tx_0..3 from axi_adrv9001/dac_1_data_*.
#           In a CLEAN build the reference design (matlab_processors.tcl blocks
#           ~790/987/1174) wires sync_output DIRECTLY to the four DAC lanes, so
#           i1/q1 = 0 -> HALF symbol rate. (In the original manual flow a prior
#           tx_dac_fifo experiment had already broken these nets; on a clean
#           project we must delete them explicitly. This is THE key gotcha.)
#        b. Add tx_dac_gather (1->2 sample gather, xpm_fifo_async) and wire:
#             write side  <- modem dut_data_out_0/1_tx + dut_data_valid_out_tx (adc_1_clk)
#             read  side  -> dac_1_data_i0/q0/i1/q1, rd_beat=dac_1_valid_i0 (dac_1_clk)
#   4. Pre-synth BD assertion gate (fails in 2 s, not multi-hour, on a wiring bug).
#   5. Single synth + impl + write_bitstream + bootgen -> BOOT.BIN.
#
# Run from:  <KITDIR>/hdl_prj_jupiter_composite/vivado_ip_prj
# Usage:     vivado -mode batch -source complete_and_gather.tcl -tclargs <abs path to tx_dac_gather.v>
# =============================================================================

set gather_v [lindex $argv 0]
if {$gather_v eq "" || ![file exists $gather_v]} {
    puts "FATAL: tx_dac_gather.v path not given / not found: '$gather_v'"; exit 1
}

open_project vivado_prj.xpr
set_param general.maxThreads 12
set_property XPM_LIBRARIES {XPM_FIFO} [current_project]

# tx_dac_gather source in first so create_bd_cell -type module can reference it.
add_files -norecurse $gather_v
update_compile_order -fileset sources_1

# ----------------------------------------------------------------------------
# STEP 2: insert + wire the modem IP (from vivado_insert_ip_TEMPLATE.tcl, with
# the CORRECTED add_ip path).
# ----------------------------------------------------------------------------
set project {jupiter_sdr}
update_ip_catalog -delete_ip {./ipcore/TxRxCompo_ip_v1_0/component.xml} -repo_path {./ipcore} -quiet
update_ip_catalog -add_ip {./ipcore/TxRxCompo_ip_v1_0.zip} -repo_path {./ipcore}
update_ip_catalog
set HDLCODERIPVLNV [get_property VLNV [get_ipdefs -filter {NAME==TxRxCompo_ip && VERSION==1.0}]]
set HDLCODERIPINST TxRxCompo_ip_0
set BDFILEPATH [get_files -quiet system.bd]
open_bd_design $BDFILEPATH

create_bd_cell -type ip -vlnv $HDLCODERIPVLNV $HDLCODERIPINST

proc conn {drv args} {
    # connect $drv (a pin) onto whatever net already exists on the first of
    # $args, or make a fresh net -- mirrors the template's if/else idiom.
    set anchor [lindex $args 0]
    if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins $anchor]]]} {
        connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins $anchor]] \
            [get_bd_pins $drv] [get_bd_pins $anchor]
    } else {
        connect_bd_net [get_bd_pins $drv] [get_bd_pins $anchor]
    }
}

conn $HDLCODERIPINST/AXI4_Lite_ACLK    axi_adrv9001/adc_1_clk
conn $HDLCODERIPINST/AXI4_Lite_ARESETN rx_rstn_inverter/Res
connect_bd_intf_net [get_bd_intf_pins $HDLCODERIPINST/AXI4_Lite] [get_bd_intf_pins axi_hpm0_lpd_interconnect/M07_AXI]
create_bd_addr_seg -range 0x10000 -offset 0x9D000000 [get_bd_addr_spaces sys_ps8/Data] [get_bd_addr_segs $HDLCODERIPINST/AXI4_Lite/reg0] SEG_${HDLCODERIPINST}_reg0

conn $HDLCODERIPINST/dut_data_valid_out_rx sync_output/data_valid_in_rx_0
conn $HDLCODERIPINST/dut_data_valid_in_rx  sync_input/data_valid_out_rx_0
conn $HDLCODERIPINST/dut_data_out_0_rx     sync_output/data_in_rx_0
conn $HDLCODERIPINST/dut_data_out_1_rx     sync_output/data_in_rx_1
conn $HDLCODERIPINST/dut_data_out_2_rx     sync_output/data_in_rx_2
conn $HDLCODERIPINST/dut_data_out_3_rx     sync_output/data_in_rx_3
conn $HDLCODERIPINST/dut_data_in_0_rx      sync_input/data_out_rx_0
conn $HDLCODERIPINST/dut_data_in_1_rx      sync_input/data_out_rx_1
conn $HDLCODERIPINST/dut_data_valid_in_tx  sync_input/data_valid_out_tx_0
conn $HDLCODERIPINST/dut_data_valid_out_tx sync_output/data_valid_in_tx_0
conn $HDLCODERIPINST/dut_data_out_0_tx     sync_output/data_in_tx_0
conn $HDLCODERIPINST/dut_data_out_1_tx     sync_output/data_in_tx_1
conn $HDLCODERIPINST/dut_data_in_0_tx      sync_input/data_out_tx_0
conn $HDLCODERIPINST/dut_data_in_1_tx      sync_input/data_out_tx_1
conn $HDLCODERIPINST/IPCORE_CLK            axi_adrv9001/adc_1_clk
conn $HDLCODERIPINST/IPCORE_RESETN         rx_rstn_inverter/Res

# ----------------------------------------------------------------------------
# STEP 3a: DISCONNECT sync_output -> DAC on all four lanes (clean-build fix).
# Iterate the DAC pins (unambiguous) rather than sync_output port names (whose
# lane mapping differs between the matlab_processors.tcl blocks).
# ----------------------------------------------------------------------------
puts "=== disconnect sync_output -> dac_1_data (clean-build half-rate break) ==="
foreach p {dac_1_data_i0 dac_1_data_q0 dac_1_data_i1 dac_1_data_q1} {
    set n [get_bd_nets -quiet -of_objects [get_bd_pins axi_adrv9001/$p]]
    if {[llength $n]} { puts "  delete net on axi_adrv9001/$p : $n"; delete_bd_objs $n }
}
# defensive: remove any leftover tx_dac_fifo from an earlier experiment
set fifo [get_bd_cells -quiet tx_dac_fifo]
if {[llength $fifo]} { puts "  deleting stray tx_dac_fifo"; delete_bd_objs $fifo }

# ----------------------------------------------------------------------------
# STEP 3b: add + wire tx_dac_gather.
# ----------------------------------------------------------------------------
puts "=== add tx_dac_gather ==="
create_bd_cell -type module -reference tx_dac_gather tx_dac_gather
# write side (modem / adc_1_clk domain)
connect_bd_net [get_bd_pins tx_dac_gather/wr_clk]   [get_bd_pins axi_adrv9001/adc_1_clk]
connect_bd_net [get_bd_pins tx_dac_gather/wr_rstn]  [get_bd_pins rx_rstn_inverter/Res]
connect_bd_net [get_bd_pins tx_dac_gather/wr_valid] [get_bd_pins TxRxCompo_ip_0/dut_data_valid_out_tx]
connect_bd_net [get_bd_pins tx_dac_gather/wr_i]     [get_bd_pins TxRxCompo_ip_0/dut_data_out_0_tx]
connect_bd_net [get_bd_pins tx_dac_gather/wr_q]     [get_bd_pins TxRxCompo_ip_0/dut_data_out_1_tx]
# read side (DAC / dac_1_clk domain) -- drives ALL 4 lanes
connect_bd_net [get_bd_pins tx_dac_gather/rd_clk]   [get_bd_pins axi_adrv9001/dac_1_clk]
connect_bd_net [get_bd_pins tx_dac_gather/rd_rstn]  [get_bd_pins tx_rstn_inverter/Res]
connect_bd_net [get_bd_pins tx_dac_gather/rd_beat]  [get_bd_pins axi_adrv9001/dac_1_valid_i0]
connect_bd_net [get_bd_pins tx_dac_gather/dac_i0]   [get_bd_pins axi_adrv9001/dac_1_data_i0]
connect_bd_net [get_bd_pins tx_dac_gather/dac_q0]   [get_bd_pins axi_adrv9001/dac_1_data_q0]
connect_bd_net [get_bd_pins tx_dac_gather/dac_i1]   [get_bd_pins axi_adrv9001/dac_1_data_i1]
connect_bd_net [get_bd_pins tx_dac_gather/dac_q1]   [get_bd_pins axi_adrv9001/dac_1_data_q1]

add_files -norecurse {projects/jupiter_sdr/system_top.v}
update_compile_order -fileset sources_1
if {[catch {validate_bd_design} verr]} { puts "VALIDATE_FAILED: $verr"; exit 1 }
puts "VALIDATE_OK"

# ----------------------------------------------------------------------------
# STEP 4: PRE-SYNTH BD ASSERTION GATE -- fail fast on a wiring mistake.
# ----------------------------------------------------------------------------
proc net_pins {pin} {
    set n [get_bd_nets -quiet -of_objects [get_bd_pins $pin]]
    if {![llength $n]} { return {} }
    return [get_bd_pins -quiet -of_objects $n]
}
proc assert_conn {pinA pinB} {
    if {[lsearch -exact [net_pins $pinA] $pinB] < 0} {
        puts "GATE_FAIL: $pinA not on same net as $pinB"; exit 1
    }
}
# each DAC lane must be driven by the matching gather output
assert_conn axi_adrv9001/dac_1_data_i0 tx_dac_gather/dac_i0
assert_conn axi_adrv9001/dac_1_data_q0 tx_dac_gather/dac_q0
assert_conn axi_adrv9001/dac_1_data_i1 tx_dac_gather/dac_i1
assert_conn axi_adrv9001/dac_1_data_q1 tx_dac_gather/dac_q1
# and NOT by sync_output any more
foreach dp {dac_1_data_i0 dac_1_data_q0 dac_1_data_i1 dac_1_data_q1} {
    foreach pin [net_pins axi_adrv9001/$dp] {
        if {[string match sync_output/* $pin]} {
            puts "GATE_FAIL: axi_adrv9001/$dp still driven by $pin"; exit 1
        }
    }
}
# gather write side + clocks + beat
assert_conn tx_dac_gather/wr_i   TxRxCompo_ip_0/dut_data_out_0_tx
assert_conn tx_dac_gather/wr_q   TxRxCompo_ip_0/dut_data_out_1_tx
assert_conn tx_dac_gather/wr_valid TxRxCompo_ip_0/dut_data_valid_out_tx
assert_conn tx_dac_gather/wr_clk axi_adrv9001/adc_1_clk
assert_conn tx_dac_gather/rd_clk axi_adrv9001/dac_1_clk
assert_conn tx_dac_gather/rd_beat axi_adrv9001/dac_1_valid_i0
puts "GATE_OK: tx_dac_gather correctly interposed on all 4 DAC lanes"

save_bd_design
generate_target all [get_files system.bd]
update_compile_order -fileset sources_1
add_files -fileset constrs_1 -norecurse projects/jupiter_sdr/system_constr.xdc

# ----------------------------------------------------------------------------
# STEP 5: synth + impl + bitstream + BOOT.BIN (single build).
# ----------------------------------------------------------------------------
set_property top system_top [current_fileset]
update_compile_order -fileset sources_1
if {[llength [get_runs -quiet synth_1]]==0} { create_run -flow {Vivado Synthesis 2025} synth_1 }
if {[llength [get_runs -quiet impl_1]]==0}  { create_run -flow {Vivado Implementation 2025} -parent_run synth_1 impl_1 }
set_property synth_checkpoint_mode Hierarchical [get_files -quiet system.bd]

puts "=== synth ==="
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "SYNTH_FAILED [get_property STATUS [get_runs synth_1]]"; exit 1 }

puts "=== impl + bitstream ==="
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "IMPL_FAILED [get_property STATUS [get_runs impl_1]]"; exit 1 }

puts "=== BOOT.BIN ==="
set b projects/common/boot/jupiter_sdr
file mkdir boot
file copy -force [get_property DIRECTORY [get_runs impl_1]]/system_top.bit boot/system_top.bit
foreach f {u-boot.elf zynq.bif fsbl.elf bl31.elf pmufw.elf regs.init} { file copy -force $b/$f boot/$f }
cd boot
exec bootgen -arch zynqmp -image zynq.bif -o BOOT.BIN -w
puts "GATHER_CLEAN_DONE md5=[exec md5sum BOOT.BIN]"
exit
