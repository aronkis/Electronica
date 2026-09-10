#!/usr/bin/env python3
"""patch_seqbist_tcl.py -- SEQ-BIST (T0b) block-design patcher.

Inserts an idempotent, marked Tcl block into a build kit's `build_txfix.tcl`
so that the SINGLE Vivado batch run that build_txfix.sh launches also re-wires
the block design before `generate_target all` / synth / impl / bootgen.

WHY build_txfix.tcl AND NOT complete_byte_t8.tcl
------------------------------------------------
`complete_byte_t8.tcl` is the from-scratch BD builder that only runs inside a
full MATLAB HDL-Coder regeneration.  The kit build (`build_txfix.sh` ->
`build_txfix.tcl`) never sources it, and on the 148 lineage it does not even
describe the BD that is actually in the kit: cnt_mux / rx_checker / sel_slice /
tgen_rx_wit_gpio were added incrementally by `two_jup/sim_repro/resynth_probe
{2,3,4}.tcl` and `resynth_dmacprobe.tcl` and live only in system.bd.  Patching
the build tcl is therefore the only edit that reaches the bitstream.

The block is inserted directly after `report_ip_status -quiet` -- late enough
that the IP catalog has been rebuilt (so `get_ipdefs` finds axi_gpio / xlslice /
xlconstant for the 146 lineage) and early enough that the existing
`generate_target all [get_files system.bd]` regenerates the edited BD.  The
IMPL_STRATEGY hook and the routed-WNS gate further down are untouched.

LINEAGES
--------
`--lineage 148`   source kit jupiter_byte_txfixF3_build.  The BD already has
                  traffic_gen / traffic_gen_rx / rx_checker / tx_checker /
                  tx_starve / cnt_mux(16) / sel_slice / tgen_ctrl_gpio /
                  tgen_rx_ctrl_gpio / tgen_rx_wit_gpio / txchk_gpio.
                  This patch: swaps traffic_gen's RTL to qpsk_traffic_gen_v2,
                  replaces cnt_mux16 with cnt_mux32 (sel widened 4 -> 5 bits),
                  adds rx_seq_checker on the DUT RX pins and wires its 16
                  counters to slots 16..31.  NO new AXI slave: NUM_MI stays 17.

`--lineage vendh` source kit jupiter_byte_txfixF3vendh_build (146).  That BD has
                  NONE of the chain.  This patch adds traffic_gen (v2) at the TX
                  byte pins, rx_seq_checker at the RX byte pins, cnt_mux32, and
                  three axi_gpio slaves at the SAME addresses as 148:
                    tgen_ctrl_gpio    0x9D400000 (dual, outputs)
                    tgen_rx_ctrl_gpio 0x9D410000 (dual, outputs)
                    tgen_rx_wit_gpio  0x9D450000 (dual, inputs)
                  NUM_MI 11 -> 14.  tx_checker (0x9D420000), traffic_gen_rx and
                  tx_starve are deliberately NOT ported: cnt_mux32 slots 0..15
                  are tied to a 32-bit zero constant on this lineage and read
                  back 0 (the host scorer must be lineage-aware).

CONTROL-BIT MAP (identical on both lineages)
--------------------------------------------
  tgen_ctrl_gpio    0x9D400000  ctrl -> traffic_gen(v2).ctrl
                                  [0] enable, [15:4] fill_len, [31:16]
                                  skip_every / corrupt_every (see the v2 header)
                    0x9D400008  gap  -> traffic_gen(v2).gap
                                  [26:0] gap clks, [27] skip/corrupt mode bit
  tgen_rx_ctrl_gpio 0x9D410000  ctrl -> traffic_gen_rx.ctrl (148 only) AND the
                                  three SEQBIST control bits:
                                  [3] rx_seq freeze
                                  [4] rx_seq en       (rising edge = clear)
                                  [5] rx_seq tgen_mode (1 = CRC field 0x54474E21)
                    0x9D410008  gap  -> traffic_gen_rx.gap (148 only);
                                  [31:27] = cnt_mux32 select (was [31:28])
  tgen_rx_wit_gpio  0x9D450000  ch1 = traffic_gen_rx.acc_beats (148) / 0 (146)
                    0x9D450008  ch2 = cnt_mux32.q  <-- the 32-slot readout

  !! COLLISION, 148 ONLY, DOCUMENTED DELIBERATELY !!  On 148 the same GPIO word
  drives qpsk_traffic_gen_rx2.ctrl, whose bits are [0] en [1] last_en
  [2] user_mask [15:4] fill_len [31:16] word_gap.  Bit 3 is genuinely spare, but
  SEQBIST bits 4 and 5 ALIAS traffic_gen_rx's fill_len[1:0].  That is harmless
  while traffic_gen_rx is disabled (ctrl[0] = 0), which is its reset state and
  the state every SEQBIST run uses -- the two instruments are MUTUALLY
  EXCLUSIVE.  Never run the Layer-B RX generator and the sequence checker in the
  same window.  On 146 traffic_gen_rx does not exist and there is no aliasing.

  The mux select moved from gap[31:28] to gap[31:27], so the gap value written
  to 0x9D410008 must stay below 2^27 (134 M clks); every value in use is <= 2e5.

RTL CONTRACT ASSUMED (delivered by Task 1 into jupiter_240k5_byte/rtl_sim/)
  rx_seq_checker    clk rst_n en freeze tgen_mode data[63:0] valid user ready
                    -> cnt0..cnt15 [31:0]
  cnt_mux32         clk sel[4:0] c0..c31 [31:0] -> q [31:0]
  qpsk_traffic_gen_v2  same ports as qpsk_traffic_gen (clk resetn ctrl gap
                    host_data host_valid host_first host_ready
                    dut_data dut_valid dut_first dut_ready)

WITH_CRC
--------
`rx_seq_checker` has `parameter integer WITH_CRC = 1`; 0 omits the CRC32
datapath (the escape hatch for a routed-WNS / utilisation failure -- every
tgen_mode stage works without it).  The patch sets it as a module-reference cell
property on `rx_seq` for BOTH lineages.  `--with-crc 0|1` bakes the default into
the emitted Tcl (default 1); the emitted Tcl still reads env `SEQBIST_WITH_CRC`
at build time, so the build driver can flip it per run without re-patching.

Usage:  patch_seqbist_tcl.py <kit_dir> [--lineage 148|vendh] [--with-crc 0|1]
Idempotent: a second run on an already-patched kit is a no-op (marker
SEQBIST_PATCH_V1).  Exit 0 on success or no-op, 1 on any failure.
"""
import argparse
import os
import sys

