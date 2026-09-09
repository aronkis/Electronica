#!/bin/bash
# flash_148_skid.sh -- flash 148 with the BANKED skid-fix image c9d3e1ece983.
# Operator-authorized 2026-08-14 ("Flash"). Standing rails:
#   verify flash by readback; FULL bring-up (restore_known_good.sh); re-check
#   NAK=4 on 148; reset-aware health gate fsync>=1100 AND wcnt>=1100 BEFORE
#   counting anything; on readback OR health-gate failure: HALT, roll back to
#   e49c011b, restore, do NOT retry. 146 is never touched by this script
#   beyond the normal link bring-up.
set -u
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem
D=$ROOT/two_jup
W=$D/anyssh.sh
A=10.0.0.148
BB=$ROOT/jupiter_byte_skid2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
EXP=${1:?usage: flash_148_skid2.sh <md5-12>}
echo "FLASH_SKID start $(date -Is) pid=$$"

scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no "$@" </dev/null 2>>/tmp/skid_scp_err.txt; }

wait_back(){ sleep 45; local n=0
  until $W $A 'echo up' >/dev/null 2>&1; do sleep 15; n=$((n+15))
    [ $n -ge 600 ] && return 1; done; echo "  148 back after ~$((45+n))s"; return 0; }

readwit(){
  echo "--- witness 0x9D300008 (read BEFORE any rollback) ---"
  $W $A 'DM=$(command -v devmem || echo "busybox devmem")
    for i in 1 2 3; do v=$($DM 0x9D300008 32 2>/dev/null || $DM 0x9D300008 2>/dev/null)
      printf "WITNESS %s raw=%s beats=%d mism=%d skid=%d alarm=%d\n" "$(date +%T)" "$v" \
        $((v & 0xFFFF)) $(( (v>>16) & 0xFF )) $(( (v>>24) & 0x7F )) $(( (v>>31) & 1 ))
      sleep 1; done' 2>/dev/null || echo "  witness read failed"
}

rollback(){
  readwit
  echo "=== ROLLBACK to e49c011b (rail: no retry) ==="
  $W $A 'cp /root/BOOT.BIN.e49c011b.bak /boot/BOOT.BIN && sync && ( sleep 2; reboot ) >/dev/null 2>&1 & exit 0' 2>/dev/null
  wait_back || { echo "FLASH_SKID_FATAL: 148 not back after rollback -- PHYSICAL ATTENTION (backup still at /root/BOOT.BIN.e49c011b.bak)"; exit 2; }
  echo "  rollback booted: $($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null) (expect e49c011b7a75)"
  bash "$D/restore_known_good.sh" 2>&1 | tail -15
  echo "FLASH_SKID_ROLLED_BACK $(date -Is)"
  exit 1
}

echo "=== [1/6] preconditions ==="
[ -f "$BB" ] || { echo "FLASH_SKID_FATAL: no image at $BB"; exit 1; }
md5sum "$BB" | grep -q "^${EXP}" || { echo "FLASH_SKID_FATAL: image md5 != ${EXP}"; exit 1; }
$W $A 'md5sum /root/BOOT.BIN.e49c011b.bak' 2>/dev/null | grep -q '^e49c011b' \
  || { echo "FLASH_SKID_FATAL: rollback backup missing/bad on 148"; exit 1; }
CUR=$($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null)
echo "  148 current image: $CUR (expect e49c011b7a75); rollback backup verified"

echo "=== [2/6] stage + flash ==="
scpput "$BB" root@$A:/boot/BOOT.BIN.new || { echo "FLASH_SKID_FATAL: scp failed"; exit 1; }
$W $A "md5sum /boot/BOOT.BIN.new | grep -q ^${EXP} || exit 1
  mv /boot/BOOT.BIN.new /boot/BOOT.BIN && sync && echo STAGED" 2>/dev/null | grep -q STAGED \
  || { echo "FLASH_SKID_FATAL: stage verify failed -- /boot/BOOT.BIN untouched"; exit 1; }
