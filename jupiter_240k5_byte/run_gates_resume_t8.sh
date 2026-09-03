#!/bin/bash
# run_gates_resume_t8.sh -- resume the byte-kit gate suite from step 3 after the
# cadence_rtl_patch removal (T8 rate fix). Steps 1 (assemble) + 2 (model oracle)
# already PASSED; checkhdl_gate re-assembles internally so step 3 is self-contained.
#   3) checkhdl + makehdl (NO cadence patch) + HDL greps  checkhdl_gate_240k5_byte.m
#   4) golden byte vectors                                gen_byte_vectors_k5.m
#   5) S1B byte netlist gate (Verilator, rot0+rot17)      s1b_analyze_byte.m
#   6) S1 ROM-path iverilog regression                    s1_analyze_240k5.m
set -e -o pipefail
KIT=/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/usr/local/bin:/usr/bin:/bin
cd "$KIT"

echo "=== [3/6] checkhdl + makehdl (patch retired) ==="
matlab -batch "run('$KIT/checkhdl_gate_240k5_byte.m')" > checkhdl_byte.out 2>&1 || true
grep -q "CHECKHDL_GATE_240K5_BYTE_DONE" checkhdl_byte.out && echo "CHECKHDL+MAKEHDL: PASS" || { echo "CHECKHDL+MAKEHDL: FAIL"; tail -25 checkhdl_byte.out; exit 1; }

echo "=== [4/6] golden byte vectors ==="
matlab -batch "run('$KIT/gen_byte_vectors_k5.m')" > gen_byte_vectors.out 2>&1 || true
tail -1 gen_byte_vectors.out

VD=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
test -f "$VD/TxRxComposite.v" || { echo "NO NETLIST"; exit 1; }

echo "=== [5/6] S1B byte-path Verilator gate ==="
cd "$KIT/rtl_sim"
rm -rf obj_byte
verilator -O2 -Wno-fatal --cc wrap_byte.v -y "$VD" --exe sim_byte.cpp \
  -Mdir obj_byte --top-module wrap_byte
make -s -C obj_byte -f Vwrap_byte.mk Vwrap_byte
CLKS=$((100 + 38*18128))   # 38 frames x 9064 rail beats x 2 clks (T8 rail)
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 0  s1b_rot0
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 17 s1b_rot17
matlab -batch "run('$KIT/s1b_analyze_byte.m')" > "$KIT/s1b_analyze_byte.log" 2>&1 || true
grep -q 'result: PASS' "$KIT/S1B_GATE.txt" && echo "S1B_GATE: PASS" || { echo "S1B_GATE: FAIL"; tail -15 "$KIT/s1b_analyze_byte.log"; tail -20 "$KIT/S1B_GATE.txt" 2>/dev/null; exit 1; }

echo "=== [6/6] S1 ROM-path iverilog regression ==="
iverilog -g2001 -o tb_tx_240k5.vvp tb_tx_240k5.v "$VD"/*.v
vvp tb_tx_240k5.vvp > tb_tx_240k5.vvpout 2>&1 || true
tail -2 tb_tx_240k5.vvpout
matlab -batch "run('$KIT/s1_analyze_240k5.m')" > "$KIT/s1_analyze_240k5.log" 2>&1 || true
grep -q 'result: PASS' "$KIT/S1_GATE.txt" && echo "S1_GATE: PASS" || { echo "S1_GATE: FAIL"; tail -15 "$KIT/s1_analyze_240k5.log"; tail -20 "$KIT/S1_GATE.txt" 2>/dev/null; exit 1; }

echo GATES_RESUME_T8_DONE
