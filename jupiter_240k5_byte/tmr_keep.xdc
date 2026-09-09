# tmr_keep.xdc -- LOAD-BEARING for the T8.9 TMR stall fix (movsum_tmr_overlay).
#
# The fix triplicates the preamble-threshold accumulator (Delay14 / Delay14B /
# Delay14C in Magnitude_Squared_and_Moving_Sum) and majority-votes them, so a
# single upset of any one copy is corrected on the next enabled beat instead of
# persisting forever (the confirmed live stall mechanism).
#
# WITHOUT THESE CONSTRAINTS THE FIX IS SILENTLY REMOVED: the three registers are
# functionally identical and driven by identical inputs, so Vivado's equivalent-
# register-removal / register-merging optimization collapses them back to ONE
# register. Synthesis reports no warning; the netlist gate still passes (Verilator
# does not merge); the deployed bitstream reverts to a single point of failure.
#
# DONT_TOUCH is applied at the cell level and survives synth + impl. Verify after
# synthesis with:
#   report_property [get_cells -hier -filter {NAME =~ *Magnitude_Squared*Delay14*}]
# and confirm three distinct *_reg cells still exist.
set _tmr [get_cells -hier -filter {NAME =~ *Magnitude_Squared_and_Moving_Sum*Delay14*reg*}]
if {[llength $_tmr] > 0} {
  set_property DONT_TOUCH true $_tmr
  set_property KEEP true $_tmr
  puts "TMR_KEEP_OK applied DONT_TOUCH/KEEP to [llength $_tmr] accumulator cells"
} else {
  puts "TMR_KEEP_WARN no Delay14* cells matched -- TMR may be absent or renamed"
}
