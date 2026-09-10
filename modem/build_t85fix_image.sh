#!/bin/bash
# build_t85fix_image.sh -- rebuild of the T8.5 stall-catch image with the
# hdlworkflow canary AXI-mapping fix (block-existence guard instead of the LEAN
# env gate that left 0x170-0x188 unmapped on the 4dafdad3 image).
# GATE-SKIP JUSTIFICATION: the only source change vs the fully-gated 4dafdad3
# build is the hdlworkflow_loopback.m mapping guard -- the model oracle never
# executes hdlworkflow, so its 12h-old PASS is invariant. checkhdl/makehdl-level
# errors are caught by the MATLAB stage of build_byte_image.sh itself. New HARD
# GATE below: generated AXI RTL must contain the 0x188 canary decode.  NO FLASH.
set -u
export QPSK_LEAN=1
export QPSK_ADC_FORENSIC=1
export QPSK_CANARY_T85=1
export QPSK_LOOP_GAIN_AXI=0
[ -n "${QPSK_FRAME:-}" ] && [ -n "${QPSK_SPS:-}" ] || {
  echo "FATAL: QPSK_FRAME and QPSK_SPS must be set explicitly (Image B: QPSK_FRAME=f1536 QPSK_SPS=4)."; exit 2; }
export QPSK_FRAME QPSK_SPS
export QPSK_TARGET_MHZ=${QPSK_TARGET_MHZ:-}
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/tools/Xilinx/2025.1/Vivado/bin:/usr/local/bin:/usr/bin:/bin
K=$(cd "$(dirname "$0")" && pwd)
B=$(cd "$K/.." && pwd)/jupiter_byte_forensic_build
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad/forb_logs
step(){ echo "T85F[$(date +%H:%M)] $*"; }
cd "$K"
grep -q "shdw_pdiv_cnt'))" hdlworkflow_loopback.m || { echo "FATAL: block-existence guard missing from hdlworkflow"; exit 1; }
mkdir -p "$S"
step "gates SKIPPED (hdlworkflow mapping-guard-only change; oracle invariant) -> Vivado build"
bash build_byte_image.sh "$B" > "$S/t85fix_buildimg.log" 2>&1
P="$B/hdl_prj_jupiter_composite/vivado_ip_prj"
BB="$P/boot/BOOT.BIN"
[ -f "$BB" ] || { echo T85FIX_BUILD_FAIL; grep -E "IMPL_FAILED|Placer|ERROR:|VALIDATE_FAILED|BYTE_IMAGE_BUILD_FAILED" "$S/t85fix_buildimg.log" | tail -8; exit 1; }
grep -q "applying canary instrumentation overlay" "$B/build_byte_matlab.log" 2>/dev/null || { echo T85FIX_OVERLAY_MISSING; exit 1; }
# HARD GATE: canary read decode must exist in the generated ADDR DECODER (not the
# axi_lite protocol module -- lesson: first gate version grepped the wrong file and
# false-failed a good build). Word addrs: 0x170>>2=7'b1011100, 0x188>>2=7'b1100010.
AD="$B/hdl_prj_jupiter_composite/vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl/TxRxCompo_ip_addr_decoder.v"
grep -q "read_reg_beat_counter" "$AD" 2>/dev/null && grep -q "1100010" "$AD" 2>/dev/null \
  || { echo "T85FIX_AXI_MAP_MISSING -- canary decode not in addr_decoder"; exit 1; }
echo "  AXI map gate: canary decode present in generated wrapper"
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
vivado -mode batch -nolog -nojournal -source "$K/bd_tap_dualdma.tcl" -tclargs ch1 > step_dualdma.log 2>&1 || { echo T85FIX_DUALDMA_FAIL; tail -5 step_dualdma.log; exit 1; }
grep -q DUALDMA_VALIDATE_OK step_dualdma.log || { echo T85FIX_DUALDMA_VALIDATE_FAIL; tail -5 step_dualdma.log; exit 1; }
vivado -mode batch -nolog -nojournal -source clear_incr.tcl > step_ci.log 2>&1
vivado -mode batch -nolog -nojournal -source "$K/ch2_build2.tcl" > step_ch2build.log 2>&1
if [ -f "$BB" ]; then
  SZ=$(stat -c %s "$BB"); [ "$SZ" -gt 6000000 ] && echo "T85FIX_IMAGE_DONE md5=$(md5sum "$BB"|cut -c1-32) size=$SZ" || echo "T85FIX_IMAGE_SMALL size=$SZ"
else echo T85FIX_DUALDMA_NOBOOT; tail -5 step_ch2build.log; exit 1; fi
