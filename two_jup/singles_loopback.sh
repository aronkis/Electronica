#!/bin/bash
# =============================================================================
# singles_loopback.sh -- Phase 1: does the forward singles-comb exist OFF AIR?
#
# Runs the RX chain in FPGA-internal loopback (0x114=0) through the REAL host DMA
# path, sweeping -M. The cadence-lock to the DMA transfer boundary -- not the
# absolute rate -- is the class fingerprint, which is why -M is swept.
#
# This mode was measured at 1246 f/s with rstcs=0 on both boards (two_jup/lb_discrim.sh,
# 2026-08-22), so it runs even while the reverse RF leg is broken.
#
# VERDICT RULE (stated before the run -- do not revise it afterwards):
#   REPRODUCES   singles+doubles dominate AND boundary_locked at every M AND PER
#                within 3x of the air value  -> channel exonerated, campaign off-air
#   NOT REPRO    PER <= 0.5% AND boundary_locked false at every M
#                -> re-run over SSI near-end loopback to split RF vs SSI clock chain
#   PARTIAL      present at a materially different rate -> record the ratio
#   VOID         the -G positive control does not frame -> config wrong, no verdict
#
# MODE CORRECTION (2026-08-22, measured -- the first version of this script ran ARM
# B as -S, which QPSK_FRAMELOG does NOT populate: -S logs every record crc_ok=0 with
# host_seq unset, and singles_cadence.py correctly refuses to score that (raises
# instead of inventing a frame universe). ARM B now runs -B (BER mode), the mode
# QPSK_FRAMELOG actually fills correctly, exactly as two_jup/capture_paired.sh does
# it. -B carries no per-frame host_seq (measured: 4 unique garbage values over
# 35,022 records) so the sequence for scoring is reg_packets (the hardware packet
# counter, measured exactly 1-per-frame and monotonic in this same probe) via
# --seq reg_packets. The -G positive control (ARM A) is unchanged.
#
# CAVEAT, worth carrying into the verdict: qpsk_tun.c forces rx_multi=0 (the
# legacy single-packet RX/DMA path) whenever -B mode is selected, REGARDLESS of
# -M ("if (ber || ...) rx_multi = 0;"). So -M does not change the host DMA
# transfer batch size under -B the way it does under -S/-G -- every DMA
# transfer is 1 frame. A "boundary_locked" result under this arm shows losses
# landing on a reg_packets % M residue class; it does NOT by itself demonstrate
# that the loss is tied to an M-frame-batched DMA transfer boundary, because
# that batching is not actually exercised here. Report this explicitly; do not
# claim the DMA-batching mechanism is confirmed by this arm alone.
#
# ONE RIG HARNESS AT A TIME. Restore afterwards: two_jup/restore_known_good.sh
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
BOARD=${BOARD:-10.0.0.148}
DUR=${DUR:-120}
MS=${MS:-"16 32 64"}
STAMP=$(date +%Y%m%d_%H%M%S)
LEDGER=$D/r3cap/singlesloop_${STAMP}_summary.txt

echo "=== singles_loopback on $BOARD, M in [$MS], ${DUR}s each -> $LEDGER ==="
: > "$LEDGER"

for M in $MS; do
  OUT=$D/r3cap/singlesloop_${STAMP}_M${M}
  echo "--- M=$M ---" | tee -a "$LEDGER"
  BOARD=$BOARD M=$M DUR=$DUR FRAMELOG=1 ARMB_FLAG=-B ARMB_GREP="^ber: t=" \
    "$D/loopback_s_test.sh" > "$OUT.log" 2>&1
  rc=$?
  # loopback_s_test.sh writes into its own timestamped dir; adopt the newest one
  SRC=$(ls -1dt "$D"/r3cap/loopback_* 2>/dev/null | head -1)
  mkdir -p "$OUT"; [ -n "$SRC" ] && cp -a "$SRC"/. "$OUT"/ 2>/dev/null

  # POSITIVE CONTROL. The verdict block prints "ARM A  -G loopback : idle_rx = <N>";
  # the control PASSES when N > 0. Use idle_rx, never dma_rx_ok (-G with no peer sends
  # only idle frames, so dma_rx_ok is structurally zero and once voided a good config).
  IDLE=$(sed -n 's/.*ARM A .*idle_rx = \([0-9][0-9]*\).*/\1/p' "$OUT.log" | tail -1)
  if grep -q '^\s*>>> VOID\.' "$OUT.log" 2>/dev/null || [ -z "$IDLE" ] || [ "$IDLE" -le 0 ]; then
    echo "  M=$M VOID -- -G control did not frame (idle_rx=${IDLE:-unparsed}, exit=$rc)" | tee -a "$LEDGER"
    continue
  fi
  if [ ! -s "$OUT/frames.bin" ]; then
    echo "  M=$M NO DATA -- frames.bin missing/empty (exit=$rc); see $OUT.log" | tee -a "$LEDGER"
    continue
  fi
  echo "  control OK (idle_rx=$IDLE)" | tee -a "$LEDGER"
  # ARM B runs -B: score on reg_packets, the only field -B populates as a
  # usable per-frame sequence (see MODE CORRECTION note above).
  python3 "$D/singles_cadence.py" "$OUT/frames.bin" --M "$M" --seq reg_packets | tee -a "$LEDGER"
done

echo "SINGLES_LOOPBACK_DONE stamp=$STAMP" | tee -a "$LEDGER"
echo "Apply the verdict rule in this script's header to the table above."
