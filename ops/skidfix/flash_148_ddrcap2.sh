#!/bin/bash
# flash_148_ddrcap2.sh <md5-12> -- flash 148 with the DDRCAP-v2 image under the standing rails,
# adapted to the 148-ONLY mode-1 campaign (146 is never touched): bring-up + gate = arm148_mode1.sh x2.
#   [1] preconditions: sentinel stopped; current image = 1cd0cd752aa6; on-board rollback copy verified
#   [2] stage + flash (size-checked), reboot, wait back
#   [3] readback md5 == expected, else ROLLBACK
#   [4] two-pass gate: arm148_mode1.sh ARM_OK with fps>=1120 and golden capTAP, twice; else ROLLBACK
#   [5] Tier-2 witness: one 4 MB sel-6 capture decoded with ddrcap2_decode.py --summary, read BEFORE any rollback
#   NO retry loop. Rollback = restore /boot from the on-board copy, reboot, arm148_mode1.sh once, stop.
#
# DRY=1 makes every board-touching action (brd, scpput, gate's arm148_mode1.sh call, wait_back,
# poll_md5_nonempty) print/report as "[dry] ..." and skip the md5-equality FATALs, so the full
# [1/5]..[5/5] sequence can be exercised with zero contact to the board. gate() is explicitly
# DRY-guarded here because arm148_mode1.sh itself has no DRY support (it always ssh's the board)
# -- without this guard DRY=1 would still arm 148 for real.
#
# SENTINEL_STOP ownership (2026-09-02 field finding, x2): the chain must NEVER delete a
# SENTINEL_STOP it did not create itself -- both a DRY run of this script and a reviewer's DRY
# run deleted a controller's manual external hold, and the sentinel then ran a both-board r3
# bring-up. [1/5] now records ownership in SS_MINE: if the file already exists on entry, this
# is an external hold and SS_MINE=0 (never touched, never removed); only if it is ABSENT does
# the chain touch it itself and set SS_MINE=1. A `trap ... EXIT` is installed right after that
# check so ~/modem-status/SENTINEL_STOP is released on EVERY exit path -- success, any FATAL,
# and rollback's own PHYSICAL ATTENTION exit -- but ONLY when SS_MINE=1. Under DRY=1 the file is
# NEVER touched or removed, regardless of whether it exists, and SS_MINE=0 unconditionally, so a
# dry run can never delete a real hold nor leave a phantom one behind.
#
# ssh-readiness (2026-09-01 17:27 real-run finding): wait_back() used to return as soon as PING
# answered, but sshd was not up yet -- the [3/5] readback ssh returned EMPTY 67s after reboot,
# that empty result was (wrongly) treated as a checksum MISMATCH, the chain went to rollback,
# and rollback's own restore-copy ssh ALSO returned empty (same board, same not-ready-yet sshd)
# and correctly FATALed "PHYSICAL ATTENTION before reboot" without rebooting -- but ssh came
# back only 64s later and the readback would have matched. Fix: poll_md5_nonempty() treats an
# EMPTY md5sum readback as "board not reachable yet," not a checksum outcome, and keeps polling
# (10s cadence, bounded) until a non-empty result comes back or the deadline lapses; wait_back()
# uses it after ping succeeds, and [3/5]'s readback uses the same helper directly, so neither
# place false-triggers a rollback on ssh-not-ready-yet. A mismatch is only ever a non-empty,
# different md5. rollback()'s own post-reboot wait is wait_back() itself, so it inherits the
# same ssh-readiness handling automatically.
set -u
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem; D=$ROOT/ops; W=$D/anyssh.sh; A=10.0.0.148
EXP=${1:?usage: flash_148_ddrcap2.sh <md5-12>}; BAK=1cd0cd752aa6
[[ "$EXP" =~ ^[0-9a-f]{12}$ ]] || { echo "FATAL: <md5-12> must be exactly 12 lowercase hex chars (got: '$EXP')"; exit 1; }
BB=$ROOT/images/BOOT.BIN.148.ddrcap2.$EXP
DRY=${DRY:-0}; LOG=$D/skidfix/ddrcap2_flash_$(date +%Y%m%d_%H%M%S).log
say(){ echo "$(date +%T) $*" | tee -a "$LOG"; }
brd(){ if [ "$DRY" = 1 ]; then echo "[dry] $*"; else $W $A "$@" 2>/dev/null | tr -d '\r'; fi; }
# brd_wit: like brd, but bounded (rail: a hung direct_reg_access must not block the chain forever
# with the sentinel stopped). Returns 124 (timeout's own code) on expiry so the caller can log a
# distinct WITNESS_TIMEOUT line instead of treating it as either a normal read or a FATAL.
brd_wit(){ if [ "$DRY" = 1 ]; then echo "[dry] $*"; return 0; fi
  timeout 180 $W $A "$@" 2>/dev/null | tr -d '\r'; return "${PIPESTATUS[0]}"; }
