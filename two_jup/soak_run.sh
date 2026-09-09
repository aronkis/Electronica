#!/bin/bash
# soak_run.sh -- Task 10 Step 2 driver: bidirectional acceptance soak.
# Attempts soak_bidir.sh A -d 200 (~250k frames/direction nominal) up to 3
# times, accumulating live-window frames per direction until BOTH have >=200k;
# scores each direction with accept_analyze.py per attempt (pooling recorded
# manually in the ledger from the per-attempt outputs). ARQ OFF verified
# in-band per attempt via nakstat on both boards; fixctl=3 asserted per attempt.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
TS=$(date +%Y%m%d_%H%M%S)
echo "SOAK_RUN start $(date -Is)"
for T in 1 2 3; do
  OUT=$D/r3cap/soak_${TS}_a$T
  echo "=== attempt $T -> $OUT ==="
  $W 10.0.0.148 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
    echo "0x208 0x3" > $DRA; echo FIXCTL3' 2>/dev/null | tail -1
  for ip in 10.0.0.146 10.0.0.148; do
    # in-band ARQ-OFF check: binary fingerprint (nakstat strings count, 148 must
    # be 4 = the ARQ-off-capable build) + live daemon cmdline (no ARQ flag)
    NS=$($W $ip 'echo "nakfp=$(strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -c nakstat) cmdline=$(cat /proc/$(pidof qpsk_tun)/cmdline 2>/dev/null | tr "\0" " ")"' 2>/dev/null | tail -1)
    echo "  ARQ-check $ip: ${NS:-unreadable}"
  done
  # both-directions gate (no GATE_DIR override): the soak scores BOTH legs, so
  # a degraded 146 RX must fail the gate, not contaminate the reverse number
  GATE_TRIES=12 $D/soak_bidir.sh A -d 200 -k -o "$OUT" > "$OUT.log" 2>&1
  echo "attempt $T rc=$?"
  for F in frames frames_peer; do
    if [ -f "$OUT/$F.bin" ]; then
      echo "--- $F analysis (attempt $T) ---"
      python3 $D/accept_analyze.py "$OUT/$F.bin" 2>&1 | tee "$OUT/analysis_$F.txt" | grep -E "live|POOLED|GATE|wedges"
    else
      echo "--- $F.bin MISSING (attempt $T); log tail:"; tail -3 "$OUT.log"
    fi
  done
  FWD=$(grep -hoE 'PER=[0-9.]+% \(([0-9]+)/([0-9]+)\)' $D/r3cap/soak_${TS}_a*/analysis_frames.txt 2>/dev/null | grep -oE '/[0-9]+' | tr -d / | paste -sd+ | bc)
  REV=$(grep -hoE 'PER=[0-9.]+% \(([0-9]+)/([0-9]+)\)' $D/r3cap/soak_${TS}_a*/analysis_frames_peer.txt 2>/dev/null | grep -oE '/[0-9]+' | tr -d / | paste -sd+ | bc)
  echo "cumulative live frames: fwd=${FWD:-0} rev=${REV:-0}"
  [ "${FWD:-0}" -ge 200000 ] && [ "${REV:-0}" -ge 200000 ] && { echo "TARGET_REACHED after attempt $T"; break; }
done
echo "--- post: restore + verify ---"
bash $D/restore_known_good.sh > /tmp/soak_rkg_post.log 2>&1
$W 10.0.0.148 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  echo "0x208 0x3" > $DRA; echo FIXCTL3' 2>/dev/null | tail -1
echo "post 148: $(bash $D/health_probe_reset_aware.sh 10.0.0.148 12 2>/dev/null | tail -1)"
echo "post 146: $(bash $D/health_probe_reset_aware.sh 10.0.0.146 12 2>/dev/null | tail -1)"
echo "SOAK_RUN_DONE $(date -Is)"
