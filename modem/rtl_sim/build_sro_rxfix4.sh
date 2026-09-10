#!/bin/bash
# [sim] Task 12: build the SRO harness against the RXFIX_R4 variant tree.
# Uses Task 7's sim_sro.cpp UNMODIFIED (that is what makes the n_p000 content-identity
# gate a test of the RTL and not of a re-typed driver) with the Task 12 wrapper
# wrap_byte_sro4.v, which declares the same module name.  THREE files now declare
# `module wrap_byte_sro` (task 7's, task 11's and this one), so the build FAILS LOUDLY
# if Verilator picked up either of the other two.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
VD=$KIT/rtl_sim/s1_rtl_rxfix_R4
cd "$KIT/rtl_sim"
rm -rf obj_byte_sro_rxfix4
verilator -O2 -Wno-fatal --cc wrap_byte_sro4.v -y "$VD" -y "$KIT/rtl_sim" +define+RXFIX_R4 --exe sim_sro.cpp \
  -Mdir obj_byte_sro_rxfix4 --top-module wrap_byte_sro > obj_byte_sro_rxfix4_verilate.log 2>&1
# --- wrapper provenance: the verilate log must name wrap_byte_sro4.v and NEITHER of
# --- the other two files that declare `module wrap_byte_sro`.
if grep -qE '(^|[^34])wrap_byte_sro\.v' obj_byte_sro_rxfix4_verilate.log; then
  echo "BUILD_SRO_RXFIX4_FAIL wrap_byte_sro.v (task 7 wrapper) was read"; exit 1; fi
if grep -q 'wrap_byte_sro3s\.v' obj_byte_sro_rxfix4_verilate.log; then
  echo "BUILD_SRO_RXFIX4_FAIL wrap_byte_sro3s.v (task 11 wrapper) was read"; exit 1; fi
grep -q 'wrap_byte_sro4\.v' obj_byte_sro_rxfix4_verilate.log || \
  { echo "BUILD_SRO_RXFIX4_FAIL wrap_byte_sro4.v not in the verilate log"; exit 1; }
grep -q 'RXFIX_R4' "$VD/Rate_Handle.v" || \
  { echo "BUILD_SRO_RXFIX4_FAIL variant tree is not patched"; exit 1; }
grep -q 'RXFIX_R3S' "$VD/Rate_Handle.v" && \
  { echo "BUILD_SRO_RXFIX4_FAIL variant tree also carries R3S"; exit 1; }
make -s -j"$(nproc)" -C obj_byte_sro_rxfix4 -f Vwrap_byte_sro.mk Vwrap_byte_sro > obj_byte_sro_rxfix4_make.log 2>&1
echo "BUILD_SRO_RXFIX4_DONE $KIT/rtl_sim/obj_byte_sro_rxfix4/Vwrap_byte_sro"
