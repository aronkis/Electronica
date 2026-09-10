#!/bin/bash
# [sim] Task 11: build the falsifier per-stage dump driver against the RXFIX_R3S tree.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
VD=$KIT/rtl_sim/s1_rtl_rxfix_R3S
cd "$KIT/rtl_sim"
rm -rf obj_stagewin3s
verilator -O2 -Wno-fatal --cc wrap_byte_sro3s.v -y "$VD" -y "$KIT/rtl_sim" +define+RXFIX_R3S --exe sim_stagewin.cpp \
  -Mdir obj_stagewin3s --top-module wrap_byte_sro > obj_stagewin3s_verilate.log 2>&1
if grep -qE '(^|[^3])wrap_byte_sro\.v' obj_stagewin3s_verilate.log; then
  echo "BUILD_STAGEWIN3S_FAIL wrap_byte_sro.v (task 7 wrapper) was read"; exit 1; fi
make -s -j"$(nproc)" -C obj_stagewin3s -f Vwrap_byte_sro.mk Vwrap_byte_sro > obj_stagewin3s_make.log 2>&1
echo "BUILD_STAGEWIN3S_DONE $KIT/rtl_sim/obj_stagewin3s/Vwrap_byte_sro"
