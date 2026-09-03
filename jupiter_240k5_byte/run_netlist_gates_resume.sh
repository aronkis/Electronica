#!/bin/bash
# run_netlist_gates_resume.sh -- stages 3+4 of run_netlist_gates.sh ONLY
# (stage 1 checkhdl+makehdl and stage 2 vectors already PASSED; s1_rtl is
# intact). S1B (Verilator byte gate) runs FIRST, then the S1 iverilog ROM
# regression. Launch DETACHED (setsid nohup) -- the harness background-task
# lifetime cap killed the first vvp run at ~86%.
set -e -o pipefail
KIT=/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte
# CLEAN PATH: ~/.local/bin/as (an unrelated CLI) shadows the binutils
# assembler and breaks the Verilator g++ compile ("No agent session ...").
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/usr/local/bin:/usr/bin:/bin
cd "$KIT"
VD=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
test -f "$VD/TxRxComposite.v"
test -f "$KIT/rtl_sim/tx_words_golden.hex"

echo "=== [4/4] S1B byte-path Verilator gate ==="
cd "$KIT/rtl_sim"
rm -rf obj_byte
verilator -O2 -Wno-fatal --cc wrap_byte.v -y "$VD" --exe sim_byte.cpp \
  -Mdir obj_byte --top-module wrap_byte
make -s -C obj_byte -f Vwrap_byte.mk Vwrap_byte
CLKS=$((100 + 38*18128))   # 38 frames x 9064 rail beats x 2 clks (T8 rail) + reset
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 0  s1b_rot0
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 17 s1b_rot17
matlab -batch "run('$KIT/s1b_analyze_byte.m')"
grep -q 'result: PASS' "$KIT/S1B_GATE.txt" && echo "S1B_GATE: PASS"

echo "=== [3/4] S1 ROM-path iverilog regression (rerun) ==="
iverilog -g2001 -o tb_tx_240k5.vvp tb_tx_240k5.v "$VD"/*.v
vvp tb_tx_240k5.vvp | tail -2
matlab -batch "run('$KIT/s1_analyze_240k5.m')"
grep -q 'result: PASS' "$KIT/S1_GATE.txt" && echo "S1_GATE: PASS"

echo NETLIST_GATES_RESUME_DONE
