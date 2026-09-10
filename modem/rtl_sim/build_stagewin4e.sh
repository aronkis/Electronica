#!/bin/bash
# [sim] Task 21: build the K8 per-stage dump driver against the RXFIX_R4E tree.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
VD=$KIT/rtl_sim/s1_rtl_rxfix_R4E
cd "$KIT/rtl_sim"
rm -rf obj_stagewin4e
verilator -O2 -Wno-fatal --cc wrap_byte_sro4e.v -y "$VD" -y "$KIT/rtl_sim" +define+RXFIX_R4E --exe sim_stagewin4e.cpp \
  -Mdir obj_stagewin4e --top-module wrap_byte_sro > obj_stagewin4e_verilate.log 2>&1
grep -q 'wrap_byte_sro4e\.v' obj_stagewin4e_verilate.log || \
  { echo "BUILD_STAGEWIN4E_FAIL wrong wrapper"; exit 1; }
make -s -j"$(nproc)" -C obj_stagewin4e -f Vwrap_byte_sro.mk Vwrap_byte_sro > obj_stagewin4e_make.log 2>&1
echo "BUILD_STAGEWIN4E_DONE $KIT/rtl_sim/obj_stagewin4e/Vwrap_byte_sro"
