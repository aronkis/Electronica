#!/bin/bash
export PATH=/tools/Xilinx/2025.1/Vivado/bin:/usr/bin:/bin
Z=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_probe4_build/hdl_prj_jupiter_composite/vivado_ip_prj
echo "PROBE4_BUILD start $(date -Is)"; rm -f $Z/boot/BOOT.BIN
( cd "$Z" && timeout 14400 vivado -mode batch -notrace -source "/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_probe4_build/resynth_probe4.tcl" ) > "/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_probe4_build/build_probe4_vivado.log" 2>&1
grep -E 'TXSTARVE_WIRE_OK|VALIDATE_OK|SYNTH_FAILED|IMPL_FAILED|TIMING_GATE_(PASS|FAIL)|BYTE_BUILD_DONE|^ERROR' "/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_probe4_build/build_probe4_vivado.log" | tail -8
grep -A3 "Design Timing Summary" $Z/vivado_prj.runs/impl_1/system_top_timing_summary_routed.rpt 2>/dev/null | tail -1
[ -f "$Z/boot/BOOT.BIN" ] && echo "PROBE4_IMAGE_DONE md5=$(md5sum $Z/boot/BOOT.BIN | cut -c1-12)" || echo "PROBE4_BUILD_FAILED"
echo "PROBE4_BUILD end $(date -Is)"