MARKER = "SEQBIST_PATCH_V1"
ANCHOR = "report_ip_status -quiet"

# --- pieces reused by both lineages ----------------------------------------

_PREAMBLE = r'''
# ==== SEQBIST_PATCH_V1 (T0b, plan happy-bubbling-owl) =======================
# Inserted by ops/skidfix/patch_seqbist_tcl.py -- see that file's header for
# the control-bit map, the 148 fill_len[1:0] aliasing note and the slot map.
puts "=== SEQBIST: block-design patch (lineage=@LINEAGE@) ==="
set HDLCODERIPINST TxRxCompo_ip_0
set _sb_kit [file dirname [info script]]
foreach _f {qpsk_traffic_gen_v2.v rx_seq_checker.v cnt_mux32.v} {
  set _p [file join $_sb_kit $_f]
  if {![file exists $_p]} { puts "SEQBIST_FAIL missing RTL source $_p"; exit 1 }
  add_files -norecurse $_p
}
update_compile_order -fileset sources_1
open_bd_design [get_files system.bd]

# extend the net already on $srcpin (if any) to $dstpin, else make a new net.
# Used everywhere so that re-wiring a pin whose old consumer was just deleted
# cannot leave a dangling net behind.
proc sb_conn {srcpin dstpin} {
  set n [get_bd_nets -quiet -of_objects [get_bd_pins $srcpin]]
  if {[llength $n]} {
    connect_bd_net -net [lindex $n 0] [get_bd_pins $dstpin]
  } else {
    connect_bd_net [get_bd_pins $srcpin] [get_bd_pins $dstpin]
  }
}
proc sb_require_driven {pins} {
  foreach p $pins {
    if {![llength [get_bd_pins -quiet $p]]} { puts "SEQBIST_FAIL pin $p does not exist"; exit 1 }
    if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins $p]]]} {
      puts "SEQBIST_FAIL pin $p left floating"; exit 1
    }
  }
}
# rx_seq_checker's WITH_CRC parameter (RTL header "PARAMETER"): 1 = instantiate
# the CRC32 datapath, 0 = omit it (the compile-time escape hatch for a routed-WNS
# or utilisation failure; every tgen_mode stage works without it).  The default
# below is baked in by patch_seqbist_tcl.py --with-crc; the build driver can
# override it per run with env SEQBIST_WITH_CRC=0|1 without re-patching.
set _sb_with_crc @WITH_CRC@
if {[info exists ::env(SEQBIST_WITH_CRC)] && [string is integer -strict $::env(SEQBIST_WITH_CRC)]} {
  set _sb_with_crc $::env(SEQBIST_WITH_CRC)
}
if {$_sb_with_crc != 0 && $_sb_with_crc != 1} { puts "SEQBIST_FAIL bad SEQBIST_WITH_CRC=$_sb_with_crc (want 0 or 1)"; exit 1 }
puts "SEQBIST_WITH_CRC $_sb_with_crc"
set _sb_slicedef [lindex [lsort -decreasing [get_ipdefs -filter {NAME == xlslice}]] 0]
if {$_sb_slicedef eq ""} { puts "SEQBIST_FAIL no xlslice ipdef"; exit 1 }
proc sb_bitslice {name srcpin bit} {
  global _sb_slicedef
  if {![llength [get_bd_cells -quiet $name]]} {
    create_bd_cell -type ip -vlnv $_sb_slicedef $name
  }
  set_property -dict [list CONFIG.DIN_WIDTH 32 CONFIG.DIN_FROM $bit CONFIG.DIN_TO $bit \
    CONFIG.DOUT_WIDTH 1] [get_bd_cells $name]
  sb_conn $srcpin $name/Din
}
'''

