#!/bin/bash
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte
VD=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
cd "$KIT/rtl_sim"
rm -rf obj_ring
verilator -O2 -Wno-fatal --cc wrap_ring.v -y "$VD" --exe sim_ring.cpp -Mdir obj_ring --top-module wrap_ring > obj_ring_verilate.log 2>&1
make -s -j4 -C obj_ring -f Vwrap_ring.mk Vwrap_ring > obj_ring_make.log 2>&1
echo "BUILD_RING_DONE"
