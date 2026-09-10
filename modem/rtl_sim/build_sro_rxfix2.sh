#!/bin/bash
# [sim] Task 6 (T2): build the SRO harness against the RXFIX_R2 variant tree.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
VD=$KIT/rtl_sim/s1_rtl_rxfix_R2
cd "$KIT/rtl_sim"
rm -rf obj_byte_sro_rxfix2
verilator -O2 -Wno-fatal --cc wrap_byte_sro.v -y "$VD" --exe sim_sro.cpp \
  -Mdir obj_byte_sro_rxfix2 --top-module wrap_byte_sro > obj_byte_sro_rxfix2_verilate.log 2>&1
make -s -j"$(nproc)" -C obj_byte_sro_rxfix2 -f Vwrap_byte_sro.mk Vwrap_byte_sro > obj_byte_sro_rxfix2_make.log 2>&1
echo "BUILD_SRO_RXFIX2_DONE $KIT/rtl_sim/obj_byte_sro_rxfix2/Vwrap_byte_sro"
