#!/bin/bash
# add_postplace_report.sh <kit_dir>
#
# RXFIX Task 13.  Adds a POST-PLACE timing report to a txfix/rxfix build kit so a
# mid-route timing failure is diagnosable after the fact (Task 9b's limitation:
# "the iteration-1 endpoints are not recoverable from any artefact on disk and no
# post-place checkpoint was written; if they are ever wanted, the build script
# would have to be changed to report_timing after place_design",
# two_jup/comb/RXFIX_W1_TIMING.md sec 5).
#
# WHY A RUN HOOK AND NOT AN INLINE COMMAND.  build_txfix.tcl implements with
# `launch_runs impl_1 -to_step write_bitstream`, i.e. a PROJECT run executed in a
# child process; there is no point in the parent script where the placed design is
# in memory.  The project-run equivalent is STEPS.PLACE_DESIGN.TCL.POST, which
# Vivado sources inside the run right after place_design, with the run directory as
# the working directory and the design open.
#
# SAFETY.  The hook body is wrapped in `catch`, so a report failure cannot fail the
# implementation run; and the property is set only under IMPL_STRATEGY=explore's
# sibling block (unconditionally, but it changes no directive).  Idempotent: run it
# twice and the second run is a no-op.
#
# Usage:  two_jup/rxfix/add_postplace_report.sh /path/to/jupiter_byte_rxfixr4b_build
set -u
KIT="${1:-}"
[ -n "$KIT" ] || { echo "POSTPLACE_HOOK_USAGE add_postplace_report.sh <kit_dir>"; exit 2; }
TCL="$KIT/build_txfix.tcl"
HOOK="$KIT/postplace_report.tcl"
[ -f "$TCL" ] || { echo "POSTPLACE_HOOK_NO_TCL $TCL"; exit 1; }

cat > "$HOOK" <<'HOOKEOF'
# postplace_report.tcl -- sourced by Vivado as STEPS.PLACE_DESIGN.TCL.POST for
# impl_1 (RXFIX Task 13).  Runs inside the impl run with the placed design open and
# the run directory as CWD, so the reports land beside Vivado's own.  EVERYTHING is
# inside catch: this is a diagnostic, it must never fail the run.
catch {
    puts "=== RXFIX post-place timing report ==="
    report_timing_summary -max_paths 10 -file system_top_timing_summary_postplace.rpt
    report_timing -max_paths 10 -sort_by group -path_type summary \
        -file system_top_timing_postplace.rpt
    set _w [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1] 0]]
    puts "RXFIX_POSTPLACE_WNS wns=$_w"
} _pperr
if {[info exists _pperr] && $_pperr ne ""} { puts "RXFIX_POSTPLACE_REPORT_ERR $_pperr" }
HOOKEOF

if grep -q 'STEPS.PLACE_DESIGN.TCL.POST' "$TCL"; then
  echo "POSTPLACE_HOOK_ALREADY_PRESENT $TCL"
else
  python3 - "$TCL" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = 'puts "=== impl+bit ==="'
assert s.count(anchor) == 1, 'anchor not unique in ' + p
ins = ('# RXFIX Task 13: post-place timing report (diagnostic only, see\n'
       '# two_jup/rxfix/add_postplace_report.sh).  The hook file sits beside this\n'
       '# script in the kit root; [info script] is how timing_gate.tcl is found too.\n'
       'set _pp [file join [file dirname [info script]] postplace_report.tcl]\n'
       'if {[file exists $_pp]} {\n'
       '    set_property STEPS.PLACE_DESIGN.TCL.POST $_pp [get_runs impl_1]\n'
       '    puts "RXFIX_POSTPLACE_HOOK_SET $_pp"\n'
       '} else {\n'
       '    puts "RXFIX_POSTPLACE_HOOK_MISSING $_pp"\n'
       '}\n')
open(p, 'w').write(s.replace(anchor, ins + anchor))
print('POSTPLACE_HOOK_INSERTED ' + p)
PYEOF
fi

# the kit script's own gates must still hold after the edit
for g in IMPL_STRATEGY TXFIX_ROUTED_TIMING_FAIL rx_seq_checker cnt_mux32 SEQBIST_PATCH_V1; do
  grep -q "$g" "$TCL" || { echo "POSTPLACE_HOOK_BROKE_GATE $g missing from $TCL"; exit 1; }
done
echo "POSTPLACE_HOOK_OK hook=$HOOK tcl=$TCL"
