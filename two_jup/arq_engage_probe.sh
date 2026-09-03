#!/bin/bash
# =============================================================================
# arq_engage_probe.sh [runs] -- catch the ~1-in-3 ARQ ENGAGEMENT FAILURE with
# counters attached, on both boards, per run.
#
# THE OPEN QUESTION. With -A enabled the delivered-PER distribution is strongly
# BIMODAL over 6 gate runs: 0.030 0.032 0.061 0.098 | 1.873 2.088 (percent).
# Median 0.080%, nothing between 0.10% and 1.8%. The good mode beats the <1%
# gate by ~50x; the bad mode is indistinguishable from ARQ-off. Two identical
# 3-run gate sets 25 min apart therefore split PASS / FAIL purely on how many
# bad runs they drew. Closing the bad mode is the highest-value work left.
#
# WHAT THIS DOES. Runs N ARQ-on captures and, after each, snapshots the ARQ
# counters on BOTH ends, then prints them next to that run's PER. The RX board
# (146) opens holes and sends NAKs; the TX board (148) receives NAKs and resends.
# So the chain is: 146.seq_gap -> 146.naks_tx -> 148.naks_rx -> 148.retx ->
# 146.recovered. A bad run should break that chain at ONE identifiable link:
#   146.naks_tx ~ 0            -> holes not being NAK'd (table/lifetime problem)
#   148.naks_rx << 146.naks_tx -> NAKs not arriving (return path)
#   148.retx ~ 0 despite naks_rx -> peer not honouring NAKs (hist miss)
#   146.recovered << 148.retx  -> retransmits arriving too late (dups high)
# Whichever link breaks on the bad runs and holds on the good ones IS the bug.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
N=${1:-4}
STAMP=$(date +%Y%m%d_%H%M%S)
OUT=$D/r3cap/arqeng_$STAMP
mkdir -p "$OUT"
export DAEMON_EXTRA="-A"; export DAEMON_ENV=""

ctr(){ $W "$1" 'tail -1 /dev/shm/qpsk_tun.log' 2>/dev/null \
       | tr ' ' '\n' | grep -E "^(seq_gap|retx|dups|recovered|naks_tx|naks_rx|arq_lost|dma_rx_ok|crc_drop)=" | tr '\n' ' '; }

for i in $(seq 1 "$N"); do
  C=$OUT/r$i
  echo "=== run $i/$N ==="
  LO_B_RX=1900020000 RXQ=1 GATE_TRIES=12 "$D/capture_r3.sh" B -n 8000000 -o "$C" \
    > "$C.log" 2>&1 || { echo "  CAPTURE FAILED"; continue; }
  { echo "146 $(ctr 10.0.0.146)"; echo "148 $(ctr 10.0.0.148)"; } > "$C.ctr"
  cat "$C.ctr"
done
unset DAEMON_EXTRA DAEMON_ENV

echo
echo "=== PER vs ARQ counters, per run ==="
for i in $(seq 1 "$N"); do
  [ -f "$OUT/r$i/frames.bin" ] || continue
  P=$(python3 "$D/accept_analyze.py" --arq "$OUT/r$i/frames.bin" 2>/dev/null \
      | grep -oE "PER=[0-9.]+%|UNUSABLE" | head -1)
  echo "--- run $i  ${P:-?}"
  sed 's/^/      /' "$OUT/r$i.ctr" 2>/dev/null
done
echo
echo "Chain to check: 146.seq_gap -> 146.naks_tx -> 148.naks_rx -> 148.retx -> 146.recovered"
echo "The link that breaks on the BAD runs and holds on the GOOD ones is the bug."
