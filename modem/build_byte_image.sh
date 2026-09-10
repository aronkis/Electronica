#!/bin/bash
# build_byte_image.sh -- build the G2 BYTE image in a fresh dir.
#   [1] fresh kit copy -> FRESH   [2] KITDIR repoint
#   [3] MATLAB build_variant_byte (byte assemble + byte reference-design IP core;
#       CreateProject EXPECTED to fail on the insert-path bug)
#   [4] Vivado completion: complete_byte_t8.tcl (stock DAC wiring + 9 byte
#       DUT<->breakout connects) -> synth/impl/bootgen
# Output: <FRESH>/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
set -u
KIT=$(cd "$(dirname "$0")" && pwd)
# Default target = the SANCTIONED rxfix build dir (was jupiter_byte_build, the
# pre-rxfix tree -- a footgun). Pass an explicit dir as $1 to override (e.g. the
# build_image.sh verification build uses a fresh jupiter_byte_verify_build).
FRESH=${1:-$(dirname "$KIT")/jupiter_byte_rxfix_build}
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/tools/Xilinx/2025.1/Vivado/bin:/usr/bin:/bin:$PATH

echo "=== [1/4] fresh kit copy -> $FRESH ==="
rm -rf "$FRESH"; mkdir -p "$FRESH"
rsync -a --exclude 'hdl_prj_*' --exclude 'slprj' --exclude '*.log' --exclude '*.out' \
  --exclude 'rtl_sim/obj_*' --exclude 's1_rtl' "$KIT/" "$FRESH/"
echo "=== [2/4] KITDIR repoint ==="
for f in "$FRESH"/*.m; do sed -i "s#$KIT#$FRESH#g" "$f"; done

echo "=== [3/4] MATLAB build_variant_byte (byte assemble + IP core; CreateProject fail EXPECTED) ==="
( cd "$FRESH" && timeout 5400 matlab -batch "cd('$FRESH'); build_variant_byte" ) > "$FRESH/build_byte_matlab.log" 2>&1
echo "  matlab exit=$? (nonzero at Create Project is expected)"
Z="$FRESH/hdl_prj_jupiter_composite/vivado_ip_prj"
[ -f "$Z/vivado_prj.xpr" ] || { echo "FATAL: no vivado project produced"; tail -20 "$FRESH/build_byte_matlab.log"; exit 1; }
[ -f "$Z/ipcore/TxRxCompo_ip_v1_0.zip" ] || { echo "FATAL: no ipcore zip"; exit 1; }
# confirm the byte reference design produced the byte DMA blocks in the BD
if ! grep -q 'byte_breakout' "$Z/vivado_prj.srcs/sources_1/bd/system/system.bd" 2>/dev/null; then
  echo "FATAL: BD has no byte_breakout -- wrong reference design (byte maps not applied)"; exit 1
fi
echo "  byte reference-design BD confirmed (byte_breakout present)"

# T8.9 TMR guard: annotate the triplicated accumulator regs with dont_touch in the
# GENERATED RTL before Vivado sees them. XDC DONT_TOUCH is too late -- synthesis
# merges the three copies during optimization (measured: only Delay14C survived,
# voter cells = 0, i.e. the fix was silently deleted from the bitstream).
if [ -n "${QPSK_MOVSUM_TMR:-}" ]; then
  bash "$(dirname "$0")/tmr_attr_inject.sh" "$FRESH" || { echo "TMR_ATTR_FAILED"; exit 1; }
fi

echo "=== [4/4] Vivado completion (stock wiring + byte connects) ==="
( cd "$Z" && timeout 14400 vivado -mode batch -notrace -source "$FRESH/complete_byte_t8.tcl" ) > "$FRESH/build_byte_vivado.log" 2>&1
grep -E 'WIRE_OK|WIRE_FAIL|BYTE_WIRE_OK|BYTE_FAIL|VALIDATE_OK|VALIDATE_FAILED|BYTE_BUILD_DONE|SYNTH_FAILED|IMPL_FAILED' "$FRESH/build_byte_vivado.log" | tail -6
B="$Z/boot/BOOT.BIN"
if [ -f "$B" ]; then echo "BYTE_IMAGE_BUILD_DONE md5=$(md5sum "$B" | cut -c1-12)"; else echo "BYTE_IMAGE_BUILD_FAILED"; exit 1; fi
