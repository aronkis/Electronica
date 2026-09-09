#!/bin/bash
# build_ddrcap2_sim.sh -- s1_rtl_ddrcap2 = s1_rtl_final + TXMARK=1 ddrcap_inject + ddrcap2_inject,
# then obj_ddrcap2 (ports only, threads) and obj_ddrcap2_flat (--public-flat-rw, for forcing).
set -eu
cd "$(dirname "$0")"
VD=s1_rtl_ddrcap2/hdlsrc/commhdlQPSKTxRxLoopback
if [ ! -d s1_rtl_ddrcap2 ] || [ "${FORCE:-0}" = 1 ]; then
  rm -rf s1_rtl_ddrcap2 && cp -a s1_rtl_final s1_rtl_ddrcap2
  TXMARK=1 python3 ../../two_jup/skidfix/ddrcap_inject.py s1_rtl_ddrcap2 | tail -2
  python3 ../../two_jup/skidfix/ddrcap2_inject.py s1_rtl_ddrcap2 | tail -3
  grep -q "ddrcap2_slot_r" "$VD/TxRxComposite.v" || { echo "ddrcap2 not injected"; exit 1; }
fi
COMMON="-O2 -Wno-fatal --cc --exe --build --top-module wrap_byte_ddrcap -y $VD -y . wrap_byte_ddrcap.v"
if [ "${NETLIST_ONLY:-0}" = 1 ]; then exit 0; fi
if [ ! -x obj_ddrcap2/Vwrap_byte_ddrcap ] || [ "${FORCE:-0}" = 1 ]; then
  verilator $COMMON --threads 4 -CFLAGS "-O2" -Mdir obj_ddrcap2 sim_ddrcap2.cpp -o Vwrap_byte_ddrcap 2>&1 | tail -3
fi
if [ ! -x obj_ddrcap2_flat/Vwrap_byte_ddrcap ] || [ "${FORCE:-0}" = 1 ]; then
  verilator $COMMON --public-flat-rw -CFLAGS "-O2 -DDDRCAP2_FLAT -DRHCTR_REG=u_Symbol_Synchronizer__DOT__u_Rate_Handle__DOT__u_FIFO__DOT__Push_Counter_out1" -Mdir obj_ddrcap2_flat sim_ddrcap2.cpp -o Vwrap_byte_ddrcap 2>&1 | tail -3
fi
ls -la obj_ddrcap2/Vwrap_byte_ddrcap obj_ddrcap2_flat/Vwrap_byte_ddrcap