# traffic_gen (v2) spliced between byte_breakout and the DUT byte-TX pins.
# Byte-for-byte the wiring of ops/skidfix/patch_tgen_tcl.py's TGEN block,
# with the module reference changed to qpsk_traffic_gen_v2.
_TGEN_SPLICE = r'''
# --8<-- SEQBIST_RETAP_CAPTURE_BEGIN
# Deleting the traffic_gen cell destroys every net it drives, silently orphaning
# EVERY OTHER consumer of those nets -- not just the snoops this patch knows
# about.  On the live 148 BD the dut_valid net has five consumers, one of them a
# system_ila probe that a hard-coded re-tap list would silently drop; and
# save_bd_design then persists the damage into the kit's own system.bd.
# So: enumerate every consumer of every net the cell drives BEFORE the delete and
# re-connect them all after.  This is inherently existence-guarded and
# future-proof -- a lineage with fewer consumers simply captures fewer pins.
set _sb_retap {}
if {[llength [get_bd_cells -quiet traffic_gen]]} {
  foreach _op {dut_data dut_valid dut_first host_ready} {
    set _n [get_bd_nets -quiet -of_objects [get_bd_pins -quiet traffic_gen/$_op]]
    if {![llength $_n]} { continue }
    foreach _pn [get_bd_pins -quiet -of_objects [lindex $_n 0]] {
      if {[lindex [split [string trimleft $_pn /] /] 0] eq "traffic_gen"} { continue }
      lappend _sb_retap $_op $_pn
    }
  }
  puts "SEQBIST_RETAP_CAPTURED n=[expr {[llength $_sb_retap] / 2}] pins=$_sb_retap"
  delete_bd_objs [get_bd_cells traffic_gen]
}
# --8<-- SEQBIST_RETAP_CAPTURE_END
create_bd_cell -type module -reference qpsk_traffic_gen_v2 traffic_gen
foreach {bo dut tg_h tg_d} {
  byte_data  dut_byte_data_in  host_data  dut_data
  byte_valid dut_byte_valid_in host_valid dut_valid
  byte_first dut_byte_first_in host_first dut_first
} {
  set n [get_bd_nets -quiet -of_objects [get_bd_pins byte_breakout/$bo]]
  if {[llength $n]} { delete_bd_objs $n }
  connect_bd_net [get_bd_pins byte_breakout/$bo] [get_bd_pins traffic_gen/$tg_h]
  connect_bd_net [get_bd_pins traffic_gen/$tg_d] [get_bd_pins $HDLCODERIPINST/$dut]
}
set n [get_bd_nets -quiet -of_objects [get_bd_pins byte_breakout/byte_ready]]
if {[llength $n]} { delete_bd_objs $n }
connect_bd_net [get_bd_pins traffic_gen/host_ready] [get_bd_pins byte_breakout/byte_ready]
connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_byte_ready_out] [get_bd_pins traffic_gen/dut_ready]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins traffic_gen/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]]   [get_bd_pins traffic_gen/resetn]
sb_conn tgen_ctrl_gpio/gpio_io_o  traffic_gen/ctrl
sb_conn tgen_ctrl_gpio/gpio2_io_o traffic_gen/gap
sb_require_driven {traffic_gen/host_data traffic_gen/host_valid traffic_gen/host_first
  traffic_gen/dut_ready traffic_gen/ctrl traffic_gen/gap traffic_gen/clk traffic_gen/resetn}
# --8<-- SEQBIST_RETAP_RESTORE_BEGIN
# Re-connect every captured consumer to the v2 cell's corresponding output net.
# Pins the splice above already put back on that same net are skipped; every
# captured pin is then asserted driven, so a lost consumer fails the build.
set _sb_retapped 0
foreach {_op _pn} $_sb_retap {
  set _dn  [get_bd_nets -quiet -of_objects [get_bd_pins traffic_gen/$_op]]
  set _pnn [get_bd_nets -quiet -of_objects [get_bd_pins $_pn]]
  if {[llength $_dn] && [llength $_pnn] && [lindex $_dn 0] eq [lindex $_pnn 0]} { continue }
  sb_conn traffic_gen/$_op $_pn
  incr _sb_retapped
}
foreach {_op _pn} $_sb_retap { sb_require_driven [list $_pn] }
puts "SEQBIST_RETAP_OK captured=[expr {[llength $_sb_retap] / 2}] reconnected=$_sb_retapped"
# --8<-- SEQBIST_RETAP_RESTORE_END
puts "SEQBIST_TGEN_V2_OK"
'''

