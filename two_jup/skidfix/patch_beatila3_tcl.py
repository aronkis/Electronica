#!/usr/bin/env python3
"""Insert the BEATILA-3 debug-XDC hookup + post-impl verification gate into a
complete_byte_t8.tcl that has ALREADY been patched with the TGEN + BEATILA blocks
(build-1 lineage). Idempotent.

(1) After the BEATILA block: add beatila3_debug.xdc to constrs_1 with
    used_in_synthesis=false (implementation-side debug-core insertion; synth
    untouched, so post-synth names match build-1's preflighted DCP).
(2) After the IMPL_FAILED gate: open the routed design and HARD-verify the
    inserted core u_ila_beat3 exists with all 10 probe ports (BEATILA3_ILA_OK) —
    a missed net name means an incomplete core; fail BEFORE bootgen.
"""
import sys

XDC_BLOCK = r'''
# ---- BEATILA-3: implementation-side debug-core XDC (BEATILA3_DESIGN.md).
# ---- Names verified against build-1's routed DCP by beatila3_preflight.tcl.
set _b3xdc [file join [file dirname [info script]] beatila3_debug.xdc]
if {![file exists $_b3xdc]} { puts "BEATILA3_FAIL: beatila3_debug.xdc missing"; exit 1 }
add_files -fileset constrs_1 -norecurse $_b3xdc
set_property USED_IN_SYNTHESIS false [get_files $_b3xdc]
set_property USED_IN_IMPLEMENTATION true [get_files $_b3xdc]
puts "BEATILA3_XDC_ADDED $_b3xdc"
'''

VERIFY_BLOCK = r'''
puts "=== BEATILA3: verify inserted debug core in routed design ==="
open_run impl_1
set _b3c [get_cells -quiet u_ila_beat3]
if {![llength $_b3c]} { puts "BEATILA3_ILA_FAIL: u_ila_beat3 cell missing (a probe net name missed at opt_design)"; exit 1 }
set _b3n 0
foreach _p [get_debug_ports -quiet u_ila_beat3/probe*] { incr _b3n }
if {$_b3n < 10} { puts "BEATILA3_ILA_FAIL: only $_b3n/10 probe ports on u_ila_beat3"; exit 1 }
# every probe port must have its nets attached
set _b3bad 0
foreach _p [get_debug_ports -quiet u_ila_beat3/probe*] {
  set _w [get_property PORT_WIDTH $_p]
  set _nets [get_nets -quiet -of_objects $_p]
  if {[llength $_nets] < $_w} { puts "BEATILA3_ILA_WARN: $_p width $_w has [llength $_nets] nets"; incr _b3bad }
}
if {$_b3bad > 0} { puts "BEATILA3_ILA_FAIL: $_b3bad probe port(s) under-connected"; exit 1 }
puts "BEATILA3_ILA_OK ports=$_b3n"
close_design
'''

ANCHOR_XDC    = 'puts "BEATILA_WIRE_OK"'
ANCHOR_VERIFY = 'if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "IMPL_FAILED [get_property STATUS [get_runs impl_1]]"; exit 1 }'

def main():
    path = sys.argv[1]
    src = open(path).read()
    if 'BEATILA3_XDC_ADDED' in src:
        print('patch_beatila3: already patched'); return 0
    if ANCHOR_XDC not in src:
        print('patch_beatila3: FATAL BEATILA anchor missing'); return 1
    if ANCHOR_VERIFY not in src:
        print('patch_beatila3: FATAL impl-gate anchor missing'); return 1
    src = src.replace(ANCHOR_XDC, ANCHOR_XDC + '\n' + XDC_BLOCK, 1)
    src = src.replace(ANCHOR_VERIFY, ANCHOR_VERIFY + '\n' + VERIFY_BLOCK, 1)
    open(path, 'w').write(src)
    print('patch_beatila3: inserted XDC hookup + post-impl gate')
    return 0

if __name__ == '__main__':
    sys.exit(main())
