#!/bin/bash
# build_iq_instruments.sh -- build the three IQ-replay instruments against the
# CURRENT generated netlist (s1_rtl/hdlsrc): per-frame verdict, CFC jitter log,
# and per-stage taps. Sibling of build_replay_iq.sh.
set -e -o pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
export PATH=/usr/local/bin:/usr/bin:/bin
VD=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
test -f "$VD/TxRxComposite.v" || { echo "FATAL: netlist missing ($VD)" >&2; exit 1; }
cd "$KIT/rtl_sim"

rm -rf obj_iq_perframe
verilator -O2 -Wno-fatal --cc wrap_byte.v -y "$VD" --exe sim_byte_iq_perframe.cpp -Mdir obj_iq_perframe --top-module wrap_byte
make -s -C obj_iq_perframe -f Vwrap_byte.mk Vwrap_byte
echo "BUILT obj_iq_perframe/Vwrap_byte (perframe)"

rm -rf obj_iq_cfclog
verilator -O2 -Wno-fatal --cc wrap_byte.v -y "$VD" --exe sim_byte_iq_cfclog.cpp -Mdir obj_iq_cfclog --top-module wrap_byte
make -s -C obj_iq_cfclog -f Vwrap_byte.mk Vwrap_byte
echo "BUILT obj_iq_cfclog/Vwrap_byte (cfclog)"

rm -rf obj_iq_taps
verilator -O2 -Wno-fatal --cc wrap_byte_taps.v -y "$VD" --exe sim_byte_taps.cpp -Mdir obj_iq_taps --top-module wrap_byte_taps
make -s -C obj_iq_taps -f Vwrap_byte_taps.mk Vwrap_byte_taps
echo "BUILT obj_iq_taps/Vwrap_byte_taps (taps)"
echo INSTRUMENTS_BUILT_DONE
