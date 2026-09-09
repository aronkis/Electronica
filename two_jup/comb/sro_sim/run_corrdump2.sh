#!/bin/bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
B=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_corr/Vwrap_corr
$B s_m10.iq 3000000 8400 d_m10 2 0 > d_m10.log 2>&1
echo "CORRDUMP2_DONE $?"
