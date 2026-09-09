#!/bin/bash
# radioprobe_go.sh -- SEQ-BIST Task 8a: one radio-process probe = one capture_r3
# forward leg (146 TX -> 148 RX) with an ADRV9002 phy attribute changed on the
# RECEIVING board for the duration of the scored window, then restored.
#
# Pre-registration: two_jup/comb/RADIO_PROBES_PREREG.md (written before any leg).
# Knob enumeration: two_jup/comb/RADIO_KNOBS_148.md (read-only, unit knobs148-8a).
#
# K=V: PROBE=A|B|C   DRY=1(default)   DUR=600   TAG=<tag>   OUT=<dir>
#
# WHY IT IS NOT legrun_go.sh: the attribute has to land AFTER the RF arm and the
# health gate and BEFORE the 600 s window (an arm re-asserts gain_control_mode=
# automatic, bringup_r2r3.sh:75). That is what capture_r3.sh's new RX_ATTR_POKE
# hook does -- same position as the existing LOOP_POKE, section 5c. This wrapper
# calls capture_r3.sh directly with that env, and keeps legrun_go.sh's gate,
# artifact fetch and meta.txt keys verbatim so the probe legs are scored by
# exactly the rule T2/T3 used.
#
# RESTORE IS INSIDE THIS SCRIPT, UNDER A TRAP on EXIT/INT/TERM (systemd stops a
# unit with SIGTERM), so a crash, a wedge or a `systemctl stop` cannot leave 148's
# radio in a probe state. The restore reads back and shouts on mismatch. This
# matters beyond this task: the overnight plan flashes 148 and measures PER after
# these probes, and a board silently left in manual gain would contaminate all of it.
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/comb
TJ=$(cd "$D/.." && pwd)                   # two_jup
W=$TJ/anyssh.sh
DRY=${DRY:-1}
PROBE=${PROBE:?usage: PROBE=A|B|C radioprobe_go.sh}
DUR=${DUR:-600}
LEG=A; DIRN=fwd; RX_IP=10.0.0.148; PEER_IP=10.0.0.146   # forward leg, fixed by the brief
TS=$(date +%Y%m%d_%H%M%S)
TAG=${TAG:-probe$PROBE}
OUT=${OUT:-$D/runs/${TS}_probe${PROBE}_${TAG}}
mkdir -p "$OUT/cap"
log(){ echo "$(date -Is) $*" | tee -a "$OUT/run.log"; }

# ---- the probe definitions (exactly the pre-registration, nothing invented here) ----
# POKE  = what capture_r3.sh's RX_ATTR_POKE applies, in order.
# ORIG  = the value read in step 1 (RADIO_KNOBS_148.md), used ONLY as a fallback if the
#         live before-value could not be recovered from attr_poke.txt. Restore order is
#         the REVERSE of the poke order (gain first, mode last, so the AGC resumes
#         control only after the gain is back).
case "$PROBE" in
  A) POKE="in_voltage0_gain_control_mode=spi in_voltage0_hardwaregain=@keep"
     ORIG="in_voltage0_hardwaregain=34 in_voltage0_gain_control_mode=automatic" ;;
  B) POKE="in_voltage0_agc_tracking_en=0 in_voltage0_bbdc_rejection_tracking_en=0 in_voltage0_rfdc_tracking_en=0 in_voltage0_rssi_tracking_en=0 in_voltage0_quadrature_fic_tracking_en=0"
     ORIG="in_voltage0_quadrature_fic_tracking_en=1 in_voltage0_rssi_tracking_en=1 in_voltage0_rfdc_tracking_en=1 in_voltage0_bbdc_rejection_tracking_en=1 in_voltage0_agc_tracking_en=1" ;;
  C) POKE="in_voltage0_gain_control_mode=spi in_voltage0_hardwaregain=@keep in_voltage0_agc_tracking_en=0 in_voltage0_bbdc_rejection_tracking_en=0 in_voltage0_rfdc_tracking_en=0 in_voltage0_rssi_tracking_en=0 in_voltage0_quadrature_fic_tracking_en=0"
     ORIG="in_voltage0_quadrature_fic_tracking_en=1 in_voltage0_rssi_tracking_en=1 in_voltage0_rfdc_tracking_en=1 in_voltage0_bbdc_rejection_tracking_en=1 in_voltage0_agc_tracking_en=1 in_voltage0_hardwaregain=34 in_voltage0_gain_control_mode=automatic" ;;
  D) # P-D: the SAME knob set, on 146 (the TRANSMITTING board). See RADIO_KNOBS_146.md --
     # 146's TX tracking cals are ALL already 0, so the briefed TX probe is null by
     # construction; its RX chain is what is actually running. Lands via PEER_ATTR_POKE.
     POKE="in_voltage0_gain_control_mode=spi in_voltage0_hardwaregain=@keep in_voltage0_agc_tracking_en=0 in_voltage0_bbdc_rejection_tracking_en=0 in_voltage0_rfdc_tracking_en=0 in_voltage0_rssi_tracking_en=0 in_voltage0_quadrature_fic_tracking_en=0"
     ORIG="in_voltage0_quadrature_fic_tracking_en=1 in_voltage0_rssi_tracking_en=1 in_voltage0_rfdc_tracking_en=1 in_voltage0_bbdc_rejection_tracking_en=1 in_voltage0_agc_tracking_en=1 in_voltage0_hardwaregain=34 in_voltage0_gain_control_mode=automatic"
     POKE_IP=$PEER_IP; POKE_ENV=PEER_ATTR_POKE; POKE_FILE=attr_poke_peer.txt ;;
  *) echo "PROBE must be A, B, C or D" >&2; exit 2;;