# rx_seq_checker on the DUT RX byte pins -- the same four pins rx_checker snoops
# (two_jup/sim_repro/resynth_probe3.tcl:17).
_RXSEQ = r'''
if {[llength [get_bd_cells -quiet rx_seq]]} { delete_bd_objs [get_bd_cells rx_seq] }
create_bd_cell -type module -reference rx_seq_checker rx_seq
set_property CONFIG.WITH_CRC $_sb_with_crc [get_bd_cells rx_seq]
puts "SEQBIST_RXSEQ_WITH_CRC [get_property CONFIG.WITH_CRC [get_bd_cells rx_seq]]"
foreach {dut pin} {
  dut_byte_data_out  data
  dut_byte_valid_out valid
  dut_byte_user_out  user
  dut_byte_ready_in  ready
} {
  connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins $HDLCODERIPINST/$dut]] [get_bd_pins rx_seq/$pin]
}
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins rx_seq/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]]   [get_bd_pins rx_seq/rst_n]
# control bits out of tgen_rx_ctrl_gpio ch1 (0x9D410000): [3] freeze [4] en [5] tgen_mode
sb_bitslice sb_freeze_slice tgen_rx_ctrl_gpio/gpio_io_o 3
sb_bitslice sb_en_slice     tgen_rx_ctrl_gpio/gpio_io_o 4
sb_bitslice sb_mode_slice   tgen_rx_ctrl_gpio/gpio_io_o 5
sb_conn sb_freeze_slice/Dout rx_seq/freeze
sb_conn sb_en_slice/Dout     rx_seq/en
sb_conn sb_mode_slice/Dout   rx_seq/tgen_mode
sb_require_driven {rx_seq/data rx_seq/valid rx_seq/user rx_seq/ready rx_seq/clk rx_seq/rst_n
  rx_seq/en rx_seq/freeze rx_seq/tgen_mode}
puts "SEQBIST_RXSEQ_OK"
'''

