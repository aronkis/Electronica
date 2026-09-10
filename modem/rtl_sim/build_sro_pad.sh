#!/bin/bash
# [sim] RXFIX_PAD gate: build the SRO/census harness against s1_rtl_pad (= s1_rtl_bs + pad_patch.py).
# Same wrapper (wrap_byte_bs.v), same driver (sim_sro.cpp), same define (RXFIX_BS) as obj_byte_sro_bs,
# so a leg on this binary differs from bs1_* legs ONLY by the ByteSerializer padding.
set -u
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem; cd "$KIT/rtl_sim"
test -d s1_rtl_pad || { echo "BUILD_SRO_PAD_FAIL no s1_rtl_pad"; exit 1; }
grep -q RXFIX_PAD s1_rtl_pad/ByteSerializer.v || { echo "BUILD_SRO_PAD_FAIL tree lacks RXFIX_PAD"; exit 1; }
O=obj_byte_sro_pad; rm -rf "$O"
verilator -O2 -Wno-fatal --cc wrap_byte_bs.v -y s1_rtl_pad -y "$KIT/rtl_sim" +define+RXFIX_BS \
  --exe sim_sro.cpp -Mdir "$O" --top-module wrap_byte_sro > "${O}_verilate.log" 2>&1 || { echo BUILD_SRO_PAD_FAIL verilate; tail -5 ${O}_verilate.log; exit 1; }
grep -q 'wrap_byte_bs\.v' "${O}_verilate.log" || { echo "BUILD_SRO_PAD_FAIL wrapper not read"; exit 1; }
grep -q 's1_rtl_pad/' "${O}_verilate.log" || { echo "BUILD_SRO_PAD_FAIL tree not read"; exit 1; }
for other in s1_rtl_bs s1_rtl_bs_base s1_rtl_bs_gen; do grep -q "$other/" "${O}_verilate.log" && { echo "BUILD_SRO_PAD_FAIL $other read"; exit 1; }; done
make -s -j"$(nproc)" -C "$O" -f Vwrap_byte_sro.mk Vwrap_byte_sro > "${O}_make.log" 2>&1 || { echo BUILD_SRO_PAD_FAIL make; tail -5 ${O}_make.log; exit 1; }
echo "BUILD_SRO_PAD_OK $O $(md5sum "$O/Vwrap_byte_sro" | cut -d' ' -f1)"
