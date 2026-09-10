#!/bin/bash
# flash_148_rxfifo_diag.sh <md5-12> -- DIAGNOSTIC flash of the RX-FIFO-4k image (v3) (BEATFIX v3 +
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
D=$ROOT/ops
W=$D/anyssh.sh
A=10.0.0.148
BB=${BB:-$ROOT/jupiter_byte_stagesig_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN}
EXP=${1:?usage: flash_148_stagesig.sh <md5-12>}
BAK_MD5=${BAK_MD5:-786dce9fafc8}   # restore point = the pdwit witness image 148 runs now
echo "FLASH_STAGESIG start $(date -Is) pid=$$"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no "$@" </dev/null 2>>/tmp/stagesig_scp_err.txt; }
T_RAIL0=$(date +%s.%N); stamp(){ printf "  T+%6.1fs %s\n" "$(echo "$(date +%s.%N) - $T_RAIL0" | bc)" "$1"; }
TIER=${TIER:-full}   # full = every rail incl. census + 0x1B0 witness; quick = same refusal/restore/readback/gate/rollback, no census/witness, 3-s polling (exploratory only, never quoted)
wait_back(){ sleep 30; local n=0
  until $W $A 'echo up' >/dev/null 2>&1; do sleep 3; n=$((n+3))
    [ $n -ge 600 ] && return 1; done; echo "  148 back after ~$((30+n))s"; stamp "reboot->ssh"; return 0; }
