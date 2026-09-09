#!/bin/bash
# [sim] Task 9: build the RXFIX_W1 instrument gate harness.
#   $1 = w1   -> patched tree s1_rtl_rxfix_W1, +define+RXFIX_W1, obj_byte_w1
#   $1 = base -> unpatched s1_rtl,             no define,         obj_byte_w1_base
# NEVER touches obj_byte_sro (Task 7's live legs run out of it).
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte
WHICH="${1:-w1}"
case "$WHICH" in
  w1)   VD=$KIT/rtl_sim/s1_rtl_rxfix_W1; OBJ=obj_byte_w1;      DEF="+define+RXFIX_W1" ;;
  base) VD=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback; OBJ=obj_byte_w1_base; DEF="" ;;
  *) echo "BUILD_W1_BAD_ARG '$WHICH' (want w1|base)"; exit 1 ;;
esac
cd "$KIT/rtl_sim"
rm -rf "$OBJ"
verilator -O2 -Wno-fatal --cc wrap_byte_w1.v -y "$VD" -y "$KIT/rtl_sim" $DEF \
  --exe sim_w1.cpp -Mdir "$OBJ" --top-module wrap_byte_w1 > "${OBJ}_verilate.log" 2>&1
make -s -j4 -C "$OBJ" -f Vwrap_byte_w1.mk Vwrap_byte_w1 > "${OBJ}_make.log" 2>&1
echo "BUILD_W1_DONE $WHICH $KIT/rtl_sim/$OBJ/Vwrap_byte_w1"
