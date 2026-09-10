#!/bin/bash
# build_txrate_sim.sh -- build txrate_probe.cpp against the TXMARK netlist (same recipe as
# build_txkick_sim.sh).  Host-only, no board.
set -e
cd "$(dirname "$0")"
rm -rf obj_txrate2
verilator -O2 -Wno-fatal --cc --exe --build --public-flat-rw --top-module wrap_byte_ddrcap \
  -y s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback -y . \
  wrap_byte_ddrcap.v txrate_probe.cpp \
  -Mdir obj_txrate2 -o Vtxrate2
echo "TXRATE_BUILD_EXIT $?"