# slots 16..31 -- the Task-1 interface contract order (cnt0..cnt15).
_SLOTS_HIGH = "\n".join(
    "sb_conn rx_seq/cnt%-2d cnt_mux/c%d" % (i, 16 + i) for i in range(16)
) + "\n"

# slots 0..15 -- IDENTICAL source-pin -> slot mapping to resynth_probe4.tcl.
# Only the connect idiom changes (sb_conn re-uses the pin's existing net so the
# nets orphaned by deleting cnt_mux16 cannot linger).
_SLOTS_LOW_148 = r'''
sb_conn traffic_gen_rx/acc_user  cnt_mux/c0
sb_conn rx_checker/frames        cnt_mux/c1
sb_conn rx_checker/crc_ok        cnt_mux/c2
sb_conn rx_checker/crc_fail      cnt_mux/c3
sb_conn rx_checker/magic_bad     cnt_mux/c4
sb_conn rx_checker/short_frm     cnt_mux/c5
sb_conn rx_checker/orphan_w      cnt_mux/c6
sb_conn traffic_gen_rx/acc_beats cnt_mux/c7
sb_conn tx_starve/ep_gt1k        cnt_mux/c8
sb_conn tx_starve/ep_gt2k        cnt_mux/c9
sb_conn tx_starve/ep_gt3k        cnt_mux/c10
sb_conn tx_starve/ep_gt6k        cnt_mux/c11
sb_conn tx_starve/ep_gt12k       cnt_mux/c12
sb_conn tx_starve/ep_gt25k       cnt_mux/c13
sb_conn tx_starve/max_len        cnt_mux/c14
sb_conn tx_starve/starve_clk     cnt_mux/c15
'''

_EPILOGUE = r'''
validate_bd_design
save_bd_design
puts "SEQBIST_WIRE_OK lineage=@LINEAGE@"
# ==== end SEQBIST_PATCH_V1 ==================================================
'''

# --- 148 ---------------------------------------------------------------------

BLOCK_148 = _PREAMBLE + r'''
foreach c {TxRxCompo_ip_0 axi_adrv9001 rx_rstn_inverter axi_hpm0_lpd_interconnect
           traffic_gen traffic_gen_rx rx_checker tx_checker tx_starve cnt_mux sel_slice
           byte_breakout rx_byte_breakout tgen_ctrl_gpio tgen_rx_ctrl_gpio tgen_rx_wit_gpio} {
  if {![llength [get_bd_cells -quiet $c]]} { puts "SEQBIST_FAIL(148) cell $c missing -- wrong lineage?"; exit 1 }
}
set _sb_nmi0 [get_property CONFIG.NUM_MI [get_bd_cells axi_hpm0_lpd_interconnect]]

# ---- (A) traffic_gen: qpsk_traffic_gen -> qpsk_traffic_gen_v2 ---------------
# A module-ref cell's reference cannot be retargeted in place, so the cell is
# deleted and rebuilt.  That ORPHANS the tx_checker and tx_starve snoops, which
# tap the DUT-TX nets traffic_gen drives -- they are re-tapped below.  A floating
# module input only warns in validate_bd_design, so the re-tap is asserted.
# Every create in this block is preceded by a guarded delete, so re-running
# build_txfix.tcl against an already-patched project (a rebuild after a failed
# synth, or Task 5's --dry -> real sequence) is safe.
''' + _TGEN_SPLICE + r'''
# The generic capture/restore above has already re-connected every consumer of
# the deleted cell's nets.  These are the 148-lineage consumers known at review
# time -- named explicitly and existence-guarded so a silent loss of any one of
# them fails the build rather than shipping a dead instrument.
foreach p {tx_checker/data tx_checker/valid tx_checker/first tx_checker/ready
           tx_starve/valid tx_starve/ready beat_ila/probe15} {
  if {[llength [get_bd_pins -quiet $p]]} { sb_require_driven [list $p] } \
  else { puts "SEQBIST_NOTE known consumer $p absent on this BD -- skipped" }
}
puts "SEQBIST_TXSNOOP_RETAP_OK"

# ---- (B) rx_seq_checker on the DUT RX byte pins -----------------------------
''' + _RXSEQ + r'''
# ---- (C) cnt_mux16 -> cnt_mux32, select widened gap[31:28] -> gap[31:27] ----
if {[llength [get_bd_cells -quiet cnt_mux]]} { delete_bd_objs [get_bd_cells cnt_mux] }
set_property -dict [list CONFIG.DIN_WIDTH 32 CONFIG.DIN_FROM 31 CONFIG.DIN_TO 27 \
  CONFIG.DOUT_WIDTH 5] [get_bd_cells sel_slice]
create_bd_cell -type module -reference cnt_mux32 cnt_mux
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins cnt_mux/clk]
sb_conn sel_slice/Dout cnt_mux/sel
set n [get_bd_nets -quiet -of_objects [get_bd_pins tgen_rx_wit_gpio/gpio2_io_i]]
if {[llength $n]} { delete_bd_objs $n }
connect_bd_net [get_bd_pins cnt_mux/q] [get_bd_pins tgen_rx_wit_gpio/gpio2_io_i]
# slots 0-15: unchanged mapping (resynth_probe4.tcl)
''' + _SLOTS_LOW_148 + r'''# slots 16-31: rx_seq_checker cnt0..cnt15 (Task-1 interface contract)
''' + _SLOTS_HIGH + r'''
set _sb_nmi1 [get_property CONFIG.NUM_MI [get_bd_cells axi_hpm0_lpd_interconnect]]
if {$_sb_nmi1 ne $_sb_nmi0} { puts "SEQBIST_FAIL(148) NUM_MI changed $_sb_nmi0 -> $_sb_nmi1 (no new AXI slave expected)"; exit 1 }
puts "SEQBIST_CNTMUX32_OK num_mi=$_sb_nmi1"
''' + _EPILOGUE

