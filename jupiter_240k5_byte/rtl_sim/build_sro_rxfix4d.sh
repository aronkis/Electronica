#!/bin/bash
# [sim] Task 14: build the SRO harness against the RXFIX_R4D variant tree.
# Uses Task 7's sim_sro.cpp UNMODIFIED (that is what makes the n_p000 content-identity
# gate a test of the RTL and not of a re-typed driver) with the Task 14 wrapper
# wrap_byte_sro4d.v, which declares the same module name.  FIVE files now declare
# `module wrap_byte_sro` (tasks 7, 11, 12, 12b and this one), so the build FAILS LOUDLY if
# Verilator picked up any of the other three.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte
VD=$KIT/rtl_sim/s1_rtl_rxfix_R4D
cd "$KIT/rtl_sim"
rm -rf obj_byte_sro_rxfix4d
verilator -O2 -Wno-fatal --cc wrap_byte_sro4d.v -y "$VD" -y "$KIT/rtl_sim" +define+RXFIX_R4D --exe sim_sro.cpp \
  -Mdir obj_byte_sro_rxfix4d --top-module wrap_byte_sro > obj_byte_sro_rxfix4d_verilate.log 2>&1
# --- wrapper provenance: the verilate log must name wrap_byte_sro4d.v and NONE of the
# --- other three files that declare `module wrap_byte_sro`.
if grep -qE '(^|[^34bd])wrap_byte_sro\.v' obj_byte_sro_rxfix4d_verilate.log; then
  echo "BUILD_SRO_RXFIX4D_FAIL wrap_byte_sro.v (task 7 wrapper) was read"; exit 1; fi
if grep -q 'wrap_byte_sro3s\.v' obj_byte_sro_rxfix4d_verilate.log; then
  echo "BUILD_SRO_RXFIX4D_FAIL wrap_byte_sro3s.v (task 11 wrapper) was read"; exit 1; fi
if grep -qE 'wrap_byte_sro4\.v' obj_byte_sro_rxfix4d_verilate.log; then
  echo "BUILD_SRO_RXFIX4D_FAIL wrap_byte_sro4.v (task 12 wrapper) was read"; exit 1; fi
if grep -q 'wrap_byte_sro4b\.v' obj_byte_sro_rxfix4d_verilate.log; then
  echo "BUILD_SRO_RXFIX4D_FAIL wrap_byte_sro4b.v (task 12b wrapper) was read"; exit 1; fi
grep -q 'wrap_byte_sro4d\.v' obj_byte_sro_rxfix4d_verilate.log || \
  { echo "BUILD_SRO_RXFIX4D_FAIL wrap_byte_sro4d.v not in the verilate log"; exit 1; }
grep -q 'RXFIX_R4D' "$VD/Rate_Handle.v" || \
  { echo "BUILD_SRO_RXFIX4D_FAIL variant tree is not patched"; exit 1; }
for m in RXFIX_R3 RXFIX_R3S RXFIX_R4 RXFIX_R4B; do
  if grep -qE "$m([^0-9A-Za-z_]|\$)" "$VD/Rate_Handle.v"; then
    echo "BUILD_SRO_RXFIX4D_FAIL variant tree also carries $m"; exit 1; fi
done
make -s -j"$(nproc)" -C obj_byte_sro_rxfix4d -f Vwrap_byte_sro.mk Vwrap_byte_sro > obj_byte_sro_rxfix4d_make.log 2>&1
echo "BUILD_SRO_RXFIX4D_DONE $KIT/rtl_sim/obj_byte_sro_rxfix4d/Vwrap_byte_sro"
