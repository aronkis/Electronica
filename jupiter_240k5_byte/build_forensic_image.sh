#!/bin/bash
# build_forensic_image.sh -- LEAN + adc_forensic(0x15C) instrumented image.
# Purpose: catch the reverse 5-100-frame live-only bursts red-handed via the SSI
# valid-cadence counters (maxGap/maxBurst) while keeping the LEAN placement budget.
# FULL gates first (lesson from the CYCLIC attempt: no gate-skipping on HDL-affecting
# changes -- and QPSK_ADC_FORENSIC changes the model, unlike the BD-only CYCLIC flag).
# Mirrors the proven build_cyclic_image.sh flow otherwise. NO FLASH.
set -u
export QPSK_LEAN=1
export QPSK_ADC_FORENSIC=1
# IMAGE-GEOMETRY GUARD (learned 2026-08-01): the deployed images REQUIRE explicit
# geometry env (REPRODUCE.md: Image B = QPSK_FRAME=f1536 QPSK_SPS=4). Building with
# these unset silently produces an Image-A-geometry (sps=8) modem that BREAKS on
# R2/R3 boards (byte plane dead, TX re-arm death, 2x gate rates). Hard-fail instead.
[ -n "${QPSK_FRAME:-}" ] && [ -n "${QPSK_SPS:-}" ] || {
  echo "FATAL: QPSK_FRAME and QPSK_SPS must be set explicitly (Image B: QPSK_FRAME=f1536 QPSK_SPS=4). See REPRODUCE.md."; exit 2; }
export QPSK_FRAME=${QPSK_FRAME:-}
export QPSK_SPS=${QPSK_SPS:-}
export QPSK_TARGET_MHZ=${QPSK_TARGET_MHZ:-}
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/tools/Xilinx/2025.1/Vivado/bin:/usr/local/bin:/usr/bin:/bin
K=$(cd "$(dirname "$0")" && pwd)                        # KIT (jupiter_240k5_byte)
B=$(cd "$K/.." && pwd)/jupiter_byte_forensic_build      # FRESH build dir (separate from lean)
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad/forb_logs
step(){ echo "FORB[$(date +%H:%M)] $*"; }
cd "$K"
# sanity: the env-gated forensic exception must be present in the KIT assemble
grep -q "QPSK_ADC_FORENSIC" assemble_jupiter_240k5_byte.m || { echo "FATAL: forensic gate missing from assemble"; exit 1; }
step "FULL QPSK_LEAN=1 + QPSK_ADC_FORENSIC=1 gates"
mkdir -p "$S"
bash run_full_gates_t8.sh > "$S/for_gates.log" 2>&1 || { echo FOR_GATES_FAIL; tail -8 "$S/for_gates.log"; exit 1; }
grep -q FULL_GATES_T8_DONE "$S/for_gates.log" || { echo FOR_GATES_INCOMPLETE; exit 1; }
step "gates green -> Vivado build (adc_forensic present)"
bash build_byte_image.sh "$B" > "$S/for_buildimg.log" 2>&1
P="$B/hdl_prj_jupiter_composite/vivado_ip_prj"
BB="$P/boot/BOOT.BIN"
[ -f "$BB" ] || { echo FOR_BUILD_FAIL; grep -E "IMPL_FAILED|Placer|ERROR:|VALIDATE_FAILED|BYTE_IMAGE_BUILD_FAILED" "$S/for_buildimg.log" | tail -8; exit 1; }
# HARD GATE: the forensic overlay must have been applied in the MATLAB stage
grep -q "applying ADC forensic overlay" "$B/build_byte_matlab.log" 2>/dev/null || { echo "FOR_OVERLAY_MISSING"; exit 1; }
# --- dual-DMA tap step (identical to the proven chain) ---
step "dual-DMA tap BD step"
cd "$P"
cat > clear_incr.tcl <<'TEOF'
open_project vivado_prj.xpr
foreach r [list synth_1 impl_1] {
  catch { set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs $r] }
  catch { set_property INCREMENTAL_CHECKPOINT {} [get_runs $r] }
}
puts "INCR_CLEARED"
TEOF
mv boot/BOOT.BIN boot/BOOT.BIN.pre_dualdma
vivado -mode batch -nolog -nojournal -source "$K/bd_tap_dualdma.tcl" -tclargs ch1 > step_dualdma.log 2>&1 || { echo FOR_DUALDMA_FAIL; tail -5 step_dualdma.log; exit 1; }
grep -q DUALDMA_VALIDATE_OK step_dualdma.log || { echo FOR_DUALDMA_VALIDATE_FAIL; tail -5 step_dualdma.log; exit 1; }
vivado -mode batch -nolog -nojournal -source clear_incr.tcl > step_ci.log 2>&1
vivado -mode batch -nolog -nojournal -source "$K/ch2_build2.tcl" > step_ch2build.log 2>&1
if [ -f "$BB" ]; then
  SZ=$(stat -c %s "$BB"); [ "$SZ" -gt 6000000 ] && echo "FORENSIC_IMAGE_DONE md5=$(md5sum "$BB"|cut -c1-32) size=$SZ" || echo "FORENSIC_IMAGE_SMALL size=$SZ"
else echo FOR_DUALDMA_NOBOOT; tail -5 step_ch2build.log; exit 1; fi
