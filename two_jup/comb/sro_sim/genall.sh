#!/bin/bash
set -e
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
G=gen_sro_stim.py
python3 $G tx5.iq s_p063.iq --ppm 0.63  --frames 165 &
python3 $G tx5.iq s_m063.iq --ppm -0.63 --frames 165 &
python3 $G tx5.iq s_p126.iq --ppm 1.26  --frames 165 &
python3 $G tx5.iq s_n063.iq --ppm 0.63  --frames 165 --esn0 15 --cfo 1260 &
python3 $G tx5.iq s_p10.iq  --ppm 10.0  --frames 165 &
wait
echo GENALL_DONE
