#!/bin/bash
# =============================================================================
# capture_residual.sh -- byte-mode reverse capture at the +20 kHz OFF-NULL
# operating point, to characterize the RESIDUAL ~11% failure mode.
#
# CONTEXT: the reverse link's DOMINANT loss was the CFO~=0 demod dead-zone. Moving
# the 146 RX LO off-null (1900002500 -> 1900020000, +20 kHz) recovered ROM golden
# 17% -> 89% (dead-zone removed). What's LEFT -- the residual ~11% -- is a SEPARATE
# mode that MORE off-null does NOT fix (89% at +20k AND +40k -> plateau), so it is
# NOT the dead-zone: candidates are SNR / carrier-loop gain / the axi_adrv9001 SSI
# interface. This capture collects that residual regime in BYTE mode with per-frame
# telemetry (frames.bin) + a raw IQ window (pair.iq) for offline analysis.
#
# It runs capture_r3.sh B with LO_B_RX overridden to +20k off-null and a long IQ
# window (40M samples ~0.65s) to contain the residual error bursts.
#
# Usage: capture_residual.sh [-d dur] [-n nsamp] [extra capture_r3 args]
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
OUT=$D/r3cap/residual_$(date +%Y%m%d_%H%M%S)
echo "=== RESIDUAL-REGIME capture: 146 RX LO +20k off-null (1900020000), byte mode ==="
echo "    (dead-zone removed; capturing the separate residual ~11% mode) -> $OUT"
# LO_B_RX env propagates through capture_r3.sh -> bringup_r2r3.sh (env-overridable).
LO_B_RX=1900020000 "$D/capture_r3.sh" B -n 40000000 -o "$OUT" "$@"
rc=$?
[ $rc -ne 0 ] && { echo "capture failed rc=$rc"; exit $rc; }

echo ""
echo "=== residual characterization (SNR / loop / SSI) -- run offline after capture ==="
echo "  # 1. per-frame error taxonomy (periodicity / rstcs / CFO-dither / level / burst):"
echo "  python3 $D/frame_taxonomy.py $OUT/frames.bin --frame-period-s 0.000803"
echo "  # 2. SNR proxy -- float per-frame EVM on the captured IQ (high EVM = SNR-limited):"
echo "  #    matlab -batch \"addpath('$(cd "$D/.." && pwd)/evm'); r=evm_ideal_ref('$OUT/pair.iq',evm_config_1536k()); fprintf('RMS EVM=%.1f%% p99=%.1f%%\\n',r.rms_evm,prctile(r.frameEVM,99))\""
echo "  # 3. errored-frame -> IQ windows (for fixed-point/state-injection follow-up):"
echo "  python3 $D/align_frames.py $OUT/frames.bin $OUT/regs_cap.txt --spf 49332 --pair $OUT/pair.iq -o $OUT"
echo "  NOTE: adc_forensic (0x15C, the SSI valid-cadence probe) is STRIPPED in LEAN Image B"
echo "        -> ruling SSI in/out needs a non-LEAN instrumented image."
echo "CAPTURE_RESIDUAL_DONE $OUT"
