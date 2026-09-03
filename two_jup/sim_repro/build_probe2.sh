#!/bin/bash
# waits for the DMAC-probe image, clones its project, splices rx_seam_checker, rebuilds.
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem; P1=$ROOT/jupiter_byte_dmacprobe_build; P2=$ROOT/jupiter_byte_probe2_build; Z=$P2/hdl_prj_jupiter_composite/vivado_ip_prj
export PATH=/tools/Xilinx/2025.1/Vivado/bin:/usr/bin:/bin
until grep -q "DMACPROBE_BUILD end" $P1/build_dmacprobe.log 2>/dev/null; do sleep 60; done
grep -q DMACPROBE_IMAGE_DONE $P1/build_dmacprobe.log || { echo "PROBE2_BUILD_ABORT: probe1 build failed"; exit 1; }
echo "PROBE2_BUILD start $(date -Is)"
rm -rf $P2; rsync -a --exclude '*.log' $P1/ $P2/ || exit 1
cp $ROOT/jupiter_240k5_byte/rtl_sim/rx_seam_checker.v $P2/; cp /tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad/resynth_probe2.tcl $P2/
rm -f $Z/boot/BOOT.BIN
( cd "$Z" && timeout 14400 vivado -mode batch -notrace -source "$P2/resynth_probe2.tcl" ) > "$P2/build_probe2_vivado.log" 2>&1
grep -E 'RXCHK_WIRE_OK|VALIDATE_OK|SYNTH_FAILED|IMPL_FAILED|TIMING_GATE_(PASS|FAIL|WNS)|BYTE_BUILD_DONE|^ERROR' "$P2/build_probe2_vivado.log" | tail -8
R=$Z/vivado_prj.runs/impl_1
grep -A3 "Design Timing Summary" $R/system_top_timing_summary_routed.rpt 2>/dev/null | tail -1
[ -f "$Z/boot/BOOT.BIN" ] && echo "PROBE2_IMAGE_DONE md5=$(md5sum $Z/boot/BOOT.BIN | cut -c1-12)" || echo "PROBE2_BUILD_FAILED"
echo "PROBE2_BUILD end $(date -Is)"
