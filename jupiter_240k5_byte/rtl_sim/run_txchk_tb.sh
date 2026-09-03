#!/bin/bash
set -e
cd "$(dirname "$0")"
iverilog -g2005 -o tb_txchk_vvp tb_tx_checker.v tx_seam_checker.v
vvp tb_txchk_vvp | tee txchk_run.log | tail -7
grep -q TXCHK_TB_PASS txchk_run.log || { echo TXCHK_GATE_FAIL; exit 1; }
echo TXCHK_GATE_GREEN
