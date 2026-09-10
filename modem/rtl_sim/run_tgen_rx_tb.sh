#!/bin/bash
set -e
cd "$(dirname "$0")"
# golden files are shared with the TX-seam TB (same frame-content contract);
# rebuild them so this gate stands alone
gcc -O2 -I../../host -o tgen_golden tgen_golden.c \
    ../../host/qpsk_seq.c ../../host/qpsk_frame.c
./tgen_golden --selftest
for s in 1 2 3 4; do ./tgen_golden $s 1516 golden_s${s}_f1516.bin; done
./tgen_golden 1 100 golden_s1_f100.bin
./tgen_golden 1 0   golden_s1_f0.bin
cat golden_s1_f1516.bin golden_s2_f1516.bin golden_s3_f1516.bin \
    golden_s4_f1516.bin golden_s1_f100.bin golden_s1_f0.bin > golden_all.bin
cat golden_s1_f1516.bin golden_s2_f1516.bin > golden_gap2.bin
iverilog -g2005 -o tb_tgen_rx_vvp tb_tgen_rx.v qpsk_traffic_gen_rx.v

vvp tb_tgen_rx_vvp | tee tb_rx_run.log | tail -15
if grep -q -e TGENRX_TB_LAST_ERR -e TGENRX_TB_NO_STALL -e TGENRX_TB_GAP_SPACING_FAIL \
           -e TGENRX_TB_GAP_TIMESTAMP_MISSING -e TGENRX_TB_PASSTHRU_FAIL \
           -e TGENRX_TB_DUTREADY_FAIL -e TGENRX_TB_USER_FAIL -e TGENRX_TB_LASTOFF_FAIL -e TGENRX_TB_LASTOFF_NO_DATA -e TGENRX_TB_LEAK_FAIL tb_rx_run.log; then
  echo TGENRX_TB_FAIL; exit 1
fi
cmp golden_all.bin tb_rx_frames.bin || { echo TGENRX_TB_FAIL; exit 1; }
cmp golden_gap2.bin tb_rx_gap_frames.bin || { echo TGENRX_TB_GAP_CONTENT_FAIL; exit 1; }
echo TGENRX_TB_PASS

vvp tb_tgen_rx_vvp +corrupt=1 >/dev/null
cmp -s golden_all.bin tb_rx_frames.bin && { echo "POSITIVE_CONTROL_FAILED (corruption not caught)"; exit 1; } \
                                       || echo TGENRX_TB_MISMATCH_AS_EXPECTED

vvp tb_tgen_rx_vvp >/dev/null
echo TB_RX_GATE_GREEN
