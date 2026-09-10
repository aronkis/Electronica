#!/bin/bash
# build_ch2_image.sh <src_build_dir> [dst_build_dir] -- derive the CHANNEL-2
# image from a COMPLETED ch1 build (campaign B2, proven trackB-era recipe):
# copy the built Vivado project, retarget the modem from adc_1/dac_1 to
# adc_2/dac_2 (bd_ch2_rewire: datapath+clocks; bd_ch2_reset: reset domains;
# ch2_fix_ch1: restore ch1 as a plain DMA channel -- MANDATORY, undriven
# dac_1_data* fails opt_design), then reset all runs, synth+impl+bootgen
# (ch2_build2). Costs one re-synth (~70 min), reuses the src build's IP core.
#
# After this image is flashed: the modem rides RX2/TX2 (in/out_voltage1 attrs,
# TX2_LO=out_altvoltage3, RX2_LO=out_altvoltage1). The modem's debug-tap capture
# stays on axi-adrv9002-rx-lpc (rx1 DMA, the only 4-iio-channel device; moved to
# the adc_2 clock domain by bd_ch2_tapfix); rx2-lpc carries raw ADC2 (2 ch).
# DAC-mux debugfs regs (0x418/0x458/0x044) target axi-adrv9002-tx2-lpc.
set -e -o pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
export PATH=/tools/Xilinx/2025.1/Vivado/bin:/usr/local/bin:/usr/bin:/bin
command -v vivado >/dev/null || { echo "FATAL: vivado not on PATH" >&2; exit 1; }
SRC=${1:?usage: build_ch2_image.sh <src_build_dir(completed ch1 build)> [dst_build_dir]}
DST=${2:-$(dirname "$KIT")/jupiter_byte_ch2tap_build}
SRCPRJ=$SRC/hdl_prj_jupiter_composite/vivado_ip_prj
test -f "$SRCPRJ/vivado_prj.xpr" || { echo "FATAL: no vivado project in $SRC" >&2; exit 1; }
test -f "$SRCPRJ/boot/BOOT.BIN" || { echo "FATAL: src build incomplete (no BOOT.BIN)" >&2; exit 1; }

# Vivado env (same as the byte build path)
ENVF=$(dirname "$KIT")/build_env_jupiter.sh
test -f "$ENVF" && source "$ENVF"

echo "=== [1/3] copy completed build $SRC -> $DST ==="
mkdir -p "$DST"
rsync -a --delete "$SRC/hdl_prj_jupiter_composite" "$DST/"
PRJ=$DST/hdl_prj_jupiter_composite/vivado_ip_prj
cd "$PRJ"
rm -f boot/BOOT.BIN   # never confuse the ch2 output with the ch1 input

echo "=== [2/3] ch2 BD retarget (rewire -> resets -> ch1 restore -> byte/tap fix) ==="
for T in bd_ch2_rewire.tcl bd_ch2_reset.tcl ch2_fix_ch1_bdonly.tcl bd_ch2_tapfix.tcl; do
  echo "--- $T ---"
  case $T in
    bd_ch2_rewire.tcl|bd_ch2_reset.tcl) ARGS="-tclargs vivado_prj.xpr";;
    *) ARGS="";;
  esac
  vivado -mode batch -nolog -nojournal -source "$KIT/$T" $ARGS > "step_$T.log" 2>&1 \
    || { echo "CH2_BUILD_FAIL: $T"; tail -25 "step_$T.log"; exit 1; }
  grep -E 'VALIDATE|CRITICAL WARNING|^ERROR' "step_$T.log" | head -6 || true
done

echo "=== [3/3] reset runs + synth + impl + bootgen (ch2_build2) ==="
# the copied project carries the src build's INCREMENTAL checkpoint; Vivado's
# guide-design graph differ SEGFAULTS on the rewired BD -- strip it first
cat > clear_incr.tcl <<'EOF'
open_project vivado_prj.xpr
foreach r [list synth_1 impl_1] {
  catch { set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs $r] }
  catch { set_property INCREMENTAL_CHECKPOINT {} [get_runs $r] }
}
puts "INCR_CLEARED"
EOF
vivado -mode batch -nolog -nojournal -source clear_incr.tcl > step_clear_incr.log 2>&1 \
  || { echo "CH2_BUILD_FAIL: clear_incr"; tail -15 step_clear_incr.log; exit 1; }
grep -q INCR_CLEARED step_clear_incr.log || { echo "CH2_BUILD_FAIL: incr not cleared"; exit 1; }
vivado -mode batch -nolog -nojournal -source "$KIT/ch2_build2.tcl" 2>&1 | tail -20

BOOT=$PRJ/boot/BOOT.BIN
SZ=$(stat -c %s "$BOOT" 2>/dev/null || echo 0)
[ "$SZ" -gt 6000000 ] || { echo "CH2_BUILD_FAIL: BOOT.BIN missing/small ($SZ)"; exit 1; }
echo "CH2_IMAGE_BUILD_DONE md5=$(md5sum "$BOOT" | cut -c1-32)  size=$SZ  path=$BOOT"
