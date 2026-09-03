#!/bin/bash
# run_beatila_build.sh -- BUILD ONLY: beat-ILA observability image (BUILD 1 of the
# beat campaign, BD-only variant -- DUT UNTOUCHED, rail parity REQUIRED).
# Carries: all three TGEN instruments (TX/RX injectors + TX checker, identical to the
# flashed 9259cfade5b4 lineage) PLUS the beat-ILA overlay (BEAT_ILA_DESIGN.md):
#   - burst_onset_det.v trigger (arm/force GPIO @0x9D430000)
#   - system_ila beat_ila on adc_1_clk (16 probes, 4096 deep)
#   - debug_bridge XVC @0x9D440000 (board daemon: host_app_k5/xvc_server.c)
# Trigger source: soft_force scheduled at arm+35s (beat law arm+34.75s+n*119.75s);
# hardware err trigger is BUILD 2 (needs DUT overlay port dut_bit_err_out).
# NO FLASH -- separate operator authorization.
set -u
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem
BASE=$ROOT/jupiter_byte_lean_build
FRESH=$ROOT/jupiter_byte_beatfix_build
SRC=$ROOT/two_jup/skidfix
KITRTL=$ROOT/jupiter_240k5_byte/rtl_sim
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/tools/Xilinx/2025.1/Vivado/bin:/usr/bin:/bin
export QPSK_LEAN=1
export QPSK_FRAME=f1536
export QPSK_SPS=4
export QPSK_FRAMESTAT=1
export QPSK_BEATOBS=1   # BEATOBS: packed state vector -> debugI1/Q1 (beatobs_overlay.m)
export QPSK_BEATFIX=1   # BEATFIX: phase contract + runtime fix arms (beatfix_overlay.m)
echo "BEATFIX_BUILD start $(date -Is) host=$(hostname) pid=$$ ppid=$PPID"

echo "=== [1/6] fresh kit copy (e49c011b lineage) -> $FRESH ==="
rm -rf "$FRESH"; mkdir -p "$FRESH"
rsync -a --exclude 'hdl_prj_*' --exclude 'slprj' --exclude '*.log' --exclude '*.out' \
  --exclude 'rtl_sim/obj_*' --exclude 's1_rtl' "$BASE/" "$FRESH/" || { echo BEATFIX_BUILD_FAILED rsync; exit 1; }
