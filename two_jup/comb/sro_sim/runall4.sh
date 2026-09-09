#!/bin/bash
# [sim] T0a extended +2.5 ppm leg, 920 frames (FULL edge predicted ~f=876).
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
B=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_byte_sro/Vwrap_byte_sro
$B rx s_p2p5_920.iq 45385440 8400 q_p2p5 2 0 > q_p2p5.log 2>&1
echo "LEGDONE p2p5 $?"
echo RUNALL4_DONE
