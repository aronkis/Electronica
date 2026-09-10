#!/bin/bash
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
VD=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
cd "$KIT/rtl_sim"
rm -rf obj_corr
verilator -O2 -Wno-fatal --cc wrap_corr.v -y "$VD" --exe sim_corr.cpp -Mdir obj_corr --top-module wrap_corr > obj_corr_verilate.log 2>&1
make -s -j4 -C obj_corr -f Vwrap_corr.mk Vwrap_corr > obj_corr_make.log 2>&1
echo "BUILD_CORR_DONE"
