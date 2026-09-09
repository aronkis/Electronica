#!/bin/bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
B=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_ring/Vwrap_ring
# window mode: WIN = -(start sample).  Frame 37 starts at 37*49332 = 1825284.
$B s_m10.iq 2200000 8400 h_m10 2 0 -1825284 > h_m10.log 2>&1
echo "RINGWIN_DONE $?"
