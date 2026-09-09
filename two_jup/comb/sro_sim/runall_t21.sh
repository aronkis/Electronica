#!/bin/bash
# [sim] Task 21 (RXFIX_R4E) gate legs.  Pre-registration: two_jup/comb/RXFIX_R4E_SIM_GATE.md
#   runall_t21.sh                 -- all seven legs
#   LEGS="p10 m10" runall_t21.sh  -- a subset
#
# NO baseline is re-run: b_p000/b_m10/b_m40/tb_m10 are task 7's, t_lol is task 6's, and
# b_m10c/b_p10 were run by task 12b.  R4B's own delivered streams (r4b_*_deliv.txt) are
# banked too, which is what the K1/K6 byte-identity rows compare against.
#
# Two plusargs, both past everything sim_sro.cpp parses (Verilated::commandArgs is the
# only consumer, so the driver is unaffected):
#   +r4ewin=<pfx>_win.txt     one line per steered event (kind 0 = skip, 1 = DROP), and
#                             for a drop its MEASURED landing slot from both the RTL
#                             witness and an independent pointer-based recount
#   +r4eper=<pfx>_period.txt  one line per pcEnd: the interval in VALIDATED POPS, the
#                             precondition the drop schedule rests on
set -u -o pipefail
cd "$(dirname "$0")"
K=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
B=$K/obj_byte_sro_rxfix4e/Vwrap_byte_sro     # RXFIX_R4E tree + task-7 sim_sro.cpp
test -x "$B"  || { echo "T21_FAIL no R4E binary at $B"; exit 1; }
N=428; NS=$((N*49332))      # 21,114,096 -- identical to every task 7 baseline leg
NST=8139780                 # tiled control: identical nsamp to task 7's tb_m10
NSL=20519440                # loss-of-lock control: identical nsamp to task 6's t_lol
LEGS=${LEGS:-"p000 m10 m40 tm10 m10c p10 lol"}
for tag in $LEGS; do
  case $tag in
    p000) iq=n_p000.iq;      ns=$NS;  pfx=r4e_p000;;
    m10)  iq=n_m10.iq;       ns=$NS;  pfx=r4e_m10;;
    m40)  iq=n_m40.iq;       ns=$NS;  pfx=r4e_m40;;
    tm10) iq=s_m10.iq;       ns=$NST; pfx=r4e_tm10;;
    m10c) iq=n_m10c.iq;      ns=$NS;  pfx=r4e_m10c;;
    p10)  iq=n_p10.iq;       ns=$NS;  pfx=r4e_p10;;
    lol)  iq=s_m2p5_lol.iq;  ns=$NSL; pfx=r4e_lol;;
    *) echo "T21_FAIL unknown leg $tag"; exit 1;;
  esac
  test -f "$iq" || { echo "T21_FAIL missing stimulus $iq"; exit 1; }
  rm -f "t21_$tag.log" "${pfx}_win.txt" "${pfx}_period.txt"
  systemctl --user reset-failed "t21_$tag" 2>/dev/null
  systemd-run --user --collect --unit="t21_$tag" -p WorkingDirectory="$PWD" \
    -p StandardOutput=append:"$PWD/t21_$tag.log" \
    -p StandardError=append:"$PWD/t21_$tag.log" \
    "$B" rx "$iq" "$ns" 8400 "$pfx" 2 0 \
    "+r4ewin=${pfx}_win.txt" "+r4eper=${pfx}_period.txt" || exit 1
done
echo "T21_LEGS_LAUNCHED legs='$LEGS' nsamp=$NS tiled=$NST lol=$NSL"