read1b0(){ $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  echo 0x1B0 > $DRA; cat $DRA' 2>/dev/null | tr -dc '0-9a-fxA-FX'; }
rollback(){
  echo "=== ROLLBACK to $BAK_MD5 (rail: no retry) ==="
  $W $A "cp /root/BOOT.BIN.$BAK_MD5.bak /boot/BOOT.BIN && sync && ( sleep 2; reboot ) >/dev/null 2>&1 & exit 0" 2>/dev/null
  wait_back || { echo "FLASH_STAGESIG_FATAL: 148 not back after rollback -- PHYSICAL ATTENTION (backup at /root/BOOT.BIN.$BAK_MD5.bak)"; exit 2; }
  echo "  rollback booted: $($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null) (expect $BAK_MD5)"
  bash "$D/restore_known_good.sh" 2>&1 | tail -15
  echo "FLASH_STAGESIG_ROLLED_BACK $(date -Is)"
  exit 1
}
echo "=== [0/6] pre-flash instrument precondition (amendment): 148 must be healthy NOW (tier=$TIER) ==="; stamp "start"
HP0=$(bash "$D/health_probe_reset_aware.sh" $A 12 2>/dev/null | tail -1); echo "  148 pre-flash: $HP0"
FS0=$(echo "$HP0" | grep -oE 'fsync=[0-9]+' | tr -dc 0-9); WC0=$(echo "$HP0" | grep -oE 'wcnt=[0-9]+' | tr -dc 0-9)
{ [ -n "$FS0" ] && [ "$FS0" -ge 1100 ] && [ -n "$WC0" ] && [ "$WC0" -ge 1100 ]; } || { echo "FLASH_STAGESIG_FATAL: 148 not healthy pre-flash (fsync=${FS0:-?} wcnt=${WC0:-?}) -- fix the instrument first, nothing flashed"; exit 1; }
# daemon fingerprint: the legacy rail demanded a hard-coded nakstat=4 (a build-feature
# string count in the on-board qpsk_tun binary); today's capture legs rebuilt the daemon
# from source, so that constant is stale. Rail kept as an INTEGRITY check instead: the
# post-flash fingerprint must equal the pre-flash one (same daemon binary survives).
FP0=$($W $A 'strings /root/host_app_k5/qpsk_tun | grep -c nakstat' 2>/dev/null | tr -dc 0-9)
echo "  148 daemon fingerprint (nakstat strings) pre-flash: ${FP0:-?}"
stamp "precondition done"; echo "=== [1/6] preconditions + restore point ==="
[ -f "$BB" ] || { echo "FLASH_STAGESIG_FATAL: no image at $BB"; exit 1; }
md5sum "$BB" | grep -q "^${EXP}" || { echo "FLASH_STAGESIG_FATAL: image md5 != ${EXP}"; exit 1; }
CUR=$($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null)
[ "$CUR" = "$BAK_MD5" ] || { echo "FLASH_STAGESIG_FATAL: 148 runs $CUR, expected $BAK_MD5 -- restore point assumption broken, nothing flashed"; exit 1; }
if $W $A "md5sum /root/BOOT.BIN.$BAK_MD5.bak 2>/dev/null | cut -c1-12" 2>/dev/null | grep -q "^$BAK_MD5"; then echo "  restore point already banked on-board (md5-verified), copy skipped"; else
$W $A "cp /boot/BOOT.BIN /root/BOOT.BIN.$BAK_MD5.bak && sync && md5sum /root/BOOT.BIN.$BAK_MD5.bak | cut -c1-12" 2>/dev/null | grep -q "^$BAK_MD5" \
  || { echo "FLASH_STAGESIG_FATAL: could not bank the restore point on 148"; exit 1; }; fi
echo "  restore point banked on-board: /root/BOOT.BIN.$BAK_MD5.bak ($BAK_MD5); also in repo boot_known_good/"
stamp "restore point banked"; echo "=== [2/6] stage + flash ==="
scpput "$BB" root@$A:/boot/BOOT.BIN.new || { echo "FLASH_STAGESIG_FATAL: scp failed"; exit 1; }
$W $A "md5sum /boot/BOOT.BIN.new | grep -q ^${EXP} || exit 1
  mv /boot/BOOT.BIN.new /boot/BOOT.BIN && sync && echo STAGED" 2>/dev/null | grep -q STAGED \
  || { echo "FLASH_STAGESIG_FATAL: stage verify failed -- /boot/BOOT.BIN untouched"; exit 1; }
echo "  staged; rebooting 148"
$W $A 'sync; ( sleep 2; reboot ) >/dev/null 2>&1 & exit 0' 2>/dev/null
wait_back || { echo "FLASH_STAGESIG_FATAL: 148 not back after 10 min"; exit 2; }
echo "=== [3/6] readback verify (rail) ==="; stamp "readback start"
BOOT=$($W $A 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null)
echo "  booted image: $BOOT (expected ${EXP})"
[ "$BOOT" = "$EXP" ] || rollback
stamp "readback done"; echo "=== [4/6] FULL bring-up (restore_known_good.sh) + NAK=4 re-check ==="
bash "$D/restore_known_good.sh" > /tmp/stagesig_bringup.log 2>&1
grep -E "ARM GATE|BRING-UP COMPLETE|watchdog|BOOT.BIN|nakstat|daemon" /tmp/stagesig_bringup.log | tail -14
NAK=$(grep -A6 "^--- $A ---" /tmp/stagesig_bringup.log | grep -m1 'nakstat' | grep -oE ': [0-9]+' | tr -dc 0-9)
echo "  148 daemon fingerprint post-flash=$NAK (rail: must equal pre-flash ${FP0:-?})"
[ -n "$NAK" ] && [ "$NAK" = "${FP0:-x}" ] || { echo "FLASH_STAGESIG_FINGERPRINT_FAIL"; rollback; }
stamp "bring-up done"; echo "=== [5/6] DIAGNOSTIC (operator-approved 2026-08-27): 10 s register census BEFORE any health gate ==="
if [ "$TIER" = quick ]; then echo "  (quick tier: census skipped)"; else
# 0x104 packets (demod frames), 0x1C0 accepted byte words (valid&&ready at the AXIS pins),
# 0x1B0 ByteRxFifo overflow (drop-oldest count). Decision matrix:
#   0x1C0 advancing            -> the FIFO delivers: continue to the health gate + A/B
#   0x1C0 frozen, 0x1B0 climbing -> words enqueued but never accepted (valid withheld or tready never high)
#   0x1C0 frozen, 0x1B0 frozen   -> words never enqueued (tog/enable path)  -> ROLLBACK either way
census(){ $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  for r in 0x104 0x1C0 0x1B0 0x150; do echo $r > $DRA; printf "%s=%s " $r $(cat $DRA); done
  grep -a "qpsk_tun stats" /dev/shm/qpsk_tun.log | tail -1 | grep -oE "dma_rx_ok=[0-9]+|crc_drop=[0-9]+|idle_rx=[0-9]+" | tr "\n" " "; date +%T' 2>/dev/null; }
for i in 1 2 3 4 5; do echo "  DIAG_CENSUS $i: $(census)"; sleep 2; done
C0=$(census); sleep 10; C1=$(census)
w0=$(( $(echo "$C0" | grep -oE '0x1C0=0x[0-9a-fA-F]+' | cut -d= -f2) )); w1=$(( $(echo "$C1" | grep -oE '0x1C0=0x[0-9a-fA-F]+' | cut -d= -f2) ))
o0=$(( $(echo "$C0" | grep -oE '0x1B0=0x[0-9a-fA-F]+' | cut -d= -f2) )); o1=$(( $(echo "$C1" | grep -oE '0x1B0=0x[0-9a-fA-F]+' | cut -d= -f2) ))
p0=$(( $(echo "$C0" | grep -oE '0x104=0x[0-9a-fA-F]+' | cut -d= -f2) )); p1=$(( $(echo "$C1" | grep -oE '0x104=0x[0-9a-fA-F]+' | cut -d= -f2) ))
echo "  DIAG_10S packets_delta=$(( (p1-p0)&0xFFFFFFFF )) words_delta=$(( (w1-w0)&0xFFFFFFFF )) ovf_delta=$(( (o1-o0)&0xFFFFFFFF ))"
if [ $(( (w1-w0)&0xFFFFFFFF )) -gt 1000 ]; then
  echo "  DIAG_VERDICT: BYTE PLANE DELIVERS ($(( (w1-w0)&0xFFFFFFFF )) words/10s, ovf delta $(( (o1-o0)&0xFFFFFFFF )) vs comb image 170-450) -- continuing to the health gate"
else
  if [ $(( (o1-o0)&0xFFFFFFFF )) -gt 0 ]; then echo "  DIAG_VERDICT: ZERO DELIVERY, FIFO OVERFLOWING (ovf +$(( (o1-o0)&0xFFFFFFFF ))/10s) -> words ENQUEUED but never accepted: valid withheld or tready never high (handshake side)";
  else echo "  DIAG_VERDICT: ZERO DELIVERY, FIFO NOT OVERFLOWING -> words never ENQUEUED (tog/enb/write side) or demod idle (packets delta $(( (p1-p0)&0xFFFFFFFF )))"; fi
  echo "FLASH_STAGESIG_NODELIVERY"; rollback
fi
fi
stamp "census done"; echo "=== [5b/6] reset-aware health gate (rail: fsync>=1100 AND wcnt>=1100), two passes ==="
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
  if [ $pass -eq 1 ]; then echo "  first-pass health fail -- ONE re-bring-up (amendment)"; bash "$D/restore_known_good.sh" > /tmp/stagesig_bringup_retry.log 2>&1; fi
done
[ -n "$gate_ok" ] || { echo "FLASH_STAGESIG_HEALTH_FAIL fsync=${FS:-?} wcnt=${WC:-?} after re-bring-up"; rollback; }
stamp "gate done"; echo "=== [6/6] STAGE-SIGNATURE SMOKE TEST (fixctl arms MUST stay 0) ==="
# The witness only changes what 0x20C/0x210 report (previously pdWitA/B, the dead
# delay-FIFO witness) and adds counters; no datapath change, so at fixctl=0 this
# image must behave identically to 786dce9fafc8 -- which the health gate above just
# confirmed. Selector lives in fixctl[11:8]; bits 0-4 stay clear so no fix is armed.
$W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo "$1">$DRA; cat $DRA; }
 for s in 0 1 2 3 4 5 6; do
   printf "0x%X00 " $s > /dev/null
   echo "0x208 $(printf 0x%X $((s<<8)))" > $DRA
   sleep 0.2
   echo "  STAGE $s sig=$(rd 0x20C) mismatches=$(rd 0x210)"
 done
 echo "0x208 0x0" > $DRA' 2>/dev/null
echo "  (stages 0 and 1 are the covered ones; 2-6 are UNCOVERED -- soft-value stages"
echo "   are not frame-invariant, see SESSION_20260830_AUTONOMOUS.md 14)"
stamp "done"; echo "FLASH_STAGESIG_DONE $(date -Is) image=${EXP} on 148, bring-up + gates green (tier=$TIER)"
