#!/bin/bash
# [sim] Task 20 (RXFIX_R4D + RXFIX_R1 = "S1") gate legs.
# Pre-registration: two_jup/comb/RXFIX_S1_SIM_GATE.md (committed before any of this existed).
#
#   runall_t20.sh                 -- all seven legs
#   LEGS="p000 p10" runall_t20.sh -- a subset
#   SMOKE=1 runall_t20.sh         -- only the 25-air-frame smoke leg (sk4dr1_p000)
#
# NO baseline is re-run: b_p000/b_m10/b_m40/tb_m10/tb_p000 are task 7's, t_lol is task 6's,
# b_m10c/b_p10 are task 12b's, and r4b_*/r4d_* are task 12b's and task 14's.  Everything
# this script writes is prefixed r4dr1_ (or sk4dr1_ for the smoke leg).
#
# PROVENANCE, and why it needs care here.  The build deliberately reuses task 14's wrapper
# wrap_byte_sro4d.v and task 7's sim_sro.cpp UNMODIFIED, so an R4DR1 leg prints exactly the
# same WRAP4D_FILE / WRAP4D_DEFINE banner as a banked R4D leg.  This script therefore
# (a) asserts the binary is the R4DR1 one, (b) asserts its md5 DIFFERS from the R4D binary's,
# and (c) writes both md5s into every leg log before the unit starts.  The RUNTIME
# discriminator is pdOcc: R4D leaves the PD FIFO short (pdOcc_end 12331/12332), R1 pins it
# at 12333 -- see section 2.3 of the pre-registration.
set -u -o pipefail
cd "$(dirname "$0")"
K=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
B=$K/obj_byte_sro_rxfix4dr1/Vwrap_byte_sro    # RXFIX_R4D + RXFIX_R1 tree + task-7 sim_sro.cpp
B4D=$K/obj_byte_sro_rxfix4d/Vwrap_byte_sro    # task 14, for the md5 discriminator only
test -x "$B"   || { echo "T20_FAIL no R4DR1 binary at $B"; exit 1; }
test -x "$B4D" || { echo "T20_FAIL no R4D binary at $B4D (needed for the md5 check)"; exit 1; }
M=$(md5sum "$B" | cut -d' ' -f1); M4D=$(md5sum "$B4D" | cut -d' ' -f1)
[ "$M" != "$M4D" ] || { echo "T20_FAIL R4DR1 binary is byte-identical to the R4D binary"; exit 1; }
N=428; NS=$((N*49332))      # 21,114,096 -- identical to every task 7 baseline leg
NST=8139780                 # tiled control: identical nsamp to task 7's tb_m10
NSL=20519440                # loss-of-lock control: identical nsamp to task 6's t_lol
NSMOKE=1233300              # smoke: 25 air frames, identical nsamp to task 14's sk4d_p000
LEGS=${LEGS:-"p000 m10 m40 tm10 m10c p10 lol"}
[ "${SMOKE:-0}" = 1 ] && LEGS="smoke"
for tag in $LEGS; do
  case $tag in
    smoke) iq=n_p000.iq;      ns=$NSMOKE; pfx=sk4dr1_p000;;
    p000)  iq=n_p000.iq;      ns=$NS;  pfx=r4dr1_p000;;
    m10)   iq=n_m10.iq;       ns=$NS;  pfx=r4dr1_m10;;
    m40)   iq=n_m40.iq;       ns=$NS;  pfx=r4dr1_m40;;
    tm10)  iq=s_m10.iq;       ns=$NST; pfx=r4dr1_tm10;;
    m10c)  iq=n_m10c.iq;      ns=$NS;  pfx=r4dr1_m10c;;
    p10)   iq=n_p10.iq;       ns=$NS;  pfx=r4dr1_p10;;
    lol)   iq=s_m2p5_lol.iq;  ns=$NSL; pfx=r4dr1_lol;;
    *) echo "T20_FAIL unknown leg $tag"; exit 1;;
  esac
  test -f "$iq" || { echo "T20_FAIL missing stimulus $iq"; exit 1; }
  rm -f "t20_$tag.log" "${pfx}_skipwin.txt"
  systemctl --user reset-failed "t20_$tag" 2>/dev/null
  {
    echo "T20_BIN $B"
    echo "T20_MD5 r4dr1=$M r4d=$M4D"
    echo "T20_LEG $tag pfx=$pfx iq=$iq nsamp=$ns"
  } >> "t20_$tag.log"
  systemd-run --user --collect --unit="t20_$tag" -p WorkingDirectory="$PWD" \
    -p StandardOutput=append:"$PWD/t20_$tag.log" \
    -p StandardError=append:"$PWD/t20_$tag.log" \
    "$B" rx "$iq" "$ns" 8400 "$pfx" 2 0 "+r4dwin=${pfx}_skipwin.txt" || exit 1
done
echo "T20_LEGS_LAUNCHED legs='$LEGS' nsamp=$NS tiled=$NST lol=$NSL smoke=$NSMOKE md5=$M"
