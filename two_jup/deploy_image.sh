#!/bin/bash
# =============================================================================
# deploy_image.sh <board-ip> [BOOT.BIN] -- flash ONE Jupiter with a byte-modem
# BOOT.BIN, back up the current image, reboot, and wait for it back. This is the
# GENERIC, board-agnostic deploy tool (deploy_pifix.sh / deploy_rxfix.sh etc. are
# frozen image-specific variants); use this one to bring up a FRESH pair of
# boards. See docs/PORTING.md.
#
#   deploy_image.sh 10.0.0.170                       # default image (lean build)
#   deploy_image.sh 10.0.0.170 /path/to/BOOT.BIN     # explicit image
#   SUFFIX=.pregeneric deploy_image.sh 10.0.0.170    # custom rollback backup name
#
# SAFETY ENVELOPE (identical to the proven deploy_pifix.sh, honoring the standing
# board constraints -- Jupiter has NO remote power, a bad /boot is a physical
# reflash to recover):
#   * new BOOT.BIN must exist and be > 6 MB
#   * /boot must have free space for the backup
#   * current /boot/BOOT.BIN backed up to /boot/BOOT.BIN$SUFFIX (size-checked)
#     -- ROLLBACK: cp /boot/BOOT.BIN$SUFFIX /boot/BOOT.BIN; sync; reboot
#   * new image staged to /root and size-verified BEFORE it overwrites /boot
#   NOTE: the backup at $SUFFIX is overwritten on every run -- deploy the two
#   boards ONE AT A TIME and confirm each is healthy before the next, so you
#   never lose your only known-good rollback.
#
# This flashes ONE board. For a pair, run it twice (staged), then provision.sh
# each and ./link_test.sh preflight. It does NOT run an acceptance test.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
# Default image = the current shipped lean build (see docs/PROVENANCE.md). Override
# with $2 or $BOOT. Build one from source per docs/BUILD.md if you have no artifact.
BOOT=${2:-${BOOT:-$(cd "$D/.." && pwd)/jupiter_byte_lean_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN}}
SUFFIX=${SUFFIX:-.pregeneric}   # rollback backup name: /boot/BOOT.BIN$SUFFIX
IP=${1:-}
[ -n "$IP" ] || { echo "usage: deploy_image.sh <board-ip> [BOOT.BIN]   (e.g. 10.0.0.170)"; exit 2; }
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

echo "=== DEPLOY IMAGE -> $IP  $(date -Is) ==="
SZ=$(stat -c %s "$BOOT" 2>/dev/null || echo 0)
[ "$SZ" -gt 6000000 ] || { echo "FATAL: BOOT.BIN missing or <6MB (path=$BOOT size=$SZ)"; exit 1; }
echo "new BOOT.BIN: size=$SZ md5=$(md5sum "$BOOT" | cut -c1-12)  (path=$BOOT)"
$W "$IP" 'echo up' 2>/dev/null | grep -q up || { echo "FATAL: $IP unreachable via anyssh.sh"; exit 1; }
# free space on /boot must hold the new backup (~7MB) with margin
FREE=$($W "$IP" "df -k /boot | awk 'NR==2{print \$4}'" 2>/dev/null || echo 0)
[ "${FREE:-0}" -gt 10000 ] || { echo "FATAL: /boot free ${FREE}KB < 10MB -- no room for backup"; exit 1; }
echo "  /boot free: ${FREE}KB"
# backup current /boot/BOOT.BIN (only if it is a sane size)
echo "  backup: $($W "$IP" "CB=\$(stat -c %s /boot/BOOT.BIN 2>/dev/null||echo 0); if [ \"\$CB\" -gt 6000000 ]; then cp -f /boot/BOOT.BIN /boot/BOOT.BIN$SUFFIX && sync && echo \"OK current=\$CB -> /boot/BOOT.BIN$SUFFIX\"; else echo \"REFUSE current size=\$CB\"; fi" 2>/dev/null)"
$W "$IP" "test -f /boot/BOOT.BIN$SUFFIX" 2>/dev/null || { echo "FATAL: backup not present -- aborting before overwrite"; exit 1; }
# push new image to /root, verify size, THEN overwrite /boot
scpput "$BOOT" root@"$IP":/root/BOOT.BIN.staged
FL=$($W "$IP" 'NB=$(stat -c %s /root/BOOT.BIN.staged 2>/dev/null||echo 0); if [ "$NB" -gt 6000000 ]; then cp -f /root/BOOT.BIN.staged /boot/BOOT.BIN && sync && echo "FLASHED size=$NB md5=$(md5sum /boot/BOOT.BIN|cut -c1-12)"; else echo "ABORT staged size=$NB"; fi' 2>/dev/null)
echo "  flash: $FL"
echo "$FL" | grep -q FLASHED || { echo "FATAL: flash did not complete -- /boot untouched or rollback with /boot/BOOT.BIN$SUFFIX"; exit 1; }
# reboot and wait for the board back (bounded)
echo "  rebooting $IP ..."; $W "$IP" 'sync; (sleep 1; reboot) &' 2>/dev/null
until ! ping -c1 -W1 "$IP" >/dev/null 2>&1; do sleep 2; done          # wait until it drops
T=0; until ping -c1 -W2 "$IP" >/dev/null 2>&1; do sleep 3; T=$((T+3)); [ "$T" -gt 180 ] && { echo "WARN: $IP not back after 180s -- check console"; break; }; done
sleep 20
echo "=== $IP back up: $($W "$IP" 'md5sum /boot/BOOT.BIN|cut -c1-12' 2>/dev/null) ==="
echo "  next: ./provision.sh $IP   then   ./link_test.sh preflight"
