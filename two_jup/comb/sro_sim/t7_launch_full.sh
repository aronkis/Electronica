#!/bin/bash
# [sim] Task 7: wait for the 432-frame TGEN capture to finish, certify it complete and
# non-tiled, then launch the DECISIVE baseline non-repeating legs.
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
while systemctl --user is-active --quiet t7txcap; do sleep 15; done
echo "T7_TXCAP_FINISHED $(tail -1 t7_txcap.log)"
NF=$(( $(stat -c%s tx432.iq) / 4 / 49332 ))
REP=$(awk -F, 'NR>1 && $4==1' tx432.iq.frames.txt | wc -l)
ZER=$(awk -F, 'NR>1 && $5==1' tx432.iq.frames.txt | wc -l)
SEQ=$(tail -1 tx432.iq.frames.txt | cut -d, -f2)
echo "T7_CAPTURE_CERT frames=$NF repeat_frames=$REP allzero_frames=$ZER last_seq=$SEQ"
if [ "$REP" != "0" ] || [ "$ZER" != "0" ]; then echo "T7_CAPTURE_CERT_FAIL"; exit 1; fi
N=$((NF-4))
TAGS="p000 m2p5 m10 m40" ./runall_t7.sh $N
