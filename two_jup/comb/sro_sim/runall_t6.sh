#!/bin/bash
# [sim] Task 6 (T2): RXFIX_R1 sim gate + baseline trace legs.
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
BB=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_byte_sro/Vwrap_byte_sro
BF=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_byte_sro_rxfix/Vwrap_byte_sro
# --- fix legs ---
( $BF rx s_p000.iq      8139780 8400 f_p000 2 0 > f_p000.log 2>&1; echo "LEGDONE f_p000 $?" ) &
( $BF rx s_m2p5.iq     20719440 8400 f_m2p5 2 0 > f_m2p5.log 2>&1; echo "LEGDONE f_m2p5 $?" ) &
( $BF rx s_m10.iq      10359720 8400 f_m10  2 0 > f_m10.log  2>&1; echo "LEGDONE f_m10 $?"  ) &
( $BF rx s_p2p5_920.iq 45385440 8400 f_p2p5 2 0 > f_p2p5.log 2>&1; echo "LEGDONE f_p2p5 $?" ) &
# --- baseline legs re-run with the T2 trace taps (RTL unchanged; _ep.txt is new) ---
( $BB rx s_p000.iq      8139780 8400 t_p000 2 0 > t_p000.log 2>&1; echo "LEGDONE t_p000 $?" ) &
( $BB rx s_m2p5.iq     20719440 8400 t_m2p5 2 0 > t_m2p5.log 2>&1; echo "LEGDONE t_m2p5 $?" ) &
( $BB rx s_m10.iq      10359720 8400 t_m10  2 0 > t_m10.log  2>&1; echo "LEGDONE t_m10 $?"  ) &
wait; echo RUNALL_T6_DONE
