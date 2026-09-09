#!/bin/bash
# =============================================================================
# arq_tune_ab.sh [pairs] -- INTERLEAVED delivered-PER A/B: cross-link NAK ARQ at
# stock tuning vs a longer-lived / larger hole table. Both arms run -A.
#
# DIAGNOSIS THIS TESTS (measured 2026-08-07, 90 s of traffic, counters both ends):
#   146 (RX): naks_tx=354 recovered=1208 dups=1307 arq_lost=27257
#   148 (TX): naks_rx=305 retx=3176
# The NAK path works -- 86% of NAKs arrive and the peer does retransmit. Two things
# then waste it:
#   1. arq_lost 27257 vs recovered 1208: holes open far faster than they are filled.
#      The table is 512 entries and one jump can open up to 128 (AXR_GAP_CLAMP).
#   2. dups 1307 > recovered 1208: MORE THAN HALF the retransmits land after their
#      hole was abandoned. At tries=3 and renak=64 rx_ticks a hole lives ~150 ms,
#      plausibly shorter than the retransmit round trip.
# Both say: hold holes longer, and hold more of them.
#   tuned = QPSK_ARQ_HOLES=2048 TRIES=8 RENAK=32 CLAMP=256
#           (4x table, ~4x lifetime via more tries at half the re-NAK interval)
#
# Success criterion is delivered PER, but ALSO watch dups vs recovered: if tuning
# works, recovered should rise and dups should fall relative to it. If dups rise
# with recovered, we are just spending more air time for the same result.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
PAIRS=${1:-3}
STAMP=$(date +%Y%m%d_%H%M%S)
TUNED="QPSK_ARQ_HOLES=2048 QPSK_ARQ_TRIES=8 QPSK_ARQ_RENAK=32 QPSK_ARQ_CLAMP=256"

for i in $(seq 1 "$PAIRS"); do
  for arm in stock tuned; do
    OUT=$D/r3cap/arqtune_${STAMP}_${arm}_r$i
    echo "=== pair $i/$PAIRS  arm=$arm -> $OUT ==="
    export DAEMON_EXTRA="-A"
    if [ "$arm" = tuned ]; then export DAEMON_ENV="$TUNED"; else export DAEMON_ENV=""; fi
    LO_B_RX=1900020000 RXQ=1 GATE_TRIES=12 "$D/capture_r3.sh" B -n 8000000 -o "$OUT" \
      > "$OUT.log" 2>&1 || { echo "  CAPTURE FAILED (see $OUT.log)"; continue; }
    echo -n "    banner: "; $D/anyssh.sh 10.0.0.146 'grep -m1 -o "holes=[0-9]* renak=[0-9]* ticks, tries=[0-9]*, clamp=[0-9]*" /dev/shm/qpsk_tun.log' 2>/dev/null
    echo -n "    counters: "; $D/anyssh.sh 10.0.0.146 'tail -1 /dev/shm/qpsk_tun.log' 2>/dev/null \
      | tr ' ' '\n' | grep -E "^(recovered|dups|naks_tx|arq_lost|seq_gap)=" | tr '\n' ' '; echo
  done
done
export DAEMON_EXTRA=""; export DAEMON_ENV=""

echo
echo "=== DELIVERED PER, interleaved (ARQ stock vs tuned) ==="
for arm in stock tuned; do
  echo "--- $arm ---"
  python3 "$D/accept_analyze.py" --arq $D/r3cap/arqtune_${STAMP}_${arm}_r*/frames.bin 2>&1 | tail -10
done
