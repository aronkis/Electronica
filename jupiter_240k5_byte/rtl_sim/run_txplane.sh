#!/bin/bash
# run_txplane.sh -- one TX-plane matrix cell. CELL name, CONTENT idle0|fill|tgen, WHITEN 0|1, NWF 385|191,
# NF frames, MODE cont|rate|gap, P1 P2. Outputs in txplane_runs/<CELL>/. Scores with txplane_score.
set -u
cd "$(dirname "$0")"; CELL=$1; CONTENT=$2; WHITEN=$3; NWF=$4; NF=$5; MODE=$6; P1=${7:-0}; P2=${8:-0}
O=txplane_runs/$CELL; mkdir -p $O; OBJ=${OBJ:-obj_txplane_fast}
QPSK_WHITEN=$WHITEN ./gen_txplane_frames $CONTENT $NF $NWF $O/words.hex || exit 1
S=$(date +%s)
if [ "$MODE" = cont ]; then nice ./$OBJ/Vwrap_byte_ce $O/words.hex $NWF $NF cont $O/r > $O/sim.log 2>&1
else nice ./$OBJ/Vwrap_byte_ce $O/words.hex $NWF $NF $MODE $P1 $P2 $O/r > $O/sim.log 2>&1; fi
echo "SIM_SECS $(( $(date +%s) - S ))" >> $O/sim.log
OPT=""; [ "$WHITEN" = 1 ] && OPT="--dewhiten"; [ "$CONTENT" = tgen ] && OPT="$OPT --tgen"
./txplane_score --skipgood=${SKIPGOOD:-20} --nf=$((NF-${SKIPGOOD:-20}-10)) $OPT $O/r_rxw.txt > $O/score.txt
echo "CELL $CELL content=$CONTENT whiten=$WHITEN nwf=$NWF nf=$NF mode=$MODE p1=$P1 p2=$P2 | $(tail -1 $O/sim.log) | $(grep TXPLANE $O/sim.log) | $(grep SCORE $O/score.txt)"
