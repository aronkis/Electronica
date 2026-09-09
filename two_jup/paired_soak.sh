#!/bin/bash
# =============================================================================
# paired_soak.sh -- ALTERNATING paired FROZEN-class soak, TMR vs unfixed.
#
# WHY: every FROZEN comparison so far has been confounded by time of day. The
# original P1 pair ran TMR in the morning and unfixed in the evening; today's
# TMR arm (FROZEN 2 in 3.50 h) and last night's unfixed arm (FROZEN 3 in 3.36 h)
# are ~18 h apart on a channel that demonstrably moved by more than the effect
# being measured. Alternating short blocks puts both arms under the same channel
# drift, which is the only way the delta means anything.
#
# SCHEDULE: 75 min soak per block + ~12 min changeover, alternating
#   TMR(433fd8da) / unfixed(ee453c76) until 05:00 -> 6 blocks = 3 COMPLETE pairs.
#   (90 min blocks would fit only 5 = 2 pairs + an unpaired spare.) Then a capping
#   perf + acceptance-PER run on TMR with ARQ ON, then the final restore.
#
# INVARIANTS:
#   - collect the CSV to the host BEFORE every flash (/dev/shm does not survive a
#     reboot; a lost block is unrecoverable)
#   - verify image md5 after every flash; a mismatch skips the block rather than
#     soaking an unknown image and silently mislabelling the arm
#   - ARQ OFF on both arms -- today's TMR arm ran ARQ off, so the reference must too
#   - 146 only. 148 is NEVER FLASHED. During the rotation nothing rebuilds it. The
#     capping run does go through capture_r3.sh, which rebuilds both boards -- that is
#     safe only because capture_r3.sh now auto-detects the deployed NAK-stat counter
#     and re-applies -DQPSK_ARQ_NAKSTAT, then verifies it survived. The rotation warns
#     if 148's daemon stops matching 01499916, and the capping run re-checks after.
#   - the poller launch is its own isolated ssh call: folding it into a multi-command
#     block silently fails to detach (hit twice, cost a soak start each time)
#   - finish on the TMR image with the link up, whatever happens
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
OUT=$D/soakdata/paired_soak_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"   # /mnt/onetb = persistent
IP=10.0.0.146
BLOCK=${BLOCK:-4500}                      # 75 min soak/block -> 6 blocks = 3 COMPLETE pairs
                                          # (90 min would fit only 5 = 2 pairs + a spare)
