#!/bin/bash
# [sim] Task 20: build the SRO harness against the RXFIX_R4D + RXFIX_R1 variant tree.
# Pre-registration RXFIX_S1_SIM_GATE.md (tag archive/pre-cleanup-2026-09-09;
# committed before this file existed).
#
# This is build_sro_rxfix4d.sh with a new VD and a new -Mdir.  EVERYTHING ELSE IS THE SAME
# BY DESIGN: task 7's sim_sro.cpp UNMODIFIED, the task 14 wrapper wrap_byte_sro4d.v
# UNMODIFIED, and the same +define+RXFIX_R4D.  That is what makes the p000 comparison a
# test of the RTL and not of a re-typed driver -- but it also means the wrapper's runtime
# banner (WRAP4D_FILE / WRAP4D_DEFINE) is IDENTICAL on an R4D leg and an R4DR1 leg, so the
# provenance has to be established here and at launch time instead.  See section 2 of the
# pre-registration; runall_t20.sh echoes the binary path + md5 into every leg log and
# asserts the md5 differs from the banked R4D binary's.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
VD=$KIT/rtl_sim/s1_rtl_rxfix_R4DR1
cd "$KIT/rtl_sim"
rm -rf obj_byte_sro_rxfix4dr1
verilator -O2 -Wno-fatal --cc wrap_byte_sro4d.v -y "$VD" -y "$KIT/rtl_sim" +define+RXFIX_R4D --exe sim_sro.cpp \
  -Mdir obj_byte_sro_rxfix4dr1 --top-module wrap_byte_sro > obj_byte_sro_rxfix4dr1_verilate.log 2>&1
L=obj_byte_sro_rxfix4dr1_verilate.log
# --- wrapper provenance: SIX files now declare `module wrap_byte_sro` (tasks 7, 11, 12,
# --- 12b, 14 and, from task 21, possibly more).  The verilate log must name the task 14
# --- wrapper and none of the others.
if grep -qE '(^|[^34bd])wrap_byte_sro\.v' "$L"; then
  echo "BUILD_SRO_RXFIX4DR1_FAIL wrap_byte_sro.v (task 7 wrapper) was read"; exit 1; fi
for w in wrap_byte_sro3s wrap_byte_sro4 wrap_byte_sro4b; do
  if grep -qE "$w\.v" "$L"; then
    echo "BUILD_SRO_RXFIX4DR1_FAIL $w.v was read"; exit 1; fi
done
grep -q 'wrap_byte_sro4d\.v' "$L" || \
  { echo "BUILD_SRO_RXFIX4DR1_FAIL wrap_byte_sro4d.v not in the verilate log"; exit 1; }
# --- TREE provenance.  'R4D' is a strict PREFIX of 'R4DR1', so the trailing slash is
# --- load-bearing: without it the R4D-tree test would match every R4DR1 path.
grep -q 's1_rtl_rxfix_R4DR1/' "$L" || \
  { echo "BUILD_SRO_RXFIX4DR1_FAIL the R4DR1 tree is not in the verilate log"; exit 1; }
if grep -q 's1_rtl_rxfix_R4D/' "$L"; then
  echo "BUILD_SRO_RXFIX4DR1_FAIL the R4D tree was read"; exit 1; fi
# --- VARIANT provenance: BOTH markers present, in their own files, and the four mutually
# --- exclusive Rate_Handle variants absent.
grep -q 'RXFIX_R4D' "$VD/Rate_Handle.v" || \
  { echo "BUILD_SRO_RXFIX4DR1_FAIL Rate_Handle.v does not carry RXFIX_R4D"; exit 1; }
grep -q 'RXFIX_R1' "$VD/Preamble_Detector.v" || \
  { echo "BUILD_SRO_RXFIX4DR1_FAIL Preamble_Detector.v does not carry RXFIX_R1"; exit 1; }
# the SHARP one: R1 must have REPLACED the tick-indexed pop, not merely been mentioned.
# (the R1 patch's own comment quotes Delay10_reg[49331], so the assign form is the test)
if grep -q 'assign Delay10_out1 = Delay10_reg\[49331\];' "$VD/Preamble_Detector.v"; then
  echo "BUILD_SRO_RXFIX4DR1_FAIL the tick-indexed PD pop is still there"; exit 1; fi
grep -q "assign Delay10_out1 = Delay8_out1 & Delay10_full;" "$VD/Preamble_Detector.v" || \
  { echo "BUILD_SRO_RXFIX4DR1_FAIL the occupancy-indexed PD pop is missing"; exit 1; }
for m in RXFIX_R3 RXFIX_R3S RXFIX_R4 RXFIX_R4B; do
  if grep -qE "$m([^0-9A-Za-z_]|\$)" "$VD/Rate_Handle.v"; then
    echo "BUILD_SRO_RXFIX4DR1_FAIL variant tree also carries $m"; exit 1; fi
done
make -s -j"$(nproc)" -C obj_byte_sro_rxfix4dr1 -f Vwrap_byte_sro.mk Vwrap_byte_sro > obj_byte_sro_rxfix4dr1_make.log 2>&1
B=$KIT/rtl_sim/obj_byte_sro_rxfix4dr1/Vwrap_byte_sro
B4D=$KIT/rtl_sim/obj_byte_sro_rxfix4d/Vwrap_byte_sro
M=$(md5sum "$B" | cut -d' ' -f1)
if [ -x "$B4D" ]; then
  M4D=$(md5sum "$B4D" | cut -d' ' -f1)
  [ "$M" != "$M4D" ] || { echo "BUILD_SRO_RXFIX4DR1_FAIL binary is byte-identical to the R4D binary"; exit 1; }
  echo "BUILD_SRO_RXFIX4DR1_MD5 r4dr1=$M r4d=$M4D (differ: OK)"
fi
echo "BUILD_SRO_RXFIX4DR1_DONE $B"