# --- vendh (146) -------------------------------------------------------------

BLOCK_VENDH = _PREAMBLE + r'''
foreach c {TxRxCompo_ip_0 axi_adrv9001 rx_rstn_inverter axi_hpm0_lpd_interconnect
           byte_breakout rx_byte_breakout byte_ctrl_gpio} {
  if {![llength [get_bd_cells -quiet $c]]} { puts "SEQBIST_FAIL(vendh) cell $c missing -- wrong lineage?"; exit 1 }
}
# Cross-lineage guard: probe cells that ONLY the 148 lineage has and that this
# patch never creates, so a RE-RUN of an already-patched vendh build tcl (which
# does have traffic_gen / rx_seq / cnt_mux / the GPIOs) is not mistaken for 148.
foreach c {rx_checker tx_checker tx_starve traffic_gen_rx} {
  if {[llength [get_bd_cells -quiet $c]]} { puts "SEQBIST_FAIL(vendh) cell $c present -- this is the 148 lineage, use --lineage 148"; exit 1 }
}
set _sb_gpiodef [lindex [lsort -decreasing [get_ipdefs -filter {NAME == axi_gpio}]] 0]
if {$_sb_gpiodef eq ""} { puts "SEQBIST_FAIL no axi_gpio ipdef"; exit 1 }
set _sb_constdef [lindex [lsort -decreasing [get_ipdefs -filter {NAME == xlconstant}]] 0]
if {$_sb_constdef eq ""} { puts "SEQBIST_FAIL no xlconstant ipdef"; exit 1 }
# the interconnect that already carries byte_ctrl_gpio (0x9D300000)
set _sb_bcintf [get_bd_intf_pins -quiet -of_objects \
  [get_bd_intf_nets -of_objects [get_bd_intf_pins byte_ctrl_gpio/S_AXI]] -filter {MODE == Master}]
set icell [get_bd_cells -of_objects $_sb_bcintf]
if {![llength $icell]} { puts "SEQBIST_FAIL(vendh) could not find byte_ctrl_gpio's interconnect"; exit 1 }
set _sb_nmi0 [get_property CONFIG.NUM_MI $icell]
set _sb_gpio_added 0
proc sb_gpio {name cfg offset} {
  global _sb_gpiodef icell _sb_gpio_added
  if {[llength [get_bd_cells -quiet $name]]} {
    puts "SEQBIST_GPIO_EXISTS $name offset=$offset (re-run: left as is)"
    return
  }
  create_bd_cell -type ip -vlnv $_sb_gpiodef $name
  set_property -dict $cfg [get_bd_cells $name]
  set nmi [get_property CONFIG.NUM_MI $icell]
  set_property CONFIG.NUM_MI [expr {$nmi + 1}] $icell
  set newm [format "M%02d_AXI" $nmi]
  connect_bd_intf_net [get_bd_intf_pins $icell/$newm] [get_bd_intf_pins $name/S_AXI]
  foreach p {ACLK ARESETN} sfx {s_axi_aclk s_axi_aresetn} {
    set src [get_bd_nets -of_objects [get_bd_pins byte_ctrl_gpio/$sfx]]
    connect_bd_net -net $src [get_bd_pins $name/$sfx]
    catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d_$p" $nmi]] }
    catch { connect_bd_net -net $src [get_bd_pins $icell/${newm}_[string tolower $p]] }
    catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d" $nmi]_[string tolower $p]] }
    # precedent: patch_tgen_tcl.py:55-60.  On this design the interconnect is a
    # smartconnect (NUM_CLKS 2, no per-master clock pins), so the three catches
    # above are expected to miss and master-to-clock association is by
    # connectivity -- but if a per-master ACLK pin DOES exist and stayed unwired,
    # say so rather than discovering it at validate_bd_design.
    if {$p eq "ACLK"} {
      set _ckpin [get_bd_pins -quiet $icell/[format "M%02d_ACLK" $nmi]]
      if {[llength $_ckpin] && ![llength [get_bd_nets -quiet -of_objects $_ckpin]]} {
        puts "SEQBIST_WARN: ${newm} clock unwired -- validate_bd_design will decide"
      }
    }
  }
  assign_bd_address -target_address_space /sys_ps8/Data \
    [get_bd_addr_segs $name/S_AXI/Reg] -offset $offset -range 64K
  incr _sb_gpio_added
  puts "SEQBIST_GPIO_OK $name offset=$offset m_port=$newm"
}
set _sb_gpio_out [list CONFIG.C_IS_DUAL 1 CONFIG.C_ALL_OUTPUTS 1 CONFIG.C_ALL_OUTPUTS_2 1 \
  CONFIG.C_GPIO_WIDTH 32 CONFIG.C_GPIO2_WIDTH 32 CONFIG.C_DOUT_DEFAULT 0x00000000 \
  CONFIG.C_DOUT_DEFAULT_2 0x00000000]
set _sb_gpio_in [list CONFIG.C_IS_DUAL 1 CONFIG.C_ALL_INPUTS 1 CONFIG.C_ALL_INPUTS_2 1 \
  CONFIG.C_GPIO_WIDTH 32 CONFIG.C_GPIO2_WIDTH 32]

# ---- (A) traffic_gen v2 at the TX byte pins + tgen_ctrl_gpio @0x9D400000 ----
sb_gpio tgen_ctrl_gpio $_sb_gpio_out 0x9D400000
''' + _TGEN_SPLICE + r'''
# ---- (B) tgen_rx_ctrl_gpio @0x9D410000 (control word + mux select) ---------
sb_gpio tgen_rx_ctrl_gpio $_sb_gpio_out 0x9D410000
''' + _RXSEQ + r'''
# ---- (C) cnt_mux32 + tgen_rx_wit_gpio @0x9D450000 --------------------------
if {![llength [get_bd_cells -quiet sb_zero32]]} { create_bd_cell -type ip -vlnv $_sb_constdef sb_zero32 }
set_property -dict [list CONFIG.CONST_WIDTH 32 CONFIG.CONST_VAL 0] [get_bd_cells sb_zero32]
if {![llength [get_bd_cells -quiet sel_slice]]} { create_bd_cell -type ip -vlnv $_sb_slicedef sel_slice }
set_property -dict [list CONFIG.DIN_WIDTH 32 CONFIG.DIN_FROM 31 CONFIG.DIN_TO 27 \
  CONFIG.DOUT_WIDTH 5] [get_bd_cells sel_slice]
sb_conn tgen_rx_ctrl_gpio/gpio2_io_o sel_slice/Din
if {[llength [get_bd_cells -quiet cnt_mux]]} { delete_bd_objs [get_bd_cells cnt_mux] }
create_bd_cell -type module -reference cnt_mux32 cnt_mux
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins cnt_mux/clk]
sb_conn sel_slice/Dout cnt_mux/sel
sb_gpio tgen_rx_wit_gpio $_sb_gpio_in 0x9D450000
sb_conn sb_zero32/dout tgen_rx_wit_gpio/gpio_io_i
connect_bd_net [get_bd_pins cnt_mux/q] [get_bd_pins tgen_rx_wit_gpio/gpio2_io_i]
# slots 0-15: no traffic_gen_rx / rx_checker / tx_starve on this lineage -> 0
for {set i 0} {$i < 16} {incr i} { sb_conn sb_zero32/dout cnt_mux/c$i }
# slots 16-31: rx_seq_checker cnt0..cnt15 (Task-1 interface contract)
''' + _SLOTS_HIGH + r'''
set _sb_nmi1 [get_property CONFIG.NUM_MI $icell]
if {$_sb_nmi1 != $_sb_nmi0 + $_sb_gpio_added} { puts "SEQBIST_FAIL(vendh) NUM_MI $_sb_nmi0 -> $_sb_nmi1 (expected +$_sb_gpio_added new axi_gpio slaves)"; exit 1 }
if {$_sb_gpio_added != 0 && $_sb_gpio_added != 3} { puts "SEQBIST_FAIL(vendh) partial GPIO set: $_sb_gpio_added of 3 created"; exit 1 }
puts "SEQBIST_CNTMUX32_OK num_mi=$_sb_nmi1"
''' + _EPILOGUE