# poll_md5_nonempty: bounded (360s) poll of `md5sum /boot/BOOT.BIN` over ssh. An EMPTY result
# means the board/sshd is not reachable yet (see the note above), not a checksum outcome --
# only a non-empty result is a value to compare. Echoes the last value seen (possibly empty,
# only once the deadline lapses) and returns 0 once non-empty, 1 on deadline. Under DRY, brd()
# always returns a non-empty "[dry] ..." line immediately, so this never sleeps or touches ssh.
poll_md5_nonempty(){
  local t=0 m
  while :; do
    m=$(brd 'md5sum /boot/BOOT.BIN | cut -c1-12')
    if [ -n "$m" ]; then echo "$m"; return 0; fi
    [ "$t" -ge 360 ] && { echo ""; return 1; }
    sleep 10; t=$((t+10))
  done
}
scpput(){ if [ "$DRY" = 1 ]; then echo "[dry] scp $*"; return 0; fi
  SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
wait_back(){ [ "$DRY" = 1 ] && return 0; sleep 45; local n=0; until ping -c1 -W2 $A >/dev/null 2>&1; do sleep 5; n=$((n+5)); [ $n -gt 240 ] && return 1; done; sleep 20
  # ping answering does not mean sshd is up yet -- poll_md5_nonempty bounds the wait for a real
  # ssh readback (360s) before declaring the board back.
  poll_md5_nonempty >/dev/null; }
gate(){
  if [ "$DRY" = 1 ]; then echo "[dry] arm148_mode1.sh (would run for real; DRY never touches the board)"; echo "[dry] ARM_OK fps=1246"; return 0; fi
  local o; o=$(bash "$D/arm148_mode1.sh" 2>&1); echo "$o" | tail -2 | tee -a "$LOG"
  echo "$o" | grep -q ARM_OK || return 1; local f; f=$(echo "$o" | sed -n 's/.*fps=\([0-9]*\).*/\1/p' | tail -1); [ "${f:-0}" -ge 1120 ]; }
rollback(){ say "=== ROLLBACK to $BAK (rail: no retry) ==="
  RBK=$(brd "cp -f /root/BOOT.BIN.$BAK.bak /boot/BOOT.BIN && sync && md5sum /boot/BOOT.BIN | cut -c1-12")
  say "  restore-copy: $RBK"
  if [ "$DRY" != 1 ] && ! echo "$RBK" | grep -q "^$BAK"; then
    say "FLASH_DDRCAP2_FATAL: rollback restore-copy failed (got: '$RBK', expect $BAK) -- PHYSICAL ATTENTION before reboot"; exit 2
  fi
  brd 'sync; (sleep 1; reboot) &'; wait_back || { say "FLASH_DDRCAP2_FATAL: 148 not back after rollback -- PHYSICAL ATTENTION"; exit 2; }
  say "  rollback booted: $(brd 'md5sum /boot/BOOT.BIN | cut -c1-12') (expect $BAK)"; gate || say "  WARN: post-rollback arm not ARM_OK -- operator"
  say "FLASH_DDRCAP2_ROLLED_BACK"; exit 1; }

say "=== [1/5] preconditions ==="
[ -f "$BB" ] && [ "$(md5sum "$BB" | cut -c1-12)" = "$EXP" ] || { say "FATAL: $BB missing or md5 != $EXP"; exit 1; }
if [ "$DRY" = 1 ]; then
  say "[dry] would touch/remove SENTINEL_STOP (DRY never touches it, present or absent, owned or not)"
  SS_MINE=0
elif [ -e ~/modem-status/SENTINEL_STOP ]; then
  SS_MINE=0; say "  SENTINEL_STOP already present (external hold) -- will NOT remove it"
else
  touch ~/modem-status/SENTINEL_STOP; SS_MINE=1; say "  sentinel stopped (SENTINEL_STOP)"
fi
trap '[ "${SS_MINE:-0}" = 1 ] && rm -f ~/modem-status/SENTINEL_STOP' EXIT
CUR=$(brd 'md5sum /boot/BOOT.BIN | cut -c1-12'); say "  148 current image: $CUR (expect $BAK)"
[ "$DRY" = 1 ] || [ "$CUR" = "$BAK" ] || { say "FATAL: current image is not the banked restore point"; exit 1; }
brd "[ -f /root/BOOT.BIN.$BAK.bak ] || cp -f /boot/BOOT.BIN /root/BOOT.BIN.$BAK.bak; md5sum /root/BOOT.BIN.$BAK.bak | cut -c1-12" | tee -a "$LOG" | grep -q "$BAK" || [ "$DRY" = 1 ] || { say "FATAL: on-board rollback copy bad"; exit 1; }
say "=== [2/5] stage + flash ==="
scpput "$BB" root@$A:/root/BOOT.BIN.staged
FL=$(brd 'NB=$(stat -c %s /root/BOOT.BIN.staged 2>/dev/null||echo 0); if [ "$NB" -gt 6000000 ]; then cp -f /root/BOOT.BIN.staged /boot/BOOT.BIN && sync && echo "FLASHED $(md5sum /boot/BOOT.BIN|cut -c1-12)"; else echo "ABORT staged=$NB"; fi')
say "  $FL"; echo "$FL" | grep -q FLASHED || [ "$DRY" = 1 ] || { say "FATAL: flash did not complete; /boot untouched"; exit 1; }
brd 'sync; (sleep 1; reboot) &'; wait_back || rollback
say "=== [3/5] readback verify ==="
BOOT=$(poll_md5_nonempty); say "  booted image: $BOOT (expect $EXP)"; [ "$DRY" = 1 ] || [ "$BOOT" = "$EXP" ] || rollback
say "=== [4/5] two-pass gate (arm148_mode1: ARM_OK, fps>=1120, capTAP golden) ==="
gate || rollback; gate || rollback; say "  GATE_PASS x2"
say "=== [5/5] Tier-2 witness (read BEFORE any rollback): sel6 4 MB, decoded ==="
WOUT=$(brd_wit "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo '0x10C 0x60003' > /sys/kernel/debug/iio/iio:device0/direct_reg_access; sleep 1; cd /tmp && rm -f w.bin && iio_readdev -b 4096 -s 1048576 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/w.bin 2>/dev/null; stat -c %s /tmp/w.bin")
WRC=$?
say "  $WOUT"
if [ "$WRC" = 124 ]; then
  say "WITNESS_TIMEOUT (non-fatal, no rollback): 180s cap hit on the sel6 capture; gate already passed, image stays"
else
  [ "$DRY" = 1 ] || { timeout 180 $W $A 'cat /tmp/w.bin' > "$D/skidfix/ddrcap2_witness_$EXP.bin" 2>/dev/null; python3 "$D/ddrcap2_decode.py" "$D/skidfix/ddrcap2_witness_$EXP.bin" --summary | tee -a "$LOG"; }
fi
if [ "${SS_MINE:-0}" = 1 ]; then say "FLASH_DDRCAP2_OK $EXP (sentinel released)"
else say "FLASH_DDRCAP2_OK $EXP (sentinel untouched -- external hold or DRY)"; fi
