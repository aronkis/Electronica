#!/bin/bash
# flash_146_txfix.sh -- flash 146 with a TXFIX fix-variant image built on 146's OWN
# (TMR / "vendh") lineage.  DERIVED FROM two_jup/skidfix/flash_146_vendh.sh; every
# rail of the 146 chain is carried VERBATIM.  The complete list of changed lines is
# in two_jup/sdd_archive/2026-09-03-txfix/task-k146-report.md; the substantive ones:
#
#   1. Image identity is now env-driven -- FLASH_MD5 (required, 12 lowercase hex),
#      FLASH_BAK (default ec414d2df8bc = the image 146 runs today), FLASH_TAG
#      (required) -- matching flash_148_txfix.sh's interface, instead of the
#      vendh script's positional <md5-12> and hard-coded 4be9286ca111 backup.
#   2. BB (the image to flash) is boot_known_good/BOOT.BIN.146.$TAG.$EXP -- the
#      repo's bank -- instead of the in-tree jupiter_byte_tmr146_gates/
#      variants_placement/v_endh/BOOT.BIN.
#   3. THE A0 BANK GATE IS FIXED.  The vendh script's [1/6] checked only that
#      jupiter_byte_tmr146_build/.../boot/BOOT.BIN EXISTS -- and that file is
#      4be9286ca111 (measured), i.e. NOT the rollback image for a chain whose
#      restore point is ec414d2df8bc.  Here ROLLBACK_BANK (default the banked
#      v_endh BOOT.BIN) must exist AND its md5 must equal $BAK, or the chain
#      aborts before touching anything.
#   4. THE ON-BOARD .bak IS CREATED, NOT ASSUMED.  146 today has /root/BOOT.BIN
#      .bak files for 433fd8da and 4be9286c only -- there is NO .bak for
#      ec414d2df8bc.  [2/6] verifies the live /boot/BOOT.BIN md5 == $BAK and only
#      then copies it to /root/BOOT.BIN.$BAK.bak and re-verifies that copy; any
#      failure aborts with /boot untouched.  (The vendh script did the same for
#      its own $BAK; the name is now parameterised.)
#   5. DRY=1 support added, modelled on flash_148_txfix.sh: every board-touching
#      action -- $W (anyssh), scpput, wait_back, restore_known_good.sh,
#      health_probe_reset_aware.sh and the read1c0 direct_reg_access reads --
#      is guarded, so the full [1/6]..[6/6] sequence runs with zero network
#      contact.  The three helper scripts are the easy ones to miss: they open
#      their own ssh sessions, so a $W-only guard would still touch the boards.
#
# WHAT IS *NOT* CHANGED (rails, verbatim from flash_146_vendh.sh):
#   - target A=10.0.0.146, gate instrument RX=10.0.0.148
#   - the 148 pre-flash liveness check before 146 is touched (2026-08-26
#     RAILS AMENDMENT: attempt 1 fired the NAK rail on a dead 148 and voided the run)
#   - staged-copy md5 verify, reboot, readback verify, rollback on mismatch
#   - FULL bring-up via restore_known_good.sh + NAK=4 re-check on 148
#   - the reset-aware two-pass health gate MEASURED ON 148 (fsync>=1100 AND
#     wcnt>=1100 AND clean>=4 AND raw_0x1C0_delta>0), with ONE re-bring-up
#     between passes (standing amendment), rollback on failure, NO retry
#   - step [6/6] intentionally empty (no witness gpio on the TMR lineage)
#
# GATE NOTE FOR THE OPERATOR (unchanged from the vendh chain, stated here because
# it matters for scheduling): this gate NEEDS THE PEER.  146's TX health is only
# observable at 148's RX, so restore_known_good.sh brings up BOTH boards and the
# health numbers are read on 148.  Running this chain therefore re-arms 148 as a
# side effect; 148's own verified mode-1 configuration must be restored afterwards,
# and the sentinel must stay stopped for the whole window.
set -u
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem
D=$ROOT/two_jup
W=$D/anyssh.sh
A=10.0.0.146
RX=10.0.0.148
EXP=${FLASH_MD5:?usage: FLASH_MD5=<md5-12> FLASH_TAG=<tag> [FLASH_BAK=ec414d2df8bc] flash_146_txfix.sh}
BAK=${FLASH_BAK:-ec414d2df8bc}
TAG=${FLASH_TAG:?usage: FLASH_MD5=<md5-12> FLASH_TAG=<tag> [FLASH_BAK=ec414d2df8bc] flash_146_txfix.sh}
[[ "$EXP" =~ ^[0-9a-f]{12}$ ]] || { echo "FLASH_146T_FATAL: FLASH_MD5 must be exactly 12 lowercase hex chars (got: '$EXP')"; exit 1; }
[[ "$BAK" =~ ^[0-9a-f]{12}$ ]] || { echo "FLASH_146T_FATAL: FLASH_BAK must be exactly 12 lowercase hex chars (got: '$BAK')"; exit 1; }
BB=$ROOT/boot_known_good/BOOT.BIN.146.$TAG.$EXP
ROLLBACK_BANK=${ROLLBACK_BANK:-$ROOT/jupiter_byte_tmr146_gates/variants_placement/v_endh/BOOT.BIN}
DRY=${DRY:-0}
echo "FLASH_146T start $(date -Is) pid=$$ image=$EXP tag=$TAG bak=$BAK dry=$DRY"

