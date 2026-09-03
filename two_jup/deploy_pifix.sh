#!/bin/bash
# deploy_pifix.sh -- flash ONE board with the pi-fix BOOT.BIN (demod boundary +
# CS loop-gain corrected; see FLOAT_FIXED_CAMPAIGN.md), reboot, wait for it back.
# SAFETY (deploy_rxfix.sh skeleton): new BOOT.BIN size-check >6MB; backup current
# /boot/BOOT.BIN -> /boot/BOOT.BIN.prepifix (size-checked, plus free-space check);
# verify staged size on-board before overwrite; reboot. NO acceptance test here.
# Staged: flash 148 first; 146's old image stays Tx-capable for the first check.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
BOOT=${BOOT:-$(cd "$D/.." && pwd)/jupiter_byte_pifix_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN}
IP=${1:-10.0.0.148}
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

echo "=== DEPLOY PIFIX -> $IP  $(date -Is) ==="
SZ=$(stat -c %s "$BOOT" 2>/dev/null || echo 0)
[ "$SZ" -gt 6000000 ] || { echo "FATAL: new BOOT.BIN missing or <6MB (path=$BOOT size=$SZ)"; exit 1; }
echo "new BOOT.BIN: size=$SZ md5=$(md5sum "$BOOT" | cut -c1-12)"
$W $IP 'echo up' 2>/dev/null | grep -q up || { echo "FATAL: $IP unreachable"; exit 1; }
# free space on /boot must hold the new backup (~7MB) with margin
FREE=$($W $IP "df -k /boot | awk 'NR==2{print \$4}'" 2>/dev/null || echo 0)
[ "${FREE:-0}" -gt 10000 ] || { echo "FATAL: /boot free ${FREE}KB < 10MB -- no room for backup"; exit 1; }
echo "  /boot free: ${FREE}KB"
# backup current /boot/BOOT.BIN (only if it is a sane size)
echo "  backup: $($W $IP 'CB=$(stat -c %s /boot/BOOT.BIN 2>/dev/null||echo 0); if [ "$CB" -gt 6000000 ]; then cp -f /boot/BOOT.BIN /boot/BOOT.BIN.prepifix && sync && echo "OK current=$CB -> /boot/BOOT.BIN.prepifix"; else echo "REFUSE current size=$CB"; fi' 2>/dev/null)"
$W $IP 'test -f /boot/BOOT.BIN.prepifix' 2>/dev/null || { echo "FATAL: backup not present -- aborting before overwrite"; exit 1; }
# push new image to /root, verify size, THEN overwrite /boot
scpput "$BOOT" root@$IP:/root/BOOT.BIN.pifix
FL=$($W $IP 'NB=$(stat -c %s /root/BOOT.BIN.pifix 2>/dev/null||echo 0); if [ "$NB" -gt 6000000 ]; then cp -f /root/BOOT.BIN.pifix /boot/BOOT.BIN && sync && echo "FLASHED size=$NB md5=$(md5sum /boot/BOOT.BIN|cut -c1-12)"; else echo "ABORT staged size=$NB"; fi' 2>/dev/null)
echo "  flash: $FL"
echo "$FL" | grep -q FLASHED || { echo "FATAL: flash did not complete"; exit 1; }
# reboot
echo "  rebooting $IP ..."; $W $IP 'sync; (sleep 1; reboot) &' 2>/dev/null
echo "=== $IP flashed + reboot issued; wait for reachability, then provision/verify ==="
