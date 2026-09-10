#!/bin/bash
# build_replay_iq.sh -- build the IQ-replay Verilator binary (sim_byte_iq.cpp)
# against the CURRENT generated netlist. Sibling of the S1B gate build in
# run_netlist_gates.sh (same verilator flags), different driver + obj dir.
# The result obj_byte_iq/Vwrap_byte replays a raw int16 I,Q capture through the
# bit-true TxRxComposite Rx (rx_input_select=1) -- the campaign's fixed-point leg.
set -e -o pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
export PATH=/usr/local/bin:/usr/bin:/bin
VD=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
test -f "$VD/TxRxComposite.v" || { echo "FATAL: netlist missing ($VD) -- run run_netlist_gates.sh first" >&2; exit 1; }
cd "$KIT/rtl_sim"
rm -rf obj_byte_iq
verilator -O2 -Wno-fatal --cc wrap_byte.v -y "$VD" --exe sim_byte_iq.cpp \
  -Mdir obj_byte_iq --top-module wrap_byte
make -s -C obj_byte_iq -f Vwrap_byte.mk Vwrap_byte
echo "BUILD_REPLAY_IQ_DONE $KIT/rtl_sim/obj_byte_iq/Vwrap_byte"
# P3 stage-tap variant (wrap_byte_taps.v + sim_byte_taps.cpp)
rm -rf obj_byte_taps
verilator -O2 -Wno-fatal --cc wrap_byte_taps.v -y "$VD" --exe sim_byte_taps.cpp \
  -Mdir obj_byte_taps --top-module wrap_byte_taps
make -s -C obj_byte_taps -f Vwrap_byte_taps.mk Vwrap_byte_taps
echo "BUILD_REPLAY_TAPS_DONE $KIT/rtl_sim/obj_byte_taps/Vwrap_byte_taps"
