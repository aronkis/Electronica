#!/bin/bash
# run_netlist_gates.sh -- modem NETLIST gates (NO Vivado):
#   1) checkhdl + makehdl -> s1_rtl/hdlsrc  (checkhdl_gate_240k5_byte.m)
#   2) golden byte vectors                   (gen_byte_vectors_k5.m)
#   3) S1  ROM-path regression: iverilog tb_tx_240k5.v (ext ports tied off)
#      + s1_analyze_240k5.m  -> S1_GATE.txt
#   4) S1B byte-path gate: Verilator wrap_byte.v + sim_byte.cpp, aligned
#      (rot=0) + rotated (rot=17) runs + s1b_analyze_byte.m -> S1B_GATE.txt
set -e -o pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/usr/local/bin:/usr/bin:/bin
cd "$KIT"

echo "=== [1/4] checkhdl + makehdl ==="
matlab -batch "run('$KIT/checkhdl_gate_240k5_byte.m')"

VD=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
test -f "$VD/TxRxComposite.v"

# pi-shadowing netlist regression gate (2026-07-11): see run_full_gates_t8.sh
if grep -q 'gain_mul_temp' "$VD/QPSK_Demodulator_Baseband.v"; then
  echo "PI_GATE FAIL: demod derotation multiply present" >&2; exit 1
fi
if grep -q "sb00000000100110011" "$VD/Loop_Filter_block.v"; then
  echo "PI_GATE FAIL: poisoned 307 CS gain" >&2; exit 1
fi
echo "PI_GATE: PASS"

echo "=== [2/4] golden byte vectors ==="
matlab -batch "run('$KIT/gen_byte_vectors_k5.m')"

echo "=== [3/4] S1 ROM-path iverilog regression ==="
cd "$KIT/rtl_sim"
iverilog -g2001 -o tb_tx_240k5.vvp tb_tx_240k5.v "$VD"/*.v
vvp tb_tx_240k5.vvp | tail -2
matlab -batch "run('$KIT/s1_analyze_240k5.m')"
grep -q 'result: PASS' "$KIT/S1_GATE.txt" && echo "S1_GATE: PASS"

echo "=== [4/4] S1B byte-path Verilator gate ==="
rm -rf obj_byte
verilator -O2 -Wno-fatal --cc wrap_byte.v -y "$VD" --exe sim_byte.cpp \
  -Mdir obj_byte --top-module wrap_byte
make -s -C obj_byte -f Vwrap_byte.mk Vwrap_byte
# Frame-aware clk budget (RXALIGN task 2026-07-25: was k5-locked at 38*18128).
# frame clks = (13 + PayloadBits/2 sym) * sps8 * 2 clks/rail-beat:
#   k5   : (13+1120)*8*2 = 18128, 38 frames
#   f1536: (13+12320)*8*2 = 197328, 12 frames (~11x longer -> fewer frames)
# sim_byte.cpp is frame-agnostic (reads NW=35/385 from tx_words_golden.hex).
if [ "${QPSK_FRAME:-k5}" = "f1536" ]; then FRCLK=197328; NF=12; else FRCLK=18128; NF=38; fi
CLKS=$((100 + NF*FRCLK))
echo "S1B: frame=${QPSK_FRAME:-k5} FRCLK=$FRCLK NF=$NF CLKS=$CLKS"
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 0  s1b_rot0
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 17 s1b_rot17
matlab -batch "run('$KIT/s1b_analyze_byte.m')"
grep -q 'result: PASS' "$KIT/S1B_GATE.txt" && echo "S1B_GATE: PASS"

echo NETLIST_GATES_DONE
