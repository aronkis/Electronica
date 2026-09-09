#!/bin/bash
# =============================================================================
# m_depth_ab.sh [pairs] -- INTERLEAVED delivered-PER A/B on the RX DMA batch depth.
#
# WHY. The steady-state frame loss is periodic at exactly the batch depth: -M 16 ->
# period 16, -M 32 -> period 32, -M 64 -> ~69 with jitter. Single-run FER was 0.34%
# / 0.68% / 2.55%, i.e. halving M halves the loss. That is a big claim resting on one
# run per point, so this measures DELIVERED PER (the campaign metric, not fabric CRC)
# with the arms INTERLEAVED, because this rig's channel drifts by more than the effect
# being measured and every block-vs-block comparison in this campaign has been wrong.
#
# ARQ stays OFF: the point is to measure the loss itself, not what retransmission can
# paper over. -M 16 alone should land under the <1% gate if the single-run number holds.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
PAIRS=${1:-3}
STAMP=$(date +%Y%m%d_%H%M%S)

for i in $(seq 1 "$PAIRS"); do
  for M in 32 16; do                      # 32 first = current default is the control
    OUT=$D/r3cap/mab_${STAMP}_M${M}_r$i
    echo "=== pair $i/$PAIRS  -M $M -> $(basename "$OUT") ==="
    RXM=$M LO_B_RX=1900020000 RXQ=1 GATE_TRIES=12 \
      "$D/capture_r3.sh" B -n 4000000 -o "$OUT" > "$OUT.log" 2>&1 \
      || { echo "  CAPTURE FAILED"; continue; }
    # confirm the daemon really took the depth we asked for -- RXM is threaded through
    # bringup and a silent default would invalidate the whole comparison
    got=$($D/anyssh.sh 10.0.0.146 'tr "\0" " " < /proc/$(pgrep -x qpsk_tun|head -1)/cmdline 2>/dev/null' 2>/dev/null | grep -oE '\-M [0-9]+' | head -1)
    echo "    daemon cmdline: ${got:-UNKNOWN}  (wanted -M $M)"
  done
done

echo
echo "=== fabric loss period per arm ==="
for M in 32 16; do
  python3 "$D/loss_period.py" $D/r3cap/mab_${STAMP}_M${M}_r*/frames.bin --periods 8,16,32,64 2>/dev/null \
    | grep -E "===|FUNDAMENTAL|NOT periodic"
done
echo
echo "=== DELIVERED PER, interleaved ==="
for M in 32 16; do
  echo "--- -M $M ---"
  python3 "$D/accept_analyze.py" --arq $D/r3cap/mab_${STAMP}_M${M}_r*/frames.bin 2>&1 | tail -8
done
