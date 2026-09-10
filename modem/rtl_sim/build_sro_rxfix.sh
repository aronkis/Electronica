#!/bin/bash
# [sim] Task 6 (T2): build the SRO harness against the RXFIX_R1 variant tree.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
VD=$KIT/rtl_sim/s1_rtl_rxfix_R1
cd "$KIT/rtl_sim"
rm -rf obj_byte_sro_rxfix
verilator -O2 -Wno-fatal --cc wrap_byte_sro.v -y "$VD" --exe sim_sro.cpp \
  -Mdir obj_byte_sro_rxfix --top-module wrap_byte_sro > obj_byte_sro_rxfix_verilate.log 2>&1
make -s -j"$(nproc)" -C obj_byte_sro_rxfix -f Vwrap_byte_sro.mk Vwrap_byte_sro > obj_byte_sro_rxfix_make.log 2>&1
echo "BUILD_SRO_RXFIX_DONE $KIT/rtl_sim/obj_byte_sro_rxfix/Vwrap_byte_sro"
