#!/bin/bash
# =============================================================================
# deploy_image.sh <board-ip> [BOOT.BIN] -- flash ONE Jupiter with a byte-modem
# BOOT.BIN, back up the current image, reboot, and wait for it back. This is the
# GENERIC, board-agnostic deploy tool (deploy_pifix.sh / deploy_rxfix.sh etc. are
# frozen image-specific variants); use this one to bring up a FRESH pair of
# boards. See docs/PORTING.md.
#
#   deploy_image.sh 10.0.0.170 A                     # current image for role A (boot_known_good/CURRENT.txt)
#   deploy_image.sh 10.0.0.170 B                     # current image for role B
#   deploy_image.sh 10.0.0.170 /path/to/BOOT.BIN     # explicit image
#   deploy_image.sh 10.0.0.170                       # legacy default: the lean build tree (only on a build host)
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
D=$(cd "$(dirname "$0")" && pwd)
# bounded board calls: SSH_T s per anyssh call (default 60), SCP_T s per scp (default 300)
wssh(){ timeout "${SSH_T:-60}" "$D/anyssh.sh" "$@"; local rc=$?; [ $rc -eq 124 ] && echo "  [TIMEOUT] anyssh $1 exceeded ${SSH_T:-60}s" >&2; return $rc; }
W=wssh
# Default image = the current shipped lean build (see docs/PROVENANCE.md). Override
# with $2 or $BOOT. Build one from source per docs/BUILD.md if you have no artifact.
ROOT=$(cd "$D/.." && pwd)
BKG=$ROOT/boot_known_good
case "${2:-}" in
  A|B)
    LINE=$(grep -E "^${2} " "$BKG/CURRENT.txt" 2>/dev/null | head -1)
    [ -n "$LINE" ] || { echo "FATAL: no role ${2} in $BKG/CURRENT.txt"; exit 1; }
    BOOT=$BKG/$(echo "$LINE" | awk '{print $2}'); WANT=$(echo "$LINE" | awk '{print $3}')
    HAVE=$(md5sum "$BOOT" 2>/dev/null | awk '{print $1}')
    [ "$HAVE" = "$WANT" ] || { echo "FATAL: $BOOT md5=$HAVE, CURRENT.txt says $WANT (git lfs/pull incomplete? file missing?)"; exit 1; }
    echo "role ${2}: $(echo "$LINE" | cut -d' ' -f4-)";;
  *)
    BOOT=${2:-${BOOT:-$ROOT/jupiter_byte_lean_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN}};;
esac
SUFFIX=${SUFFIX:-.pregeneric}   # rollback backup name: /boot/BOOT.BIN$SUFFIX
IP=${1:-}
[ -n "$IP" ] || { echo "usage: deploy_image.sh <board-ip> [BOOT.BIN]   (e.g. 10.0.0.170)"; exit 2; }
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 timeout "${SCP_T:-300}" setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

echo "=== DEPLOY IMAGE -> $IP  $(date -Is) ==="
SZ=$(stat -c %s "$BOOT" 2>/dev/null || echo 0)
[ "$SZ" -gt 6000000 ] || { echo "FATAL: BOOT.BIN missing or <6MB (path=$BOOT size=$SZ)"; echo "  hint: pass a role, e.g.  deploy_image.sh $IP A   (images + md5s in $BKG/CURRENT.txt), or an explicit /path/to/BOOT.BIN"; exit 1; }
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
T=0; until ! ping -c1 -W1 "$IP" >/dev/null 2>&1; do sleep 2; T=$((T+2)); [ "$T" -gt 90 ] && { echo "WARN: $IP never went down within 90s -- reboot may not have taken; check console"; break; }; done   # wait until it drops (bounded)
T=0; until ping -c1 -W2 "$IP" >/dev/null 2>&1; do sleep 3; T=$((T+3)); [ "$T" -gt 180 ] && { echo "WARN: $IP not back after 180s -- check console"; break; }; done
sleep 20
echo "=== $IP back up: $($W "$IP" 'md5sum /boot/BOOT.BIN|cut -c1-12' 2>/dev/null) ==="
echo "  next: ./provision.sh $IP   then   ./link_test.sh preflight"
