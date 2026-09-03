#!/bin/bash
# flash_148_rxfifo.sh <md5-12> -- flash 148 with the RX-FIFO-4k image (BEATFIX v3 +
# BRAM ByteRxFifo 4096 deep, E9 fix). Cloned from flash_148_beatfix2.sh; standing
# rails unchanged: md5 precondition, on-board rollback bank of the CURRENT image
# (fe5bd8a4fe19 = the restore point), readback verify, FULL bring-up, NAK=4,
# two-pass reset-aware health gate (fsync>=1100 AND wcnt>=1100 AND 0x1C0 advance),
# auto-rollback on failure, NO retry. Amendment (08-26): pre-flash 148 health
# precondition -- never flash onto a wedged/degraded instrument.
# Extra witness (non-fatal): ByteRxFifo overflow counter 0x1B0 delta over 10 s
# after bring-up (expected ~0 on this image; the comb image drops 17-45 words/s).
set -u
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem
D=$ROOT/two_jup
W=$D/anyssh.sh
A=10.0.0.148
BB=$ROOT/jupiter_byte_rxfifo4k_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
EXP=${1:?usage: flash_148_rxfifo.sh <md5-12>}
BAK_MD5=fe5bd8a4fe19
echo "FLASH_RXFIFO start $(date -Is) pid=$$"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no "$@" </dev/null 2>>/tmp/rxfifo_scp_err.txt; }
wait_back(){ sleep 45; local n=0
  until $W $A 'echo up' >/dev/null 2>&1; do sleep 15; n=$((n+15))
    [ $n -ge 600 ] && return 1; done; echo "  148 back after ~$((45+n))s"; return 0; }
