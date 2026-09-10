#!/bin/bash
set -e -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
KIT=$(dirname "$R")
VD="$KIT/rtl_sim/s1_rtl_fix/hdlsrc/commhdlQPSKTxRxLoopback"
export PATH=/usr/local/bin:/usr/bin:/bin
cd "$R"
rm -rf obj_byte_cefix
verilator -O2 -Wno-fatal --public-flat-rw -CFLAGS "-O2 -DHAVE_FLAT_RW" --cc wrap_byte_ce.v -y "$VD" \
  --exe sim_byte_ce.cpp -Mdir obj_byte_cefix --top-module wrap_byte_ce
make -j12 -C obj_byte_cefix -f Vwrap_byte_ce.mk Vwrap_byte_ce
echo CEFIX_FLAT_DONE
