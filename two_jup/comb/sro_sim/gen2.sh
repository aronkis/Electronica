#!/bin/bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
python3 gen_sro_stim.py tx5.iq s_m2p5.iq --ppm -2.5 --frames 420 &
python3 gen_sro_stim.py tx5.iq s_p2p5.iq --ppm 2.5  --frames 420 &
python3 gen_sro_stim.py tx5.iq s_m10.iq  --ppm -10  --frames 210 &
wait; echo GEN2_DONE
