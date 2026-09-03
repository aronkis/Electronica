#!/bin/bash
# Build + run the two-clock clk_enable-beat model. Sim only.
set -e
cd "$(dirname "$0")"
HDL=../../jupiter_byte_beatila_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback
LIB=../../jupiter_byte_beatila_build/hdl_prj_jupiter_composite/vivado_ip_prj/projects/scripts
TC=$HDL/TxRxCompo_ip_src_TxRxComposite_tc.v
SER=$HDL/TxRxCompo_ip_src_Serializer.v
REG=$LIB/util_valid_regularizer.v

echo "### compiling REAL tc + REAL Serializer + REAL regularizer + TB"
iverilog -g2012 -o sim.vvp tb_clken_beat.v "$TC" "$SER" "$REG"

echo; echo "### SIM1-A  aligned, NO slip  (expect 0% coded-bit error)"
vvp sim.vvp +MODE=1 +SLIP_AT=0 +NCYC=20000 | grep -E "coded_bit_err|FINAL"

echo; echo "### SIM1-B  ONE one-tick symbol/grid slip at cyc=8000 (expect step to ~50%, sustained)"
vvp sim.vvp +MODE=1 +SLIP_AT=8000 +NCYC=20000 | grep -E "cyc=|FINAL"

echo; echo "### SIM2-clean   regularizer, clean 1-in-2 input (pops all on one parity)"
vvp sim.vvp +MODE=2 +INJ=clean   +NCYC=20000 | grep -E "FINAL"
echo "### SIM2-jitter  regularizer, bursty jitter avg 1-in-2 (pop-parity must stay locked)"
vvp sim.vvp +MODE=2 +INJ=jitter  +NCYC=20000 | grep -E "FINAL"
echo "### SIM2-surplus regularizer, >1-in-2 surplus (fill overflow => fix fails)"
vvp sim.vvp +MODE=2 +INJ=surplus +NCYC=20000 | grep -E "cyc=4000|cyc=8000|FINAL"
