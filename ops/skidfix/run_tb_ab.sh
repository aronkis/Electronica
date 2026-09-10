#!/bin/bash
# run_tb_ab.sh -- DMA-contract testbench full A/B (SKID_BUILD.md sim gate).
# Pure sim, reap-proof. Matrix: {m0,m1,m2} x {tick off,on}, 400 frames each,
# cold start mid-frame (widx=57). Verdicts:
#   POSITIVE CONTROL 1 (fault): m0+tick shows the ~57/s-class corruption.
#   POSITIVE CONTROL 2 (deadlock): m1 reproduces silicon wcnt=0 total stall.
#   FIX: m2+tick corrupt=0 AND delivered stream bitwise-identical to m0 clean.
set -u
D=/mnt/onetb/scratch/qpsk-jupiter-modem/ops/skidfix
cd "$D"
echo "TB_AB start $(date -Is) pid=$$"
iverilog -g2005 -o tb/tb_test tb/tb_dma_contract.v qpsk_axis_skid.v qpsk_axis_skid_v2.v || { echo TB_AB_FAILED compile; exit 1; }
for m in 0 1 2; do for t in 0 1; do
  echo "--- mode $m tick=$t ---"
  timeout 1800 vvp tb/tb_test +mode=$m +tick=$t +frames=400 +dump=tb/stream_m${m}_t${t}.txt 2>&1 | grep RESULT
done; done
echo "=== bitwise compares ==="
cmp -s tb/stream_m2_t0.txt tb/stream_m0_t0.txt && echo "BITWISE m2_clean == m0_clean : IDENTICAL" || echo "BITWISE m2_clean vs m0_clean : DIFFER"
cmp -s tb/stream_m2_t1.txt tb/stream_m0_t0.txt && echo "BITWISE m2_tick  == m0_clean : IDENTICAL" || echo "BITWISE m2_tick  vs m0_clean : DIFFER"
wc -l tb/stream_m*_t*.txt
echo "TB_AB_DONE $(date -Is)"
