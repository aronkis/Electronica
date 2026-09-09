#!/bin/bash
# [sim] Task 11 (RXFIX_R3S) gate legs.  Pre-registration: two_jup/comb/RXFIX_R3S_SIM_GATE.md
#   runall_t11.sh            -- the four gate legs
#   LEGS="p000" runall_t11.sh
# Baselines b_p000 / b_m10 / b_m40 / tb_m10 are Task 7's and are NOT re-run.
set -u -o pipefail
cd "$(dirname "$0")"
K=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
B=$K/obj_byte_sro_rxfix3s/Vwrap_byte_sro       # RXFIX_R3S tree + task-7 sim_sro.cpp
test -x "$B" || { echo "T11_FAIL no R3S binary at $B"; exit 1; }
N=428                       # air frames, identical to task 7's baseline legs
NS=$((N*49332))             # 21,114,096
NST=8139780                 # tiled control: identical nsamp to task 7's tb_m10
LEGS=${LEGS:-"p000 m10 m40 tm10"}
for tag in $LEGS; do
  case $tag in
    p000) iq=n_p000.iq; ns=$NS;;
    m10)  iq=n_m10.iq;  ns=$NS;;
    m40)  iq=n_m40.iq;  ns=$NS;;
    tm10) iq=s_m10.iq;  ns=$NST;;
    *) echo "T11_FAIL unknown leg $tag"; exit 1;;
  esac
  test -f "$iq" || { echo "T11_FAIL missing stimulus $iq"; exit 1; }
  rm -f "t11_s_$tag.log"
  systemd-run --user --collect --unit="t11_$tag" -p WorkingDirectory="$PWD" \
    -p StandardOutput=append:"$PWD/t11_s_$tag.log" \
    -p StandardError=append:"$PWD/t11_s_$tag.log" \
    "$B" rx "$iq" "$ns" 8400 "s_$tag" 2 0 || exit 1
done
echo "T11_LEGS_LAUNCHED legs='$LEGS' nframes=$N nsamp=$NS nsamp_tiled=$NST"
