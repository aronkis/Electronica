#!/bin/bash
# [sim] Task 6 (T2): RXFIX_R2 (frame-sync flywheel) sim gate + loss-of-lock controls.
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
BB=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_byte_sro/Vwrap_byte_sro
B2=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_byte_sro_rxfix2/Vwrap_byte_sro
( $B2 rx s_p000.iq      8139780 8400 g_p000 2 0 > g_p000.log 2>&1; echo "LEGDONE g_p000 $?" ) &
( $B2 rx s_m2p5.iq     20719440 8400 g_m2p5 2 0 > g_m2p5.log 2>&1; echo "LEGDONE g_m2p5 $?" ) &
( $B2 rx s_m10.iq      10359720 8400 g_m10  2 0 > g_m10.log  2>&1; echo "LEGDONE g_m10 $?"  ) &
( $B2 rx s_p2p5_920.iq 45385440 8400 g_p2p5 2 0 > g_p2p5.log 2>&1; echo "LEGDONE g_p2p5 $?" ) &
# loss-of-lock control (4.05 air frames deleted at frame 200): fix and baseline
( $B2 rx s_m2p5_lol.iq 20519440 8400 g_lol  2 0 > g_lol.log  2>&1; echo "LEGDONE g_lol $?"  ) &
( $BB rx s_m2p5_lol.iq 20519440 8400 t_lol  2 0 > t_lol.log  2>&1; echo "LEGDONE t_lol $?"  ) &
wait; echo RUNALL_T6R2_DONE
