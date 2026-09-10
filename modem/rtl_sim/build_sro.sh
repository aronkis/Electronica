#!/bin/bash
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
VD=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
cd "$KIT/rtl_sim"
rm -rf obj_byte_sro
verilator -O2 -Wno-fatal --cc wrap_byte_sro.v -y "$VD" -y "$KIT/rtl_sim" --exe sim_sro.cpp \
  -Mdir obj_byte_sro --top-module wrap_byte_sro > obj_byte_sro_verilate.log 2>&1
make -s -j"$(nproc)" -C obj_byte_sro -f Vwrap_byte_sro.mk Vwrap_byte_sro > obj_byte_sro_make.log 2>&1
echo "BUILD_SRO_DONE $KIT/rtl_sim/obj_byte_sro/Vwrap_byte_sro"
