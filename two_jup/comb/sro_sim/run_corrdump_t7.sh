#!/bin/bash
# [sim] Task 7: correlator magnitude + threshold dump on the NON-REPEATING -10 ppm
# leg.  Baseline tree, unchanged from task 6 (obj_corr), so this is the direct
# non-repeating counterpart of d_m10_corr.txt.
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
B=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_corr/Vwrap_corr
$B n_m10.iq 3000000 8400 t7d_m10 2 0 > t7d_m10.log 2>&1
echo "T7_CORRDUMP_DONE $?"
