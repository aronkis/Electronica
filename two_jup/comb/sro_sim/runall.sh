#!/bin/bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
B=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_byte_sro/Vwrap_byte_sro
N=8139780
for tag in p000 p063 m063 p126 n063 p10; do
  ( $B rx s_$tag.iq $N 8400 r_$tag 2 0 > r_$tag.log 2>&1 ; echo "LEGDONE $tag $?" ) &
done
wait
echo RUNALL_DONE
