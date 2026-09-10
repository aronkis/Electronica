#!/bin/bash
# [sim] Task 21: build the SRO harness against the RXFIX_R4E variant tree.
# Uses Task 7's sim_sro.cpp UNMODIFIED (that is what makes the content-identity gate a
# test of the RTL and not of a re-typed driver) with the Task 21 wrapper
# wrap_byte_sro4e.v, which declares the same module name.  SIX files now declare
# `module wrap_byte_sro` (tasks 7, 11, 12, 12b, 14 and this one), so the build FAILS
# LOUDLY if Verilator picked up any of the other five.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
VD=$KIT/rtl_sim/s1_rtl_rxfix_R4E
cd "$KIT/rtl_sim"
rm -rf obj_byte_sro_rxfix4e
verilator -O2 -Wno-fatal --cc wrap_byte_sro4e.v -y "$VD" -y "$KIT/rtl_sim" +define+RXFIX_R4E --exe sim_sro.cpp \
  -Mdir obj_byte_sro_rxfix4e --top-module wrap_byte_sro > obj_byte_sro_rxfix4e_verilate.log 2>&1
# --- wrapper provenance: the verilate log must name wrap_byte_sro4e.v and NONE of the
# --- other five files that declare `module wrap_byte_sro`.
if grep -qE '(^|[^34bde])wrap_byte_sro\.v' obj_byte_sro_rxfix4e_verilate.log; then
  echo "BUILD_SRO_RXFIX4E_FAIL wrap_byte_sro.v (task 7 wrapper) was read"; exit 1; fi
for w in wrap_byte_sro3s wrap_byte_sro4 wrap_byte_sro4b wrap_byte_sro4d; do
  if grep -qE "$w\.v" obj_byte_sro_rxfix4e_verilate.log; then
    echo "BUILD_SRO_RXFIX4E_FAIL $w.v was read"; exit 1; fi
done
grep -q 'wrap_byte_sro4e\.v' obj_byte_sro_rxfix4e_verilate.log || \
  { echo "BUILD_SRO_RXFIX4E_FAIL wrap_byte_sro4e.v not in the verilate log"; exit 1; }
grep -q 'RXFIX_R4E' "$VD/Rate_Handle.v" || \
  { echo "BUILD_SRO_RXFIX4E_FAIL variant tree is not patched"; exit 1; }
for m in RXFIX_R3 RXFIX_R3S RXFIX_R4 RXFIX_R4B RXFIX_R4D; do
  if grep -qE "$m([^0-9A-Za-z_]|\$)" "$VD/Rate_Handle.v"; then
    echo "BUILD_SRO_RXFIX4E_FAIL variant tree also carries $m"; exit 1; fi
done
make -s -j"$(nproc)" -C obj_byte_sro_rxfix4e -f Vwrap_byte_sro.mk Vwrap_byte_sro > obj_byte_sro_rxfix4e_make.log 2>&1
echo "BUILD_SRO_RXFIX4E_DONE $KIT/rtl_sim/obj_byte_sro_rxfix4e/Vwrap_byte_sro"
