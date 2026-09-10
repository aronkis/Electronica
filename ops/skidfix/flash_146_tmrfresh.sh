#!/bin/bash
# flash_146_tmrfresh.sh <md5-12> -- FIRST 146 FLASH OF THE CAMPAIGN (freeze lifted
# by operator 2026-08-25, spec 2026-08-25-146-fix-full-sweep-design.md).
# Image: fresh-placement TMR rebuild candidate (A1 PASS incl. tmr_attr_inject,
# A2 rail census CLEAN). Cloned from flash_148_beatfix2.sh; standing rails
# carried forward unchanged: md5 precondition, on-board backup verified BEFORE
# staging, staged-copy md5 verify, readback verify after boot, FULL bring-up
# (restore_known_good.sh), NAK=4 re-check on 148, reset-aware two-pass health
# gate fsync>=1100 AND wcnt>=1100 measured ON 148 (148's RX is where 146's TX
# health is visible -- the whole point of this flash), rollback to the banked
# 433fd8dab393 on any gate failure, NO retry.
#
# 146-specific deltas vs the 148 script:
#   - target A=10.0.0.146; image staged to 146's /boot
#   - rollback backup created ON 146 (/root/BOOT.BIN.433fd8da.bak) by copying
#     the live /boot/BOOT.BIN before staging, verified against the nemo bank
#     jupiter_byte_tmr146_gates/boot/BOOT.BIN.146.433fd8da.bak (md5 433fd8dab393)
#   - the tgen/beat-ILA gpio readback steps of the 148 script are omitted:
#     those instruments do not exist on the TMR lineage image (no-op here)
set -u
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem
D=$ROOT/ops
W=$D/anyssh.sh
A=10.0.0.146
RX=10.0.0.148
BB=$ROOT/jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
BAK_MD5=433fd8dab393
EXP=${1:?usage: flash_146_tmrfresh.sh <md5-12>}
echo "FLASH_146 start $(date -Is) pid=$$"

scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password \
  "$@"; }

wait_back(){ sleep 45; local n=0
  until $W $A 'echo up' >/dev/null 2>&1; do sleep 15; n=$((n+15))
    [ $n -ge 600 ] && return 1; done; echo "  146 back after ~$((45+n))s"; return 0; }

rollback(){
  echo "=== ROLLBACK to ${BAK_MD5} (rail: no retry) ==="
  $W $A 'cp /root/BOOT.BIN.433fd8da.bak /boot/BOOT.BIN && sync && ( sleep 2; reboot ) >/dev/null 2>&1 & exit 0' 2>/dev/null
  wait_back || { echo "FLASH_146_FATAL: 146 not back after rollback -- PHYSICAL ATTENTION (backups: /root/BOOT.BIN.433fd8da.bak on 146 AND jupiter_byte_tmr146_gates/boot/BOOT.BIN.146.433fd8da.bak on nemo)"; exit 2; }
  echo "  rollback booted: $($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null) (expect ${BAK_MD5})"
  bash "$D/restore_known_good.sh" 2>&1 | tail -15
  echo "FLASH_146_ROLLED_BACK $(date -Is)"
  exit 1
}

echo "=== [1/6] preconditions ==="
[ -f "$BB" ] || { echo "FLASH_146_FATAL: no image at $BB"; exit 1; }
md5sum "$BB" | grep -q "^${EXP}" || { echo "FLASH_146_FATAL: image md5 != ${EXP}"; exit 1; }
[ -f "$ROOT/jupiter_byte_tmr146_gates/boot/BOOT.BIN.146.433fd8da.bak" ] \
  || { echo "FLASH_146_FATAL: nemo-side bank missing (A0 gate)"; exit 1; }
CUR=$($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null)
echo "  146 current image: $CUR (expect ${BAK_MD5})"
[ "$CUR" = "$BAK_MD5" ] || { echo "FLASH_146_FATAL: running image is not ${BAK_MD5} -- identity in question, STOP"; exit 1; }

echo "=== [2/6] on-board rollback backup, then stage + flash ==="
$W $A "cp /boot/BOOT.BIN /root/BOOT.BIN.433fd8da.bak && sync
  md5sum /root/BOOT.BIN.433fd8da.bak | grep -q ^${BAK_MD5} && echo BAK_OK" 2>/dev/null | grep -q BAK_OK \
  || { echo "FLASH_146_FATAL: on-board backup create/verify failed"; exit 1; }