BLOCKS = {"148": BLOCK_148, "vendh": BLOCK_VENDH}

# Guards that must survive the patch (the build rails Task 5 depends on).
REQUIRED_AFTER = ["IMPL_STRATEGY", "TXFIX_ROUTED_WNS", "TXFIX_ROUTED_TIMING_FAIL"]


def patch_text(src, lineage, with_crc=1):
    """Return (new_text, status). status in {'patched', 'noop'}."""
    if MARKER in src:
        # a no-op is only correct when the file was patched for THIS lineage
        for other in BLOCKS:
            if ("SEQBIST_WIRE_OK lineage=%s" % other) in src and other != lineage:
                raise ValueError(
                    "already patched for lineage %r, refusing to treat --lineage %r as a no-op"
                    % (other, lineage))
        return src, "noop"
    if src.count(ANCHOR) != 1:
        raise ValueError(
            "anchor %r found %d times (expected exactly 1)" % (ANCHOR, src.count(ANCHOR)))
    for g in REQUIRED_AFTER:
        if g not in src:
            raise ValueError("target build tcl lacks required guard %r" % g)
    block = (BLOCKS[lineage].replace("@LINEAGE@", lineage)
             .replace("@WITH_CRC@", str(with_crc)))
    return src.replace(ANCHOR, ANCHOR + "\n" + block, 1), "patched"


