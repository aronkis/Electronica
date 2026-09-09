#!/bin/bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
B=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_ring/Vwrap_ring
$B s_m10.iq 2600000 8400 c_m10 2 0 64 > c_m10_ring.log 2>&1
echo "RINGDUMP_DONE $?"