# --- board-contact helpers; every one is a no-op under DRY=1 -----------------
brd(){ if [ "$DRY" = 1 ]; then echo "[dry] ssh $A $*"; else $W $A "$@" 2>/dev/null | tr -d '\r'; fi; }

scpput(){ if [ "$DRY" = 1 ]; then echo "[dry] scp $*"; return 0; fi
  SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password \
  "$@"; }

wait_back(){ [ "$DRY" = 1 ] && { echo "  [dry] would wait for 146 to come back"; return 0; }
  sleep 45; local n=0
  until $W $A 'echo up' >/dev/null 2>&1; do sleep 15; n=$((n+15))
    [ $n -ge 600 ] && return 1; done; echo "  146 back after ~$((45+n))s"; return 0; }

# restore_known_good.sh and health_probe_reset_aware.sh each open their OWN ssh
# sessions to BOTH boards -- guarding only $W would leave DRY=1 touching the rig.
bringup(){ if [ "$DRY" = 1 ]; then echo "[dry] restore_known_good.sh (full both-board bring-up)" > "${1:-/dev/stdout}"; return 0; fi
  bash "$D/restore_known_good.sh" > "${1:-/dev/stdout}" 2>&1; }
health_rx(){ if [ "$DRY" = 1 ]; then echo "[dry] health_probe_reset_aware.sh $RX -- fsync=1259 wcnt=1259 clean=12"; return 0; fi
  timeout 90 bash "$D/health_probe_reset_aware.sh" $RX 12 2>/dev/null | tail -1; }
