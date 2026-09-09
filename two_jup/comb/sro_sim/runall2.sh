#!/bin/bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
B=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_byte_sro/Vwrap_byte_sro
( $B rx s_m2p5.iq 20719440 8400 q_m2p5 2 0 > q_m2p5.log 2>&1; echo "LEGDONE m2p5 $?" ) &
( $B rx s_p2p5.iq 20719440 8400 q_p2p5 2 0 > q_p2p5.log 2>&1; echo "LEGDONE p2p5 $?" ) &
( $B rx s_m10.iq  10359720 8400 q_m10  2 0 > q_m10.log  2>&1; echo "LEGDONE m10 $?"  ) &
wait; echo RUNALL2_DONE
