#!/bin/bash
# t8_final_restore.sh -- task 8 hand-over: put the plain daemons back on BOTH boards
# using capture_r3.sh's own build line (restore_known_good.sh drives it), verify the
# instrumentation survived, and report the state. Does NOT release the keeper hold --
# that is a separate, explicit step by the driver after this reports clean.
# Env: DRY=1 (default), LO_B_RX (default 1900040000 = the SHIPPED reverse default;
#      restore_known_good.sh's own default is 1900020000, which is NOT the shipped one).
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh
DRY=${DRY:-1}
export LO_B_RX=${LO_B_RX:-1900040000}
echo "=== t8_final_restore $(date -Is) DRY=$DRY LO_B_RX=$LO_B_RX ==="
if [ "$DRY" = 1 ]; then
  echo "[dry] LO_B_RX=$LO_B_RX bash $D/restore_known_good.sh   (capture_r3 build line: gcc -O2 -Wall -DQPSK_CARVE_2MB \$NAKKEEP ... -> bringup_r2r3.sh r3 -> daemons + watchdogs)"
  echo "[dry] verify: 148 strings qpsk_tun | grep -c nakstat == 4; both boards qpsk_tun + lock_watchdog running; 0x104 rate"
  echo "=== t8_final_restore DONE (dry) ==="; exit 0
fi
bash "$D/restore_known_good.sh" 2>&1 | tail -40
echo "--- post-restore verification (read-only) ---"
for ip in 10.0.0.148 10.0.0.146; do
  out=$($W $ip 'echo IMG=$(md5sum /boot/BOOT.BIN | cut -c1-12) NAKSTAT_N=$(strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -c nakstat)
echo TUN=$(pgrep -x qpsk_tun | tr "\n" ",") WD=$(pgrep -f "lock_watchdog.sh" | tr "\n" ",")' 2>&1 | tr -d '\r')
  echo "  $ip $out"
done
echo "=== t8_final_restore DONE $(date -Is) ==="
