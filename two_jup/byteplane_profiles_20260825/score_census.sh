#!/bin/bash
# score_census.sh <railcensus.txt> -- A2 scoring, same rules as railcensus_146candidate:
#  C1 tc-cell count sane (witness defect = 4; known-good ~86-100)
#  C2 byte-plane logic hosted in addr_decoder (state_bitIdx / dataOut_last_value): 0
#  C3 no const-folded rail nets (TYPE=POWER/GROUND): 0
#  C4 gated globals among rail nets: exactly 1 (FrameStatFifo enb_1_2_0_gated), no fragmentation
#  C5 tc-hosted phase_0_reg BUFG present with CE=VCC
f=$1
tc=$(awk '/^TC_CELLS/{print $2}' $f)
c1=FAIL; [ -n "$tc" ] && [ "$tc" -ge 60 ] && [ "$tc" -le 120 ] && c1=PASS
rehost=$(grep -c -e 'addr_decoder.*state_bitIdx' -e 'addr_decoder.*dataOut_last_value' $f)
c2=FAIL; [ "$rehost" -eq 0 ] && c2=PASS
cf=$(grep -c '^NET .*TYPE=POWER\|^NET .*TYPE=GROUND' $f)
c3=FAIL; [ "$cf" -eq 0 ] && c3=PASS
# C4: global-clock rail-net basename set must equal the candidate's
# {enb_1_2_0, enb_1_2_0_gated (FrameStatFifo), enb_gated (ByteRxFifo)} and no
# addr_decoder-hosted global (witness-defect signature = re-hosting/fragmentation)
ggset=$(grep '^NET .*TYPE=GLOBAL_CLOCK' $f | awk '{print $2}' | awk -F/ '{print $NF}' | sort -u | tr '\n' ',')
ggad=$(grep -c '^NET .*addr_decoder.*TYPE=GLOBAL_CLOCK' $f)
gg=$(grep -c '^NET .*TYPE=GLOBAL_CLOCK' $f)
c4=FAIL; [ "$ggset" = "enb_1_2_0,enb_1_2_0_gated,enb_gated," ] && [ "$ggad" -eq 0 ] && c4=PASS
c5=FAIL; grep -q 'phase_0_reg_0\[0\]_BUFG_inst BUFGCE CE={.*VCC' $f && c5=PASS
verdict=CLEAN
for c in $c1 $c2 $c3 $c4 $c5; do [ "$c" = FAIL ] && verdict=DEFECT; done
echo "$(basename $f): TC_CELLS=$tc($c1) ADDR_REHOST=$rehost($c2) CONSTFOLD=$cf($c3) GATED_GLOBALS=$gg:set=$ggset($c4) TC_BUFG_CEVCC=$c5 => $verdict"