read1b0(){ $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  echo 0x1B0 > $DRA; cat $DRA' 2>/dev/null | tr -dc '0-9a-fxA-FX'; }
rollback(){
  echo "=== ROLLBACK to $BAK_MD5 (rail: no retry) ==="
  $W $A "cp /root/BOOT.BIN.$BAK_MD5.bak /boot/BOOT.BIN && sync && ( sleep 2; reboot ) >/dev/null 2>&1 & exit 0" 2>/dev/null
  wait_back || { echo "FLASH_RXFIFO_FATAL: 148 not back after rollback -- PHYSICAL ATTENTION (backup at /root/BOOT.BIN.$BAK_MD5.bak)"; exit 2; }
  echo "  rollback booted: $($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null) (expect $BAK_MD5)"
  bash "$D/restore_known_good.sh" 2>&1 | tail -15
  echo "FLASH_RXFIFO_ROLLED_BACK $(date -Is)"
  exit 1
}
echo "=== [0/6] pre-flash instrument precondition (amendment): 148 must be healthy NOW ==="
HP0=$(bash "$D/health_probe_reset_aware.sh" $A 12 2>/dev/null | tail -1); echo "  148 pre-flash: $HP0"
FS0=$(echo "$HP0" | grep -oE 'fsync=[0-9]+' | tr -dc 0-9); WC0=$(echo "$HP0" | grep -oE 'wcnt=[0-9]+' | tr -dc 0-9)
{ [ -n "$FS0" ] && [ "$FS0" -ge 1100 ] && [ -n "$WC0" ] && [ "$WC0" -ge 1100 ]; } || { echo "FLASH_RXFIFO_FATAL: 148 not healthy pre-flash (fsync=${FS0:-?} wcnt=${WC0:-?}) -- fix the instrument first, nothing flashed"; exit 1; }
# daemon fingerprint: the legacy rail demanded a hard-coded nakstat=4 (a build-feature
# string count in the on-board qpsk_tun binary); today's capture legs rebuilt the daemon
# from source, so that constant is stale. Rail kept as an INTEGRITY check instead: the
# post-flash fingerprint must equal the pre-flash one (same daemon binary survives).
FP0=$($W $A 'strings /root/host_app_k5/qpsk_tun | grep -c nakstat' 2>/dev/null | tr -dc 0-9)
echo "  148 daemon fingerprint (nakstat strings) pre-flash: ${FP0:-?}"
echo "=== [1/6] preconditions + restore point ==="
[ -f "$BB" ] || { echo "FLASH_RXFIFO_FATAL: no image at $BB"; exit 1; }
md5sum "$BB" | grep -q "^${EXP}" || { echo "FLASH_RXFIFO_FATAL: image md5 != ${EXP}"; exit 1; }
CUR=$($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null)
[ "$CUR" = "$BAK_MD5" ] || { echo "FLASH_RXFIFO_FATAL: 148 runs $CUR, expected $BAK_MD5 -- restore point assumption broken, nothing flashed"; exit 1; }
$W $A "cp /boot/BOOT.BIN /root/BOOT.BIN.$BAK_MD5.bak && sync && md5sum /root/BOOT.BIN.$BAK_MD5.bak | cut -c1-12" 2>/dev/null | grep -q "^$BAK_MD5" \
  || { echo "FLASH_RXFIFO_FATAL: could not bank the restore point on 148"; exit 1; }
echo "  restore point banked on-board: /root/BOOT.BIN.$BAK_MD5.bak ($BAK_MD5); also in repo boot_known_good/"
echo "=== [2/6] stage + flash ==="
scpput "$BB" root@$A:/boot/BOOT.BIN.new || { echo "FLASH_RXFIFO_FATAL: scp failed"; exit 1; }
$W $A "md5sum /boot/BOOT.BIN.new | grep -q ^${EXP} || exit 1
  mv /boot/BOOT.BIN.new /boot/BOOT.BIN && sync && echo STAGED" 2>/dev/null | grep -q STAGED \
  || { echo "FLASH_RXFIFO_FATAL: stage verify failed -- /boot/BOOT.BIN untouched"; exit 1; }
echo "  staged; rebooting 148"
$W $A 'sync; ( sleep 2; reboot ) >/dev/null 2>&1 & exit 0' 2>/dev/null
wait_back || { echo "FLASH_RXFIFO_FATAL: 148 not back after 10 min"; exit 2; }
echo "=== [3/6] readback verify (rail) ==="
BOOT=$($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null)
echo "  booted image: $BOOT (expected ${EXP})"
[ "$BOOT" = "$EXP" ] || rollback
echo "=== [4/6] FULL bring-up (restore_known_good.sh) + NAK=4 re-check ==="
bash "$D/restore_known_good.sh" > /tmp/rxfifo_bringup.log 2>&1
grep -E "ARM GATE|BRING-UP COMPLETE|watchdog|BOOT.BIN|nakstat|daemon" /tmp/rxfifo_bringup.log | tail -14
NAK=$(grep -A6 "^--- $A ---" /tmp/rxfifo_bringup.log | grep -m1 'nakstat' | grep -oE ': [0-9]+' | tr -dc 0-9)
echo "  148 daemon fingerprint post-flash=$NAK (rail: must equal pre-flash ${FP0:-?})"
[ -n "$NAK" ] && [ "$NAK" = "${FP0:-x}" ] || { echo "FLASH_RXFIFO_FINGERPRINT_FAIL"; rollback; }
echo "=== [5/6] reset-aware health gate (rail: fsync>=1100 AND wcnt>=1100), two passes ==="
probe148(){ bash "$D/health_probe_reset_aware.sh" $A 12 2>/dev/null | tail -1; }
read1c0(){ $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  echo 0x1C0 > $DRA; cat $DRA' 2>/dev/null | tr -dc '0-9a-fxA-FX'; }
gate_ok=""
for pass in 1 2; do
  W0=$(( $(read1c0) )); HP=$(probe148); W1=$(( $(read1c0) )); DW=$(( (W1 - W0) & 0xFFFFFFFF ))
  echo "  148 (gate pass $pass): $HP raw_0x1C0_delta=$DW"
  FS=$(echo "$HP" | grep -oE 'fsync=[0-9]+' | tr -dc 0-9); WC=$(echo "$HP" | grep -oE 'wcnt=[0-9]+' | tr -dc 0-9); CL=$(echo "$HP" | grep -oE 'clean=[0-9]+' | tr -dc 0-9)
  if [ -n "$FS" ] && [ -n "$WC" ] && [ "${CL:-0}" -ge 4 ] && [ "$FS" -ge 1100 ] && [ "$WC" -ge 1100 ] && [ "$DW" -gt 0 ]; then
    echo "  HEALTH_GATE_PASS fsync=$FS wcnt=$WC raw_0x1C0_delta=$DW (pass $pass)"; gate_ok=1; break; fi
  if [ $pass -eq 1 ]; then echo "  first-pass health fail -- ONE re-bring-up (amendment)"; bash "$D/restore_known_good.sh" > /tmp/rxfifo_bringup_retry.log 2>&1; fi
done
[ -n "$gate_ok" ] || { echo "FLASH_RXFIFO_HEALTH_FAIL fsync=${FS:-?} wcnt=${WC:-?} after re-bring-up"; rollback; }
echo "=== [6/6] fixctl=3 arm (as on the comb image) + ByteRxFifo overflow witness 0x1B0 over 10 s (non-fatal) ==="
$W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo "0x208 0x3" > $DRA' 2>/dev/null && echo "  fixctl=3 written (write-only; verified by effect)"
O0=$(( $(read1b0) )); sleep 10; O1=$(( $(read1b0) )); echo "  OVF_WITNESS 0x1B0 delta over 10 s = $(( (O1-O0) & 0xFFFFFFFF )) dropped words (comb image: 170-450)"
echo "FLASH_RXFIFO_DONE $(date -Is) image=${EXP} on 148, bring-up + gates green"
