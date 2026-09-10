#!/bin/bash
# build_replay_inject.sh -- build the T8.7 state-injection replay driver.
# Requires the makehdl netlist (run checkhdl gate first). --public-flat-rw
# guarantees every register is a writable public member of the flat root
# (STATE_CAPTURE_PLAN.md; forcing verified against Verilator 5.020).
set -e
R=$(cd "$(dirname "$0")" && pwd)
K=$(dirname "$R")
VD=$K/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
test -f "$VD/TxRxComposite.v" || { echo "FATAL: no netlist at $VD (run gates first)"; exit 1; }
export PATH=/usr/local/bin:/usr/bin:/bin
cd "$R"
verilator -O2 -Wno-fatal --public-flat-rw --inline-mult 2000000 --cc wrap_byte_taps.v -y "$VD" \
  --exe sim_byte_inject.cpp -Mdir obj_byte_inject --top-module wrap_byte_taps
# generate the injection map from the freshly generated flat-root header
python3 gen_inject_map.py obj_byte_inject/Vwrap_byte_taps___024root.h obj_byte_inject/inject_map.h --prefixes dut
# inject_map.h is included by sim_byte_inject.cpp; add -I for the Mdir
make -s -C obj_byte_inject -f Vwrap_byte_taps.mk Vwrap_byte_taps \
  USER_CPPFLAGS="-I$R/obj_byte_inject"
echo "BUILD_REPLAY_INJECT_DONE: $R/obj_byte_inject/Vwrap_byte_taps"
