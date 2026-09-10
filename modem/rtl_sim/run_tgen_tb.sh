#!/bin/bash
set -e
cd "$(dirname "$0")"
gcc -O2 -I../../host -o tgen_golden tgen_golden.c \
    ../../host/qpsk_seq.c ../../host/qpsk_frame.c
./tgen_golden --selftest
for s in 1 2 3 4; do ./tgen_golden $s 1516 golden_s${s}_f1516.bin; done
./tgen_golden 1 100 golden_s1_f100.bin
./tgen_golden 1 0   golden_s1_f0.bin
cat golden_s1_f1516.bin golden_s2_f1516.bin golden_s3_f1516.bin \
    golden_s4_f1516.bin golden_s1_f100.bin golden_s1_f0.bin > golden_all.bin
# gap-leg content reuses the seq1/seq2 @1516 goldens unmodified (gap is
# timing-only); this is a derived concatenation, not a new golden file.
cat golden_s1_f1516.bin golden_s2_f1516.bin > golden_gap2.bin
iverilog -g2005 -o tb_tgen_vvp tb_tgen.v qpsk_traffic_gen.v

vvp tb_tgen_vvp | tee tb_run.log | tail -15
if grep -q -e TGEN_TB_FIRST_ERR -e TGEN_TB_NO_STALL -e TGEN_TB_GAP_SPACING_FAIL \
           -e TGEN_TB_GAP_TIMESTAMP_MISSING -e TGEN_TB_PASSTHRU_FAIL \
           -e TGEN_TB_HOSTREADY_FAIL tb_run.log; then
  echo TGEN_TB_FAIL; exit 1
fi
cmp golden_all.bin tb_frames.bin || { echo TGEN_TB_FAIL; exit 1; }
cmp golden_gap2.bin tb_gap_frames.bin || { echo TGEN_TB_GAP_CONTENT_FAIL; exit 1; }
echo TGEN_TB_PASS

vvp tb_tgen_vvp +corrupt=1 >/dev/null
cmp -s golden_all.bin tb_frames.bin && { echo "POSITIVE_CONTROL_FAILED (corruption not caught)"; exit 1; } \
                                    || echo TGEN_TB_MISMATCH_AS_EXPECTED

# leave tb_frames.bin / tb_gap_frames.bin in their clean (non-corrupted) state on disk
vvp tb_tgen_vvp >/dev/null
echo TB_GATE_GREEN
