#!/usr/bin/env python3
"""Add gated-clock conversion to every synth run in complete_byte_t8.tcl."""
import sys
p = sys.argv[1]
s = open(p).read()
if 'GATED_CLOCK_CONVERSION' in s:
    print('gcc: already patched'); raise SystemExit(0)
anchor = 'puts "=== synth ==="'
assert anchor in s
block = '''# GATED-CLOCK CONVERSION (skid4, HANDOFF_20260815 forward hypothesis):
# the DUT's enb rail + RAM write clocks are LUT-generated gated clocks
# promoted to BUFG (glitch_probe_skid3.txt: all BUFGCE CEs are VCC, gates on
# the I inputs) -- glitch-capable by construction. Convert to BUFGCE-CE form.
foreach _r [get_runs -quiet *synth*] {
  catch { set_property STEPS.SYNTH_DESIGN.ARGS.GATED_CLOCK_CONVERSION auto $_r }
}
puts "GCC_OPTION_SET [llength [get_runs -quiet *synth*]] runs"
'''
s = s.replace(anchor, block + anchor, 1)
open(p, 'w').write(s)
print('gcc: patched')
