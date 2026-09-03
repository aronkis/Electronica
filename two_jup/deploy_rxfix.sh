#!/bin/bash
# deploy_rxfix.sh -- flash ONE board with the rxfix BOOT.BIN, reboot, wait for it back.
# SAFETY: new BOOT.BIN size-check >6MB; backup current /boot/BOOT.BIN (size-check) before overwrite;
# verify on-board size before overwrite; reboot; wait for reachability. NO acceptance test here
# (run live_check.sh after). Staged: flash 148 (RX) first; 146 old image still Tx-capable for the test.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
BOOT=${BOOT:-/mnt/onetb/scratch/qpsk_variants/jupiter_byte_rxfix_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN}
IP=${1:-10.0.0.148}
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

echo "=== DEPLOY RXFIX -> $IP  $(date -Is) ==="
SZ=$(stat -c %s "$BOOT" 2>/dev/null || echo 0)
[ "$SZ" -gt 6000000 ] || { echo "FATAL: new BOOT.BIN missing or <6MB (path=$BOOT size=$SZ)"; exit 1; }
echo "new BOOT.BIN: size=$SZ md5=$(md5sum "$BOOT" | cut -c1-12)"
$W $IP 'echo up' 2>/dev/null | grep -q up || { echo "FATAL: $IP unreachable"; exit 1; }
# backup current /boot/BOOT.BIN (only if it is a sane size)
echo "  backup: $($W $IP 'CB=$(stat -c %s /boot/BOOT.BIN 2>/dev/null||echo 0); if [ "$CB" -gt 6000000 ]; then cp -f /boot/BOOT.BIN /boot/BOOT.BIN.prerxfix && echo "OK current=$CB -> /boot/BOOT.BIN.prerxfix"; else echo "REFUSE current size=$CB"; fi' 2>/dev/null)"
$W $IP 'test -f /boot/BOOT.BIN.prerxfix' 2>/dev/null || { echo "FATAL: backup not present -- aborting before overwrite"; exit 1; }
# push new image to /root, verify size, THEN overwrite /boot
scpput "$BOOT" root@$IP:/root/BOOT.BIN.rxfix
FL=$($W $IP 'NB=$(stat -c %s /root/BOOT.BIN.rxfix 2>/dev/null||echo 0); if [ "$NB" -gt 6000000 ]; then cp -f /root/BOOT.BIN.rxfix /boot/BOOT.BIN && sync && echo "FLASHED size=$NB md5=$(md5sum /boot/BOOT.BIN|cut -c1-12)"; else echo "ABORT staged size=$NB"; fi' 2>/dev/null)
echo "  flash: $FL"
echo "$FL" | grep -q FLASHED || { echo "FATAL: flash did not complete"; exit 1; }
# reboot
echo "  rebooting $IP ..."; $W $IP 'sync; (sleep 1; reboot) &' 2>/dev/null
echo "=== $IP flashed + reboot issued; run: until anyssh reachable; then live_check.sh ==="