def main(argv=None):
    ap = argparse.ArgumentParser(description="SEQ-BIST BD patch for a build kit")
    ap.add_argument("kit", help="kit directory (contains build_txfix.tcl)")
    ap.add_argument("--lineage", choices=sorted(BLOCKS), default="148")
    ap.add_argument("--with-crc", type=int, choices=(0, 1), default=1,
                    help="baked-in default for rx_seq_checker's WITH_CRC parameter "
                         "(1 = CRC32 datapath instantiated). The emitted Tcl still "
                         "honours env SEQBIST_WITH_CRC at build time.")
    ap.add_argument("--tcl", default="build_txfix.tcl",
                    help="build tcl basename inside the kit (default build_txfix.tcl)")
    a = ap.parse_args(argv)

    path = os.path.join(a.kit, a.tcl)
    if not os.path.isfile(path):
        print("SEQBIST_PATCH_FAIL no such file: %s" % path)
        return 1
    with open(path) as f:
        src = f.read()
    try:
        out, status = patch_text(src, a.lineage, a.with_crc)
    except ValueError as e:
        print("SEQBIST_PATCH_FAIL %s: %s" % (path, e))
        return 1
    if status == "noop":
        print("SEQBIST_PATCH_NOOP already patched: %s" % path)
        return 0
    with open(path, "w") as f:
        f.write(out)
    print("SEQBIST_PATCH_OK lineage=%s with_crc=%d file=%s bytes=%d"
          % (a.lineage, a.with_crc, path, len(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
