#!/bin/bash
# [sim] Task 11: build the SRO harness against the RXFIX_R3S variant tree.
# Uses Task 7's sim_sro.cpp UNMODIFIED (that is what makes the n_p000 md5 identity
# gate a test of the RTL and not of a re-typed driver) with the Task 11 wrapper
# wrap_byte_sro3s.v, which declares the same module name.  The build FAILS LOUDLY if
# Verilator picked up Task 7's wrap_byte_sro.v instead.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte
VD=$KIT/rtl_sim/s1_rtl_rxfix_R3S
cd "$KIT/rtl_sim"
rm -rf obj_byte_sro_rxfix3s
verilator -O2 -Wno-fatal --cc wrap_byte_sro3s.v -y "$VD" -y "$KIT/rtl_sim" +define+RXFIX_R3S --exe sim_sro.cpp \
  -Mdir obj_byte_sro_rxfix3s --top-module wrap_byte_sro > obj_byte_sro_rxfix3s_verilate.log 2>&1
# --- wrapper provenance: the verilate log must name wrap_byte_sro3s.v and NOT
# --- wrap_byte_sro.v (two files declare `module wrap_byte_sro`).
if grep -qE '(^|[^3])wrap_byte_sro\.v' obj_byte_sro_rxfix3s_verilate.log; then
  echo "BUILD_SRO_RXFIX3S_FAIL wrap_byte_sro.v (task 7 wrapper) was read"; exit 1; fi
grep -q 'wrap_byte_sro3s\.v' obj_byte_sro_rxfix3s_verilate.log || \
  { echo "BUILD_SRO_RXFIX3S_FAIL wrap_byte_sro3s.v not in the verilate log"; exit 1; }
grep -q 'RXFIX_R3S' "$VD/Rate_Handle.v" || \
  { echo "BUILD_SRO_RXFIX3S_FAIL variant tree is not patched"; exit 1; }
make -s -j"$(nproc)" -C obj_byte_sro_rxfix3s -f Vwrap_byte_sro.mk Vwrap_byte_sro > obj_byte_sro_rxfix3s_make.log 2>&1
echo "BUILD_SRO_RXFIX3S_DONE $KIT/rtl_sim/obj_byte_sro_rxfix3s/Vwrap_byte_sro"
