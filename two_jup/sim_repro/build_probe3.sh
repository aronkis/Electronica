#!/bin/bash
export PATH=/tools/Xilinx/2025.1/Vivado/bin:/usr/bin:/bin
Z=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_probe3_build/hdl_prj_jupiter_composite/vivado_ip_prj
echo "PROBE3_BUILD start $(date -Is)"; rm -f $Z/boot/BOOT.BIN
( cd "$Z" && timeout 14400 vivado -mode batch -notrace -source "/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_probe3_build/resynth_probe3.tcl" ) > "/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_probe3_build/build_probe3_vivado.log" 2>&1
grep -E 'RXCHK3_WIRE_OK|VALIDATE_OK|SYNTH_FAILED|IMPL_FAILED|TIMING_GATE_(PASS|FAIL)|BYTE_BUILD_DONE|^ERROR' "/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_probe3_build/build_probe3_vivado.log" | tail -8
[ -f "$Z/boot/BOOT.BIN" ] && echo "PROBE3_IMAGE_DONE md5=$(md5sum $Z/boot/BOOT.BIN | cut -c1-12)" || echo "PROBE3_BUILD_FAILED"
echo "PROBE3_BUILD end $(date -Is)"
