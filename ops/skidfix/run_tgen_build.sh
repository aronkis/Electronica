#!/bin/bash
# run_tgen_build.sh -- BUILD ONLY the traffic-generator splice image on the
# jupiter_byte_lean_build lineage (Task 6 of the 2026-08-17 traffic-gen plan;
# reap-proof, HARD STOP before flash).
#
# Base kit  : jupiter_byte_lean_build (exact e49c011b-recipe lean snapshot).
# Splice    : qpsk_traffic_gen.v inserted between byte_breakout and the DUT
#             byte-TX pins, config via tgen_ctrl_gpio @0x9D400000
#             (patch_tgen_tcl.py, spec 2026-08-17).
# Gates     : TGEN_WIRE_OK marker, timing gate (in-flow), DCP rail census vs
#             the lean routed DCP (dcp_rail_dump.tcl -- TC_CELLS parity +
#             enb driver location; DUT is untouched by this splice so PARITY
#             is REQUIRED, not just expected).
# NO FLASH. The image is banked; flashing is a separate operator decision.
set -u
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem
BASE=$ROOT/jupiter_byte_lean_build
FRESH=$ROOT/jupiter_byte_tgen_build
SRC=$ROOT/ops/skidfix
KITRTL=$ROOT/modem/rtl_sim
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/tools/Xilinx/2025.1/Vivado/bin:/usr/bin:/bin
# EXACT e49c011b recipe (HANDOFF_20260813.md:208 -- "exact e49c011b env").
# Attempt 1 (no env) failed the timing gate on the fat canary stack; attempt 2
# (QPSK_LEAN=1 only) built at sps=8 without framestat -> a different DUT and a
# spurious rail-census mismatch. All four are required to reproduce the lineage:
export QPSK_LEAN=1
export QPSK_FRAME=f1536
export QPSK_SPS=4
export QPSK_FRAMESTAT=1
echo "TGEN_BUILD start $(date -Is) host=$(hostname) pid=$$ ppid=$PPID"

echo "=== [1/6] fresh kit copy (e49c011b lineage) -> $FRESH ==="
rm -rf "$FRESH"; mkdir -p "$FRESH"
rsync -a --exclude 'hdl_prj_*' --exclude 'slprj' --exclude '*.log' --exclude '*.out' \
  --exclude 'rtl_sim/obj_*' --exclude 's1_rtl' "$BASE/" "$FRESH/" || { echo TGEN_BUILD_FAILED rsync; exit 1; }