ROT_END=${ROT_END:-$(date -d 'tomorrow 05:00' +%s)}   # rotation stops here...
DEADLINE=$ROT_END                                     # ...leaving ~1 h for the capping run
WARMUP=${WARMUP:-60}                      # s of post-bring-up RF settle to MARK and exclude
# Arm A defaults to the COMBINED image, but that build carries TMR *plus* loop-tune,
# canaries and forensic taps -- it cannot isolate TMR. Override to b7aa58ba (TMR-only)
# for the comparison that actually does. RESTORE_* is what the rig is left on at the end.
IMG_TMR=${IMG_A:-$S/BOOT.BIN.t90_433fd8dab393};  MD5_TMR=${MD5_A:-433fd8dab393}
IMG_UNF=${IMG_B:-$S/BOOT.BIN.t88_ee453c76};      MD5_UNF=${MD5_B:-ee453c769730}
RESTORE_IMG=${RESTORE_IMG:-$S/BOOT.BIN.t90_433fd8dab393}
RESTORE_MD5=${RESTORE_MD5:-433fd8dab393}
ARM_A_NAME=${ARM_A_NAME:-tmr}
SKIP_CAP=${SKIP_CAP:-0}
log(){ echo "[$(date +%m-%d\ %H:%M:%S)] $*" | tee -a "$OUT/soak.log"; }
scpget(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
          -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
          -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

collect(){   # $1 = destination basename
  $W $IP 'pgrep -f "[s]tallpoll" >/dev/null && pkill -f "[s]tallpoll"; sleep 1; echo stopped' >/dev/null 2>&1
  scpget root@$IP:/dev/shm/stallcatch.csv "$OUT/$1.csv"
  if [ -s "$OUT/$1.csv" ]; then log "  collected $(wc -l < "$OUT/$1.csv") rows -> $1.csv"
  else log "  WARNING: no rows collected for $1"; fi
  $W $IP 'rm -f /dev/shm/stallcatch.csv' >/dev/null 2>&1
}

# rescue whatever the in-flight soak has already gathered before we disturb it
log "=== paired soak starting; deadline $(date -d @$DEADLINE +'%m-%d %H:%M') ==="
log "rescuing the in-flight unfixed soak first"
collect "block00_unfixed_partial"

N=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  REMAIN=$(( DEADLINE - $(date +%s) ))
  [ "$REMAIN" -lt 1800 ] && { log "under 30 min to deadline -- stopping the rotation"; break; }
  USE=$(( BLOCK < REMAIN - 600 ? BLOCK : REMAIN - 600 ))
  N=$(( N + 1 ))
  if [ $(( N % 2 )) -eq 1 ]; then ARM=$ARM_A_NAME; IMG=$IMG_TMR; WANT=$MD5_TMR
  else                            ARM=unfixed; IMG=$IMG_UNF; WANT=$MD5_UNF; fi
  log "--- block $N: $ARM  (${USE}s soak) ---"

  CUR=$($W $IP 'md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-12' 2>/dev/null)
  if [ "$CUR" = "$WANT" ]; then
    log "  already on $ARM ($CUR) -- no flash needed"
  else
    log "  flashing $ARM ($WANT), current=$CUR"
    SUFFIX=.paired ./deploy_image.sh $IP "$IMG" > "$OUT/flash_b$N.log" 2>&1
    CUR=$($W $IP 'md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-12' 2>/dev/null)
    if [ "$CUR" != "$WANT" ]; then
      log "  FLASH VERIFY FAILED (got $CUR want $WANT) -- skipping block $N"
      continue
    fi
    log "  flash verified: $CUR"
  fi

  unset DAEMON_EXTRA DAEMON_ENV
  SSI146="5 4" RXQ=1 bash "$D/bringup_r2r3.sh" r3 > "$OUT/bringup_b$N.log" 2>&1
  if ! grep -q "BRING-UP COMPLETE" "$OUT/bringup_b$N.log"; then
    log "  bring-up FAILED -- retrying once"
    SSI146="5 4" RXQ=1 bash "$D/bringup_r2r3.sh" r3 > "$OUT/bringup_b${N}r.log" 2>&1
    grep -q "BRING-UP COMPLETE" "$OUT/bringup_b${N}r.log" || { log "  bring-up failed twice -- skipping block"; continue; }
  fi
  log "  bring-up ok: $(grep -oE 'ARM GATE PASS \(try [0-9]+\)' "$OUT"/bringup_b$N*.log | tail -1)"

  NB=$($W 10.0.0.148 'md5sum /root/host_app_k5/qpsk_tun | cut -c1-8' 2>/dev/null)
  [ "$NB" = "01499916" ] || log "  WARNING: 148 daemon is $NB, expected 01499916 (counter may be gone)"

  # isolated launch -- see header
  $W $IP "setsid nohup /root/stallpoll.sh $USE </dev/null >/dev/shm/stallpoll.log 2>&1 & echo ok" >/dev/null 2>&1
  sleep 12
  if $W $IP 'pgrep -f "[s]tallpoll" >/dev/null && echo up' 2>/dev/null | grep -q up; then
    # MARK the warmup window: the RF-enable transient (measured: three ~1 s bursts at
    # 7.9/9.8/11.6 s) must not count as mutes. Recorded, not silently dropped -- the
    # classifier excludes it via --skip-s and reports what was excluded.
    printf 'block=%d\narm=%s\nimage=%s\npoller_start_epoch=%s\nwarmup_s=%d\n' \
      "$N" "$ARM" "$WANT" "$(date +%s)" "$WARMUP" > "$OUT/block$(printf %02d $N)_$ARM.meta"
    log "  poller running, soaking ${USE}s (first ${WARMUP}s marked as RF warmup)"
  else
    log "  POLLER FAILED TO START -- skipping block $N"; continue
  fi

  END=$(( $(date +%s) + USE + 60 ))
  while [ "$(date +%s)" -lt "$END" ]; do
    $W $IP 'pgrep -f "[s]tallpoll" >/dev/null && echo up' 2>/dev/null | grep -q up || break
    sleep 60
  done
  collect "block$(printf %02d $N)_$ARM"
done

# ---------------- capping run: TMR image, ARQ ON, perf + acceptance-grade PER ----
if [ "$SKIP_CAP" = 1 ]; then log "=== rotation done; capping run SKIPPED (SKIP_CAP=1) ==="; else
log "=== rotation done; capping run on TMR with ARQ ON ==="
CUR=$($W $IP 'md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-12' 2>/dev/null)
if [ "$CUR" != "$MD5_TMR" ]; then
  log "  flashing TMR for the capping run (current $CUR)"
  SUFFIX=.paired_cap ./deploy_image.sh $IP "$IMG_TMR" > "$OUT/flash_cap.log" 2>&1
  CUR=$($W $IP 'md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-12' 2>/dev/null)
fi
if [ "$CUR" = "$MD5_TMR" ]; then
  log "  on TMR ($CUR); bring-up with ARQ ON"
  DAEMON_EXTRA="-A" SSI146="5 4" RXQ=1 bash "$D/bringup_r2r3.sh" r3 > "$OUT/bringup_cap.log" 2>&1
  if grep -q "BRING-UP COMPLETE" "$OUT/bringup_cap.log"; then
    log "  --- sustained forward goodput (perf_ceiling.sh, no build path, counter safe) ---"
    bash "$D/perf_ceiling.sh" fwd > "$OUT/perf_ceiling.log" 2>&1
    grep -iE "mbit|bps|ceiling|rung" "$OUT/perf_ceiling.log" | tail -8 | tee -a "$OUT/soak.log"
    log "  --- acceptance-grade PER, ARQ ON (capture_r3 guard preserves the 148 counter) ---"
    DAEMON_EXTRA="-A" bash "$D/acceptance_rxq.sh" 3 > "$OUT/acceptance_cap.log" 2>&1
    sed -n '/=== ACCEPTANCE/,$p' "$OUT/acceptance_cap.log" | tail -12 | tee -a "$OUT/soak.log"
    log "  --- 148 counter still live after the capping run? ---"
    $W 10.0.0.148 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "nakstat:" \
      && echo "  148 NAK-stat counter PRESENT" || echo "  148 NAK-stat counter LOST"
    grep -m1 "nakstat:" /dev/shm/qpsk_tun.log 2>/dev/null' 2>/dev/null | tee -a "$OUT/soak.log"
  else
    log "  capping bring-up FAILED -- skipping perf/PER"
  fi
else
  log "  could not get onto TMR for the capping run -- skipping"
fi

fi
log "=== restoring $RESTORE_MD5 and leaving the link up ==="
CUR=$($W $IP 'md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-12' 2>/dev/null)
if [ "$CUR" != "$RESTORE_MD5" ]; then
  SUFFIX=.paired_end ./deploy_image.sh $IP "$RESTORE_IMG" > "$OUT/flash_final.log" 2>&1
fi
unset DAEMON_EXTRA DAEMON_ENV
SSI146="5 4" RXQ=1 bash "$D/bringup_r2r3.sh" r3 > "$OUT/bringup_final.log" 2>&1
log "final image: $($W $IP 'md5sum /boot/BOOT.BIN|cut -c1-12' 2>/dev/null)  $(grep -oE 'ARM GATE PASS \(try [0-9]+\)' "$OUT/bringup_final.log" | tail -1)"
log "=== artifacts in $OUT ==="
ls "$OUT"/*.csv 2>/dev/null | sed 's/^/  /' | tee -a "$OUT/soak.log"