read1c0(){ if [ "$DRY" = 1 ]; then echo "1"; return 0; fi
  $W $RX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  echo 0x1C0 > $DRA; cat $DRA' 2>/dev/null | tr -dc '0-9a-fxA-FX'; }

rollback(){
  echo "=== ROLLBACK to ${BAK} (rail: no retry) ==="
  brd "cp /root/BOOT.BIN.${BAK}.bak /boot/BOOT.BIN && sync && ( sleep 2; reboot ) >/dev/null 2>&1 & exit 0"
  wait_back || { echo "FLASH_146T_FATAL: 146 not back after rollback -- PHYSICAL ATTENTION (backups: /root/BOOT.BIN.${BAK}.bak on 146 AND $ROLLBACK_BANK on nemo)"; exit 2; }
  echo "  rollback booted: $(brd 'md5sum /boot/BOOT.BIN | cut -c1-12') (expect ${BAK})"
  bringup /tmp/flash146_rollback_bringup.log; tail -15 /tmp/flash146_rollback_bringup.log 2>/dev/null
  echo "FLASH_146T_ROLLED_BACK $(date -Is)"
  exit 1
}

echo "=== [1/6] preconditions ==="
[ -f "$BB" ] || { echo "FLASH_146T_FATAL: no image at $BB"; exit 1; }
md5sum "$BB" | grep -q "^${EXP}" || { echo "FLASH_146T_FATAL: image md5 != ${EXP}"; exit 1; }
# A0 gate, FIXED: the nemo-side rollback bank must BE the rollback image, not merely exist.
[ -f "$ROLLBACK_BANK" ] || { echo "FLASH_146T_FATAL: nemo-side rollback bank missing: $ROLLBACK_BANK (A0 gate)"; exit 1; }
RBM=$(md5sum "$ROLLBACK_BANK" | cut -c1-12)
echo "  nemo rollback bank: $ROLLBACK_BANK md5=$RBM (expect ${BAK})"
[ "$RBM" = "$BAK" ] || { echo "FLASH_146T_FATAL: rollback bank md5 $RBM != FLASH_BAK ${BAK} (A0 gate)"; exit 1; }
# RAILS AMENDMENT 2026-08-26: the health gate is MEASURED ON 148 -- verify the
# gate instrument is alive and healthy BEFORE touching 146 (attempt 1 fired the
# NAK rail on a dead 148 and voided the run).
RXHP=$(health_rx)
echo "  148 pre-flash health: ${RXHP:-NO RESPONSE}"
echo "$RXHP" | grep -qE 'fsync=[0-9]+' || { echo "FLASH_146T_FATAL: 148 (gate instrument) unreachable/unhealthy -- fix 148 first"; exit 1; }
CUR=$(brd 'md5sum /boot/BOOT.BIN | cut -c1-12')
echo "  146 current image: $CUR (expect ${BAK})"
[ "$DRY" = 1 ] || [ "$CUR" = "$BAK" ] || { echo "FLASH_146T_FATAL: running image is not ${BAK} -- identity in question, STOP"; exit 1; }

echo "=== [2/6] on-board rollback backup, then stage + flash ==="
# 146 has NO /root/BOOT.BIN.${BAK}.bak today (only 433fd8da and 4be9286c). Create it
# from the live /boot/BOOT.BIN, but ONLY after that file's own md5 has been shown to
# be ${BAK} -- verify, then copy, then re-verify the copy; abort on any of the three.
# `| grep -q BAK_OK` would otherwise swallow LIVE_MD5_BAD and leave the operator with a
# generic FATAL; tee the remote output to stderr first so "146 is not running ${BAK}"
# explains itself in the log.
brd "md5sum /boot/BOOT.BIN | grep -q ^${BAK} || { echo LIVE_MD5_BAD; exit 1; }
  cp /boot/BOOT.BIN /root/BOOT.BIN.${BAK}.bak && sync
  md5sum /root/BOOT.BIN.${BAK}.bak | grep -q ^${BAK} && echo BAK_OK" | tee /dev/stderr | grep -q BAK_OK \
  || [ "$DRY" = 1 ] \
  || { echo "FLASH_146T_FATAL: on-board backup create/verify failed (/boot untouched)"; exit 1; }
echo "  on-board backup verified (/root/BOOT.BIN.${BAK}.bak)"
scpput "$BB" root@$A:/boot/BOOT.BIN.new || { echo "FLASH_146T_FATAL: scp failed"; exit 1; }
brd "md5sum /boot/BOOT.BIN.new | grep -q ^${EXP} || exit 1
  mv /boot/BOOT.BIN.new /boot/BOOT.BIN && sync && echo STAGED" | grep -q STAGED \
  || [ "$DRY" = 1 ] \
  || { echo "FLASH_146T_FATAL: stage verify failed -- /boot/BOOT.BIN untouched"; exit 1; }
echo "  staged; rebooting 146"
brd 'sync; ( sleep 2; reboot ) >/dev/null 2>&1 & exit 0'
wait_back || { echo "FLASH_146T_FATAL: 146 not back after 10 min -- PHYSICAL ATTENTION"; exit 2; }

echo "=== [3/6] readback verify (rail) ==="
BOOT=$(brd 'md5sum /boot/BOOT.BIN | cut -c1-12')
echo "  booted image: $BOOT (expected ${EXP})"
[ "$DRY" = 1 ] || [ "$BOOT" = "$EXP" ] || rollback

echo "=== [4/6] FULL bring-up (restore_known_good.sh) + NAK=4 re-check on 148 ==="
bringup /tmp/flash146_bringup.log
grep -E "ARM GATE|BRING-UP COMPLETE|watchdog|BOOT.BIN|nakstat|daemon" /tmp/flash146_bringup.log | tail -14
if [ "$DRY" = 1 ]; then NAK=4; else
  NAK=$(grep -A6 "^--- $RX ---" /tmp/flash146_bringup.log | grep -m1 'nakstat' | grep -oE ': [0-9]+' | tr -dc 0-9); fi
echo "  148 nakstat=$NAK (rail: must be 4)"
[ "$NAK" = "4" ] || { echo "FLASH_146T_NAK_FAIL"; rollback; }

echo "=== [5/6] reset-aware health gate on 148 (rail: fsync>=1100 AND wcnt>=1100; forward link = 146 TX under test) ==="
gate_ok=""
for pass in 1 2; do
  W0=$(( $(read1c0) ))
  HP=$(health_rx)
  W1=$(( $(read1c0) ))
  DW=$(( (W1 - W0) & 0xFFFFFFFF ))
  [ "$DRY" = 1 ] && DW=1
  echo "  148 (gate pass $pass): $HP raw_0x1C0_delta=$DW"
  FS=$(echo "$HP" | grep -oE 'fsync=[0-9]+' | tr -dc 0-9)
  WC=$(echo "$HP" | grep -oE 'wcnt=[0-9]+'  | tr -dc 0-9)
  CL=$(echo "$HP" | grep -oE 'clean=[0-9]+' | tr -dc 0-9)
  if [ -n "$FS" ] && [ -n "$WC" ] && [ "${CL:-0}" -ge 4 ] && [ "$FS" -ge 1100 ] && [ "$WC" -ge 1100 ] && [ "$DW" -gt 0 ]; then
    echo "  HEALTH_GATE_PASS fsync=$FS wcnt=$WC raw_0x1C0_delta=$DW (pass $pass)"; gate_ok=1; break
  fi
  if [ $pass -eq 1 ]; then
    echo "  first-pass health fail (fsync=${FS:-?} wcnt=${WC:-?}) -- ONE re-bring-up (standing amendment)"
    bringup /tmp/flash146_bringup_retry.log
    grep -E "ARM GATE|BRING-UP COMPLETE" /tmp/flash146_bringup_retry.log | tail -2
  fi
done
[ -n "$gate_ok" ] || { echo "FLASH_146T_HEALTH_FAIL fsync=${FS:-?} wcnt=${WC:-?} after re-bring-up"; rollback; }

echo "=== [6/6] (no witness gpio on the TMR lineage -- step intentionally empty) ==="
echo "FLASH_146T_DONE $(date -Is) image=${EXP} on 146, bring-up + gates green"
