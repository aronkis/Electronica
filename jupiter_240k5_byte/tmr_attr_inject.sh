#!/bin/bash
# tmr_attr_inject.sh <FRESH_BUILD_DIR> -- LOAD-BEARING for the T8.9 TMR stall fix.
#
# WHY THIS EXISTS (measured 2026-08-05, post-synth checkpoint query):
# The TMR overlay emits three identical accumulator registers (Delay14 / Delay14B /
# Delay14C) plus a majority voter in the generated Verilog -- all three ARE present
# in the RTL. Vivado then merged them: the synthesized netlist contained ONLY
# Delay14C (32 bits) and ZERO AccVoter cells. Equivalent-register removal collapsed
# the triplication and constant-folded the voter into a wire, with no warning. The
# resulting bitstream is functionally the UNFIXED design.
#
# An XDC `set_property DONT_TOUCH` did NOT prevent this (verified: DONT_TOUCH read
# back empty on the surviving cells) -- by the time the constraint is applied the
# merge has already happened during synth_design optimization.
#
# The reliable guard is an RTL attribute, honored by synthesis before optimization.
# This script injects (* dont_touch = "true" *) on the three register declarations
# in EVERY copy of the generated module (hdlsrc + packaged ipcore trees), then
# HARD-VERIFIES the injection. Run between RTL generation and Vivado.
set -u
FRESH=${1:?usage: tmr_attr_inject.sh <fresh build dir>}
MOD=TxRxCompo_ip_src_Magnitude_Squared_and_Moving_Sum.v
FILES=$(find "$FRESH" -name "$MOD" 2>/dev/null)
[ -n "$FILES" ] || { echo "TMR_ATTR_FATAL no $MOD found under $FRESH"; exit 1; }
N=0
for f in $FILES; do
  # idempotent: skip if already annotated
  if grep -q 'dont_touch.*Delay14' "$f" 2>/dev/null; then echo "  already annotated: $f"; N=$((N+1)); continue; fi
  # annotate the three accumulator regs and their bypass regs
  # NOTE: sed alternation with | as the delimiter breaks; use a plain awk pass.
  awk '{ if ($0 ~ /^  reg signed \[31:0\] Delay14[BC]?(_reg|_bypass_delay);/) \
           printf "  (* dont_touch = \"true\" *) %s\n", substr($0,3); \
         else print }' "$f" > "$f.tmr" && mv "$f.tmr" "$f"
  C=$(grep -c 'dont_touch = "true"' "$f")
  echo "  annotated $C decls in $f"
  [ "$C" -ge 3 ] || { echo "TMR_ATTR_FATAL only $C annotations in $f (need >=3)"; exit 1; }
  N=$((N+1))
done
# CRITICAL (measured 2026-08-06): the loose .v copies above are NOT what Vivado
# synthesizes. The BD extracts the PACKAGED IP ZIP into
#   vivado_ip_prj/vivado_prj.gen/sources_1/bd/system/ipshared/<hash>/hdl/
# and synthesizes THAT. Annotating only the loose files leaves the real source
# unannotated -> the merge happens anyway (observed twice: Delay14/B gone,
# voter=0). So patch the zip itself, and any already-extracted copies.
for z in $(find "$FRESH" -name "TxRxCompo_ip_v1_0.zip" 2>/dev/null); do
  TD=$(mktemp -d)
  ( cd "$TD" && unzip -o -q "$z" "hdl/$MOD" ) || { echo "TMR_ATTR_FATAL cannot unzip $z"; rm -rf "$TD"; exit 1; }
  ZF="$TD/hdl/$MOD"
  if ! grep -q 'dont_touch.*Delay14' "$ZF"; then
    awk '{ if ($0 ~ /^  reg signed \[31:0\] Delay14[BC]?(_reg|_bypass_delay);/) \
             printf "  (* dont_touch = \"true\" *) %s\n", substr($0,3); \
           else print }' "$ZF" > "$ZF.tmr" && mv "$ZF.tmr" "$ZF"
  fi
  C=$(grep -c 'dont_touch = "true"' "$ZF")
  [ "$C" -ge 3 ] || { echo "TMR_ATTR_FATAL zip copy only $C annotations"; rm -rf "$TD"; exit 1; }
  ( cd "$TD" && zip -q "$z" "hdl/$MOD" ) || { echo "TMR_ATTR_FATAL cannot rezip $z"; rm -rf "$TD"; exit 1; }
  echo "  zip patched ($C annots): $z"
  rm -rf "$TD"
  N=$((N+1))
done
echo "TMR_ATTR_OK annotated $N file(s)/zip(s)"
