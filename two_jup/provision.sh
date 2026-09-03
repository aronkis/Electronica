#!/bin/bash
# =============================================================================
# provision.sh <board-ip> -- install the on-board files that link_test.sh
# preflight REQUIRES, onto ONE Jupiter that is ALREADY flashed with a byte-modem
# BOOT.BIN. This is the piece deploy_rxfix.sh does NOT do (it flashes /boot only):
#
#   /root/host_app_k5/qpsk_tun      built on-board from the host_app_k5 sources
#   /root/lvds_1p92_mhz.{bin,json}  ADRV9002 LVDS 1.92 MHz profile
#   /root/lock_watchdog.sh          on-board acquisition watchdog
#
# Board access via anyssh.sh; sources via scp+askpass (never cat). Compiling on
# the board is safe: it never arms the radio, touches a DMA, or writes /boot.
# Run once per board:  ./provision.sh 10.0.0.148   &&   ./provision.sh 10.0.0.146
# then verify:         ./link_test.sh preflight
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$D/../host_app_k5
IP=${1:-}
[ -n "$IP" ] || { echo "usage: provision.sh <board-ip>   (e.g. 10.0.0.148)"; exit 2; }
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

echo "=== PROVISION $IP  $(date -Is) ==="
$W "$IP" 'echo up' 2>/dev/null | grep -q up || { echo "FATAL: $IP unreachable via anyssh.sh"; exit 1; }

# sanity: the master files must exist on the host
for f in "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_ber.c" \
         "$D/lvds_1p92_mhz.bin" "$D/lvds_1p92_mhz.json" "$D/lock_watchdog.sh"; do
  [ -f "$f" ] || { echo "FATAL: master file missing on host: $f"; exit 1; }
done

# 1) host app: scp the sources qpsk_tun needs, build on-board with plain gcc
#    (the board-proven recipe from ber_loopback_gate.sh -- no dependence on make).
echo "-- host_app_k5 sources -> board; build qpsk_tun (on-board gcc) --"
$W "$IP" 'mkdir -p /root/host_app_k5' 2>/dev/null
scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_ber.c" \
       "$SRC/qpsk_frame.h" "$SRC/qpsk_ber.h" "$SRC/qpsk_hw.h" root@"$IP":/root/host_app_k5/
$W "$IP" 'cd /root/host_app_k5 && gcc -O2 -Wall -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c 2>&1 | tail -3
  [ -x qpsk_tun ] && echo "  qpsk_tun built OK" || echo "  qpsk_tun BUILD FAILED"' 2>/dev/null

# 2) LVDS 1.92 MHz profile
echo "-- lvds_1p92_mhz.{bin,json} -> /root --"
scpput "$D/lvds_1p92_mhz.bin" "$D/lvds_1p92_mhz.json" root@"$IP":/root/

# 3) on-board acquisition watchdog
echo "-- lock_watchdog.sh -> /root --"
scpput "$D/lock_watchdog.sh" root@"$IP":/root/
$W "$IP" 'chmod +x /root/lock_watchdog.sh' 2>/dev/null

# verify EXACTLY what link_test.sh preflight checks
echo "-- verify (mirrors link_test.sh preflight) --"
$W "$IP" '
  [ -x /root/host_app_k5/qpsk_tun ] && echo "  [ ok ] qpsk_tun"  || echo "  [FAIL] qpsk_tun"
  [ -f /root/lvds_1p92_mhz.bin ]    && echo "  [ ok ] lvds_bin"  || echo "  [FAIL] lvds_bin"
  [ -f /root/lvds_1p92_mhz.json ]   && echo "  [ ok ] lvds_json" || echo "  [FAIL] lvds_json"
  [ -f /root/lock_watchdog.sh ]     && echo "  [ ok ] watchdog"  || echo "  [FAIL] watchdog"
' 2>/dev/null
echo "=== PROVISION $IP done -- next: ./link_test.sh preflight ==="
