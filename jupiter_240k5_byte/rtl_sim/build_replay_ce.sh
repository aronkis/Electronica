#!/bin/bash
# build_replay_ce.sh -- build the Model-1 ENABLE-INJECT positive-control harness
# (wrap_byte_ce.v + sim_byte_ce.cpp) against a chosen netlist.
# Builds TWO variants:
#   obj_byte_<TAG>_fast  : optimized, NO flat-rw -- gate0, --drop-ce, fix legs.
#   obj_byte_<TAG>       : --public-flat-rw (slow) -- --flip-count2 / --flip-serctr.
# Usage: build_replay_ce.sh [netlist_dir] [objdir_suffix]
#   netlist_dir   default $KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback (FLASHED lineage)
#   objdir_suffix default "ce"
set -e -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
KIT=$(dirname "$R")
VD=${1:-$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback}
TAG=${2:-ce}
export PATH=/usr/local/bin:/usr/bin:/bin
[ -f "$VD/TxRxComposite.v" ] || { echo "FATAL: no netlist at $VD" >&2; exit 1; }
cd "$R"

# fast variant (no flat-rw; -O3 host compile)
OBJF=obj_byte_${TAG}_fast
rm -rf "$OBJF"
verilator -O2 -Wno-fatal -CFLAGS "-O2" --cc wrap_byte_ce.v -y "$VD" \
  --exe sim_byte_ce.cpp -Mdir "$OBJF" --top-module wrap_byte_ce
make -s -C "$OBJF" -f Vwrap_byte_ce.mk Vwrap_byte_ce
echo "BUILD_REPLAY_CE_FAST_DONE $R/$OBJF/Vwrap_byte_ce"

# flat-rw variant (pokeable internal regs)
OBJ=obj_byte_${TAG}
rm -rf "$OBJ"
verilator -O2 -Wno-fatal --public-flat-rw -CFLAGS "-O2 -DHAVE_FLAT_RW" --cc wrap_byte_ce.v -y "$VD" \
  --exe sim_byte_ce.cpp -Mdir "$OBJ" --top-module wrap_byte_ce
make -s -C "$OBJ" -f Vwrap_byte_ce.mk Vwrap_byte_ce
echo "BUILD_REPLAY_CE_DONE $R/$OBJ/Vwrap_byte_ce"
echo "  netlist : $VD"
