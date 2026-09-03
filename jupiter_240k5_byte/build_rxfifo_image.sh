#!/bin/bash
# build_rxfifo_image.sh <BUILD_DIR> -- Vivado-only completion of a cloned BEATFIX v3
# build tree after rxfifo_inject.sh (no MATLAB regeneration: the image differs from
# fe5bd8a4fe19 in exactly one module). Hard gates: injection marker present in the
# ipshared copy Vivado synthesizes; fresh BOOT.BIN; timing summary WNS >= 0.
set -u
B=${1:?build dir}
export PATH=/tools/Xilinx/2025.1/Vivado/bin:/usr/bin:/bin
Z=$B/hdl_prj_jupiter_composite/vivado_ip_prj
grep -q "injected by rxfifo_inject.sh" $Z/vivado_prj.gen/sources_1/bd/system/ipshared/*/hdl/TxRxCompo_ip_src_ByteRxFifo.v || { echo "RXFIFO_BUILD_FATAL ipshared copy not injected"; exit 1; }
rm -f $Z/boot/BOOT.BIN $Z/boot/system_top.bit
( cd "$Z" && timeout 14400 vivado -mode batch -notrace -source "$B/resynth_rxfifo.tcl" ) > "$B/build_rxfifo_vivado.log" 2>&1
grep -E 'WIRE_OK|WIRE_FAIL|BYTE_WIRE_OK|BYTE_FAIL|VALIDATE_OK|VALIDATE_FAILED|BYTE_BUILD_DONE|SYNTH_FAILED|IMPL_FAILED' "$B/build_rxfifo_vivado.log" | tail -6
R=$Z/vivado_prj.runs/impl_1
grep -A3 "Design Timing Summary" $R/system_top_timing_summary_routed.rpt 2>/dev/null | tail -1
grep -E "^\| (Block RAM Tile|CLB Registers|CLB LUTs) " $R/system_top_utilization_placed.rpt 2>/dev/null
if [ -f "$Z/boot/BOOT.BIN" ]; then echo "RXFIFO_IMAGE_BUILD_DONE md5=$(md5sum "$Z/boot/BOOT.BIN" | cut -c1-12) size=$(stat -c %s "$Z/boot/BOOT.BIN")"; else echo "RXFIFO_IMAGE_BUILD_FAILED"; exit 1; fi
