#!/bin/bash
# build_beat_sim.sh -- netlist matching the flashed TXMARK image + two Verilator builds.
#   obj_beat_fast : ports only, -O2, --threads 4         (long unforced run)
#   obj_beat_flat : --public-flat-rw --savable --trace-fst (state dump / checkpoint / trace)
# Run from jupiter_240k5_byte/rtl_sim. Idempotent: skips a build whose binary exists unless FORCE=1.
set -eu
cd "$(dirname "$0")"
VD=s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback
if [ ! -d s1_rtl_txmark ] || [ "${FORCE:-0}" = 1 ]; then
  rm -rf s1_rtl_txmark && cp -a s1_rtl_final s1_rtl_txmark
  TXMARK=1 python3 ../../two_jup/skidfix/ddrcap_inject.py s1_rtl_txmark
  grep -q "Transmitter_txFrameStart" "$VD/TxRxComposite.v" || { echo "TXMARK marker not injected"; exit 1; }
fi
COMMON="-O2 -Wno-fatal --cc --exe --build --top-module wrap_byte_ddrcap -y $VD -y . wrap_byte_ddrcap.v"
# one driver (one main) per verilator call / per -Mdir
if [ ! -x obj_beat_fast/Vwrap_byte_ddrcap ] || [ "${FORCE:-0}" = 1 ]; then
  verilator $COMMON --threads 4 -CFLAGS "-O2" -Mdir obj_beat_fast \
    sim_beat_long.cpp -o Vwrap_byte_ddrcap 2>&1 | tail -3
fi
if [ ! -x obj_beat_flat/Vwrap_byte_ddrcap ] || [ "${FORCE:-0}" = 1 ]; then
  verilator $COMMON --public-flat-rw --savable --trace-fst -CFLAGS "-O2 -DBEAT_FLAT" -Mdir obj_beat_flat \
    sim_beat_long.cpp -o Vwrap_byte_ddrcap 2>&1 | tail -3
fi
# obj_golden : golden per-tap DDR record stream generator, no register access needed, but
#   NF=220 runs are ~45 Mclk each -- built with --threads 4 (like obj_beat_fast) so the four
#   campaign selectors finish in a practical wall-clock time when run concurrently.
if [ ! -x obj_golden/Vgolden ] || [ "${FORCE:-0}" = 1 ]; then
  verilator $COMMON --threads 4 -CFLAGS "-O2" -Mdir obj_golden sim_golden_taps.cpp -o Vgolden 2>&1 | tail -3
fi
ls -la obj_beat_fast/Vwrap_byte_ddrcap obj_beat_flat/Vwrap_byte_ddrcap obj_golden/Vgolden
