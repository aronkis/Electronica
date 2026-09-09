#!/bin/bash
# [sim] Task 7 (T2b): build the SRO harness against the RXFIX_R3 variant tree.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte
VD=$KIT/rtl_sim/s1_rtl_rxfix_R3
cd "$KIT/rtl_sim"
rm -rf obj_byte_sro_rxfix3
verilator -O2 -Wno-fatal --cc wrap_byte_sro.v -y "$VD" -y "$KIT/rtl_sim" +define+RXFIX_R3 --exe sim_sro.cpp \
  -Mdir obj_byte_sro_rxfix3 --top-module wrap_byte_sro > obj_byte_sro_rxfix3_verilate.log 2>&1
make -s -j"$(nproc)" -C obj_byte_sro_rxfix3 -f Vwrap_byte_sro.mk Vwrap_byte_sro > obj_byte_sro_rxfix3_make.log 2>&1
echo "BUILD_SRO_RXFIX3_DONE $KIT/rtl_sim/obj_byte_sro_rxfix3/Vwrap_byte_sro"
