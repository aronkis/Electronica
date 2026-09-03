#!/bin/bash
# lean_build.sh -- full QPSK_LEAN=1 gate suite + Vivado build. Run ONLY after
# the fail-fast checkhdl passed both paths. Produces the lean BOOT.BIN. NO FLASH.
set -u
export QPSK_LEAN=1
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/tools/Xilinx/2025.1/Vivado/bin:/usr/local/bin:/usr/bin:/bin
K=$(cd "$(dirname "$0")" && pwd)                       # this kit dir
B=${LEAN_BUILD_DIR:-$(cd "$K/.." && pwd)/jupiter_byte_lean_build}
S=${LEAN_LOG_DIR:-$B/build_logs}; mkdir -p "$S"        # build logs (was a hardcoded scratchpad)
step(){ echo "LEANB[$(date +%H:%M)] $*"; }
cd $K
step "full QPSK_LEAN=1 gates"
bash run_full_gates_t8.sh > $S/lean_gates.log 2>&1 || { echo LEAN_GATES_FAIL; tail -6 $S/lean_gates.log; exit 1; }
grep -q FULL_GATES_T8_DONE $S/lean_gates.log || { echo LEAN_GATES_INCOMPLETE; exit 1; }
step "gates green -> Vivado build (DDS-diet in complete_byte_t8.tcl)"
bash build_byte_image.sh $B > $S/lean_buildimg.log 2>&1
P=$B/hdl_prj_jupiter_composite/vivado_ip_prj
BB=$P/boot/BOOT.BIN
[ -f "$BB" ] || { echo LEAN_BUILD_FAIL; grep -E "IMPL_FAILED|Placer|ERROR:|BYTE_IMAGE_BUILD_FAILED" $S/lean_buildimg.log | tail -6; exit 1; }
# --- dual-DMA tap step (KEEP the 0x10C tap -> rx2-lpc): same as the v3 chain ---
step "dual-DMA tap BD step (routes 0x10C mux -> rx2-lpc capture)"
cd $P
cat > clear_incr.tcl <<'TEOF'
open_project vivado_prj.xpr
foreach r [list synth_1 impl_1] {
  catch { set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs $r] }
  catch { set_property INCREMENTAL_CHECKPOINT {} [get_runs $r] }
}
puts "INCR_CLEARED"
TEOF
mv boot/BOOT.BIN boot/BOOT.BIN.pre_dualdma
vivado -mode batch -nolog -nojournal -source $K/bd_tap_dualdma.tcl -tclargs ch1 > step_dualdma.log 2>&1 || { echo LEAN_DUALDMA_FAIL; tail -5 step_dualdma.log; exit 1; }
grep -q DUALDMA_VALIDATE_OK step_dualdma.log || { echo LEAN_DUALDMA_VALIDATE_FAIL; tail -5 step_dualdma.log; exit 1; }
vivado -mode batch -nolog -nojournal -source clear_incr.tcl > step_ci.log 2>&1
vivado -mode batch -nolog -nojournal -source $K/ch2_build2.tcl > step_ch2build.log 2>&1
if [ -f "$BB" ]; then
  SZ=$(stat -c %s "$BB"); [ "$SZ" -gt 6000000 ] && echo "LEAN_IMAGE_DONE md5=$(md5sum "$BB"|cut -c1-32) size=$SZ" || echo "LEAN_IMAGE_SMALL size=$SZ"
else echo LEAN_DUALDMA_NOBOOT; tail -5 step_ch2build.log; exit 1; fi