echo "  on-board backup verified (/root/BOOT.BIN.433fd8da.bak)"
scpput "$BB" root@$A:/boot/BOOT.BIN.new || { echo "FLASH_146_FATAL: scp failed"; exit 1; }
$W $A "md5sum /boot/BOOT.BIN.new | grep -q ^${EXP} || exit 1
  mv /boot/BOOT.BIN.new /boot/BOOT.BIN && sync && echo STAGED" 2>/dev/null | grep -q STAGED \
  || { echo "FLASH_146_FATAL: stage verify failed -- /boot/BOOT.BIN untouched"; exit 1; }
echo "  staged; rebooting 146"
$W $A 'sync; ( sleep 2; reboot ) >/dev/null 2>&1 & exit 0' 2>/dev/null
wait_back || { echo "FLASH_146_FATAL: 146 not back after 10 min -- PHYSICAL ATTENTION"; exit 2; }

echo "=== [3/6] readback verify (rail) ==="
BOOT=$($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null)
echo "  booted image: $BOOT (expected ${EXP})"
[ "$BOOT" = "$EXP" ] || rollback

echo "=== [4/6] FULL bring-up (restore_known_good.sh) + NAK=4 re-check on 148 ==="
bash "$D/restore_known_good.sh" > /tmp/flash146_bringup.log 2>&1
grep -E "ARM GATE|BRING-UP COMPLETE|watchdog|BOOT.BIN|nakstat|daemon" /tmp/flash146_bringup.log | tail -14
NAK=$(grep -A6 "^--- $RX ---" /tmp/flash146_bringup.log | grep -m1 'nakstat' | grep -oE ': [0-9]+' | tr -dc 0-9)
echo "  148 nakstat=$NAK (rail: must be 4)"
[ "$NAK" = "4" ] || { echo "FLASH_146_NAK_FAIL"; rollback; }

echo "=== [5/6] reset-aware health gate on 148 (rail: fsync>=1100 AND wcnt>=1100; forward link = 146 TX under test) ==="
probe_rx(){ bash "$D/health_probe_reset_aware.sh" $RX 12 2>/dev/null | tail -1; }
read1c0(){ $W $RX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  echo 0x1C0 > $DRA; cat $DRA' 2>/dev/null | tr -dc '0-9a-fxA-FX'; }
gate_ok=""
for pass in 1 2; do
  W0=$(( $(read1c0) ))
  HP=$(probe_rx)
  W1=$(( $(read1c0) ))
  DW=$(( (W1 - W0) & 0xFFFFFFFF ))
  echo "  148 (gate pass $pass): $HP raw_0x1C0_delta=$DW"
  FS=$(echo "$HP" | grep -oE 'fsync=[0-9]+' | tr -dc 0-9)
  WC=$(echo "$HP" | grep -oE 'wcnt=[0-9]+'  | tr -dc 0-9)
  CL=$(echo "$HP" | grep -oE 'clean=[0-9]+' | tr -dc 0-9)
  if [ -n "$FS" ] && [ -n "$WC" ] && [ "${CL:-0}" -ge 4 ] && [ "$FS" -ge 1100 ] && [ "$WC" -ge 1100 ] && [ "$DW" -gt 0 ]; then
    echo "  HEALTH_GATE_PASS fsync=$FS wcnt=$WC raw_0x1C0_delta=$DW (pass $pass)"; gate_ok=1; break
  fi
  if [ $pass -eq 1 ]; then
    echo "  first-pass health fail (fsync=${FS:-?} wcnt=${WC:-?}) -- ONE re-bring-up (standing amendment)"
    bash "$D/restore_known_good.sh" > /tmp/flash146_bringup_retry.log 2>&1
    grep -E "ARM GATE|BRING-UP COMPLETE" /tmp/flash146_bringup_retry.log | tail -2
  fi
done
[ -n "$gate_ok" ] || { echo "FLASH_146_HEALTH_FAIL fsync=${FS:-?} wcnt=${WC:-?} after re-bring-up"; rollback; }

echo "=== [6/6] (no witness gpio on the TMR lineage -- step intentionally empty) ==="
echo "FLASH_146_DONE $(date -Is) image=${EXP} on 146, bring-up + gates green"
