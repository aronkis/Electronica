#!/bin/bash
# s1b_stage2.sh <GATE_DIR> -- S1B netlist byte gate for the N2 f1536/sps4 images.
# Mirrors run_netlist_gates.sh stages [2] and [4] with the FRAMESTAT_NOTES §7
# sps4 budget: frame clks = (13+12320)*sps*2 = 98664 at sps4, NF=16
# (the historical 12-frame sps8 budget is 1 frame short at sps4 startup).
# S1 (iverilog ROM regression) stays DEFERRED at f1536 (k5-ROM-locked TB, §7).
set -e -o pipefail
G=${1:?usage: s1b_stage2.sh <gate dir>}
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/usr/local/bin:/usr/bin:/bin
cd "$G"
VD=$G/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
test -f "$VD/TxRxComposite.v"
echo "=== [S1B-2a] golden byte vectors ==="
matlab -batch "run('$G/gen_byte_vectors_k5.m')"
echo "=== [S1B-2b] Verilator build + rot0/rot17 (sps4 budget) ==="
cd "$G/rtl_sim"
rm -rf obj_byte
verilator -O2 -Wno-fatal --cc wrap_byte.v -y "$VD" --exe sim_byte.cpp \
  -Mdir obj_byte --top-module wrap_byte
make -s -C obj_byte -f Vwrap_byte.mk Vwrap_byte
FRCLK=98664; NF=16; CLKS=$((100 + NF*FRCLK))
echo "S1B: frame=f1536 sps4 FRCLK=$FRCLK NF=$NF CLKS=$CLKS"
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 0  s1b_rot0
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 17 s1b_rot17
matlab -batch "run('$G/s1b_analyze_byte.m')"
grep -q 'result: PASS' "$G/S1B_GATE.txt" && echo "S1B_GATE: PASS" || { echo "S1B_GATE: FAIL"; exit 1; }
