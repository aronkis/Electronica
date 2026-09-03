#!/bin/bash
# build_tgen_wedge.sh -- build the short-fill wedge repro harness
# (wrap_byte_tgen.v + sim_byte_tgen.cpp) against the FLASHED-generation
# netlist ($KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback, cadence 2).
# Clone of build_replay_lock.sh (which documents WHY $KIT/s1_rtl is the
# flashed lineage and the cadence contract).
set -e -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
KIT=$(dirname "$R")
VD=${1:-$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback}
TAG=${2:-tgen_wedge_flashed}
export PATH=/usr/local/bin:/usr/bin:/bin

[ -f "$VD/TxRxComposite.v" ] || { echo "FATAL: no netlist at $VD" >&2; exit 1; }
cd "$R"
OBJ=obj_${TAG}
rm -rf "$OBJ"
verilator -O2 -Wno-fatal --cc wrap_byte_tgen.v -y "$VD" --exe sim_byte_tgen.cpp \
  -Mdir "$OBJ" --top-module wrap_byte_tgen
make -s -C "$OBJ" -f Vwrap_byte_tgen.mk Vwrap_byte_tgen
echo "BUILD_TGEN_WEDGE_DONE $R/$OBJ/Vwrap_byte_tgen"
echo "  netlist : $VD  (cadence 2 = flashed lineage)"