echo "  staged; rebooting 148"
$W $A 'sync; ( sleep 2; reboot ) >/dev/null 2>&1 & exit 0' 2>/dev/null
wait_back || { echo "FLASH_SKID_FATAL: 148 not back after 10 min"; exit 2; }

echo "=== [3/6] readback verify (rail) ==="
BOOT=$($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null)
echo "  booted image: $BOOT (expected ${EXP})"
[ "$BOOT" = "$EXP" ] || rollback

echo "=== [4/6] FULL bring-up (restore_known_good.sh) + NAK=4 re-check ==="
bash "$D/restore_known_good.sh" > /tmp/skid_bringup.log 2>&1
grep -E "ARM GATE|BRING-UP COMPLETE|watchdog|BOOT.BIN|nakstat|daemon" /tmp/skid_bringup.log | tail -14
NAK=$(grep -A6 "^--- $A ---" /tmp/skid_bringup.log | grep -m1 'nakstat' | grep -oE ': [0-9]+' | tr -dc 0-9)
echo "  148 nakstat=$NAK (rail: must be 4)"
[ "$NAK" = "4" ] || { echo "FLASH_SKID_NAK_FAIL"; rollback; }

echo "=== [5/6] reset-aware health gate (rail: fsync>=1100 AND wcnt>=1100) ==="
# Flash attempt 2 amendment (operator-authorized retest, SKID_BUILD.md): on a
# FIRST gate fail, run ONE more bring-up pass and re-probe before rolling back
# -- 2026-08-14 measured e49c011b itself needing a 2nd post-reboot bring-up
# (fsync 420 -> 1254). Rollback fires on the SECOND consecutive fail.
probe148(){ bash "$D/health_probe_reset_aware.sh" $A 12 2>/dev/null | tail -1; }
gate_ok=""
for pass in 1 2; do
  HP=$(probe148)
  echo "  148 (gate pass $pass): $HP"
  FS=$(echo "$HP" | grep -oE 'fsync=[0-9]+' | tr -dc 0-9)
  WC=$(echo "$HP" | grep -oE 'wcnt=[0-9]+'  | tr -dc 0-9)
  CL=$(echo "$HP" | grep -oE 'clean=[0-9]+' | tr -dc 0-9)
  if [ -n "$FS" ] && [ -n "$WC" ] && [ "${CL:-0}" -ge 4 ] && [ "$FS" -ge 1100 ] && [ "$WC" -ge 1100 ]; then
    echo "  HEALTH_GATE_PASS fsync=$FS wcnt=$WC (pass $pass)"; gate_ok=1; break
  fi
  if [ $pass -eq 1 ]; then
    echo "  first-pass health fail (fsync=${FS:-?} wcnt=${WC:-?}) -- ONE re-bring-up (amendment)"
    bash "$D/restore_known_good.sh" > /tmp/skid_bringup_retry.log 2>&1
    grep -E "ARM GATE|BRING-UP COMPLETE" /tmp/skid_bringup_retry.log | tail -2
  fi
done
[ -n "$gate_ok" ] || { echo "FLASH_SKID_HEALTH_FAIL fsync=${FS:-?} wcnt=${WC:-?} after re-bring-up"; rollback; }

echo "=== [6/6] first witness reads (0x9D300008, 5 samples 1 s apart) ==="
$W $A 'DM=$(command -v devmem || echo "busybox devmem")
  for i in 1 2 3 4 5; do v=$($DM 0x9D300008 32 2>/dev/null || $DM 0x9D300008 2>/dev/null)
    printf "WITNESS %s raw=%s beats=%d mism=%d skid=%d alarm=%d\n" "$(date +%T)" "$v" \
      $((v & 0xFFFF)) $(( (v>>16) & 0xFF )) $(( (v>>24) & 0x7F )) $(( (v>>31) & 1 ))
    sleep 1; done' 2>/dev/null || echo "  witness read tool missing on 148 (non-fatal)"
echo "FLASH_SKID_DONE $(date -Is) image=${EXP} on 148, bring-up + gates green"