for f in "$FRESH"/*.m; do sed -i "s#$BASE#$FRESH#g" "$f"; done
# hook beatobs_overlay into assemble (env-gated; call after framestat_overlay)
python3 - "$FRESH/assemble_jupiter_240k5_byte.m" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'beatobs_overlay(sys, loop)' not in s:
    a='    framestat_overlay(sys, loop);'
    assert a in s, 'framestat anchor missing'
    s=s.replace(a, a+"\nfprintf('=== applying BEAT observability overlay (env-gated QPSK_BEATOBS) ===\\n');\nbeatobs_overlay(sys, loop);\nfprintf('=== applying BEATFIX overlay (env-gated QPSK_BEATFIX) ===\\n');\nbeatfix_overlay(sys, loop);",1)
    a2="patch_hdlworkflow_loopgain('hdlworkflow_loopback.m');   % C3: loop-gain regs 0x170-0x184 (block-guarded)"
    if 'patch_hdlworkflow_beatfix' not in s:
        assert a2 in s, 'loopgain helper anchor missing'
        s=s.replace(a2, a2+"\npatch_hdlworkflow_beatfix('hdlworkflow_loopback.m');   % BEATFIX: fixctl 0x208 + viol 0x20C/0x210 (env-gated)",1)
    open(p,'w').write(s); print('assemble hooked')
else: print('assemble already hooked')
PYEOF
grep -q 'beatobs_overlay(sys, loop)' "$FRESH/assemble_jupiter_240k5_byte.m" || { echo BEATFIX_BUILD_FAILED assemble-hook; exit 1; }
cp "$KITRTL/qpsk_traffic_gen.v" "$KITRTL/qpsk_traffic_gen_rx.v" "$KITRTL/tx_seam_checker.v" \
   "$KITRTL/burst_onset_det.v" "$FRESH/" || { echo BEATFIX_BUILD_FAILED cp; exit 1; }

echo "=== [2/6] patch complete_byte_t8.tcl (TGEN splices + beat-ILA overlay) ==="
python3 "$SRC/patch_tgen_tcl.py" "$FRESH/complete_byte_t8.tcl" || { echo BEATFIX_BUILD_FAILED patch-tgen; exit 1; }
grep -q 'TGEN_RX_WIRE_OK' "$FRESH/complete_byte_t8.tcl" || { echo BEATFIX_BUILD_FAILED patch-tgen-verify; exit 1; }
python3 "$SRC/patch_beatila_tcl.py" "$FRESH/complete_byte_t8.tcl" || { echo BEATFIX_BUILD_FAILED patch-beatila; exit 1; }
grep -q 'BEATILA_WIRE_OK' "$FRESH/complete_byte_t8.tcl" || { echo BEATFIX_BUILD_FAILED patch-beatila-verify; exit 1; }

echo "=== [3/6] MATLAB build_variant_byte (CreateProject fail EXPECTED) ==="
( cd "$FRESH" && timeout 7200 matlab -batch "cd('$FRESH'); build_variant_byte" ) > "$FRESH/build_byte_matlab.log" 2>&1
echo "  matlab exit=$? (nonzero at Create Project is expected)"
Z=$FRESH/hdl_prj_jupiter_composite/vivado_ip_prj
[ -f "$Z/vivado_prj.xpr" ] || { echo "BEATFIX_BUILD_FAILED: no vivado project"; tail -20 "$FRESH/build_byte_matlab.log"; exit 1; }
[ -f "$Z/ipcore/TxRxCompo_ip_v1_0.zip" ] || { echo "BEATFIX_BUILD_FAILED: no ipcore zip"; exit 1; }
grep -q 'byte_breakout' "$Z/vivado_prj.srcs/sources_1/bd/system/system.bd" 2>/dev/null \
  || { echo "BEATFIX_BUILD_FAILED: BD has no byte_breakout"; exit 1; }

echo "=== [4/6] Vivado completion (splices + ILA/XVC + synth/impl/bootgen) ==="
( cd "$Z" && timeout 16200 vivado -mode batch -notrace -source "$FRESH/complete_byte_t8.tcl" ) > "$FRESH/build_byte_vivado.log" 2>&1
grep -E 'WIRE_OK|WIRE_FAIL|BEATILA|VALIDATE_OK|VALIDATE_FAILED|BYTE_BUILD_DONE|SYNTH_FAILED|IMPL_FAILED|TIMING' \
  "$FRESH/build_byte_vivado.log" | tail -24
grep -q "BEATOBS_OVERLAY_OK" "$FRESH/build_byte_matlab.log" || { echo "BEATFIX_BUILD_FAILED: BEATOBS overlay never ran"; exit 1; }
grep -q "BEATFIX_OVERLAY_OK" "$FRESH/build_byte_matlab.log" || { echo "BEATFIX_BUILD_FAILED: BEATFIX overlay never ran"; exit 1; }
grep -q "patch_hdlworkflow_beatfix: added AXI mappings" "$FRESH/build_byte_matlab.log" || { echo "BEATFIX_BUILD_FAILED: AXI mappings 0x208-0x210 never applied"; exit 1; }
for M in TGEN_WIRE_OK TGEN_RX_WIRE_OK TXCHK_WIRE_OK BEATILA_WIRE_OK; do
  grep -q "$M" "$FRESH/build_byte_vivado.log" || { echo "BEATFIX_BUILD_FAILED: $M never confirmed"; exit 1; }
done
B=$Z/boot/BOOT.BIN
[ -f "$B" ] || { echo "BEATFIX_BUILD_FAILED: no BOOT.BIN"; exit 1; }
MD5=$(md5sum "$B" | cut -c1-12)
echo "BEATFIX_IMAGE_MD5 $MD5"
LTX=$(find "$Z" -name '*.ltx' | head -1)
echo "BEATFIX_LTX ${LTX:-MISSING}"

echo "=== [5/6] DCP rail census gate (BD-only overlay: PARITY REQUIRED) ==="
DCP=$Z/vivado_prj.runs/impl_1/system_top_routed.dcp
if [ -f "$DCP" ] && [ -f "$BASE/rail_lean_ref.txt" ]; then
  ( cd "$FRESH" && timeout 3600 vivado -mode batch -notrace -source "$ROOT/two_jup/dcp_rail_dump.tcl" \
      -tclargs "$DCP" "$FRESH/rail_beatila.txt" ) > "$FRESH/rail_dump_beatila.log" 2>&1
  TCS=$(grep -m1 '^TC_CELLS' "$FRESH/rail_beatila.txt" | awk '{print $2}')
  TCL_=$(grep -m1 '^TC_CELLS' "$BASE/rail_lean_ref.txt" | awk '{print $2}')
  echo "RAIL_GATE tc_cells beatila=$TCS lean=$TCL_ $( [ "$TCS" = "$TCL_" ] && echo PARITY_OK || echo PARITY_MISMATCH )"
  grep -m2 'enb_1_2_0' "$FRESH/rail_beatila.txt" | sed 's/^/RAIL_BEATILA /'
else
  echo "RAIL_GATE SKIPPED (missing dcp or lean ref)"
fi

echo "=== [6/6] DONE -- image BANKED, HARD STOP (no flash) ==="
echo "BEATFIX_BUILD_DONE md5=$MD5 image=$B ltx=${LTX:-MISSING} $(date -Is)"
echo "OPERATOR GATE: flashing requires a separate explicit authorization."
