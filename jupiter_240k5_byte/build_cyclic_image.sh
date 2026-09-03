#!/bin/bash
# build_cyclic_image.sh -- like build_lean_image.sh but SKIPS the QPSK_LEAN gates.
# Rationale: the CYCLIC=1 change is a Vivado BD IP param (rx_byte_dma, the MODEM
# byte-plane S2MM DMAC at 0x9D200000 -- see two_jup/DMAC_IDENTIFIED.md; NOT
# axi_adrv9001_rx1_dma, the prior wrong target) ONLY;
# the modem RTL/model is byte-identical, and the gates (assemble/oracle/checkhdl/makehdl/
# S1B/S1) already passed green (FULL_GATES_T8_DONE) in the prior run. So re-running them
# adds no validation. Everything else mirrors build_lean_image.sh exactly. NO FLASH.
# The CYCLIC injection lives in complete_byte_t8.tcl (KIT source) -> rsync'd into FRESH.
set -u
export QPSK_LEAN=1
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
# FRESH build dir -- overridable via QPSK_BUILD_DIR so two images can build in
# PARALLEL in separate fresh dirs (N2 2026-08-12); default = the historical dir.
B=${QPSK_BUILD_DIR:-$(cd "$K/.." && pwd)/jupiter_byte_lean_build}
S=$B/build_logs; mkdir -p "$S"
step(){ echo "CYCB[$(date +%H:%M)] $*"; }
cd "$K"
# sanity: the CYCLIC injection must be present in the KIT source we are about to rsync
grep -q "set_property CONFIG.CYCLIC 1 \[get_bd_cells rx_byte_dma\]" complete_byte_t8.tcl || { echo "FATAL: CYCLIC injection missing from KIT complete_byte_t8.tcl"; exit 1; }
step "gates SKIPPED (BD-only change; gates green in prior run) -> Vivado build w/ CYCLIC=1"
bash build_byte_image.sh "$B" > "$S/cyc_buildimg.log" 2>&1
P="$B/hdl_prj_jupiter_composite/vivado_ip_prj"
BB="$P/boot/BOOT.BIN"
[ -f "$BB" ] || { echo CYC_BUILD_FAIL; grep -E "IMPL_FAILED|Placer|ERROR:|CYCLIC_FAIL|VALIDATE_FAILED|BYTE_IMAGE_BUILD_FAILED" "$S/cyc_buildimg.log" | tail -8; exit 1; }
# HARD GATE: the CYCLIC injection must have executed in Vivado
grep -q "CYCLIC_RXBYTE_OK" "$B/build_byte_vivado.log" 2>/dev/null || { echo "CYC_INJECT_MISSING -- CYCLIC_RXBYTE_OK not in build_byte_vivado.log"; exit 1; }
echo "  $(grep -h CYCLIC_RXBYTE_OK "$B/build_byte_vivado.log" | tail -1)"
# --- dual-DMA tap step (KEEP the 0x10C tap -> rx2-lpc): identical to build_lean_image.sh ---
step "dual-DMA tap BD step (routes 0x10C mux -> rx2-lpc capture)"
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
vivado -mode batch -nolog -nojournal -source "$K/bd_tap_dualdma.tcl" -tclargs ch1 > step_dualdma.log 2>&1 || { echo CYC_DUALDMA_FAIL; tail -5 step_dualdma.log; exit 1; }
grep -q DUALDMA_VALIDATE_OK step_dualdma.log || { echo CYC_DUALDMA_VALIDATE_FAIL; tail -5 step_dualdma.log; exit 1; }
vivado -mode batch -nolog -nojournal -source clear_incr.tcl > step_ci.log 2>&1
vivado -mode batch -nolog -nojournal -source "$K/ch2_build2.tcl" > step_ch2build.log 2>&1
if [ -f "$BB" ]; then
  SZ=$(stat -c %s "$BB"); [ "$SZ" -gt 6000000 ] && echo "CYCLIC_IMAGE_DONE md5=$(md5sum "$BB"|cut -c1-32) size=$SZ" || echo "CYCLIC_IMAGE_SMALL size=$SZ"
else echo CYC_DUALDMA_NOBOOT; tail -5 step_ch2build.log; exit 1; fi
