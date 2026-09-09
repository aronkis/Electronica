#!/bin/bash
# [sim] Task 7 (T2b): NON-REPEATING-stimulus SRO legs, baseline and RXFIX_R3.
#   runall_t7.sh <nframes>
# Stimulus: tx432.iq (TGEN v2, incrementing seq + PN(seq) payload, gap 20000 =
# exactly one emitted frame per air slot, certified non-tiled by --no-tile).
set -u -o pipefail
cd "$(dirname "$0")"
N=${1:-430}
# p10 is included deliberately: at +2.5 ppm the ring's first FULL edge is ~876
# frames away (RATE_HANDLE_FIX_SURVEY.md 6), so a +2.5 leg cannot gate R3's
# occ >= 30 extra-pop branch. +10 ppm reaches FULL near frame 220 and laps every
# ~260, so it gates the FULL branch inside 430 frames.
TAGS=${TAGS:-"p000 m2p5 m10 p2p5 p10"}
K=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
BB=$K/obj_byte_sro/Vwrap_byte_sro           # baseline tree
B3=$K/obj_byte_sro_rxfix3/Vwrap_byte_sro    # RXFIX_R3 tree
NS=$((N*49332))
for tag in $TAGS; do
  case $tag in p000) ppm=0;; m2p5) ppm=-2.5;; m10) ppm=-10;; m40) ppm=-40;; p2p5) ppm=2.5;; p10) ppm=10;; esac
  python3 gen_sro_stim.py tx432.iq n_$tag.iq --ppm $ppm --frames $N --no-tile || exit 1
done
for tag in $TAGS; do
  systemd-run --user --collect --unit=t7leg_b_$tag --working-directory="$PWD" \
    -p StandardOutput=append:"$PWD/t7_b_$tag.log" -p StandardError=append:"$PWD/t7_b_$tag.log" \
    $BB rx n_$tag.iq $NS 8400 b_$tag 2 0
  systemd-run --user --collect --unit=t7leg_r_$tag --working-directory="$PWD" \
    -p StandardOutput=append:"$PWD/t7_r_$tag.log" -p StandardError=append:"$PWD/t7_r_$tag.log" \
    $B3 rx n_$tag.iq $NS 8400 r3_$tag 2 0
done
echo "T7_LEGS_LAUNCHED nframes=$N nsamp=$NS"
