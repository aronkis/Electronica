#!/bin/bash
# =============================================================================
# arq_per_ab.sh [pairs] -- INTERLEAVED delivered-PER A/B: cross-link NAK ARQ
# (-A) on vs off. This is the headline PER lever found 2026-08-07.
#
# BACKGROUND. In two-radio -G mode qpsk_tun sets arq_on=0 by design ("the board
# that DETECTS a loss is not the board that SENT the frame"), and bringup_r2r3.sh
# has never passed -A. Confirmed on the rig: retx=0 dups=0 recovered=0 naks_tx=0
# across 93936 received frames, while seq_gap=662. Gaps were being detected and
# nothing was ever retransmitted.
# The loss budget explains why that matters: steady-state delivered PER (~1.38%)
# almost exactly equals never-detected (~0.38%, the framesync-rate deficit vs the
# 1245.44 f/s nominal geometry) plus CRC-fail among detected (~0.96%) -- agreeing
# per-run to within 0.02 points. Net ARQ recovery was ZERO because ARQ was off.
#
# FIRST MEASUREMENT with -A: pooled 0.675% (CP95UL 0.716%) = GATE PASS, vs 1.38%
# without. But the three runs improved monotonically (1.378 / 0.592 / 0.047%),
# which is equally consistent with the channel improving over those ~18 minutes.
# THAT is what this script controls for -- alternating on/off per run, so a time
# trend hits both arms equally.
#
# CAVEAT to carry into the analysis: NAK control frames consume a normal tx_seq
# but are never delivered to tun, so they should INFLATE measured PER on the -A
# arm. Any improvement measured here is therefore conservative.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
PAIRS=${1:-3}
STAMP_IN=${STAMP_IN:-}
STAMP=${STAMP_IN:-$(date +%Y%m%d_%H%M%S)}

for i in $(seq 1 "$PAIRS"); do
  for arm in arqoff arqon; do
    OUT=$D/r3cap/arqab_${STAMP}_${arm}_r$i
    echo "=== pair $i/$PAIRS  arm=$arm -> $OUT ==="
    if [ "$arm" = arqon ]; then export DAEMON_EXTRA="-A"; else export DAEMON_EXTRA=""; fi
    LO_B_RX=1900020000 RXQ=1 GATE_TRIES=12 "$D/capture_r3.sh" B -n 8000000 -o "$OUT" \
      > "$OUT.log" 2>&1 || { echo "  CAPTURE FAILED (see $OUT.log)"; continue; }
    $D/anyssh.sh 10.0.0.146 'tail -1 /dev/shm/qpsk_tun.log' 2>/dev/null \
      | grep -oE "recovered=[0-9]+ naks_tx=[0-9]+|seq_gap=[0-9]+" | tr '\n' ' '
    echo
  done
done
export DAEMON_EXTRA=""

echo
echo "=== DELIVERED PER, interleaved (ARQ off vs on) ==="
for arm in arqoff arqon; do
  echo "--- $arm ---"
  python3 "$D/accept_analyze.py" --arq $D/r3cap/arqab_${STAMP}_${arm}_r*/frames.bin 2>&1 | tail -10
done
