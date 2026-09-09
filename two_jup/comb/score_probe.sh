#!/bin/bash
# score_probe.sh <run-dir> -- the pre-registered Task 8a scoring set, in one place,
# so every probe leg is scored identically (RADIO_PROBES_PREREG.md sec 5).
set -u
R=${1:?usage: score_probe.sh <run-dir>}
D=$(cd "$(dirname "$0")" && pwd); TJ=$(cd "$D/.." && pwd)
C=$R/cap
{
echo "======== SCORE $R  $(date -Is)"
echo "---- meta"; cat "$R/meta.txt" 2>/dev/null
echo "---- attribute witness (capture_r3 hook)"; cat "$C/attr_poke.txt" 2>/dev/null
echo "---- restore witness"; cat "$R/attr_restore.txt" 2>/dev/null
echo "---- (1) accept_analyze  [PER, lost frames in the denominator]"
python3 "$TJ/accept_analyze.py" "$C/frames.bin" 2>&1
echo "---- (2) comb_autocorr   [ALL-LOSS lag family, lag16 floor]"
python3 "$D/comb_autocorr.py" "$C/frames.bin" 2>&1
echo "---- (3) comb_period_ms  [fractional period in frames and ms]"
python3 "$D/comb_period_ms.py" "$C/frames.bin" 2>&1
echo "---- (4) comb_census     [fail classes, MAGIC share, TX<->RX join]"
python3 "$D/comb_census.py" "$C/frames.bin" --failhdr "$C/failhdr.bin" --txlog "$C/txlog_peer.bin" 2>&1
echo "---- (5) detections vs deliveries: 0x104 delta vs host record count"
grep -E "CAP_START|CAP_END" "$C/regs_cap.txt" 2>/dev/null
echo "regs_pre:"; cat "$C/regs_pre.txt" 2>/dev/null
echo "regs_post:"; cat "$C/regs_post.txt" 2>/dev/null
echo "host records in frames.bin: $(( $(stat -c%s "$C/frames.bin" 2>/dev/null || echo 0) / 48 )) (48 B/record)"
echo "======== END SCORE $R"
} 2>&1 | tee "$R/score.txt"