for f in "$FRESH"/*.m; do sed -i "s#$BASE#$FRESH#g" "$f"; done
cp "$KITRTL/qpsk_traffic_gen.v" "$FRESH/" || { echo TGEN_BUILD_FAILED cp; exit 1; }

echo "=== [2/6] patch complete_byte_t8.tcl (traffic-gen splice) ==="
python3 "$SRC/patch_tgen_tcl.py" "$FRESH/complete_byte_t8.tcl" || { echo TGEN_BUILD_FAILED patch; exit 1; }
grep -q 'TGEN_WIRE_OK' "$FRESH/complete_byte_t8.tcl" || { echo TGEN_BUILD_FAILED patch-verify; exit 1; }

echo "=== [3/6] MATLAB build_variant_byte (CreateProject fail EXPECTED) ==="
( cd "$FRESH" && timeout 7200 matlab -batch "cd('$FRESH'); build_variant_byte" ) > "$FRESH/build_byte_matlab.log" 2>&1
echo "  matlab exit=$? (nonzero at Create Project is expected)"
Z=$FRESH/hdl_prj_jupiter_composite/vivado_ip_prj
[ -f "$Z/vivado_prj.xpr" ] || { echo "TGEN_BUILD_FAILED: no vivado project"; tail -20 "$FRESH/build_byte_matlab.log"; exit 1; }
[ -f "$Z/ipcore/TxRxCompo_ip_v1_0.zip" ] || { echo "TGEN_BUILD_FAILED: no ipcore zip"; exit 1; }
grep -q 'byte_breakout' "$Z/vivado_prj.srcs/sources_1/bd/system/system.bd" 2>/dev/null \
  || { echo "TGEN_BUILD_FAILED: BD has no byte_breakout"; exit 1; }
echo "  byte reference-design BD confirmed"

echo "=== [4/6] Vivado completion (traffic-gen splice + synth/impl/bootgen) ==="
( cd "$Z" && timeout 16200 vivado -mode batch -notrace -source "$FRESH/complete_byte_t8.tcl" ) > "$FRESH/build_byte_vivado.log" 2>&1
grep -E 'TGEN_WIRE_OK|TGEN_NOTE|TGEN_WARN|TGEN_FAIL|WIRE_OK|WIRE_FAIL|BYTE_WIRE_OK|VALIDATE_OK|VALIDATE_FAILED|BYTE_BUILD_DONE|SYNTH_FAILED|IMPL_FAILED|TIMING' \
  "$FRESH/build_byte_vivado.log" | tail -20
grep -q 'TGEN_WIRE_OK' "$FRESH/build_byte_vivado.log" || { echo "TGEN_BUILD_FAILED: splice never confirmed"; exit 1; }
B=$Z/boot/BOOT.BIN
[ -f "$B" ] || { echo "TGEN_BUILD_FAILED: no BOOT.BIN"; exit 1; }
MD5=$(md5sum "$B" | cut -c1-12)
echo "TGEN_IMAGE_MD5 $MD5"

echo "=== [5/6] DCP rail census gate (vs lean e49c011b routed DCP) ==="
DCP=$Z/vivado_prj.runs/impl_1/system_top_routed.dcp
LEANDCP=$BASE/hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/impl_1/system_top_routed.dcp
if [ -f "$DCP" ]; then
  ( cd "$FRESH" && timeout 3600 vivado -mode batch -notrace -source "$ROOT/ops/dcp_rail_dump.tcl" \
      -tclargs "$DCP" "$FRESH/rail_tgen.txt" ) > "$FRESH/rail_dump_tgen.log" 2>&1
  if [ -f "$BASE/rail_lean_ref.txt" ]; then :; elif [ -f "$LEANDCP" ]; then
    ( cd "$FRESH" && timeout 3600 vivado -mode batch -notrace -source "$ROOT/ops/dcp_rail_dump.tcl" \
        -tclargs "$LEANDCP" "$BASE/rail_lean_ref.txt" ) > "$FRESH/rail_dump_lean.log" 2>&1
  fi
  if [ -f "$BASE/rail_lean_ref.txt" ] && [ -f "$FRESH/rail_tgen.txt" ]; then
    TCS=$(grep -m1 '^TC_CELLS' "$FRESH/rail_tgen.txt" | awk '{print $2}')
    TCL_=$(grep -m1 '^TC_CELLS' "$BASE/rail_lean_ref.txt" | awk '{print $2}')
    echo "RAIL_GATE tc_cells tgen=$TCS lean=$TCL_ $( [ "$TCS" = "$TCL_" ] && echo PARITY_OK || echo PARITY_MISMATCH )"
    grep -m2 'enb_1_2_0' "$FRESH/rail_tgen.txt" | sed 's/^/RAIL_TGEN /'
    grep -m2 'enb_1_2_0' "$BASE/rail_lean_ref.txt" | sed 's/^/RAIL_LEAN /'
  else
    echo "RAIL_GATE SKIPPED (missing dump)"
  fi
else
  echo "RAIL_GATE SKIPPED (no routed dcp)"
fi

echo "=== [6/6] DONE -- image BANKED, HARD STOP (no flash) ==="
echo "TGEN_BUILD_DONE md5=$MD5 image=$B $(date -Is)"
echo "OPERATOR GATE: flashing requires a separate explicit authorization."
