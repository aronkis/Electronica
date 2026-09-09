#!/bin/bash
# [sim] Task 12b (RXFIX_R4B) gate legs.  Pre-registration: two_jup/comb/RXFIX_R4B_SIM_GATE.md
#   runall_t12b.sh                 -- all nine legs
#   LEGS="p000 m10" runall_t12b.sh -- a subset
#
# Baselines b_p000 / b_m10 / b_m40 / tb_m10 (task 7) and t_lol (task 6) are NOT re-run.
# Two baselines ARE run, because their stimuli are new and there is nothing banked:
#   b_m10c  -- the +20 kHz CFO leg's control (G13; without it G12 is uninterpretable)
#   b_p10   -- the +10 ppm control (G14 compares R4B against it)
# Both use TASK 7's UNMODIFIED binary obj_byte_sro/Vwrap_byte_sro.
#
# The R4B legs pass +r4bwin=<pfx>_skipwin.txt: wrap_byte_sro4b.v writes one line per
# steered skip there (RTL window slot + an INDEPENDENT recount).  It is argv[8], past
# every argument sim_sro.cpp parses (cadence 2 / vphase 0 are passed explicitly, which
# is what the banked legs used), so the driver is unaffected -- Verilated::commandArgs
# is the only consumer.
set -u -o pipefail
cd "$(dirname "$0")"
K=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
B=$K/obj_byte_sro_rxfix4b/Vwrap_byte_sro     # RXFIX_R4B tree + task-7 sim_sro.cpp
BB=$K/obj_byte_sro/Vwrap_byte_sro            # task 7 BASELINE, unmodified
test -x "$B"  || { echo "T12B_FAIL no R4B binary at $B"; exit 1; }
test -x "$BB" || { echo "T12B_FAIL no baseline binary at $BB"; exit 1; }
N=428; NS=$((N*49332))      # 21,114,096 -- identical to every task 7 baseline leg
NST=8139780                 # tiled control: identical nsamp to task 7's tb_m10
NSL=20519440                # loss-of-lock control: identical nsamp to task 6's t_lol
LEGS=${LEGS:-"p000 m10 m40 tm10 m10c bm10c p10 bp10 lol"}
for tag in $LEGS; do
  bin=$B; win=1
  case $tag in
    p000) iq=n_p000.iq;      ns=$NS;  pfx=r4b_p000;;
    m10)  iq=n_m10.iq;       ns=$NS;  pfx=r4b_m10;;
    m40)  iq=n_m40.iq;       ns=$NS;  pfx=r4b_m40;;
    tm10) iq=s_m10.iq;       ns=$NST; pfx=r4b_tm10;;
    m10c) iq=n_m10c.iq;      ns=$NS;  pfx=r4b_m10c;;
    p10)  iq=n_p10.iq;       ns=$NS;  pfx=r4b_p10;;
    lol)  iq=s_m2p5_lol.iq;  ns=$NSL; pfx=r4b_lol;;
    bm10c) iq=n_m10c.iq;     ns=$NS;  pfx=b_m10c; bin=$BB; win=0;;
    bp10)  iq=n_p10.iq;      ns=$NS;  pfx=b_p10;  bin=$BB; win=0;;
    *) echo "T12B_FAIL unknown leg $tag"; exit 1;;
  esac
  test -f "$iq" || { echo "T12B_FAIL missing stimulus $iq"; exit 1; }
  rm -f "t12b_$tag.log" "${pfx}_skipwin.txt"
  systemctl --user reset-failed "t12b_$tag" 2>/dev/null
  if [ "$win" = 1 ]; then extra="+r4bwin=${pfx}_skipwin.txt"; else extra=""; fi
  systemd-run --user --collect --unit="t12b_$tag" -p WorkingDirectory="$PWD" \
    -p StandardOutput=append:"$PWD/t12b_$tag.log" \
    -p StandardError=append:"$PWD/t12b_$tag.log" \
    "$bin" rx "$iq" "$ns" 8400 "$pfx" 2 0 $extra || exit 1
done
echo "T12B_LEGS_LAUNCHED legs='$LEGS' nsamp=$NS tiled=$NST lol=$NSL"
