#!/bin/bash
# =============================================================================
# gapsweep_go.sh -- SEQ-BIST stage-1 GAP SWEEP (coordinator ruling 2, 2026-09-04).
#
# THE QUESTION: the mission-gap legs show a steady fabric-only loss of ~0.067 %
# (1 gap event per ~1,720 emitted frames), with no DMA, no host and no radio in the
# path. Is it caused by the inter-frame SILENCE the TGEN leaves between frames, or is
# it rate-independent?
#
# PRE-REGISTERED PREDICTIONS (before the runs):
#  * TX byte-in STARVATION mechanism -- ByteWordBuffer readyNext = count <= 6, and
#    TXPLANE_SIM_RESULTS.md reports ALIGNLOSS on host silence > ~20 us. This predicts
#    loss RISING with the silence: worst at ~200 us (1,000 f/s), smaller at ~30 us
#    (1,200 f/s), and ~0 at ~3 us (1,240 f/s).
#  * A RATE-INDEPENDENT process predicts a FLAT ~1/1,720 across all three.
#  These are opposite orderings, so one 120 s leg per point separates them.
#
# The three points are ~1,000 / 1,200 / 1,240 f/s of TGEN emission; the silence quoted
# is relative to the air-frame slot (1/r - 1/1245.5 s), which is the quantity the
# starvation mechanism actually sees.
#
# TX-SIDE WITNESS: seqbist_run.sh reads tx_seam_checker (txchk_gpio 0x9D420000 ch1
# bit_errors / ch2 frames_checked) before and after every leg. frames_checked ==
# emitted with bit_errors == 0 proves the frames left the TX byte pins intact and
# localises the loss DOWNSTREAM (modulator / demod / deframer).
#
# GAPs are the model's estimates; the ACHIEVED rate is measured per leg and is what
# gets plotted -- the nominal is never quoted as a result.
# Env: DUR=120  SINK=tgenrx  DRY=1 (default)
# =============================================================================
set -u
S=$(cd "$(dirname "$0")" && pwd)
DUR=${DUR:-120}
DRY=${DRY:-1}
# GAP register value -> nominal TGEN rate (f/s) -> silence vs the 802.9 us air slot
# KNEE TRIALS (2026-09-04, after the first sweep collapsed): GAPs 31894/20471/18629 all
# sat at the consumption ceiling -- emitted == 0x104 == 1245 f/s, filler 0.00 %, silence
# 0 us -- so the independent variable was never varied and the legs measured one point
# three times. The gap register only bites ABOVE the ceiling gap, which is somewhere
# between 31894 (saturated) and 73384 (622.9 f/s, clearly under). These two points
# bracket the knee. ACCEPTANCE for a usable mission gap: emitted rate at least 4 % BELOW
# the 0x104 rate -- that is the operational definition of "under saturation", and it is
# what separates gap1-dominant (candidate fabric loss) from gap2-dominant (over-supply).
POINTS=${POINTS:-"45000:knee45:0 60000:knee60:0"}

echo "$(date -Is) === GAP SWEEP: ${DUR}s per point, points: $POINTS ==="
RC=0
for p in $POINTS; do
  GAP=${p%%:*}; rest=${p#*:}; NOM=${rest%%:*}; SIL=${rest##*:}
  echo "$(date -Is) --- point GAP=$GAP nominal=${NOM}f/s silence~${SIL}us ---"
  DRY=$DRY BOARD=148 MODE=loopback FILL=1516 GAP=$GAP DUR=$DUR \
    WINDOW_MIN=$(( DUR - 30 )) SINK=tgenrx TAG=sweep${NOM} bash "$S/seqbist_run.sh"
  rc=$?
  echo "$(date -Is) --- point GAP=$GAP rc=$rc ---"
  [ "$rc" = 0 ] || RC=$rc
done
echo "$(date -Is) === GAP SWEEP DONE rc=$RC ==="
exit $RC