esac
POKE_IP=${POKE_IP:-$RX_IP}; POKE_ENV=${POKE_ENV:-RX_ATTR_POKE}; POKE_FILE=${POKE_FILE:-attr_poke.txt}

RESTORE_DONE=0
restore(){
  # Idempotent, safe to call twice (trap + explicit call). Never runs in DRY.
  [ "$RESTORE_DONE" = 1 ] && return 0
  RESTORE_DONE=1
  if [ "$DRY" = 1 ]; then log "[dry] restore skipped (no board contact)"; return 0; fi
  # Prefer the LIVE before-values the hook recorded; fall back to the step-1 values.
  local plan="" src="attr_poke.txt"
  if [ -s "$OUT/cap/$POKE_FILE" ]; then
    # reverse order, first whitespace token of before='...'
    plan=$(grep -o "ATTR_POKE [^ ]* before='[^']*'" "$OUT/cap/$POKE_FILE" \
           | sed -E "s/ATTR_POKE ([^ ]+) before='([^ ']+).*/\1=\2/" | tac | tr '\n' ' ')
  fi
  if [ -z "$plan" ]; then plan="$ORIG"; src="ORIG-fallback(step1)"; log "RESTORE WARNING: no live before-values in attr_poke.txt, using $src"; fi
  log "RESTORE ($src) on $POKE_IP: $plan"
  $W "$POKE_IP" "P=\$(for d in /sys/bus/iio/devices/iio:device*; do case \"\$(cat \$d/name 2>/dev/null)\" in *adrv9002*phy*) echo \$d;; esac; done)
    [ -n \"\$P\" ] || { echo 'RESTORE FATAL: no adrv9002 phy'; exit 9; }
    for kv in $plan; do a=\${kv%%=*}; v=\${kv#*=}
      echo \"\$v\" > \$P/\$a 2>&1 && w=ok || w=WRITE_FAIL
      n=\$(cat \$P/\$a 2>&1)
      echo \"  ATTR_RESTORE \$a want='\$v' write=\$w after='\$n'\"
    done" > "$OUT/attr_restore.txt" 2>&1
  cat "$OUT/attr_restore.txt" | tee -a "$OUT/run.log"
  # verify: every restored attribute's read-back must start with the wanted value
  RESTORE_OK=1
  while IFS= read -r line; do
    a=$(echo "$line" | sed -E "s/.*ATTR_RESTORE ([^ ]+) want.*/\1/")
    v=$(echo "$line" | sed -E "s/.*want='([^']*)'.*/\1/")
    n=$(echo "$line" | sed -E "s/.*after='([^']*)'.*/\1/" | awk '{print $1}')
    # D-8a-1: compare NUMERICALLY when both sides parse as numbers. The sysfs gain
    # reads back as '34.000000 dB' while the fallback plan wants '34' -- string-equal
    # called that a MISMATCH on P-C att.1 when the board was in fact at its original
    # value. A false restore alarm is as bad as a missed one: it trains the reader to
    # ignore the line that exists to be believed.
    if [ "$v" = "$n" ]; then :
    elif awk -v a="$v" -v b="$n" 'BEGIN{exit !(a+0==b+0 && a ~ /^-?[0-9.]+$/ && b ~ /^-?[0-9.]+$/)}'; then
      log "restore ok (numeric) $a want='$v' after='$n'"
    else RESTORE_OK=0; log "!!! RESTORE MISMATCH $a want='$v' after='$n'"; fi
  done < <(grep "ATTR_RESTORE" "$OUT/attr_restore.txt" 2>/dev/null)
  if [ "$RESTORE_OK" = 1 ]; then log "RESTORE VERIFIED: all attributes back to their before-values"
  else log "!!! RESTORE NOT VERIFIED -- 148 MAY BE LEFT IN A PROBE STATE, see attr_restore.txt"; fi
  echo "attr_restored=$RESTORE_OK" >> "$OUT/meta_restore.txt"
}
trap restore EXIT INT TERM

log "probe=$PROBE leg=$LEG dir=$DIRN rx=$RX_IP peer=$PEER_IP dur=$DUR dry=$DRY"
log "poke on $POKE_IP via $POKE_ENV: $POKE"
log "orig(step1 fallback): $ORIG"

SINK_ENV="QPSK_FAILHDR=/dev/shm/failhdr.bin QPSK_TXLOG=/dev/shm/txlog.bin QPSK_TXLOG_USR1=1"
CAP_ENV=("DAEMON_ENV_A=$SINK_ENV" "DAEMON_ENV_B=$SINK_ENV" "$POKE_ENV=$POKE")

if [ "$DRY" = 1 ]; then
  log "[dry] ${CAP_ENV[*]} $TJ/capture_r3.sh $LEG -d $DUR -o $OUT/cap"
  for f in frames.bin frames_peer.bin txlog.bin txlog_peer.bin; do head -c 48000 /dev/urandom > "$OUT/cap/$f"; done
  for f in failhdr.bin failhdr_peer.bin; do head -c 12000 /dev/urandom > "$OUT/cap/$f"; done
  { echo "  phy=/sys/bus/iio/devices/iio:device2"
    for kv in $POKE; do a=${kv%%=*}; v=${kv#*=}
      echo "  ATTR_POKE $a before='DRYVAL dB' want='$v' write=ok after='$v'"; done
  } > "$OUT/cap/$POKE_FILE"
  RATE_PRE=1180; RATE_POST=1150; WEDGE_NOTE="healthy crc=99% rate=${RATE_POST}f/s"; CAP_EXIT=0
  WD_RELAUNCH_RX=0; WD_RELAUNCH_PEER=0
else
  env "${CAP_ENV[@]}" "$TJ/capture_r3.sh" "$LEG" -d "$DUR" -o "$OUT/cap" > "$OUT/capture_r3.log" 2>&1
  CAP_EXIT=$?
  RATE_PRE=$(grep -m1 "health try" "$OUT/capture_r3.log" | grep -oE "rate [0-9]+" | grep -oE "[0-9]+" || echo 0)
  RATE_POST=$(grep "health try" "$OUT/capture_r3.log" | tail -1 | grep -oE "rate [0-9]+" | grep -oE "[0-9]+" || echo 0)
  WEDGE_NOTE=$(grep -oE "wedge_verdict=.*" "$OUT/cap/meta.txt" 2>/dev/null | head -1)
  SCPGET(){ SSH_ASKPASS="$TJ/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>>"$OUT/scp_err.txt"; }
  SCPGET root@"$RX_IP":/dev/shm/failhdr.bin  "$OUT/cap/failhdr.bin"      || log "WARN: failhdr.bin ($RX_IP) fetch failed"
  SCPGET root@"$RX_IP":/dev/shm/txlog.bin    "$OUT/cap/txlog.bin"        || log "WARN: txlog.bin ($RX_IP) fetch failed"
  SCPGET root@"$PEER_IP":/dev/shm/failhdr.bin "$OUT/cap/failhdr_peer.bin" || log "WARN: failhdr.bin ($PEER_IP) fetch failed"
  SCPGET root@"$PEER_IP":/dev/shm/txlog.bin   "$OUT/cap/txlog_peer.bin"   || log "WARN: txlog.bin ($PEER_IP) fetch failed"
  SCPGET root@"$RX_IP":/dev/shm/watchdog.log  "$OUT/cap/watchdog_rx.log"  || log "WARN: watchdog.log ($RX_IP) fetch failed"
  SCPGET root@"$PEER_IP":/dev/shm/watchdog.log "$OUT/cap/watchdog_peer.log" || log "WARN: watchdog.log ($PEER_IP) fetch failed"
  WD_RELAUNCH_RX=$(grep -c "relaunch" "$OUT/cap/watchdog_rx.log" 2>/dev/null)
  WD_RELAUNCH_PEER=$(grep -c "relaunch" "$OUT/cap/watchdog_peer.log" 2>/dev/null)
fi
WD_RELAUNCH_RX=${WD_RELAUNCH_RX:-0}; WD_RELAUNCH_PEER=${WD_RELAUNCH_PEER:-0}

# restore NOW (before scoring), so the radio is out of the probe state as early as
# possible; the trap re-call is a no-op.
restore

# ---- legrun_go.sh's gate, verbatim ----
GATE_PASS=0
if [ "${RATE_PRE:-0}" -ge 1000 ] 2>/dev/null && [ "${RATE_POST:-0}" -ge 1000 ] 2>/dev/null; then GATE_PASS=1; fi
if [ "$WD_RELAUNCH_RX" != 0 ] || [ "$WD_RELAUNCH_PEER" != 0 ]; then GATE_PASS=0; fi
[ "${CAP_EXIT:-0}" = 0 ] || GATE_PASS=0
case "$WEDGE_NOTE" in *WEDGE*|*"NOT usable"*) GATE_PASS=0;; esac

ATTR_BEFORE=$(grep -o "ATTR_POKE [^ ]* before='[^']*'" "$OUT/cap/$POKE_FILE" 2>/dev/null | sed -E "s/ATTR_POKE ([^ ]+) before='([^']*)'/\1=\2/" | tr '\n' ';')
ATTR_AFTER=$(grep -o "ATTR_POKE [^ ]* .* after='[^']*'" "$OUT/cap/$POKE_FILE" 2>/dev/null | sed -E "s/ATTR_POKE ([^ ]+) .* after='([^']*)'/\1=\2/" | tr '\n' ';')
ATTR_WRITE_FAILS=$(grep -c "write=WRITE_FAIL" "$OUT/cap/$POKE_FILE" 2>/dev/null); ATTR_WRITE_FAILS=${ATTR_WRITE_FAILS:-0}
ATTR_RESTORED=$(grep -o "attr_restored=[01]" "$OUT/meta_restore.txt" 2>/dev/null | tail -1 | cut -d= -f2)

{
  echo "leg=$LEG dir=$DIRN rx=$RX_IP peer=$PEER_IP dur=$DUR dry=$DRY"
  echo "probe=$PROBE"
  echo "poke=$POKE"
  echo "attr_before=$ATTR_BEFORE"
  echo "attr_after=$ATTR_AFTER"
  echo "attr_write_fails=$ATTR_WRITE_FAILS"
  echo "attr_restored=${ATTR_RESTORED:-unknown} (1 = every attribute read back at its before-value)"
  echo "rxm_148= rxm_146= drain_148= drain_146="
  echo "resolved: ${CAP_ENV[*]}"
  echo "capture_r3_exit=$CAP_EXIT"
  echo "wedge_verdict=$WEDGE_NOTE"
  echo "deliver_rate_pre=$RATE_PRE deliver_rate_post=$RATE_POST deliver_rate_gate_pass=$GATE_PASS (need >=1000 f/s both AND zero watchdog relaunches)"
  echo "watchdog_relaunch_rx=$WD_RELAUNCH_RX watchdog_relaunch_peer=$WD_RELAUNCH_PEER"
  echo "ts=$(date -Is)"
} > "$OUT/meta.txt"
cat "$OUT/meta.txt"

if [ "$GATE_PASS" = 1 ]; then echo "PROBERUN_DONE $OUT"; else
  echo "PROBERUN_GATE_FAIL $OUT (rate < 1000 f/s, a watchdog relaunch, or a wedge -- UNINFORMATIVE unless the pre-registered P-A third branch applies)"
  exit 3
fi
