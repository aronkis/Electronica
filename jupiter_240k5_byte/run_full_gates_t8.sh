#!/bin/bash
# run_full_gates_t8.sh -- FULL fresh gate suite on the T8-rate-fixed masters:
#   1) assemble (fresh composite, Rsym=1.92e6 rail)   run_assemble_byte.m
#   2) model-level byte oracle gate (4 runs)          sim_byte_gate_k5.m
#   3) checkhdl + makehdl + HDL greps                 checkhdl_gate_240k5_byte.m
#   4) golden byte vectors                            gen_byte_vectors_k5.m
#   5) S1B byte netlist gate (Verilator, rot0+rot17)  s1b_analyze_byte.m
#   6) S1 ROM-path iverilog regression                s1_analyze_240k5.m
# Launch DETACHED (setsid nohup) -- the harness background-task cap kills
# >60 min tasks. CLEAN PATH (~/.local/bin/as shadows the binutils assembler).
set -e -o pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/usr/local/bin:/usr/bin:/bin
cd "$KIT"

echo "=== [1/6] assemble (T8 rate fix) ==="
matlab -batch "run('$KIT/run_assemble_byte.m')" > assemble_byte.log 2>&1
grep -q "ASSEMBLE_240K5_BYTE PRE-SYNTH GATES OK" assemble_byte.log && echo "ASSEMBLE: PASS"

echo "=== [2/6] model-level byte oracle gate ==="
matlab -batch "run('$KIT/sim_byte_gate_k5.m')" > sim_byte_gate_k5.out 2>&1
grep -q "SIM_BYTE_GATE_K5_DONE PASS" sim_byte_gate_k5.out && echo "MODEL_GATE: PASS"

echo "=== [3/6] checkhdl + makehdl ==="
matlab -batch "run('$KIT/checkhdl_gate_240k5_byte.m')" > checkhdl_byte.out 2>&1
grep -q "CHECKHDL_GATE_240K5_BYTE_DONE" checkhdl_byte.out && echo "CHECKHDL+MAKEHDL: PASS"

# pi-shadowing netlist regression gate (2026-07-11): with the demod mask
# Ph=pi/4 evaluating CORRECTLY the derotate factor is 1.0 and HDL Coder elides
# the multiply entirely (all pre-byte kits). The poisoned build ('for pi=' in
# assemble) carried a 30.68deg derotation (28183/-16718 = 14.3deg decision
# margin = the ~2-3e-3 OTA floor) and a 3.14x-hot carrier loop gain (307 vs 98).
VDQ=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
if grep -q 'gain_mul_temp' "$VDQ/QPSK_Demodulator_Baseband.v"; then
  echo "PI_GATE FAIL: demod derotation multiply present (pi-shadowing regression)" >&2; exit 1
fi
if grep -q "sb00000000100110011" "$VDQ/Loop_Filter_block.v"; then
  echo "PI_GATE FAIL: carrier loop-filter carries poisoned 307 gain (expect 98)" >&2; exit 1
fi
echo "PI_GATE: PASS (demod pure slicer; CS loop gain sane)"

echo "=== [4/6] golden byte vectors ==="
matlab -batch "run('$KIT/gen_byte_vectors_k5.m')" 2>&1 | tail -1

VD=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
test -f "$VD/TxRxComposite.v"

echo "=== [5/6] S1B byte-path Verilator gate ==="
cd "$KIT/rtl_sim"
rm -rf obj_byte
verilator -O2 -Wno-fatal --cc wrap_byte.v -y "$VD" --exe sim_byte.cpp \
  -Mdir obj_byte --top-module wrap_byte
make -s -C obj_byte -f Vwrap_byte.mk Vwrap_byte
CLKS=$((100 + 38*18128))   # 38 frames x 9064 rail beats x 2 clks (T8 rail)
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 0  s1b_rot0
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 17 s1b_rot17
matlab -batch "run('$KIT/s1b_analyze_byte.m')"
grep -q 'result: PASS' "$KIT/S1B_GATE.txt" && echo "S1B_GATE: PASS"

echo "=== [6/6] S1 ROM-path iverilog regression ==="
iverilog -g2001 -o tb_tx_240k5.vvp tb_tx_240k5.v "$VD"/*.v
vvp tb_tx_240k5.vvp | tail -2
matlab -batch "run('$KIT/s1_analyze_240k5.m')"
grep -q 'result: PASS' "$KIT/S1_GATE.txt" && echo "S1_GATE: PASS"

echo FULL_GATES_T8_DONE
